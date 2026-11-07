# Failures — netease-mini-player

- 把 App 逻辑错误误判为安卓直连风控（或反之）：先隔离变量再归因。
- 用路由路径当内部 URI 调接口 → 404，误以为接口变更。
- 在标准安卓 TLS 栈上硬碰反爬：JA3 指纹会被拦，应改用网页形态。
- 追求大而全的依赖栈：与 <500KB、零第三方 Gradle 依赖的目标冲突。
- 把"中间设备拦截明文 http(502 空 body)"误判成音频解码问题: 报错文案是 ExoPlayer 的 extractor
  列表, 但真正的证据是 status/内容类型 —— 先看服务端给了什么, 再怀疑解码器。
- 没检查代理环境变量就断言"接口挂了/设备风控": reqwest 的 `error sending request` 对
  "代理端口没人监听"和"真断网"长得一模一样。
- 看到"模拟器里 https 打不开"就先骂站点/风控: 先分栈验证——同一 guest 里 rustls 通、
  chromium 不通, 且宿主 curl 通 ⇒ 先怀疑模拟器的会话语义(本次是 wlan0/netsim, 关 wifi 即好)。
- 身份指纹"成套"才有效: cookie 说 `os=pc` 而 UA 是 iPhone / 网页是移动版, 属于自相矛盾的客户端,
  风控会"假通过"(静默降权)而不是报错 —— 曾长期带着这个不一致在跑。

§
## 2026-11-05 手工跑 cargo test 挂 vendor 联网集成测试
- `tools/env.sh` 会 export 指向 127.0.0.1:7890 的代理变量(本机 7890 常没起): 手工跑 `cargo test --manifest-path core/Cargo.toml` 时 vendor/ncm-api 的 8 个真实联网集成测试 reqwest 走死代理必挂 `assert!(result.is_ok())`。手工跑测试前必须 `unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY`(ci.sh 自己会 unset, 所以 CI 没暴露)。
- vendor/ncm-api/tests/integration.rs(8 个)打真实网易云接口, 全量连跑偶发 1~3 个风控失败, 且每轮失败集合不同; 单独复跑即过, 是网络抖动不是代码问题。判据: 只盯新增/离线单测, vendor 联网测试复跑确认。
- fabric/pi 会话里别裸 `git stash`: 会把运行时一直改写的 `.pi/fabric/mesh/state.json` 一起 stash, pop 必被卡"本地修改将被合并操作覆盖"。解法: pop 前 `git checkout -- .pi/fabric/mesh/state.json` 再 pop。

§
## 2026-11-06 封面图全 403 / 切 tab 占位符高频闪烁
- 现象: 所有封面/头像只显示占位音符, logcat 里逐个 `HTTP request failed, statusCode: 403`; 切 tab 时占位符和图片交替闪。
- 根因 1(403): 网易 CDN 对默认 `Dart/3.x (dart:io)` UA 回 403。用 `Image.network(headers: {'User-Agent': browser})` **修不好** —— NetworkImage 内部是 `HttpHeaders.add`, 会**追加**到 HttpClient 预置的默认 UA 后面, 实际发出 "Dart/3.9 (dart:io), Mozilla/..." 拼接值, 照样 403。必须自定义 ImageProvider, 用 `HttpClient()..userAgent = ...` 整体替换(见 `ui/lib/src/cover_art.dart::_UaNetworkImage`)。
- 根因 2(闪烁): tab 用 switch 直接返回新 Widget ⇒ 每次切 tab 都销毁重建子树, 图片 State 重来 + 占位符重绘。改为 IndexedStack + 访问过才构建(`_tabVisited`), 并让 provider 实现 `==`/`hashCode` 以命中 ImageCache, 再加 `gaplessPlayback: true`。
- 判据: `adb logcat | grep IMGFAIL` 为 0; 连续截图 md5 相同即无闪烁。

§
## 2026-11-07 本机不稳定导致的一次「子代理全灭」+ 三处环境假故障
- **/tmp 整体被清空, fabric 子代理全灭**: 08:35 前后本机出现内存/内核级异常(同日 `litellm` 反复 SIGSEGV、
  /tmp tmpfs 被清、两个 fabric worker 消失且 `/tmp/pi-fabric-runs-*` 全没)。教训: 派工单要求 worker
  的阶段产物**写仓库或 `~/.cache`, 不要只写 `/tmp/*.md`**; 判定 worker 存活不能只看 `agents.list`(会返回空),
  用 `pgrep -af pi-fabric/dist/worker` + run 目录里的 `status.json`; 收口前先把 /tmp 里的报告 cp 出来。
