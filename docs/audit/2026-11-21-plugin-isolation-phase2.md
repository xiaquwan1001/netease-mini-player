# 2026-11-21 插件运行期隔离二期评估（README §4 第 11 项）

> 问题：线程内 QuickJS 沙箱（8s interrupt + 32MB 内存 + 512KB 栈 + 8 请求预算）之外的
> 「进程外隔离」该怎么做、什么时候做。本文只基于仓库代码与既有文档事实，不编造 LX 生态行为。
> 写法对齐 `docs/audit/2026-11-21-plugin-android-crosscompile.md`（判据/成本/风险/推荐）。

## 1. 风险判据（带代码位置）

### ① Core 唯一一把锁的阻塞面

`PluginHost` 是 `Core` 的字段，`Core` 的所有 FFI 调用走同一把锁（`ncm-ffi` 的 `api.rs`
`with_provider`/`routed_call` 经由 `Core` 单实例）。插件调用本身在 provider 的 worker 线程
上跑（`ncm-plugin/src/worker.rs` 专属线程 + oneshot），**锁持有期不含脚本执行**；但以下 FFI
站点在持锁期间会做与插件宿主相关的同步工作：

| 站点 | 持锁期间发生什么 | 阻塞风险 |
|---|---|---|
| `Core::route_decision`（`ncm-service/src/plugins/host.rs::route_plan` → `PluginHost::route_plan`） | `ids()` / `provider(id).supports(cap)` / `is_active()`，锁内查注册表 | 小（纯内存），但每次取链都走一遍 |
| `PluginHost::summaries / failures / rejected / status / sources`（host.rs） | 遍历注册表 + `declared_sources()`（**已在装载期算好并缓存在 `ScriptProvider.declared_sources` 字段**，不再每次 eval `__lxSends()`；见「勘误 2026-11-21」） | 小（纯内存遍历）；`PluginHost::take_logs` 头注释仍强调「拉取要拿 Core 的唯一一把锁，别轮询」 |
| `PluginHost::set_enabled / set_root / rescan / enable / disable / install_source`（host.rs） | `rebuild()` ⇒ `registry.scan()` ⇒ 装载（`ScriptProvider::load` 装载预算 8s，`recv_timeout`） | **最大**：`rescan`/`install_source` 锁内全量重扫 + 逐插件装载，期间所有其它 FFI 域调用排队 |
| `PluginHost::enable/disable` 之外的**常规取链** `song_url` | 插件 provider 的 oneshot `recv` 是异步等待（worker 线程执行脚本），**不持 Core 锁** | 小（**已核实 2026-11-21**：`ncm-ffi/src/api.rs:346` `routed_call` 只在花括号作用域内取判定，guard 在 `call_routed(...).await` 之前就已释放；`api.rs:330` `with_provider` 同样只取 `Arc` 后立即释放 ⇒ 脚本执行期间没有 Core 锁） |

结论：死循环脚本被 8s interrupt 限死在**worker 线程**，不会直接占锁；真正的锁内阻塞面
只剩 `rescan`/`install_source` 的锁内装载（最多 8s × 插件数）。
**已核实（2026-11-21，读码）**：`ncm-ffi` 的取链入口**不**整段持 Core 锁 —— `api.rs:346`
`routed_call` 把 `route_decision` 关在一个块里，guard 在 `call_routed(...).await` 之前释放
（future 自带 provider `Arc`）；`api.rs:330` `with_provider` 亦然。所以死循环脚本被 8s
interrupt 限死在 worker 线程，**不会**阻塞其它域 FFI。仍然成立的锁内阻塞面只有
「`rescan`/`install_source` 的装载」一处（上表第 3 行）。
剩余待实测：死循环 fixture 下 `search` 的墙钟延迟（确认 worker 线程之外确实无锁）。

