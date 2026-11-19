# 后端(core/) 架构可维护性审计 — 2026-11-15

> 仓库: /home/xuqianhui/netease-mini-player ｜ 基线: HEAD of `main`(见 §0)
> 性质: **只读审计**, 不改代码, 不动 `.pi/memory/`。所有数字由 rg/wc/git 本机静态取得, 未跑全量测试。
> 关联: `docs/archive/plans-2026-11/arch-slim-2026-11-15.md`(文档层精简) — 本文只谈 `core/` 代码结构。

## 0. 基线与方法

| 项 | 值 |
|---|---|
| HEAD | `738fc27` fix(ui): 播放队列面板排版收口 |
| 工作区 | **不干净且在移动**: 审计开始时已有 14 个未提交修改, 审计过程中变为 20 个(`ui/src/{mine_view,vip_page}.dart`、`test/signin_card_test.dart` 删除等 —— 另一条车道正在下线 vip 相关面)。本文所有数字取自**当时的工作区快照**(非 HEAD); 抽样复核: `api.rs` 在审计期间从 3 184 → 3 165 行, 但 `pub fn` 导出数稳定在 **160**, 故 §2 结论不受影响 |
| 方法 | 只用 `rg` / `wc` / `awk` / `git log` / `cargo tree --offline`; **未跑** `cargo test` / `flutter test` 全量, 未跑 clippy |
| 只读 | 只写 `.pi/plans/` 这一个文件 |

### 代码规模(core/, 单位行, 含同文件内 `#[cfg(test)]`)

| crate | 行数 | 最大文件 | 说明 |
|---|---|---|---|
| `ncm-domain` | 3 227 | `lib.rs` 1 771(92 个 pub struct/enum) | 纯 DTO + 3 个解析器(ttml/lrc/word_lyric) + eq_profile |
| `ncm-provider` | 1 321 | `lib.rs` 1 321 | 单文件: Capability(37 变体) + AudioLevel + ProviderError + `trait Provider`(131 方法) + Registry |
| `ncm-service` | **16 212** | `ttml_source.rs` 1 108 | `netease/` 11 379(其中 `tests/` 2 893, 协议层主体 8 486) + **本地状态 3 542**(identity/credential×3/history/cache/read_cache/loudness_store) + 歌词管线+lib 1 291 |
| `ncm-playback` | 1 687 | `lib.rs` 728 | rodio/CPAL + 响度测量 + biquad + agc |
| `ncm-cli` | 1 763 | `main.rs` 1 763 | headless 验证器, 允许直连 vendor |
| `ncm-ffi` | 16 711 | `frb_generated.rs` **13 523**(81%)｜`api.rs` 3 184 | 手写 3 184 / 生成 13 523 |
| `vendor/ncm-api` | 4 558 | — | 锁定上游 commit, 11 个本地提交 |

> 一句话: **生成代码 + 单文件样板**占了 backend 的 16%（`frb_generated` 13.5k 行）; 真正的业务解析面在 `ncm-service/netease/` 的 8.5k 行。

## 1. workspace 结构与依赖方向

### 1.1 实测依赖图(`core/crates/*/Cargo.toml` + `cargo tree --offline`)

```
ncm-domain      (leaf: 仅 serde)
   ↑                    ↑
ncm-provider       ncm-playback
   ↑                    ↑
ncm-service ──→ vendor/ncm-api-rs (ncm-api)
   ↑                    ↑
ncm-ffi ────────────────┘   ← ffi **不**依赖 vendor
   ↑
ncm-cli  ──→ 全部 5 个 crate + vendor(调试后门, 3 处 ApiClient)
```

**判定: 方向干净。** 五个 crate 里没有一条「上层被下层依赖」的反向边, 没有循环, 没有 `#[path]`/`include!` 绕过模块系统(`rg '#\[path =|include!\(' crates vendor` 零命中)。`ncm-domain` 是真正的叶子: 依赖表只有 `serde`, **不含 tokio/reqwest/平台 crate**, 任何人想往 domain 里塞 I/O 会立刻在 Cargo.toml 暴露。

### 1.2 vendor 边界: 守住了

