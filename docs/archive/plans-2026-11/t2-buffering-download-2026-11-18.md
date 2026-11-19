# T2 · 下载鲁棒性 + 缓冲策略(2026-11-18)

> 角色 T2(下载鲁棒性 + 缓冲策略, 为「香港用户卡顿」降 rebuffer 与静音时长)。
> 依据: `docs/archive/plans-2026-11/source-acquisition-research-2026-11-18.md` §3.4 / §4 #4 #6 #7 / §5 / §8 方案 A 的 ②③④⑤⑥。
> 未 commit; 未改 `docs/PROGRESS.md`、`docs/remaining-batches.md`; 只格式化了自己改的文件。

## 0. 一句话

四件事落地: **明文 http 统一升级 https(两端, 只认网易域名族)** · **桌面下载器补全 UA/Referer/超时 + 首包/HTML 判失败并分类回传** · **失败只重试一次** · **Android 重缓冲恢复线 5s → 2s, 起播 2.5s → 1s**; 顺带修掉桌面 `GrowingFile` 的**真实缺陷**(判死计时从"打开文件"起算, 慢网会把正常曲目提前判 EOF)与缓存键缺音质。

## 1. 改动清单(按文件)

### Rust

`core/crates/ncm-service/src/cache.rs`
- 新增 `prefer_https(url)` / `prefer_https_with(url, allow_host)` + `is_netease_host`:
  只把 **`*.126.net` / `*.163.com`** 的 `http` 升 `https`(保留 host/path/query, 去掉显式 `:80`);
  非网易域、非 http、解析失败的 URL 原样返回。判定可注入(单测直接注入别的域名族)。
- 新增 `DownloadFailure{HttpStatus,Hijacked,TooSmall}` + `classify_http(status, content_type, server)`:
  **非 2xx ⇒ 失败**(401/403 ⇒ `forbidden` 不可重试; 404 ⇒ `notFound`; 5xx/429 ⇒ `network` 可重试);
  **2xx 但首包 `text/html`/`xhtml` ⇒ `network` 可重试**(明文被中间设备换成重定向页的特征);
  完整落盘但 < 64 KiB ⇒ `internal` 不可重试。全部收口到 `ProviderError{kind,retryable,detail}`。
- 下载客户端改为单例 `reqwest::Client`: **UA = `identity::platform_profile().ua`**(与取链同一身份串, 不再有第二份)、
  `Referer: https://music.163.com/`、`connect_timeout=10s`、`read_timeout=20s`(读间隔, 不是整请求)。
- **首包单独再压一道 `FIRST_CHUNK_TIMEOUT=15s`**(连上了但 CDN 迟迟不给 body ⇒ 明确报"首包超时")。
- **失败重试一次**: `DOWNLOAD_RETRIES=1`, 只对 `retryable` 失败重试(300ms 间隔), 401/403/404/太小 不重试。
  `fetch()`(下完再播, Windows/CLI)与 `download_progressive()`(边下边播)共用同一套。
- 错误类型 `Result<_, String>` → `Result<_, ProviderError>`; FFI 侧已有 `From<ProviderError> for FfiError`,
  所以下载失败的原因(`kind/retryable/detail`)直接走既有错误通道, 不再是一句 `"http 403"`。
- 缓存键: 新增 `path_for_level(track_id, url, level)` = `{track_id}.{level}.{ext}`;
  `cached_with_level()` **先试新键再回退旧键 `{track_id}.{ext}`**(不一次性清缓存)。
  `legacy_path_for`/`path_for` 保留为旧键; `enforce_limit` 的"正在播放不淘汰"用 `{id}.` 前缀, 新键天然兼容。
- 音质旁路 `remember_level()/level_hint()`: 因为 `play_track` 是 FFI 导出(本车道不动 codegen), 不能加参数,
  所以 `song_url` 成功时记一条 `track_id → level`, `play_track` 取它给缓存键打标(上限 512 条, 溢出清空; 丢了就退回旧键)。

`core/crates/ncm-ffi/src/api.rs`
- `song_url`: 成功后 `cache::remember_level(track_id, level)`。
- `play_track`: 命中用 `cached_with_level`, Windows 分支用 `fetch(.., level)`(错误可回传 Dart),
  渐进分支 `start_progressive(.., level)`。**未改任何签名**(codegen 面零变更)。