**勘误（2026-11-21 落地切片 B/C 时读码）**：上一版把 `sources()` 也列为锁内 JS eval，实际不是 ——
`worker.rs` 在 `ScriptProvider::load` 里只调一次 `engine.declared_sources()`，结果存进
`declared_sources: Vec<String>` 字段，之后 `Provider::declared_sources()` 只 clone 那个 Vec。
`ScriptEngine::declared_sources()`（eval 那一份）只在装载期和 `examples/android_smoke` 里用。

### ② panic 传播面

- 沙箱路径：脚本错误一律收敛成 `PluginError` → `ProviderError`（`sandbox.rs` + `error.rs`），
  不 panic；宿主 native 闭包失败走 `{"__error"}` 信封（`sandbox.rs` install 注释）。
- 真正的 panic 面：rquickjs 的 `JS_FreeRuntime` 断言（Context/Runtime 析构顺序错 ⇒ SIGABRT，
  `sandbox.rs` 字段顺序注释）——属于我们自己的代码纪律，不是脚本可触发面。
- `ScriptProvider::Drop` 不 join（`worker.rs`），避免析构阻塞到超时预算结束。
- 子进程方案下 panic/abort 被进程边界吸收，宿主只见「子进程退出」⇒ 这是方案 c/d 的核心收益。

### ③ 预算在真实起播路径上的时序影响

起播链路：Dart 取链点（`playback_coordinator` 预取/播放、`song_action_wiring` 下载）→
FFI `song_url` → `call_routed`（`route.rs`）→ 插件 `song_url`（worker 线程，8s 预算）→
失败才回落内置（`call_routed` 只在**插件侧失败**时回落，`route.rs` 头注释「回落边界」）。

时序影响：
- 插件命中且正常：脚本内若干次 `lx.request`（≤8 次/调用），每次受 transport 的连接/读超时
  约束（`ReqwestTransport` 复用 service 口径），总墙钟可到 8s 预算顶——**起播延迟直接叠加**；
- 插件超时：8s 后 `Timeout` → 回落内置 provider，起播再多等一次内置取链（约再 +内置耗时）；
  最坏起播 ≈ 8s + 内置取链耗时。**这是现状方案最大的产品级风险**（不是安全风险）。
- 预取路径同样受 8s 界限；`setTimeout` 泵用 `thread::sleep`（1–25ms 浅睡）推进（`sandbox.rs`
  `drive_promises`）， worker 线程繁忙不影响宿主其它线程。

### ④ Android 前台优先级 / ANR 面

- 脚本执行在普通 Rust 线程（JNI 附属线程之外），不直接持主线程；QuickJS 是纯 CPU +
  `thread::sleep`，无 Binder 同步等锁。
- ANR 面已核实（2026-11-21）：插件 FFI **全是 async**（`api/plugin.rs` 无 `#[frb(sync)]`；
  Dart 侧是 `Future<…>` + `frb_generated.dart` 的 `executeNormal` ⇒ 走 flutter_rust_bridge
  的 worker 线程池，**不在 Dart/Android 主线程同步执行**）。因此「点重扫 ⇒ 主线程通道被占 ⇒
  input dispatch ANR」这条**不成立**；真实影响只是 frb worker 池被占用期间其它 FFI 排队
  （Dart 层 `await` 挂起，非 ANR），以及 8s×N 的用户可感知等待。
- 仍然成立的产品级影响：8s 取链超时 + 回落内置的叠加耗时让 Media3 起播路径空转，用户可感
  卡顿（非 ANR）。剩余待实测：Android 上死循环插件期间 `adb logcat` 线程名与 Choreographer
  跳帧，确认无跨线程同步等待。

## 2. 方案对比