| 检查 | 结果 |
|---|---|
| `rg ncm_api` 全仓引用点 | **5 处**: `ncm-service/src/netease/mod.rs`(2, import + `finish()` 私有签名) · `netease/song.rs`(2, 一处 `RequestOption`/`CryptoType`) · `ncm-cli`(3 段调试命令) |
| domain / provider / playback / ffi 里 vendor 类型 | **零命中** |
| vendor 类型出现在 `pub` 签名或 `pub use` | **零**(`map_error`/`finish` 都是 `pub(super)`/私有) |
| FFI 出参类型 | 全部 `ncm_domain` 类型 + 67 个 `#[frb(mirror)]` 影子结构, 无 vendor 类型 |
| vendor 本地改动 | 4 558 行, 11 个提交, 最大一次是「裁到 118 个已接入 endpoint, 移死 server 特性」(−22 457 行) |

结论: 边界是**结构性**守住的(ffi 的 Cargo.toml 里根本没有 `ncm-api-rs`, 想泄漏得先加依赖), 不是靠纪律守住的。这是整个 backend 最健康的一面。

### 1.3 隐患(不是当前违规, 是「变化轴错位」)

1. **`ncm-service` 一个 crate 承载三个变化轴** — 16 212 行里: 协议适配 `netease/` 8 486 · 本地状态 8 个模块(identity/credential_channel/credential_keyring/credential_store/history/cache/read_cache/loudness_store) **3 542** · 歌词管线 `ttml_source.rs` 1 108。三者只通过 `impl Provider` 与 `Core` 组合, 但同 crate ⇒ 改任一 provider 方法都要重编译整包, 且 `identity.rs`(885 行, 凭据+设备指纹+账号簿)与网络层同 crate 让「凭据纪律」和「协议纪律」混在一处评审。
2. **响度/播放这条链跨 3 个 crate 且没有归属者** — 算法在 `ncm-playback/loudness.rs`(459), 落盘在 `ncm-service/loudness_store.rs`(147), 编排在 `ncm-ffi/api.rs` 的 `loudness_measure_cached`(34 行)。三者任一处要改「缓存键含不含 level/增益」时, 改动会横跨 3 个 crate。
3. **`ncm-domain/src/lib.rs` 1 771 行装 92 个 DTO** — 与 `api.rs` 同构的「单文件大杂烩」, 只是拆分收益更低(DTO 之间零耦合)。真要拆应按域(`song.rs`/`playlist.rs`/`community.rs`/`vip.rs`/`radio.rs`), 但会牵动 67 个 `#[frb(mirror)]` 的路径 ⇒ 与 §2 打包做才有意义。
4. **`ncm-cli` 直连 vendor 是有意的例外**(3 处 `ApiClient::new`), 它是唯一能绕过 provider 打上游的入口 —— 保留是对的(协议冒烟), 但应在代码里标成「仅调试」, 否则后来者会以为这是合法写法。

## 2. ncm-ffi 单文件 `api.rs` 与 FFI 导出面

### 2.1 实测形状

| 指标 | 值 |
|---|---|
| `api.rs` 行数 | **3 184** |
| `pub fn` / `pub async fn` 导出 | **160**(与 `tools/api-coverage.sh` 的 160 一致) |
| 其中 `ffi_forward!` 展开 | **77 处宏调用**(3 个分支: 直通 / `map` / `map_each`) |
| 手写(非宏)导出 | **86 个** —— 但最长仅 39 行(`play_track`), 中位数 < 10 行, 只是 DTO 转换与参数拼装 ⇒ **这一层确实是薄的**, 没有业务逻辑下沉到不完整 |
| `pub struct/enum` | 100 个, 其中 **67 个是 `#[frb(mirror(...))]` 影子结构** |
| mirror 样板占行 | **663 行(≈21%)** |
| 文件内 `// ----` 分节标记 | 21 个 |
| 生成物 `frb_generated.rs` | 13 523 行(crate 的 81%) |

导出分布的极端不均匀(按现有分节标记统计):