`core/crates/ncm-playback/src/lib.rs`
- `GrowingFile` 修真实缺陷: 判死计时以前叫 `since` 且**只在 open 时赋值**, 于是"打开后 90s"就是死线 ——
  慢网下播放线程(比下载快)在 90s 后偶尔读空一次就会被当成 EOF **提前结束**。现在改名 `last_data`,
  **每次读到字节都刷新**, 判死口径是"连续 N 秒没有任何新字节"。
- 阈值可配: `NCM_GROWING_STALL_SECS`(下限 5s, 非法值/缺省 ⇒ **仍 90s**)。默认不降的理由写在代码里:
  下载器本身有 20s 读超时, 真 stalled 会先在下载侧失败并置 `done`; 这里只兜"下载线程整个消失"。
- stalled 时 **返回 `io::ErrorKind::TimedOut` 而不是 `Ok(0)`**: 以前 `Ok(0)` 等于"这首正常播完了",
  用户听感是无缘无故切下一首、日志里没有失败痕迹。

### Android(Kotlin)

`ui/android/app/src/main/kotlin/com/minincm/minincm/AudioBufferPolicy.kt`(新, 纯 Kotlin)
- `MIN_BUFFER_MS=15_000` / `MAX_BUFFER_MS=50_000` / `BUFFER_FOR_PLAYBACK_MS=1_000` /
  `BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS=2_000` + `invariantsHold()`(media3 Builder 的合法性条件, JVM 可测)。

`ui/android/app/src/main/kotlin/com/minincm/minincm/PlaybackService.kt`
- `buildExoPlayer()` 加 `.setLoadControl(buildLoadControl())`:
  `DefaultLoadControl.Builder().setBufferDurationsMs(MIN, MAX, BFP, BFPAR).setPrioritizeTimeOverSizeThresholds(true)`。
- **没有动** `handleAudioFocus=true`、`DefaultHttpDataSource`(15s/20s/跨协议重定向)、`CacheDataSource`/`SimpleCache` 配置。
- 取值理由(代码注释 + 本文 §2): 重缓冲 5s→2s 是"卡顿体感"的直接旋钮; 15s 水位抗抖动; 上限不变。
- `setPrioritizeTimeOverSizeThresholds(true)`: 音频按**时长**定缓冲, 不然无损曲目(≈4MB)拿到的秒数比 128kbps 少。

### Dart

`ui/lib/src/playback.dart`
- `preferHttpsStreamUrl(url, {shouldUpgrade})`: 语义从"任何 http 都升"收窄为**只升网易域名族**
  (`isNeteaseStreamHost`), 显式 `:80` 一并去掉, 判定可注入。
- 桌面 `play()` 也走 `preferHttpsStreamUrl`(以前直接把上游给的明文直链交给 Rust)。
  Rust 下载器会再兜底升一次(双保险, 也保证日志/缓存键看到同一个 URL)。
- 未动 UI 排版/文案,`home/**` `feed/` `app_sheet.dart` 一行没碰。

## 2. 关键决策与副作用

| 决策 | 理由 | 副作用/风险 |
|---|---|---|
| 只升网易域名族, 不升"所有 http" | 第三方源将来可能只支持明文, 强行改 scheme 会把能播的源改坏 | 若网易换到别的域名族(如自有 CDN 新域)需同步 `is_netease_host`/`isNeteaseStreamHost` |
| 401/403/404 不重试 | 直链失效, 原样重试只会多打上游、放大风控 | 需要"重取链"才能救 —— 那条链路在 Dart `retryNetwork`(取链层), 不在下载器 |
| 首包 15s / 读间隔 20s | 香港侧 TTFB 实测 0.1-0.4s(尖峰 1.15s), 15s 只抓"真的没响应" | 极慢网(吞吐 < 需求的 1/20)可能被判首包超时 ⇒ 重试一次后失败 |
| 重缓冲恢复线 2s | 一次 200-400ms 抖动不再被放大成 5s 静音 | 极慢网下 rebuffer 次数变多但每次更短(音乐码率低, 总体体感更好) |
| 起播门槛 1s | 切歌几乎立刻出声 | media3 硬下限就是 1000ms, 不能再低 |
| 缓存键兼容优先 | 验收口径要求"不清缓存" | **迁移期换档第一次仍可能命中旧码率文件**(旧文件无音质信息); 淘汰/重下后写成新键即恢复严格。命中旧键时会打 `[cache] hit legacy key ...` 日志 |
| GrowingFile 默认仍 90s | 下载器已有 20s 读超时, 阈值太小会把正常慢网判死 | 病态"下载线程消失"时最多仍要等 90s(可用 `NCM_GROWING_STALL_SECS` 调) |