| 判据 | a) 现状（线程内沙箱+收紧预算） | b) 独立线程+自带 runtime+有界队列（不共享 Core 锁） | c) 子进程+IPC | d) Android isolatedProcess + 桌面子进程 |
|---|---|---|---|---|
| **隔离强度** | 中：CPU/内存/栈/请求有硬界；无文件/网络直访；但与宿主同进程同地址空间，rquickjs 的 C 代码若有 CVE 可被打穿 | 同 a（还是线程内）+ 把「锁内装载/eval」移出 Core 锁，**消除阻塞面** | 强：进程边界吸收 panic/abort/CPU 抢占；内存按 OS 上限 | 最强：Android 沙箱级（无网络默认拒）、桌面用户级子进程 |
| **改动面（文件级）** | `sandbox.rs`（调 `SandboxConfig` 默认值） | `worker.rs`（队列有界 + 拒绝策略）、`host.rs`（装载移到锁外、`sources()` 去掉锁内 eval 或缓存） | 新 crate `ncm-plugin-proc` + `worker.rs` 分叉 + FFI 序列化层；IPC 帧、超时/重启策略 | c 的全部 + Android 侧 Kotlin AIDL 服务 + gradle 打包双产物 + 三端分叉的启动/生命周期管理 |
| **构建/打包影响** | 无 | 无（仍是进程内线程） | Android 可行但子进程要打包独立可执行或 `app_process` 入口（NDK 下可执行文件打包进 APK jniLibs 属非常规路径，**待验证** Play/厂商兼容性） | Android `isolatedProcess` 服务是标准机制（manifest `android:isolatedProcess="true"`），但**只能跑 Java/Kotlin 代码**——QuickJS 在 Rust 侧，要么 Android 退回 JS 引擎用 Kotlin 实现（重写整个 lx 兼容层），要么放弃 isolatedProcess 回到 c 的子进程形态；三端双实现成本最高 |
| **延迟/内存成本** | 0 额外；最坏起播 8s+回落 | 0 额外内存（同进程）；消除锁排队延迟 | 每插件一个进程：约 5–10MB RSS + IPC 序列化（每请求 2 次 pipe 往返，微秒~毫秒级）；进程冷启动 50–200ms | d 同 c + Android 服务绑定往返更慢；双实现维护内存成本最大 |
| **失败模式** | 脚本把 8s 预算吃满 ⇒ 起播 8s 等待；rquickjs C 层 bug 同进程崩 | 同 a 的安全强度不变；队列满时的拒绝策略要定义（现状等价于无界 oneshot） | 子进程死循环/崩 ⇒ 检测+重启+回落内置；IPC 半开连接；僵尸进程 | d：isolatedProcess 被系统随时杀 ⇒ 重连风暴；双实现行为漂移（同一脚本两端结果不一致） |

## 3. 推荐路径与切片

**推荐：先落 b（把装载/eval 移出 Core 锁 + 有界队列），把「锁阻塞面」这个当前唯一已证实的
产品级风险消掉；进程外隔离（c）推迟到「有真实插件生态、出现 rquickjs C 层不可信风险或
内存逃逸实例」时再做；d 明确不做**（Android isolatedProcess 跑不了 Rust QuickJS，双实现
成本远超收益，与上一份 Android 交叉编译审计「进程外隔离三端统一放二期」口径一致）。

切片（每片可独立验收，不动 UI）：

1. **切片 A：锁面收敛（已落，v0.36.0）**——落地形态与本文初稿的预案不同，取更小的一刀：
   ```
   Core.plugin_host: Arc<RwLock<PluginHost>>      // plugins::PluginHostHandle
   ncm-ffi: static PLUGIN: OnceLock<PluginHostHandle>   // init() 时与 CORE 填同一个 Arc
   ```
   插件 FFI 入口（18 个）**不再取 `CORE` 锁**，改为 `plugin_host()?` 拿句柄再 `read()/write()`：
   读类取读锁（并发互不阻塞），写类（`rescan/install_*/enable/disable/uninstall/set_enabled/
   set_root/set_route_mode`）取写锁并彼此串行。`Core` 侧的插件方法保留原签名，内部改走
   `plugin_host_read()/plugin_host_write()`（`&mut` 方法照样能调）。
   锁序纪律：允许 `Core 锁 -> 插件句柄`，**禁止**反向（插件 FFI 一个都不再调 `core()`）。
   判据用例：`ncm-service` `plugins::route_tests::plugin_handle_does_not_hold_the_core_lock_while_loading`
   （另一线程持写锁 300ms 模拟装载，主线程取 `Core` 锁 < 200ms；改造前必红）。
   **残留（A2 候选，未做）**：`routed_call` 仍在 `CORE` 锁内做 `route_decision`，而后者要取插件
   句柄**读锁** ⇒ 重扫（写锁，最多 8s×N）进行中，取链/搜索的**判定**会等。修法：把判定快照
   （`RouteDecision` 级别的只读视图）在重扫结束时缓存成 `Arc<...>`，读路径不再进句柄锁。