| 分节(行范围) | 行数 | `pub fn` 数 |
|---|---|---|
| 推荐页 / 私人FM / 我的(收藏播客·关注艺人·动态) 2187–3098 | **911** | **66** |
| 歌单详情 / 评论 / 分享 1664–1920 | 256 | 11 |
| 多账号(账号簿) 603–902 | 299 | 10 |
| 歌手全部歌曲 / MV 341–487 | 146 | 9 |
| 收藏(红心)与歌单 902–1163 | 261 | 7 |
| 播放 1163–1272 | 109 | 4 |
| 音乐云盘 3098–end | 86 | 3 |

⇒ **第 19 节一个区域就装了 41% 的导出**。两人分别改「推荐页接口」和「云盘接口」今天几乎不会撞车(位置远), 但改「推荐页」和「收藏」就要抢同一段。

### 2.2 按域拆分可行性(flutter_rust_bridge 2.13 约束)

- 现有入口是 `crate::api`: `lib.rs` 只有 `pub mod api;` + `mod frb_generated;`。FRB 解析的是**以 `rust_input` 为根的模块树**(跟着 `mod` 递归), 因此把 `src/api.rs` 改成 `src/api/mod.rs` + `mod recommend;` + `pub use recommend::*;` 在 2.13 下是合法形状, 不需要改 codegen 命令。
- **真正的成本不在 Rust, 在生成物路径**: FRB 按 **Rust 模块**落盘, `crate::api::recommend` 里的函数会生成到 `ui/lib/src/rust/api/recommend.dart`, 不再进 `api.dart`。当前 `ui/` 有 **141 个文件** `import .../rust/api.dart`, `api.dart` 本身 4 668 行。
  ⇒ 一次性成本 = 141 处 import 改一行(sed 可做), 或新增一个手写聚合文件 `ui/lib/src/rust/api_all.dart`(`export 'api.dart'; export 'api/recommend.dart'; …`), 把 141 处改成它。**不能**在 `api.dart` 里加 `export` —— 那是生成文件, 下次 codegen 覆盖。
- **mirror 结构必须留在一个模块里**: 67 个 `#[frb(mirror)]` 决定 67 个 Dart 类的落盘位置, 跟着拆分走会让 Dart 侧类型路径碎成 12 份。建议 mirror 全部集中到 `api/dto.rs` 并在 `api/mod.rs` `pub use dto::*`(只动 1 次 import 面), 业务 fn 才按域拆。
- **不会变便宜的部分**: `frb_generated.rs` 13.5k 行仍是单体(FRB 生成策略决定), 改 API 三步骤、codegen 时间、hash 校验一个都不少。

### 2.3 结论

拆分是**低风险纯搬运**, 收益是评审/冲突面积(单文件 3184 → 12 个 ≤400 行文件), **不减少任何生成代码**。工作量估: 搬运 160 fn + mirror 归位 ~5 小时, 加一次全量 codegen(`flutter_rust_bridge_codegen generate`) + `cargo build -p ncm_ffi` + `flutter test`(必须跑, 因为 Dart 生成文件路径变了)。**优先级中等**: 只有在「多人并行改 FFI」成为常态时才值得做。

## 3. Provider trait 与 Capability 设计

### 3.1 现状实测

| 指标 | 值 |
|---|---|
| `trait Provider` 内 `fn` 行数 | **131** |
| 必须实现(无默认体) | **6**: `id` / `name` / `capabilities` / `search` / `song_url` / `lyric` |
| 有默认实现 | 125, 其中 **123 个默认体就是 `Err(ProviderError::unsupported(...))`** |
| `Capability` 枚举变体 | **37** |
| 生产实现方 | **1**(`NetaseProvider`, `netease/provider.rs`, 130 个一行转发) |
| 测试实现方 | 5(ttml_source.rs 4 个 + provider.rs 1 个 dummy) |
| 路由方式 | 运行时按 `Capability` 查注册表: `ffi` 的 `with_provider(cap)` → `providers.first_with(cap)` |

两个关键事实:

1. **这个 god trait 其实不咬人**: 125/131 有默认实现, 新 provider 只需实现 6 个方法就能编过, 其余自动 `Unsupported`; 而调用方走的是 `with_provider(Capability::X)` 的**枚举路由**, 不会去调 `capabilities()` 未声明的方法。所以「任何新实现都要空实现一大片」这个 `docs/remaining-batches.md` §12.2 的前提, 在当前代码里**已经不成立**(它描述的是默认实现补齐之前的状态)。
2. **枚举与方法双份登记**: 37 个 `Capability` vs 131 个方法(平均 1 个能力 ≈ 3.5 个方法), 两处都要维护; 一致性靠 `CAPABILITIES` 常量表 + 测试, 没有编译期校验。

### 3.2 按能力拆 trait 的收益/成本

收益(小):
- 可读性: 找「评论相关方法」从 1 321 行的单文件里翻 131 个签名 → 变成 8 个子 trait。
- 测试 mock 精度: 现在 mock 只能 `impl Provider` 然后依赖默认实现(其实够用)。
- 编译期约束「声明了 `Capability::Comment` 就必须实现 6 个 comment 方法」—— 今天漏实现等于运行时 `Unsupported`, 有 `capabilities()` 兜着不会崩, 只是该功能静默缺失。

成本(中):
- 131 个签名(全部带 `BoxFuture<'a, ProviderResult<…>>` 生命周期)要搬进 8 个子 trait, 逐个核对 `'a`。
- `pub trait Provider: ReadProvider + LyricProvider + … {}` 需保持 object-safe(8 个 supertrait 都 object-safe 时成立), 且 `dyn Provider` 的 23 处 `core()`/`with_provider` 调用点语义不变。
- `impl Provider for NeteaseProvider`(130 行转发)要拆成 8 个 `impl XProvider for …`, 且 `netease/provider.rs` 会重新变长(§12.1 刚把它压平)。
- 全量回归必需(`cargo test` 287 / `flutter test` 942), 与 §12.1 的拆分成果在同一文件上叠加。
- **风险点**: 拆完后 `&dyn Provider` 的 vtable 从 1 张变 9 张, 动态分发成本略升(本项目 FFI 调用频率下可忽略, 但需要一次实测确认)。

判定: **收益主要是「可读性 + 未来 QuickJS ScriptProvider 的按能力实现」, 不是安全性**; 若近期没有第二个 provider 实现方的计划, 属于「装饰性重构」。

## 4. 错误模型 `ProviderError{kind,retryable,detail}` 贯彻度

### 4.1 做得好的: 上游错误有唯一收口

| 检查 | 结果 |
|---|---|
| 7 个 `ProviderErrorKind`(`Network/Auth/RiskControl/NotFound/Unsupported/Forbidden/Internal`) + 8 个构造器 + `Display = "[kind] detail"` | 齐备 |
| vendor `NcmError` → `ProviderError` | **单点**: `netease/mod.rs:260 fn map_error`(+ `map_code`) |
| `map_error` 调用点 | **~140 处**, 分布在 12 个 `netease/*.rs`, 无一处把 `NcmError` 直接越过边界上传(唯一带 `NcmError` 的签名是私有 `finish()`) |
| 生产代码 `panic!`/`todo!`/`unreachable!` | **0**(46 文件全量 rg) |
| 生产代码裸 `unwrap()/expect()` | **≈25 处, 全部是 `std::sync::Mutex::lock().unwrap()`**(identity.rs 12 / credential_channel.rs 10 / credential_store.rs 3)。`ncm-playback` 与 `ncm-domain` 的 unwrap **100% 在 `#[cfg(test)]` 内**(逐个核对过, 含缩进的 `#[cfg(test)]`) |

⇒ 服务层正文没有「随手 unwrap 崩溃」, 只有**锁中毒**这一类: 任一持锁线程 panic 后, 该 `Mutex` 永久 poisoned, 后续所有 `lock().unwrap()` 连锁 panic。对比 `ncm-ffi` 的 `core()` 用 `lock().map_err(|e| e.to_string())`(23 处)是正确写法 —— **同一个仓库两种口径**。

### 4.2 最大的贯彻缺口: 跨桥时错误被压平成字符串

```rust
// macro_rules! ffi_forward  (77 处调用)
let v = $p.$m($($arg),*).await.map_err(|e| e.to_string())?;   // 手写处同样写法, ~20 处
```