**"失败重取链一次"的落点(如实说明)**: 下载器层做的是**同一 URL 重试一次**(新连接, 覆盖劫持/瞬时 5xx/超时);
"重取链"发生在 Dart 取链层(`home/playback_coordinator.dart` 的 `retryNetwork` 包住 `songUrl`),
而**下载动作的重取链**在 `home/song_action_wiring.dart::_downloadSong` 里已有 `retryNetwork`(取链)
—— 该文件属 `home/**`(本车道边界外), 未改动。

## 3. 自验结果

| 门 | 命令 | 结果 |
|---|---|---|
| Rust 全量单测 | `cargo test --offline`(workspace) | **349 passed / 0 failed**(基线 313 + 本车道 6 + 其它车道并发新增); 其中 `ncm-service` 227、`ncm-playback` 47 |
| Rust 静态 | `cargo clippy -p ncm-service -p ncm-playback -p ncm_ffi --all-targets --offline` | **0 warning / 0 error** |
| Rust 格式 | `cargo fmt -p ncm-service` / `-p ncm-playback`; `rustfmt --check crates/ncm-ffi/src/api.rs` | 干净 |
| Dart 静态 | `cd ui && dart analyze` | **No issues found!** |
| Dart 单测(全量) | `cd ui && flutter test` | **1281 passed / 1 skipped / 1 failed** —— 唯一失败是 `one_click_diag_test` 的「端点未配置」用例, 原因是**另一车道**把 `ui/lib/src/app_meta.dart` 的 `kDiagUploadEndpoint` 填成了真实域名(`git status` 可见该文件被改), 与本车道改动无关(未触碰 diag 相关文件) |
| Kotlin 单测 | `source tools/env.sh && cd ui/android && ./gradlew :app:testDebugUnitTest :app:lintDebug` | **BUILD SUCCESSFUL**; 单测 **10 passed / 0 failed**(基线 7 + 本车道 3); lint **0 error** |
| UI 纪律 | `tools/check-tokens.sh` / `check-row-padding.sh` / `check-write-guard.sh` | 全 OK(未改 UI 排版/写接口) |

### 本车道新增的单测(不联网)
- `cache::tests::prefer_https_upgrades_netease_http_only` —— http→https / https 不变 / `:80` 去掉 / 非网易域不动 / 不可解析原样
- `cache::tests::prefer_https_host_predicate_is_injectable` —— 判定可注入
- `cache::tests::classify_http_rejects_bad_status_and_html_first_packet` —— 非 2xx 分类 + `text/html` 首包判失败 + 可重试性 + `kind` 映射
- `cache::tests::cache_key_carries_level_and_falls_back_to_legacy` —— 新键形状 / 旧键回退 / 迁移期行为
- `cache::tests::cache_key_isolates_levels_when_no_legacy_file` —— 无历史遗留时换档不串码率
- `playback::backend::growing_tests::stall_limit_is_configurable_with_a_floor` —— 阈值默认/可配/下限
- `playback_url_test.dart` +3: 非网易域不动(含仿冒后缀) / `:80` 去掉 / 判定可注入

## 4. 需真机验证(本机做不到的部分)

1. **Android 缓冲水位真的生效**: 真机(弱网/香港网络)听 + `adb logcat` 抓 ExoPlayer `BUFFERING` 事件,
   对比恢复时延是否从 ~5s 降到 ~2s。JVM 单测只锁数值与合法性, 锁不了真实 rebuffer 时长。
2. **明文 http 劫持消失**: 桌面在校园网/运营商网的实机跑一首, 确认不再出现 `text/html` 首包(日志里 `[play] progressive download failed` 不应再出现 "被中间设备劫持")。
3. **GrowingFile stalled 错误可见性**: 真 stalled 时日志应出现 `[playback] growing file stalled > ... aborting this track` 且不再"静默切歌"。

## 5. 边界声明

- 未改 `ncm-domain::StreamUrl` 形状、未改任何 FFI 导出/未跑 codegen(`ui/lib/src/rust/*` 的改动来自并发车道 T1, 不是本车道)。
- 未改 UI 排版;`feed/`、`app_sheet.dart`、`home/**` 一行未动。
- 只格式化自己改的文件(`cargo fmt` 仅 `-p ncm-service`/`-p ncm-playback`;`ui/lib/src/playback.dart` 未跑 `dart format` —— 全仓会被 tall style 重排)。
- 未 commit。

■ 结束