- **cargo 假网络故障**: `cargo test` 报 `failed to download 'litemap v0.8.3'`, 根因是
  `~/.cargo/registry/src/.../litemap-0.8.3/Cargo.toml` **缓存文件 utf-8 损坏**(位翻转),
  `cargo fetch` 直接报 `path ... was not valid utf-8`。删掉该版本的 src 目录与 `cache/*.crate` 后重 fetch 即好,
  别一看到 download 失败就怀疑镜像/代理。
- **Gradle daemon JVM SIGSEGV(一次性)**: `assembleDebug` 报 `daemon disappeared`,
  `ui/android/hs_err_pid*.log` 里 `SIGSEGV ... G1CMOopClosure::oop_oop_iterate`。`./gradlew --stop` 后重跑即成功。
  本机 14700KF 有内存/内核级不稳定史(litellm 同理), 同类崩溃先"重跑一次"再查代码; hs_err/core 产物别提交。
- **vendor 匿名联网 smoke 连跑 3 次全挂**: 与 2026-11-05 条目同源(上游风控/公网抖动)。已把 `tools/ci.sh` 拆成
  「本地 workspace 测试(阻塞门)」+「vendor 8 例匿名联网 smoke(3 次重试, 仅 WARN)」;
  需要严格核验公网链路时 `NCM_VENDOR_SMOKE_STRICT=1 tools/ci.sh`。

§
## 2026-11-09 本机 flutter analyze 连续 SIGSEGV（dart analyze 正常）
- 现象: `flutter analyze [--no-fatal-infos]` 每次都 `analysis server exited with code -6`，
  `si_signo=Segmentation fault(11) ... dart::ConcurrentMarkTask::Run / MarkingVisitor::VisitPointers`
  崩溃在并发标记 GC；同一份代码 `dart analyze`（整包）与 `dart analyze lib/src/xxx.dart`（单文件）全正常，
  内存 43G 可用、/tmp 未满、无残留 analysis_server 进程，`flutter test`/`flutter build` 也都正常。
- 判据与处置: 这是本机 Dart VM/GC 级的偶发不稳定（与 litellm/Gradle 那次 SIGSEGV 同源史），**不是代码问题**。
  连续 3+ 次失败后不要继续怀疑自己的改动，改用 `cd ui && dart analyze`（0 error 即过，info 级照旧忽略）
  作为 analyze 门；`tools/ci.sh` 会因此 RC=250 停在 analyze 步，其余步骤(test/两端构建)可手工补跑。
  需要在 ci.sh 里长期兜底时，可考虑把 analyze 步骤改成「flutter analyze 失败则回落 dart analyze」。
- 后续验证(同日): `flutter clean`(清掉 20G build + 173M .dart_tool) 与删 `~/.dartServer`(133M) 后**仍然崩溃**,
  `flutter analyze lib` / `flutter analyze test` 都崩 ⇒ 不是脏状态或某个文件触发, 是 flutter_tools 这层起 analysis server
  的 Dart VM 在本机稳定崩(并发标记 GC)；`dart analyze`、`flutter test`、`flutter build` 全部正常。
  结论: analyze 门固定用 `cd ui && dart analyze`，不要再反复重试 flutter analyze。

## flutter analyze 崩溃：是 DAS 并发标记的竞态，不是硬件随机位翻转（2026-11-07 量化）
- 崩溃点固定：`dart::MarkingVisitor::VisitPointers` ← `dart::UntaggedObjectPool::VisitObjectPoolPointers` ← `ConcurrentMarkTask::Run`（analysis server 并发标记对象池）；si_addr 每次漂移：nil / 0x44 / 0xa8 / 0xffffffffffff0000。
- 实测分布（同一台机、同一时刻）：空项目 `/tmp/azt` `flutter analyze` **11/11 通过**（含 8 路并发 8/8）；
  本项目 `lib` 3/3 崩、`test` 3/3 崩、`lib/src/rust` 1/3 崩；同项目 `dart analyze` 3/3 通过、稳定 28 issues。
  ⇒ 概率随 DAS 工作量上升，与代码内容无关；位翻转不可能造成「空项目 0 次 / 本项目 3/3」。
  ⇒ 定性为 Flutter 3.47.9 / Dart 3.13.7 在本机上 DAS 并发标记的竞态（flutter_tools 启动参数路径更容易命中），不是本机 VM 全局不稳、也不是脏缓存。
- 门禁仍固定 `cd ui && dart analyze`；不要重装 Flutter/清缓存来「修复」它。