- 全部 **160 个导出**签名是 `Result<T, String>`;
- `retryable` **完全没有跨桥**: `rg retryable crates/ncm-ffi` = 0 命中; 全仓只有 `ncm-service` 的两个测试里出现过这个词;
- `kind` 只以文本前缀存活: `Display for ProviderError` → `"[network] timeout: …"`, Dart 侧靠 `ui/lib/src/login_sheet.dart:28-37` 的**手写映射表** + `_error.contains('riskControl')` 分支解析。

这与项目规则「任何 provider 的外部错误都转成 `ProviderError{kind,retryable,detail}`, UI 按 `kind` 决策」**形式上满足、机制上是字符串协议**。已经能看到的脆弱点:
- `detail` 直接来自上游 `msg`(中文, 可能含 `[`/`]`), 前端 `startsWith('[')` 类的解析会被上游文案污染;
- 新加一个 `ProviderErrorKind` 变体, Dart 侧映射表不会报错, 只会静默落到 default 文案;
- `retryable` 是服务层算出来的结论(`network = true`, 其余 false), UI 拿到后只能自己重猜。

**改法(小改动、大收益)**: 在 `ncm-ffi` 加一个 `pub struct FfiError { kind: String, retryable: bool, detail: String }`, 把 `ffi_forward!` 的 `map_err` 换掉, 160 个签名一起变(`Result<T, FfiError>`), Dart 侧错误处理点从「字符串 contains」变成结构化字段; 不动 service/provider 一行。工作量 S(宏 1 处 + codegen + Dart 侧改动点), 但**会让 141 个 Dart 文件的编译期错误暴露出来**(正是想要的: 现状是运行时静默)。

### 4.3 其他不一致

| 位置 | 现象 | 评价 |
|---|---|---|
| `ttml_source.rs:437,500` | `provider.word_lyric(...).await.ok()` —— 把 `ProviderError` 降级成 `None` | 可接受(歌词缺失), 但**丢掉 kind**, 风控/网络无法区分, 也没日志 |
| `ncm-service` 自己还有 2 套错误类型 | `CredentialError`(credential_store) · `EqProfileError`(domain) · `PlaybackError`(playback) | 合理(不同关注点), 但 `CredentialError` 跨 FFI 时也是 `to_string()`, 前端只能看文案 |
| 生产代码 `let _ = …` | ~20 处, 全是 best-effort 落盘/删除(`fs::remove_file`/`create_dir_all`/`rename`) | 可接受, 但 `ttml_source.rs` 里 5 处 `let _ = fs::rename(&tmp, &cache)` 失败会被静默忽略 ⇒ 缓存「永远不命中」但没人知道 |

## 5. 缓存与并发职责边界

### 5.1 现状: 1 个内存缓存 + 7 套磁盘落盘, 各自为政

| 模块 | 行数 | 落点 | 职责 | 淘汰/上限 |
|---|---|---|---|---|
| `netease/mod.rs` + `read_cache.rs` | 551 | 进程内 `HashMap` | 只读接口响应(白名单 9 个 endpoint) | TTL 300s + LRU 200 条 + 单飞 |
| `identity.rs` | 885 | `accounts.json` + 设备 cookie + device_id | 身份与账号簿 | 无 |
| `credential_store.rs` | 756 | 明文(0600) / DPAPI / keyring 三后端 | 凭据 | 无 |
| `cache.rs` | 355 | 音频文件 `.part` → 正式 | 「边下边播」+ 文件 LRU | `enforce_limit` 字节上限 |
| `loudness_store.rs` | 147 | `loudness.json` | 响度测量结果 | 无 |
| `history.rs` | ~107 | `history.json` | 播放历史 | 无 |
| `ttml_source.rs` | 1 108 | `ttml/*.ttml` + `*.none` | 逐字歌词缓存 + 负缓存 | 无 |
| `ui/lib/src/daily_cache.dart` | 275 | `cache/daily-playlists/YYYY-MM-DD.json` | 每日推荐歌单(Dart 侧) | 保留 N 天 |

### 5.2 重复职责(实测)