2. **切片 B：有界调用队列（已落，v0.35.0）**——`worker.rs` 的 oneshot 通道改有界
   （`CALL_QUEUE_DEPTH = 2`/插件，`sync_channel` + `try_send`，满时立即返回
   `ProviderError{kind:network, retryable:true}`）+ 同曲取链合并（`SongUrlCoalescer`：
   同一 `track + 档位` 的在飞请求只让脚本执行一次，follower 共享结果；leader 被取消时
   用 `CoalesceLeader` 守卫唤醒 follower 成「可重试」）。验收用例：
   `ncm-plugin/tests/worker_limits.rs`（10 并发同曲网络命中 ≤ 2；4 并发不同曲恰好拒 1~2 次且
   拒绝在 ≤ 200ms 内返回、不打网络）。实测拒绝是**微秒级**（远好于 10ms 目标）。
   口径差异：`Shutdown` 也用 `try_send`（队列满时丢弃也没关系 —— `tx` 随结构体 drop，
    worker 的 `recv()` 会立刻返回 `Err` 退出）。
3. **切片 C：起播超时上限（已落，v0.35.0）**——`SandboxConfig::song_url_timeout`（缺省 4s）
   + `SandboxConfig::timeout_for(event)`（**唯一判定点**：`ScriptEngine::invoke`；装载期仍吃
   `call_timeout`），取链实际预算 = `min(song_url_timeout, call_timeout)` ⇒ 收紧通用预算
   不会反而放宽取链。超时仍是 `Timeout` → `Network` + 可重试，`call_routed` 照旧回落内置。
   验收：死循环插件 fixture 下，端到端起播（死循环→超时→内置取链成功）总墙钟 ≤ 4s + 内置
   取链耗时；`tests/sandbox.rs` 的超时用例改用新预算并保持绿。

## 4. 明确不做

- **d) Android `isolatedProcess` 双实现**：isolatedProcess 服务只能承载 Java/Kotlin 代码，
  QuickJS 宿主在 Rust，等价于重写 lx 兼容层 + 永久双实现行为漂移风险；且桌面子进程方案
  与 Android 进程模型差异已在上一份审计里明确「单独评估，不混进本次」。
- **c) 子进程 IPC（现阶段）**：当前插件层仍「未接产品默认路径」（host.rs 头注释：总开关
  缺省 false、无 UI 管理页之前无真实第三方脚本在跑），进程边界收益（抗 C 层 CVE/abort）
  没有真实威胁源；线程内预算体系已有 21 例红→绿实证兜底。触发条件：接入真实插件生态
  （≥3 个社区脚本在用户机上跑）或出现一次 rquickjs 崩溃实例后再评估。
- ** boa_engine 换引擎**：上一份审计已判「丢 32MB 内存上限硬门，收益为负」，不重复评估。
- **不做后台常驻脚本线程 / `setInterval`**：契约 v1 明确「一次调用结束即丢弃未到期任务」
  （README §1.3），常驻执行面会引入新的资源泄漏维度，与「按调用计预算」的模型冲突。
- **不编造 LX 生态对进程外隔离的行为**：上游 LX 桌面宿主如何隔离脚本在本仓未验证
  （待验证项），不做依赖该行为的任何设计假设。