1. **原子写样板 7 份**: `fs::rename(tmp→final)` 出现在 `credential_store`(2)/`ttml_source`/`loudness_store`/`history`/`identity`/`cache`, 加上 Dart 侧 `playback_state.dart:150-166` 与 `daily_cache` 的 `.tmp` 写法 ⇒ **同一段「create_dir_all → 写 tmp → rename」样板在 2 种语言里共 9 份**, 没有 `service/src/fsutil.rs`。`create_dir_all` 在 ncm-service 出现 12 次。
2. **目录布局是跨语言隐式契约**: Rust 写 `<dataDir>/{ttml,cache,history.json,loudness.json,accounts.json}`, Dart 写 `<dataDir>/cache/daily-playlists/` 与 `<dataDir>/play_state.json`。`dataDir` 由 `init()` 下发(`InitInfo.dataDir`), 但「谁拥有哪些子目录」没有任何单一登记处。
3. **缓存纪律在两处相反**: Rust `read_cache` 的白名单**刻意排除**每日推荐(`daily_recommend`), 理由写在注释里是「带账号上下文, 缓存会串号」。但 Dart 的 `daily_cache.dart` 把日推歌单**按日期落盘 7 天**, **而且目录里没有 uid 维度**(`rg uid|userId|account lib/src/daily_cache.dart` 零命中)。退出登录路径(`main.dart:2198 _logout → rust.logout()`)也没有清理它 —— 只清了 `PlaybackStateStore`(`main.dart:3025`)。
   ⇒ **跨账号切换后, 账号 A 的日推歌单清单会被合并展示给账号 B**。这不是 Rust 侧的问题, 但正是「缓存无 owner」的直接后果, 而且与 Rust 侧写下的纪律**互相矛盾**。严重度: 低(只是歌单标题/封面, 不含凭据), 但属于隐私面 + 逻辑错误, 修法很小(daily_cache 目录加 `uid` 段, 或 logout 时清目录)。
4. **`loudness_store` 与 `ncm-playback::loudness` 分居两 crate**, 而 `read_cache` 与 `AudioCache` 同 crate 却零共享抽象(一个是响应缓存, 一个是文件下载) —— 同名「cache」的两个模块实际没有任何共同接口, 命名制造的错觉比代码问题更贵。

### 5.3 并发: 结构上安全, 但有一颗全局锁

- `ncm-ffi` 只有一个全局 `static CORE: OnceLock<Mutex<Core>>`(23 处 `core()?.lock()`), 加 `PLAYER`/`DATA_DIR` 两个 `OnceLock`。
- **没有一处跨 `await` 持锁**: `rg -U 'guard\.lock\(\)[^;]*;[\s\S]{0,400}?\.await'` 零命中 —— 所有取锁都是 `{ let guard = core()?…; guard.providers.first_with(cap) }` 这种表达式内取 `Arc<dyn Provider>` 然后释放。这不是巧合, 是 `flutter_rust_bridge` 要求 future `Send` 的编译期后果(持 `std::sync::MutexGuard` 跨 await ⇒ `!Send` ⇒ 编不过)。**这条约束值得写进 memory, 它是这套设计的隐性护栏。**
- 代价: 全局单锁 ⇒ 所有 FFI 入口(包括纯读的 `get_settings` 类)串行化; 目前调用都在 Flutter 的 isolate 里异步等, 没观察到问题; 抽查最可疑的一处(`account_switch` 在 `api.rs:886` 调 `account_sync_active().await`)确认锁已在 `{}` 作用域里释放, **不持锁跨 await**, 只是把一次网络同步串在了切换路径上(耗时无条件加法)。
- 锁中毒风险见 §4.1(服务层 `lock().unwrap()` 25 处)。

## 6. 收益/风险/工作量排序表 + 前 5 建议

### 6.1 排序表(按「收益 ÷ 成本」从高到低)

| # | 项 | 收益 | 风险 | 工作量 | 触及面 | 判定 |
|---|---|---|---|---|---|---|
| 1 | **FFI 错误结构化**: `Result<T, String>` → `Result<T, FfiError{kind,retryable,detail}>` | **高**(规则「UI 按 kind 决策」从字符串协议变成类型, `retryable` 首次跨桥) | 低(service/provider 零改动) | **S**(宏 1 处 + codegen + Dart 错误处理点) | `ffi_forward!` 77 + 手写 20 | **做** |
| 2 | **`daily_cache` 按账号隔离 + 登出清理** | 中(隐私串号 + 与 Rust `read_cache` 纪律矛盾) | 极低 | **S**(Dart 单文件 + logout 一行) | `ui/lib/src/daily_cache.dart`(275) | **做** |
| 3 | **服务层 `lock().unwrap()` 统一成容忍中毒** | 中(消除「一处 panic 全局连锁崩」) | 低 | **S**(`identity` 12 / `credential_channel` 10 / `credential_store` 3) | ncm-service 3 文件 | **做** |
| 4 | **`service/src/fsutil.rs` + dataDir 目录登记表**: 收 9 份「create_dir_all→tmp→rename」样板, 登记 `<dataDir>` 各子目录的 owner | 中(重复职责消失, 跨语言契约有唯一出处) | 低(纯搬运) | **M**(半天) | ncm-service 6 模块 + 2 个 Dart 文件 | **做**(可与 3 合并) |
| 5 | **`api.rs` 按 12 个能力域拆分 + 67 个 mirror 归到 `api/dto.rs`** | 中(单文件 3 184 → ≤400; 66 个推荐页导出不再与云盘同文件) | 中(Dart 生成物路径变, 141 处 import) | **M**(~1 天, 含全量 codegen + flutter test) | `api.rs` + `ui/lib/src/rust/*` | **择机做**(多人并行改 FFI 时) |
| 6 | **`Provider` 拆 8 个能力 trait**(`docs/remaining-batches.md` §12.2) | **低**(125/131 已有默认实现, 新 provider 只需 6 个方法; 路由靠 `Capability` 枚举, 不靠 trait 形状) | 中(`'a` 生命周期 ×131, supertrait object-safety, `netease/provider.rs` 重新变长) | **M**(1–2 天 + 全量回归) | `ncm-provider` + `netease/provider.rs` | **缓做/不做**, 除非确定要上 QuickJS `ScriptProvider` |
| 7 | `ncm-service` 拆出 `ncm-store`(本地状态 crate: identity/credential×3/history/cache/read_cache/loudness_store) | 中(三个变化轴分离, provider 层改动不再重编译本地状态) | 中高(跨 crate 移动 + FFI 调用点全改 + 4 个平台 cfg 归属重划) | **L**(2–3 天) | 8 模块 **3 542 行** + `api.rs` 调用面 | **暂不做**, 记入债务 |
| 8 | `ncm-provider/src/lib.rs`(1 321) 拆 `capability.rs`/`error.rs`/`trait`/`registry.rs` | 低(纯可读性) | 极低 | **S**(1 小时) | 1 文件 | 搭车做 |
| 9 | `ncm-domain/src/lib.rs`(1 771 / 92 DTO) 按域拆 | 低 | 低 | **M**(牵动 67 个 mirror 路径 ⇒ 必须与 #5 同一批) | `ncm-domain` + `api.rs` | 与 #5 绑定 |
| 10 | `ttml_source.rs` 5 处 `let _ = fs::rename` 加 `log::warn!` | 低(缓存永不命中不再是哑巴) | 极低 | **S** | 1 文件 | 搭车做 |

### 6.2 前 5 个建议(可直接开工的顺序)

1. **`FfiError` 结构化错误(第 1 项)** — 这是全篇唯一「规则写了但机制没落地」的地方。160 个导出全是 `Result<T, String>`, `retryable` 一次都没跨桥, `kind` 靠 `"[network] "` 文本前缀让 Dart 用 `contains` 猜。改在 `ffi_forward!` 一个宏上, service/provider 一行不动; 收益是「新加 kind 变体时 Dart 编译期报错」而不是静默降级。**唯一要接受的代价**: 141 个 Dart 文件的错误处理点会一次性暴露编译错误(这正是想要的清单)。
2. **`daily_cache` 账号隔离(第 2 项)** — 现成的事实级不一致: Rust `read_cache` 用长注释论证「日推带账号上下文, 绝不缓存」, Dart 却把它按日期落盘 7 天且目录无 uid、登出不清理 ⇒ 切号后 A 的日推清单展示给 B。修法最小(目录加 uid 段, 或 `_logout` 里清目录), 风险几乎为零。**顺带**: 把「`<dataDir>` 子目录 owner」写进 `.pi/memory/notes-*`, 避免第四份缓存再各写各的。
3. **锁中毒统一(第 3 项)+ `fsutil` 收敛(第 4 项)一起做** — 两件都是纯机械、无行为变化的清理, 合一个 commit: (a) 25 处 `lock().unwrap()` 改成 `lock().unwrap_or_else(|e| e.into_inner())`(中毒即续用, 与 `ncm-ffi` 的 `map_err` 口径对齐); (b) 抽 `fsutil::write_atomic(dir, name, bytes)`, 替掉 7 处 Rust 样板。验收看 `rg 'lock\(\)\.unwrap\(\)' crates/ncm-service` 归零。
4. **`api.rs` 按域拆(第 5 项)—— 但先只搬 mirror** — 分两步: 先 `api/mod.rs` + `api/dto.rs`(67 个 mirror 集中, Dart 侧只改 1 处 import 面), 观察一次 codegen + `flutter test` 是否零 diff; 稳了再把 160 个 fn 按 §2.1 的分节搬 12 个文件。**不要**一次搬完再修 141 处 import, 那样出问题无法二分。
5. **`Provider` 拆 trait 先别做, 改成「补 3 个测试」** — 表里第 6 项收益被高估: 默认实现已经把「新 provider 成本」压到 6 个方法, 真正的洞是**没有任何编译期/测试校验「`CAPABILITIES` 里声明的能力确实被实现」**。花 2 小时写一个测试(遍历 `CAPABILITIES`, 对每个能力调一次代表方法, 断言不返回 `Unsupported`), 收益 > 拆 8 个 trait 花 2 天。真要拆, 等第二个 provider 实现方(QuickJS)立项时再拆 —— 那时才有真实的收益面。

### 6.3 明确「不做」

- **不把 `ncm-cli` 直连 vendor 的 3 处改掉** —— 它是唯一的协议冒烟入口。
- **不给 `read_cache` 扩白名单**(日推/收藏类) —— 注释里的串号论证是对的, 这条纪律别放宽。
- **不动 `frb_generated.rs`**(13.5k 行生成物) —— 任何手改都会在下次 codegen 被覆盖。

## 附录 A. 章节进度
(每节完成追加一行)

- [x] §0 基线与方法
- [x] §1 workspace 结构与依赖方向
- [x] §2 ncm-ffi 单文件 api.rs 与 FFI 导出面
- [x] §3 Provider trait 与 Capability 设计
- [x] §4 错误模型 ProviderError 贯彻度
- [x] §5 缓存与并发职责边界
- [x] §6 收益/风险/工作量排序表 + 前 5 建议

## 附录 B. 复现命令(全部只读)

```bash
cd core
# 依赖方向
cargo tree --offline -p ncm_ffi --depth 1; cargo tree --offline --workspace --duplicates
# vendor 边界
rg -n "ncm_api" crates/ ; rg -n "pub use ncm_api|-> .*ncm_api" crates/
# trait 形状
awk '/^pub trait Provider/,/^}/' crates/ncm-provider/src/lib.rs | rg -c "^    fn "
awk '/^pub trait Provider/,/^}/' crates/ncm-provider/src/lib.rs | rg -c "ProviderError::unsupported"
# FFI 面
rg -c "^pub (async )?fn " crates/ncm-ffi/src/api.rs      # 160
rg -c "ffi_forward!" crates/ncm-ffi/src/api.rs             # 77
rg -c "#\[frb\(\(mirror" crates/ncm-ffi/src/api.rs      # 67
# 错误贯彻度
rg -c "map_error" crates/ncm-service/src | sort
rg -n "retryable" crates/ncm-ffi/                         # 0 命中
rg -n "lock\(\)\.unwrap\(\)" crates/ncm-service/src
# 缓存重复
rg -n "fs::rename" crates/ncm-service/src
rg -c "create_dir_all" crates/ncm-service/src | sort
rg -n "uid|userId" ui/lib/src/daily_cache.dart            # 0 命中
```
