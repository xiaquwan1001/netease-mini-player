# 平台层（Android / 桌面 / 打包与 CI）架构审计 — 2026-11-16

**仓库** `/home/xuqianhui/netease-mini-player`（`git rev-parse --show-toplevel` 已核对）@ `346efb7` `chore(release): v0.14.0`
**性质**：只读审计。不改源码、不动分支/tag、不跑构建（避免和进行中的 lane 抢资源）；只用了 `rg`/`read`/`wc`/`cargo metadata`/`tools/check-tokens.sh` 这类轻量只读命令（附录 5）。
**承接**：`docs/archive/plans-2026-11/arch-audit-frontend-2026-11-15.md`、`docs/archive/plans-2026-11/arch-audit-backend-2026-11-15.md`。本文只覆盖**平台层**（Kotlin/Media3/MediaSession/WebView、桌面壳与 rodio、tools/*.sh、workflows、packaging、三端差异面），不重复前两份已判定的项（见 §3.3）。

## 目录

- 1. 现状实测表
  - 1.1 Android（Kotlin）
  - 1.2 桌面壳（Linux / Windows）
  - 1.3 播放引擎 `core/crates/ncm-playback`
  - 1.4 tools / CI / 打包
  - 1.5 三端分叉点矩阵（实测）
  - 1.6 重复职责清单
- 2. 具体缺陷候选（20 条，判据 + 位置 + 影响 + 修法）
- 3. 收益 / 风险 / 工作量排序表 + 明确不做
- 4. 前 5 建议（可直接开工）
- 5. 复现命令附录（全部只读）

---

## 1. 现状实测表

### 1.1 Android（Kotlin，`ui/android/app/src/main/kotlin/com/minincm/minincm/`）

| 文件 | 行数 | 实际职责 | 判读 |
|---|---|---|---|
| `PlaybackService.kt` | 641 | 拥有 ExoPlayer + MediaSession；通知按钮**槽位策略**；增益/淡入/slew/EQ/硬解/SimpleCache；`SkipAwarePlayer` 假 hasNext；UA/Referer | 单一类里 6 个变化轴（会话/通知/增益/EQ/缓存/解码），是 Android 侧最大的耦合点 |
| `MainActivity.kt` | 487 | **6 条 MethodChannel**：`ncm/player`、`ncm/upload`、`ncm/auth`、`ncm/keystore`、`ncm/mv`、`ncm/open`、`ncm/share`（实为 7 条）+ MediaController 连接 + 通知权限 + FileProvider 分享 + MediaStore 落图 + DownloadManager | "每个新平台能力都往这里塞一条"，无按通道拆分 |
| `EqAudioProcessor.kt` | 353 | AutoEQ ParametricEQ **文本解析** + RBJ biquad + Media3 `AudioProcessor`（16bit/float 交错 PCM） | 与 Rust `ncm-domain::eq_profile` / `ncm-playback::biquad`、Dart `eq_profile.dart` 三份等价实现（§2 P-05） |
| `KeystoreChannel.kt` | 192 | AES-256-GCM（AndroidKeyStore）+ `filesDir/cred/*.bin`（12B IV + 密文）；异常一律降级为 null/false | 与 `credential_store.rs` 的抽象对齐良好；Dart 侧 `keystore.dart` 已有 `CredentialSync` |
| `LoginActivity.kt` | 186 | WebView 官方授权页 + 1.5s cookie 轮询（`MUSIC_U=`）+ 顶栏关闭 | 见 §2 P-08（双重清 cookie）、P-09（硬编码浅色） |
| `MvPlayerActivity.kt` | 90 | 独立 `VideoView`，16:9 适配，不进 Media3 队列 | 见 §2 P-07（无 onPause 门） |

合计 Kotlin **1949 行 / 6 文件**；`find ui/android -name '*Test*.kt'` **为空**（无 instrumented test、无 Kotlin 单测）。
资源面：`res/drawable` 8 个通知图标（prev/next/heart filled+outline/repeat/repeat_one/shuffle/sequence）+ `launch_background`；`values` 与 `values-night` 各一份 `styles.xml`（仅 LaunchTheme/NormalTheme）。
构建：AGP 9.1.0 / Kotlin 2.4.0 / Gradle wrapper **9.3.1（腾讯镜像）**；media3 三个模块锁 1.9.4；minSdk/targetSdk 走 Flutter 默认；debug 变体 `applicationIdSuffix=".dev"` + `app_name` 加 `dev` 后缀。

### 1.2 桌面壳

| 文件 | 行数 | 职责 | 判读 |
|---|---|---|---|
| `ui/linux/runner/my_application.cc` | 148 | GTK 窗口/header bar、`#000000` 背景、1280×720、`G_APPLICATION_NON_UNIQUE` | 基本是 Flutter 模板；标题写死 `"minincm"`（:48/:52） |
| `ui/linux/runner/main.cc` | 6 | 模板入口 | 无改动 |
| `ui/linux/CMakeLists.txt` | ~158 | `APPLICATION_ID "com.minincm.minincm"`（:10）+ **GLib 基线钉 2.72**（`GLIB_VERSION_MIN/MAX_REQUIRED`）| GLib 钉法是本项目唯一"必须保留"的模板改动，注释完整 |
| `ui/windows/runner/main.cpp` | 43 | 窗口 `轻音 MiniNCM`、1180×780（:29-30） | 与 Linux 标题/尺寸不一致（§2 P-16） |
| `ui/windows/runner/flutter_window.cpp` | 71 | 模板 + WM_FONTCHANGE | 无改动 |
| `ui/windows/runner/win32_window.cpp / utils.cpp` | 288 / 69 | Flutter 模板（DPI、拖拽） | 无改动 |

**桌面没有**：托盘/MPRIS/媒体键、窗口位置记忆、单实例（Linux 显式 `NON_UNIQUE`）。MV 在桌面 = `PlatformBridge.openUrl`（系统播放器），与 Android 内嵌 `VideoView` 是两条完全不同的链路（`mv_playback.dart:13-36`）。

### 1.3 播放引擎 `core/crates/ncm-playback`

| 文件 | 行数 | 职责 |
|---|---|---|
| `lib.rs` | 728 | `Player`（命令 channel + 状态 Mutex）、rodio/CPAL 后端（`cfg(linux/windows)`）、`GrowingFile`（边下边播）、`GainLimiter` tick、EQ 包装源、非桌面桩后端 |
| `biquad.rs` | 353 | RBJ PK/LS/HS + 转置直接 II 型 + `EqChain` |
| `loudness.rs` | 459 | 自实现 BS.1770-4（EBU R128）测量 + ReplayGain 换算 |
| `agc.rs` | 147 | `GainLimiter`（默认 3 dB/s，上下对称） |

依赖按 target 分离（`Cargo.toml:14-16`）：`rodio` 只在 linux/windows 拉，Android 只留 symphonia（测量用），因此 Android 上 `ncm_playback::Player` 是 **空桩（stub）**（`lib.rs:640-654` 打日志直接返回）。这个设计是干净的，不是缺陷。

### 1.4 tools / CI / 打包

| 文件 | 行数 | 职责 | 与别处重复 |
|---|---|---|---|
| `tools/ci.sh` | 58 | 本地全量 CI（rust test/fmt/clippy → dart format → write-guard → **check-tokens** → analyze → bridge → build linux → build apk） | 与 `ci.yml`/`release.yml`/`.gitlab-ci.yml` 四处手抄同一批命令 |
| `tools/build-android.sh` | 49 | debug(`--split-per-abi`)/release + 签名指纹自检 | `flutter build apk` 参数在 5 处各写一遍（附录 §5.6） |
| `tools/build-linux.sh` | 11 | cargo test + flutter test + `flutter build linux --debug` | 与 ci.sh 重复 |
| `tools/bump-version.sh` | 57 | 唯一版本源 `ui/pubspec.yaml` → 同步 `app_meta.dart kAppVersion` | release.yml 里另有 3 处**独立**解析 pubspec 的 sed/pwsh |
| `tools/check-tokens.sh` | 118 | 间距/圆角/字号白名单（`--strict` 门） | **只在 tools/ci.sh 调用**，两套 CI 都没有（§2 P-14） |
| `tools/check-write-guard.sh` | 37 | 测试禁止直连写接口 | 三套 CI 都有（口径一致） |
| `tools/smoke-desktop.sh` | 238 | 桌面冒烟（env/bundle/arch/GLib 符号/DATA 目录/启动耗时） | GH release 与 gitlab 各自内联了一份 GLib 符号检查 |
| `tools/apt-install.sh` | 78 | apt 重试 + USTC 兜底 + 参数 trim | 位置合适，无重复 |
| `tools/api-coverage.sh` | 56 | vendor endpoint 覆盖率 | 无 |
| `tools/env.sh` | 15 | 统一环境变量 | 被 gitlab-ci 的 `before_script` 手抄一份 PATH |
| `tools/devui/*` | 6 脚本 | adb 语义树/截图/点击 | 无 |
| `.github/workflows/ci.yml` | 200 | rust / flutter / debug-apk / linux(x64+arm64) | 见 §2 P-18 |
| `.github/workflows/release.yml` | 373 | verify 门 + Android/Linux x64/arm64/Windows + publish | 同上（且 tag 的测试门比 ci.yml **弱**） |
| `.github/workflows/windows.yml` | 77 | 仅 `feat/windows` 分支 + 路径触发 | 与 release 的 build-windows 大量重复 |
| `.gitlab-ci.yml` | 144 | rust/flutter(测试) + 3 个 build job（tag 自动 / 分支手动） | 头部注释与 2026-11-16 的 runner 口径**相反**（§2 P-20 第 3 条） |
| `packaging/linux/build-deb.sh` | 104 | dpkg-deb，`/opt/minincm` + 软链 + desktop + pixmaps + metainfo | GLib 符号检查第 3 份副本 |
| `packaging/linux/build-appimage.sh` | 114 | AppDir + appimagetool（自动下载） | 见 §2 P-17（未 pin/未校验） |
| `packaging/linux/README.md` | — | 打包说明 | 引用了**不存在**的 `build-tarball.sh`（§2 P-15） |
| `packaging/windows/installer.iss` | 63 | Inno Setup，`AppVersion` 由 `/D` 传入 | 合理（版本不落第二份真相） |

### 1.5 三端分叉点矩阵（实测，全部可定位到文件:行）

| 维度 | Android（Media3） | Linux（rodio） | Windows（rodio） |
|---|---|---|---|
| 播放器 | `ExoPlayer` + `MediaSession`（`PlaybackService.kt:97-104`） | rodio `Player`（`lib.rs:400`） | 同 Linux（WASAPI） |
| 队列 | 原生只有 1 个 MediaItem，hasNext/Prev 恒真（`PlaybackService.kt:645-680`） | 无队列概念，单源 | 同 Linux |
| **增益变化** | `loudnessDynamic` 才 slew 3 dB/s，默认**瞬时**（`PlaybackService.kt:435-450`） | **恒定 3 dB/s**（`lib.rs:404-410`、`:509-513`），FFI 无 slew 参数（`api.rs:1424-1444`） | 同 Linux |
| 淡入 | `ValueAnimator`，作用在 `player.volume`（:470-490） | `Source::fade_in`，作用在样本（`lib.rs:375-377`） | 同 Linux |
| EQ 生效时机 | 改 EQ = **重建 player**，当前曲目短暂中断（:377-400） | 下一首开始才换源（`lib.rs:433-437` 注释） | 同 Linux |
| 缓存 | Media3 `SimpleCache` 分片 + LRU（私有 `cacheDir/audio`） | `AudioCache` 完整文件 + `.part` 渐进（`api.rs:1312-1328`） | **整首下完才播**（`api.rs:1305-1311` `#[cfg(windows)]`） |
| "边听边存"开关 | 生效 | **无效果**（恒渐进） | **无效果**（恒整首） |
| seek | `c.seekTo(ms)`（`MainActivity.kt:388-391`） | `let _ = player.try_seek(..)`，渐进期非 seekable → **静默失败**（`lib.rs:472`、`:443-450`） | 可精确 seek |
| 播放结束 | `STATE_ENDED` 事件 + 500ms 轮询兜底 | 只有轮询兜底 | 同 Linux |
| `state.volume` 语义 | **实际施加**（用户档×增益，`MainActivity.kt:412`） | 用户档（`lib.rs:474-482`） | 同 Linux |
| 凭据后端 | AndroidKeyStore | secret-service（`credential_keyring.rs`）/ file | DPAPI |
| 通知 | Media3 默认通知 + 5 按钮槽位 | 无 | 无 |
| MV | 内嵌 `VideoView` Activity | 系统播放器打开直链 | 同 Linux |
| 分享 | FileProvider + ACTION_SEND / MediaStore | 写文件 | 写文件 |
| 下载 | `DownloadManager`（`MainActivity.kt:180-215`） | Rust 缓存 | Rust 缓存 |

### 1.6 重复职责清单（真实重复，不是"设计如此"）

1. **EQ 文本解析 3 份**：Dart `eq_profile.dart:95`、Kotlin `EqAudioProcessor.kt:56`、Rust `ncm-domain/src/eq_profile.rs:127`；常量也各一份（`maxEqFilters=20`/`MAX_FILTERS=20`、`maxEqGainDb=24`/`MAX_GAIN_DB=24f`）。
2. **RBJ biquad 2 份**：`biquad.rs:28-100` 与 `EqAudioProcessor.kt:179-250`（注释自称"与 Rust 一致"，但无共享测试向量）。
3. **UA 字符串 2 份**：`identity.rs:42` 与 `PlaybackService.kt:568-570`（→ P-21）。
4. **GLib 2.80 符号检查 4 份**：`smoke-desktop.sh`、`build-deb.sh`、`release.yml`（x64 与 arm64 各一次）、`.gitlab-ci.yml`。
5. **`flutter build apk` 参数 5 份**、**`flutter test` tag 口径 3 份**（附录 §5.6）。
6. **apt 系统依赖清单 4 份**（ci.yml rust/flutter、release.yml build、gitlab 无此清单）。
7. **版本解析 5 处**：`bump-version.sh`（写）、`release.yml`（tag 门 + 2 处 Package）、`build-deb.sh:62`、`build-appimage.sh:58`、`.gitlab-ci.yml`（3 处）、`windows.yml:60`。

---

## 2. 具体缺陷候选

严重度：**P1** = 用户可见故障/功能静默丢失；**P2** = 漂移、可移植性、门禁缺口；**P3** = 卫生/一致性。共 **22 条**：P1×6、P2×11、P3×5。

### P-01（P1）划掉任务后，通知栏/耳机键的上一首·下一首·喜欢·模式全部静默失效

- **判据**：`MainActivity.onDestroy()` 主动把两个静态回调置空（`MainActivity.kt:479-482`），而 service 在"正在播放"时**不会**随任务消失（`PlaybackService.onTaskRemoved` 只在 `!playWhenReady || mediaItemCount==0` 时 `stopSelf()`，`PlaybackService.kt:236-241`）。通知按钮的点击路径是 `onCustomCommand → requestSkip → skipListener`（`PlaybackService.kt:138-152,582-585`）。
- **位置**：`MainActivity.kt:479-482`、`PlaybackService.kt:236-241`、`:582-585`、`:645-680`。
- **影响**：上划清任务 + 音乐继续播 → 通知还在，但 4 个自定义按钮和耳机键全部无反应（无 toast、无日志），必须重开 App；这是"看起来能用、实际哑掉"的最坏形态。
- **修法**：把"意图"与"消费者"解耦。最小改法：service 在 listener 为 null 时**缓存最近一条意图**（`pendingIntent`），并在 `skipListener` 非空时重放；或在 `onCustomCommand` 里直接用 `PendingIntent` 拉起 `MainActivity` 并带 action（不依赖同进程静态字段）。顺带在 `SkipAwarePlayer` 里让 `availableCommands` 在无消费者时去掉相应命令（至少诚实）。

### P-02（P1）通知按钮状态（红心/模式）没有自愈路径，服务重建后与真实状态不一致

- **判据**：原生侧状态默认 `likedState=false`、`modeIcon="sequence"`（`PlaybackService.kt:90-91`），只有 Dart 主动 `setActionState` 才更新（:127-131）；Dart 侧只在"换曲 / 点赞 / 切模式 / 初始化"时推（`main.dart:493,689,1317-1318,1334,2032,2048`），推送失败是**静默吞掉**（`playback.dart:224-235` `on PlatformException` 注释"下次状态变化再同步"）。
- **位置**：`PlaybackService.kt:90-91,127-131,155-175`；`ui/lib/src/playback.dart:206-235`；`ui/lib/main.dart:2119-2124`。
- **影响**：service 被系统回收后由媒体键拉起（或 Dart 侧一次 `not_ready`）→ 通知里显示"喜欢"但当前曲目已红心、图标停在"列表循环"，直到用户切歌；没有查询/重推机制。
- **修法**：给 `ncm/player` 加 `actionState` 读回（或让 `onConnect` 时主动向 Dart 发一条 `syncRequest`），并在 `_pollPlayer` 的 500ms tick 里做"每 N 秒或状态变更才推"的幂等同步（现在已有 tick，成本极低）。

### P-03（P1）增益变化语义三端不一致：桌面恒定 3 dB/s 斜坡，Android 默认瞬时

- **判据**：Android 只有 `loudnessDynamic` 且 slew>0 才走斜坡，否则瞬时（`PlaybackService.kt:435-450`，Dart 传 `loudnessDynamic ? 3.0 : 0.0`，`audio_tuning.dart:98`）；桌面 `GainLimiter` **默认 3 dB/s 且无法关闭**（`agc.rs:19-26,61`）`Player::configure` 直接进 limiter（`lib.rs:404-410`），而 FFI `player_configure` 签名只有 `gain_db/fade_ms/eq_text`（`api.rs:1424-1444`）。Dart 注释声称"Linux 侧由 Rust 自己在 200ms tick 上做同样的限速"（`audio_tuning.dart:97`）——**"同样的"只对动态模式成立**。
- **位置**：`ui/lib/src/audio_tuning.dart:96-108`、`ui/lib/src/playback.dart:202-221`、`core/crates/ncm-ffi/src/api.rs:1424-1444`、`core/crates/ncm-playback/src/lib.rs:404-410,509-513`、`agc.rs:12-40`。
- **影响**：同一份设置/同一首歌，桌面拖"精细音量"滑块听感是 1–4 s 渐变（+12→−12 dB 约 8 s），Android 瞬时；用户报"桌面音量反应慢"会归因到播放卡顿，排查方向直接跑偏。
- **修法**：给 `PlaybackTuning` 加 `gain_slew_db_per_sec: f32`（0=瞬时），FFI 透传，Dart 两个平台都按 `loudnessDynamic ? 3.0 : 0.0` 传；`agc::GainLimiter::with_slew` 已支持。改动小（~30 行 + 一次 codegen），且顺手把"同一口径"写死在类型上。

### P-04（P1）「边听边存」开关在桌面是安慰剂，Windows 必等整首下载

- **判据**：设置页在**所有平台**都显示"边听边存"和"缓存上限"（`settings_audio_page.dart:255-282`，只有"硬件解码"做了平台分支 :249-264）；Dart 桌面分支只把 `gainDb/fadeMs/eqText` 传给 Rust（`audio_tuning.dart:102-106`），`streamCache` 根本没有通道；Rust 播放路径：Linux 恒 `start_progressive`（`api.rs:1312-1328`），Windows 恒 `cache.fetch`（整首，:1305-1311）。
- **位置**：`ui/lib/src/settings_audio_page.dart:249-282`、`ui/lib/src/audio_tuning.dart:102-106`、`core/crates/ncm-ffi/src/api.rs:1305-1328`。
- **影响**：(a) 用户在桌面关掉开关，行为零变化（设置说谎）；(b) Windows 上每首歌都要等整首下载完才出声，切歌延迟随网速线性增长——这是三端体验差异最大的一处，但 UI 完全没提。
- **修法**：桌面把"边听边存"改成只读说明（Linux："恒开（渐进下载+落盘）"、Windows："不可用（整首下载后播放）"）；若要动行为，给 Windows 补 `GrowingFile` 路径（`PlaySource::Growing` 已存在，只需去掉 `#[cfg(windows)]` 分支并验证 WASAPI 下的 EOF 阻塞语义）。

### P-05（P1）EQ 解析三份实现，且 Kotlin 的解析失败/生效结果**永远不会到达 UI**

- **判据**：三个解析器（§1.6-1）；`configure` 回显里带 `eqApplied/eqError/eqFilters`（`PlaybackService.kt:288-299,338-350`），Dart 调用处**丢弃返回值**（`audio_tuning.dart:89-99` 只 `await`，不读 map）。`cachedFileFor`/Logcat `NCM-EQ` 是唯一可观测面。
- **位置**：`ui/android/.../EqAudioProcessor.kt:31-32,56-160`、`PlaybackService.kt:288-350`、`ui/lib/src/audio_tuning.dart:80-108`、`ui/lib/src/eq_profile.dart:18-136`、`core/crates/ncm-domain/src/eq_profile.rs:23,127`。
- **影响**：Dart 校验通过（±24 dB / 20 filter 与 Rust 一致，但**规则细节**由三份代码各自解释，例如单位大小写、`Preamp` 缺省、`ON/OFF` 变体）→ Kotlin 解析失败 → EQ 静默旁路，用户以为曲线在跑。修 EQ 相关问题只能靠 `adb logcat`。
- **修法**：(1) 立刻可做：`applyAudioTuning` 读回显，`eqApplied==false` 时 toast/日志上报（S）；(2) 中期：把"同一段文本"作为共享 fixture，Dart/Kotlin/Rust 各跑一遍断言系数与错误行号（S–M）；(3) 长期才考虑让 Kotlin 不做文本解析（见 §3.3 不做）。

### P-06（P1）冷启动时保存的调音参数可能完全没落到底层（竞态 + 静默失败）

- **判据**：`_bootstrap()` 里 `unawaited(applyAudioTuning())`（`main.dart:342`）与 `PlaybackService` 的创建（`MainActivity.configureFlutterEngine` 里的 `MediaController.Builder`）无任何同步；Android 侧 `configure` 在服务未建好时返回 `not_ready`（`MainActivity.kt:320-325`），Dart 侧 `catch (_) {}` 全部吞掉（`audio_tuning.dart:105-108`）。
- **位置**：`ui/lib/main.dart:342`、`MainActivity.kt:320-325`、`ui/lib/src/audio_tuning.dart:80-108`。
- **影响**：非默认设置（增益/淡入/EQ/硬解/缓存上限）在冷启动后有概率不生效，直到用户改一次设置或切歌触发下一轮 `applyAudioTuning`。属"偶发、难复现、被当成玄学"的一类。
- **修法**：`PlaybackService.onCreate` 里从 `AppSettings`（持久化 json）读一次并 `configure`；或 `MainActivity` 缓存 `pendingConfigure`，在 `PlaybackService.instance` 就绪时重放（`SkipAwarePlayer` 已有"就绪回调"的位置）。另：`not_ready` 不该静默，至少 `debugPrint` 一次。
  - 注：本条为**静态可判定**时序缺口，未在设备上复现（审计不开模拟器）。

### P-07（P2）MV 播放没有生命周期门：切后台/锁屏后视频声音继续

- **判据**：`MvPlayerActivity.onPause` 仅 `if (isFinishing) video.stopPlayback()`（`MvPlayerActivity.kt:76-79`），`onDestroy` 才停（:81-84）。`VideoView` 不会因 Activity 暂停自动停。
- **位置**：`ui/android/app/src/main/kotlin/com/minincm/minincm/MvPlayerActivity.kt:76-84`。
- **影响**：按 Home/锁屏后 MV 音频继续，与后台歌曲播放叠加；用户以为"MV 关不掉"。
- **修法**：`onPause`/`onStop` 里 `video.pause()`（或 `stopPlayback()`），`onResume` 恢复播放位置；屏幕常亮已用 `FLAG_KEEP_SCREEN_ON`，不必再动。

### P-08（P2）登录 cookie 清理做了两遍，且第二遍是"发起后不等"

- **判据**：`MainActivity` 的 `loginWeb` 先 `removeAllCookies { flush; startActivity }`（`MainActivity.kt:104-115`），`LoginActivity.onCreate` 又 `removeAllCookies(null)` 并**立刻** `loadUrl`（`LoginActivity.kt:52-54,73`）。
- **位置**：`ui/android/.../MainActivity.kt:104-115`、`LoginActivity.kt:50-54,73`。
- **影响**：`removeAllCookies` 是异步的，第二次清理的回调可能在页面已开始写 cookie 之后落地（取决于机型/时序），理论上会吃掉刚写入的域 cookie；至少也是重复劳动 + 两处语义各写一半，改一处漏一处。
- **修法**：只保留 `LoginActivity` 一处，并且**在回调里再 `loadUrl`**（把 `loadUrl` 从 `apply{}` 里移到 `removeAllCookies { flush; loadUrl(...) }`）；`MainActivity` 只负责 `startActivity`。

### P-09（P2）登录页/MV 页固定浅色，与 App 深浅色主题冲突

- **判据**：manifest 给两个 Activity 指定 `@android:style/Theme.Material.Light.NoActionBar`（`AndroidManifest.xml:41,47`），`LoginActivity` 还硬编码顶栏色 `HEADER_BG=0xFFF5F5F5`/`HEADER_FG=0xFF1A1A1A`（`LoginActivity.kt:181-182`）；而 App 有 `values-night` 且 Flutter 侧有深色主题。
- **位置**：`ui/android/app/src/main/AndroidManifest.xml:41,47`、`LoginActivity.kt:85-92,181-182`。
- **影响**：夜间模式打开登录页/播 MV，整屏闪白；MV 页还会因为亮色 theme 让状态栏/导航栏处理不一致。
- **修法**：两个 Activity 换 `Theme.Material.DayNight.NoActionBar`（或项目自定义 theme），配色改从 `?android:attr/colorBackground`/`values-night` 资源取。

### P-10（P2）桌面渐进播放期间 seek 静默失败（Linux）

- **判据**：`Cmd::Seek` 用 `let _ = player.try_seek(..)` 丢弃错误（`lib.rs:472`）；渐进播放用 `with_seekable(false)` 构建解码器（`lib.rs:443-450`），rodio 对非 seekable 源 `try_seek` 必失败。Dart 侧 `_seekTo` 用返回的 state 覆盖 UI（`main.dart:2140-2149`）。
- **位置**：`core/crates/ncm-playback/src/lib.rs:443-450,472`、`ui/lib/main.dart:2140-2149`。
- **影响**：Linux 上"边下边播"期间拖进度条，进度条会跳到你拖的位置然后**弹回旧位置**，没有提示；用户会认为"seek 坏了/播放器卡住了"。
- **修法**：`Player` 暴露"当前源是否可 seek"（`state` 加字段或 `PlaybackError::Unsupported` 回传），Dart 据此禁用/提示进度条；或渐进期把 seek 记成 `pending_seek`，等 `done` 后应用。

### P-11（P2）桌面侧没有任何自动化测试，Android 侧零测试

- **判据**：`find ui/android -name '*Test*.kt'` 为空、无 `androidTest`/`test` 目录；`ui/test` 里只有 5 个文件通过 mock channel 覆盖桥接形状（`keystore_channel_test.dart`、`playback_tuning_test.dart`、`mv_page_test.dart` 等）；`notification_actions_test.dart` 只测纯 Dart 的 `notification_mode.dart` 映射，测不到槽位策略。
- **位置**：`ui/android/app/src/main/**`（无测试）、`ui/test/notification_actions_test.dart`。
- **影响**：本报告 6 条 P1 里有 4 条（P-01/P-02/P-05/P-06）都在这一层，且都是"改一行就可能回归、回归只有真机能发现"的逻辑；现有门禁（dart analyze / flutter test / cargo clippy）一条都覆盖不到。
- **修法**：把可纯化的部分抽出来测（按钮槽位表、`modeIcon` 映射、cookie 去重、`stateMap` 语义）；Kotlin 侧加一组 `test/`（JVM 单测，无需设备）覆盖 `parseParametricEq` 与 `cachedFileFor` 的纯逻辑；再加一条 `tools/devui` 风格的 adb 断言脚本（通知 action 顺序，可从 `dumpsys notification` 读）。

### P-12（P2）通知点击没有指定 session activity

- **判据**：`rg -n 'setSessionActivity|PendingIntent' ui/android` **0 命中**；`MediaSession.Builder` 只设了 callback（`PlaybackService.kt:100-103`）。
- **位置**：`PlaybackService.kt:100-103`。
- **影响**：点击通知回到 App 依赖 Media3 默认行为（未设 session activity 时多数版本不生成 contentIntent），在部分 ROM 上表现为"点通知没反应，只能从桌面图标进"。**需一条 adb 实测确认当前表现**（附录 §5.9），确认后再按 P2/P3 处理。
- **修法**：`MediaSession.Builder(...).setSessionActivity(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), FLAG_IMMUTABLE))`。

### P-13（P2）CI 四处手抄命令且口径已经漂：发版门的测试比 CI **弱**

- **判据**：`flutter test` 排除标签三处不一致——`ci.yml:65`/`.gitlab-ci.yml:41` 用 `--exclude-tags network`（**含** golden），`release.yml:54` 用 `--exclude-tags 'network || golden'`（**排除** golden 与 network，最弱的门装在发版上）；`flutter build apk` 参数 5 份（附录 §5.6）；`tools/ci.sh` 有 `flutter analyze` 回落 `dart analyze`（:47-52），两套 CI 都没有；`apt` 依赖清单 4 份且 gitlab 缺 `clang/cmake/libgtk-3-dev`（靠 runner 自带）。
- **位置**：`.github/workflows/ci.yml:28-65`、`.github/workflows/release.yml:40-54`、`.gitlab-ci.yml:20-41`、`tools/ci.sh:1-58`。
- **影响**：golden 回归在 tag 上不跑 → "发出去的包比 main 上测过的少一层"；命令漂移导致的差异（ABI 列表、排除标签、analyze 回落）只能靠人记。
- **修法**：CI 只调 `bash tools/ci.sh`（把 tag/环境差异做成参数），或至少把三处 `flutter test` 指令统一成 `--exclude-tags network`（golden 有字体就一定会跑，见 ci.yml:47-49 的 fonts 步骤）。发版门至少不能比 CI 弱。

### P-14（P2）门禁覆盖不对称：token 门与 Android 静态检查都不在 CI 里

- **判据**：`bash tools/check-tokens.sh --strict` 只出现在 `tools/ci.sh:41`，`rg -n 'check-tokens' .github .gitlab-ci.yml` **0 命中**；Kotlin 侧无 `ktlint/detekt/lintOptions`，`rg -n 'ktlint|detekt|lintOptions' ui/android` **0 命中**，CI 也没有 `./gradlew lint`。
- **位置**：`tools/ci.sh:41`、`.github/workflows/ci.yml`（flutter job）、`.gitlab-ci.yml`、`ui/android/app/build.gradle.kts`。
- **影响**：AGENTS.md 把 token 集合写成"固定门"，但只有本地脚本跑它；Kotlin 1949 行（含 641 行的 `PlaybackService`）完全没有任何静态检查，PR 只靠人眼。
- **修法**：两套 CI 的 flutter job 各加一行 `bash tools/check-tokens.sh --strict`；Android job 加 `flutter build apk` 后的 `cd android && ./gradlew :app:lintDebug`（或引入 ktlint CLI，见 §3.3 不做 Gradle 插件）。

### P-15（P2）Gradle wrapper 指到腾讯镜像，构成构建可移植性单点

- **判据**：`ui/android/gradle/wrapper/gradle-wrapper.properties:5` `distributionUrl=https\://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-bin.zip`。AGENTS.md 记录的 CI 环境是 GitHub `ubuntu-24.04` 与 USTC 共享 runner。
- **位置**：`ui/android/gradle/wrapper/gradle-wrapper.properties:5`。
- **影响**：非中国网络环境（或镜像临时不可用）时 gradle 分发包拉取失败，表现是 `flutter build apk` 在依赖解析前就红；本地开发则反过来卡 `services.gradle.org`。这是"离线可复现性"里最容易忘的一环。
- **修法**：默认写官方 `distributionUrl`，镜像通过 `~/.gradle/init.d/` 或 `GRADLE_USER_HOME` 的 `gradle-wrapper.properties` 覆盖（本地已有带宽问题时用环境变量，不要写进仓库）。

### P-16（P2）打包文档引用不存在的脚本

- **判据**：`packaging/linux/README.md:21` 指示 `bash packaging/linux/build-tarball.sh dist`，但 `ls packaging/linux/` 只有 `README.md build-appimage.sh build-deb.sh metainfo.xml minincm.png`；tar.gz 实际由 `release.yml:150` 与 `.gitlab-ci.yml:71` 内联 `tar` 生成。
- **位置**：`packaging/linux/README.md:21`。
- **影响**：任何按文档在本机出 tar.gz 的人第一步就失败；也让"打包只有 deb/AppImage 两个脚本"的事实被误读。
- **修法**：补 `build-tarball.sh`（3 行 `tar`，同时被 CI 复用，顺带消掉 2 份内联 tar），或把 README 改成"tar.gz 由 CI 内联生成"。

### P-17（P2）AppImage 工具链未 pin、未校验，且首次失败把 stderr 丢掉

- **判据**：`build-appimage.sh:55-66` 从 `.../releases/download/continuous/appimagetool-$ARCH.AppImage` 下载并直接 `chmod +x` 执行，无版本 pin、无 sha256；调用处 `:110-111` 第一条命令 `>/dev/null 2>&1` 失败后才回退第二条。
- **位置**：`packaging/linux/build-appimage.sh:55-66,108-112`。
- **影响**：供应链上"CI 里跑一个可变 URL 的二进制"；失败时（例如 FUSE 缺失、下载被墙）第一条的报错被掩埋，只剩第二条的噪声日志，排查时间显著变长。
- **修法**：pin 一个 release tag + 内置 sha256 校验；失败路径保留 stderr 到文件并在末尾打印。

### P-18（P3）窗口标题/默认尺寸/application-id 三处不一致

- **判据**：Linux 标题 `"minincm"`、1280×720（`my_application.cc:48,52,55`）；Windows 标题 `轻音 MiniNCM`、1180×780（`main.cpp:29-30`）；`APPLICATION_ID = "com.minincm.minincm"`（`ui/linux/CMakeLists.txt:10`）vs AppStream/desktop 用 `io.github.xiaquwan1001.MiniNCM`（`metainfo.xml` 文件名、deb 的 `StartupWMClass=minincm`）。
- **位置**：`ui/linux/runner/my_application.cc:48,52,55`、`ui/windows/runner/main.cpp:29-30`、`ui/linux/CMakeLists.txt:10`、`packaging/linux/build-deb.sh:83-97`。
- **影响**：桌面任务栏/窗口标题显示小写包名；两平台默认窗口尺寸与标题不同，截图回归/截图对比脚本要写两套；应用 ID 与 AppStream ID 不一致会让软件中心的关联/图标匹配不稳定。
- **修法**：标题统一 `轻音 MiniNCM`、尺寸统一（建议 1180×780 或 1280×720 二选一写进 layout 常量）；application-id 与 AppStream id 对齐——**但改 id 会影响单实例行为/用户数据路径，需评估后再动**（本条不建议顺手改）。

### P-19（P3）metainfo 版本靠 sed 覆盖且无断言

- **判据**：`packaging/linux/io.github.xiaquwan1001.MiniNCM.metainfo.xml:46` 写死占位 `<release version="0.3.2" .../>`（当前 pubspec 是 `0.14.0`），`build-deb.sh:78`/`build-appimage.sh:87` 用 `sed -i "s|<release version=\"[^\"]*\"|...|` 覆盖，**不校验**是否命中。
- **位置**：`packaging/linux/io.github.xiaquwan1001.MiniNCM.metainfo.xml:46`、`build-deb.sh:78`、`build-appimage.sh:87`。
- **影响**：格式一变（改成多个 `<release>` 或换引号）sed 静默 no-op，出厂包带着 0.3.2 进入软件中心而流水线全绿。
- **修法**：sed 后 `grep -q "version=\"$VER\"" || exit 1`；或让 CI 用 `bump-version.sh` 同源生成 metainfo。

### P-20（P3）残留死代码与注释漂移（四处，低风险）

- **判据**：
  1. `CMD_NEXT` 在 `MainActivity.actionListener` 里的映射已不可达（`PlaybackService.kt:601-605` 自己写了"不再被使用(文件范围外, 未删)"，`MainActivity.kt:55-68` 仍保留）；
  2. `PlaybackService.kt:280-283` 有一处被拆断的 KDoc（`*/` 结束后面跟一个列 0 的 `/**`，因为中间插了另一个函数的注释块）；
  3. `.gitlab-ci.yml:2-3` 头部"本机 runner：宿主工具链直跑"与 2026-11-16 的"USTC 不用本地 runner，用平台共享 runner 且空闲才跑"口径**相反**；
  4. `main.dart:340-341` 的注释"启动时把已保存的播放参数与缓存上限应用一次"下面插进了"首帧后 3s 后台静默检查更新"，读起来像更新检查在应用参数。
- **位置**：`PlaybackService.kt:280-283,601-605`、`MainActivity.kt:55-68`、`.gitlab-ci.yml:2-3`、`ui/lib/main.dart:340-345`。
- **影响**：审计/交接时误导（尤其第 3 条会让人以为 CI 跑在谁身上都搞错）。
- **修法**：逐条删/改，一次性 5 分钟，不改行为。

### P-21（P2）播放 UA 是两份独立的字符串常量，注释只写"同一串"

- **判据**：Rust `identity.rs:42` 的 `ANDROID_PROFILE.ua` 与 Kotlin `PlaybackService.kt:568-570` 的 `USER_AGENT` 是同一串手抄常量，Kotlin 侧注释"（与 ncm-service 的 ANDROID_PROFILE.ua 同一串），不要拿 PC 桌面 UA 冒充"——**没有任何机制保证**这两串一致；CDN 对 UA 敏感（同文件 :461-466 注释记录了"ExoPlayer 默认 UA 会被 CDN 拒"）。
- **位置**：`core/crates/ncm-service/src/identity.rs:42`、`ui/android/app/src/main/kotlin/com/minincm/minincm/PlaybackService.kt:461-466,565-571`。
- **影响**：升级客户端版本号（UA 里带 `9.1.65.240927161425(9001065)`）只改一侧 → 取链用新 UA、播放用旧 UA，风控/CDN 行为不一致，表现为"偶发 403/偶发无声"，而两处代码看起来都对。
- **修法**：Rust 侧把 UA 作为 FFI 常量/函数暴露（`ncm-ffi` 一行），Kotlin 在 `PlaybackService.onCreate` 里取一次并缓存；或反过来让 Rust 的 provider 从 Dart 注入同一个常量。再加一条断言（Kotlin 侧拿不到 FFI 时退化为记录 logcat 对比）。改 FFI 需走固定三步（codegen → `cargo build -p ncm_ffi` → `flutter test`）。

### P-22（P3）全局放开明文流量，但直链已经强制 https

- **判据**：`AndroidManifest.xml:13` `android:usesCleartextTraffic="true"`（注释解释是 `*.music.126.net` 明文直链）；而 Dart 侧已把播放直链统一升级 https（`playback.dart:31-40` `preferHttpsStreamUrl`，注释记录了"CDN 同路径支持 https"）。
- **位置**：`ui/android/app/src/main/AndroidManifest.xml:13`、`ui/lib/src/playback.dart:31-40`。
- **影响**：整机范围内允许明文（含下载/外链通道），比实际需要更宽；将来 Play 商店/安全审阅会问这一条。
- **修法**：改成 `networkSecurityConfig` 只对 `music.126.net`/`music.163.com` 放开 cleartext（其余默认拒绝），并实测歌词/封面/下载/MV 四条链路。**注意**：先确认没有别的明文域（`rg -n 'http://' core ui/lib --glob '!core/vendor/**'`），否则会打断某条链路，所以排 P3。

---

## 3. 收益 / 风险 / 工作量排序表

评分口径同前两份：收益 = 消除的用户可见故障 + 消除的漂移面 + 防护面；工作量 S(<0.5d)/M(0.5–2d)/L(>2d)；风险按"可能引入用户可见回归 + 需要真机验证"。

### 3.1 排序表

| # | 改动 | 缺陷 | 收益 | 风险 | 工作量 | 收益/成本 |
|---|---|---|---|---|---|---|
| 1 | 统一增益 slew 口径（类型 + FFI + 两端调用） | P-03 | **高**（消掉三端最大听感差异，且把口径写进类型） | 中低（改 FFI 需 codegen，桌面行为变"瞬时"要听一耳朵） | S–M（~30 行 + codegen） | ⭐⭐⭐⭐⭐ |
| 2 | 桌面设置项诚实化（`streamCache`/缓存上限加平台说明） | P-04 | 中高（去掉"设置说谎"，Windows 用户知道为什么慢） | **极低**（纯 UI 文案/可见性） | S | ⭐⭐⭐⭐⭐ |
| 3 | 通知意图与服务生命周期解耦（pending intent 缓存 / PendingIntent 拉起） | P-01 | **高**（恢复"清任务后通知仍可用"） | 中（MediaSession/Service 生命周期，需 2 条真机用例） | M | ⭐⭐⭐⭐ |
| 4 | 通知按钮状态自愈（onConnect 请求同步 + tick 幂等推送） | P-02 | 中高（图标与真相一致，无"僵尸图标"） | 低（只是在已有 tick 里加推送） | S–M | ⭐⭐⭐⭐ |
| 5 | CI 收敛到 tools/ci.sh + 统一 `flutter test` 口径 | P-13 | 中高（发版门不再弱于 CI；4 份清单一处改） | 低（不碰产品代码） | M | ⭐⭐⭐⭐ |
| 6 | token 门进 CI + Android 静态检查进 CI | P-14 | 中（门禁从"本地自觉"变真门） | 低（新增 job 只会更红，不影响产物） | S（token 一行）/ M（gradle lint） | ⭐⭐⭐⭐ |
| 7 | EQ 错误回显到 UI（消费 `eqApplied/eqError`） | P-05 立刻项 | 中（把"静默旁路"变成可见提示） | 低 | S | ⭐⭐⭐⭐ |
| 8 | MV 生命周期门（onPause/onStop 停） | P-07 | 中（消掉"MV 关不掉/双重声音"） | 低 | S | ⭐⭐⭐⭐ |
| 9 | 冷启动调音竞态（service 侧读设置 or pending configure） | P-06 | 中（消掉偶发"设置没生效"） | 中低（需冷启动实测 3 次） | S–M | ⭐⭐⭐ |
| 10 | 登录 cookie 清理归一（只留 LoginActivity 并等回调） | P-08 | 中（多账号登录/切号稳定） | 中（登录是主路径，要真机走一遍扫码/手机号） | S | ⭐⭐⭐ |
| 11 | 桌面渐进期 seek 诚实化（禁/提示或 pending_seek） | P-10 | 中（消掉"进度条弹回"投诉） | 中（改 seek 交互语义） | S–M | ⭐⭐⭐ |
| 12 | 平台层测试补齐（纯函数抽测 + JVM 单测 + adb 断言脚本） | P-11 | **高**（护住 4 条 P1 的落点） | 低（只加测试/脚本） | M | ⭐⭐⭐ |
| 13 | EQ 三份解析共享 fixture（同文本 → 同系数/同行号） | P-05 中期 | 中高（防三份实现慢慢分叉） | 低 | S–M | ⭐⭐⭐ |
| 14 | Gradle wrapper 改官方源 + 本地覆盖机制 | P-15 | 中（构建可移植性） | 低（本地首次要重下 9.3.1） | S | ⭐⭐⭐ |
| 15 | AppImage 工具链 pin + sha256 + 保留 stderr | P-17 | 中（供应链 + 可排查性） | 低 | S | ⭐⭐⭐ |
| 16 | 补 `build-tarball.sh` 并让 CI 复用 | P-16 | 中低（文档不再骗人，消 2 份内联 tar） | 极低 | S | ⭐⭐⭐ |
| 17 | UA 单一真相（Rust 常量经 FFI 给 Kotlin + 一致性测试） | P-21 | 中（防 CDN 403 类"协议玄学"） | 中低（codegen + 启动顺序） | S–M | ⭐⭐⭐ |
| 18 | metainfo 版本 sed 后断言 | P-19 | 低中（防静默错版本） | 极低 | S | ⭐⭐⭐ |
| 19 | 登录/MV 页 DayNight 主题 + 资源配色 | P-09 | 中低（夜间体验一致） | 低（纯资源） | S | ⭐⭐⭐ |
| 20 | 死代码/注释漂移清理（4 处） | P-20 | 低（读代码不误导） | 极低 | S | ⭐⭐ |
| 21 | 窗口标题/尺寸统一；application-id 与 AppStream 对齐 | P-18 | 低 | 中（改 application-id 影响单实例/数据路径） | S / M | ⭐⭐ |
| 22 | cleartext 收窄到 `*.music.126.net`（networkSecurityConfig） | P-22 | 低中（缩小攻击面，且 Dart 已 prefer https） | 中（可能打断某条下载/外链路径） | S | ⭐⭐ |

### 3.2 建议节奏

- **第一批（半天，零行为风险）**：1、2、6(token 一行)、7、16、18、20 —— 全是配置/文案/门禁。
- **第二批（1–2 天，需 3 条真机用例）**：3、4、8、9 —— 都是 Android 生命周期，验收口径：清任务后通知 4 按钮仍生效、服务重建后红心图标正确、MV 切后台静音、冷启动 3 次设置生效。
- **第三批（结构项，独立提交）**：5、12、13 —— CI 与测试基建，先把门建好再动 5/11 的行为。
- **第四批（可选，按用户反馈排）**：10、11、14、15、17、19、21、22。

### 3.3 明确「不做」（含前两份已判定的，不再重提）

1. **不给桌面加 MPRIS / 托盘 / 媒体键**（现在没有需求，且与 500ms 轮询状态模型不是一套东西；成本 L，验收要靠桌面环境矩阵）。
2. **不把 `ncm-playback` 的 rodio 后端做成可插拔 backend trait**（唯一消费者是 `ncm-cli`/`ncm-ffi`，YAGNI；`cfg` 分文件已经够）。
3. **不让 Kotlin 改成"从 Rust 拿 EQ 系数"**（跨 FFI 传数组 + codegen + 采样率协商，L；先做 P-05 的 fixture 与错误回显即可）。
4. **不引入 ktlint/detekt 的 Gradle 插件**（改构建链风险 > 收益；要门就用独立 CLI 跑在 CI，或用 `./gradlew :app:lintDebug`）。
5. **不把 6 条 MethodChannel 改成 Pigeon**（要重生成两侧代码 + 改 Dart 测试桩，收益只是少写几行 handler；按通道拆文件（§1.1）就够了）。
6. **不重提**：`api.rs` 按域拆、Provider 拆 trait、引 provider/riverpod、golden 改字体资产（见前两份报告的"明确不做"段）；`setCustomLayout` 替代 media button preferences（`PlaybackService.kt:186-231` 已实测否决，含 a34 的 dumpsys 证据）。
7. **不动 `APPLICATION_ID`**（P-18 只做标题/尺寸；改 id 影响单实例与用户数据路径，需用户决策）。

---

## 4. 前 5 建议（可直接开工，一句话一条）

1. **给 `PlaybackTuning` 加 `gain_slew_db_per_sec`（0 = 瞬时）并让两端都按 `loudnessDynamic ? 3.0 : 0.0` 传**，一次性消掉"桌面音量反应慢/Android 瞬时"的三端分叉 —— `core/crates/ncm-playback/src/lib.rs`、`src/agc.rs`、`core/crates/ncm-ffi/src/api.rs`、`ui/lib/src/audio_tuning.dart`、`ui/android/.../PlaybackService.kt`（改 FFI 记得走固定三步：codegen → `cargo build -p ncm_ffi` → `flutter test`）。
2. **把"边听边存/缓存上限"在桌面改成只读说明**（Linux 恒渐进、Windows 恒整首），并把 Windows 的整首下载行为写进设置页副标题 —— `ui/lib/src/settings_audio_page.dart`、`ui/lib/src/audio_tuning.dart`（只改 UI，不改 Rust）。
3. **通知意图与服务生命周期解耦**：`onCustomCommand` 在无 Dart 消费者时缓存意图（或用 `PendingIntent` 拉起 `MainActivity` 带 action），并在 `onConnect` 主动请求一次状态同步 —— `ui/android/.../PlaybackService.kt`、`MainActivity.kt`、`ui/lib/src/playback.dart`、`ui/lib/main.dart`。
4. **CI 收敛**：两套 CI 的 flutter job 各加 `bash tools/check-tokens.sh --strict`，三处 `flutter test` 统一为 `--exclude-tags network`（发版门不得弱于 CI）—— `.github/workflows/ci.yml`、`.github/workflows/release.yml`、`.gitlab-ci.yml`、`tools/ci.sh`。
5. **EQ 失败可见**：`applyAudioTuning` 读回 `configure` 的 `eqApplied/eqError`，失败时 toast + `debugPrint`；同时加一份三方共享的 EQ 文本 fixture —— `ui/lib/src/audio_tuning.dart`、`ui/test/eq_profile_test.dart`、新增 `ui/android/app/src/test/.../EqParseTest.kt`、`core/crates/ncm-domain/src/eq_profile.rs`（test 段）。

---

## 5. 复现命令附录（全部只读）

```bash
# 0) 身份校验
git -C /home/xuqianhui/netease-mini-player rev-parse --show-toplevel   # 必须等于该路径
git -C /home/xuqianhui/netease-mini-player rev-parse --short HEAD       # 346efb7

# 1) 规模
wc -l ui/android/app/src/main/kotlin/com/minincm/minincm/*.kt \
      ui/linux/runner/*.cc ui/windows/runner/*.cpp \
      core/crates/ncm-playback/src/*.rs tools/*.sh \
      .github/workflows/*.yml .gitlab-ci.yml packaging/linux/*.sh packaging/windows/installer.iss

# 2) 平台层是否有任何 Kotlin 测试 / 静态检查（预期：都为空）
find ui/android -name '*Test*.kt'
find ui/android -type d -name 'androidTest*' -o -type d -name 'test*'
rg -n 'ktlint|detekt|lintOptions|lint \{' ui/android --glob '!**/build/**'

# 3) 通知命令链（P-01/P-02）
rg -n 'skipListener|actionListener|requestSkip|onTaskRemoved|likedState|modeIcon|setActionState' \
   ui/android/app/src/main/kotlin/com/minincm/minincm/{MainActivity,PlaybackService}.kt
rg -n 'setSessionActivity|PendingIntent' ui/android           # P-12：预期 0 命中
rg -n 'setActionState|_syncActionState' ui/lib/main.dart ui/lib/src/playback.dart

# 4) 增益/淡入/EQ/缓存 的三端分叉（P-03/P-04/P-05）
rg -n 'gainSlewDbPerSec|loudnessDynamic' ui/lib/src/audio_tuning.dart ui/android/app/src/main/kotlin/com/minincm/minincm/PlaybackService.kt
rg -n 'GainLimiter|with_slew|max_slew_db_per_sec' core/crates/ncm-playback/src/{lib.rs,agc.rs}
rg -n 'pub fn player_configure' -A22 core/crates/ncm-ffi/src/api.rs
rg -n 'cfg\(windows\)|start_progressive|play_stream' core/crates/ncm-ffi/src/api.rs
rg -n 'fun parseParametricEq|MAX_FILTERS|MAX_GAIN_DB' ui/android/app/src/main/kotlin/com/minincm/minincm/EqAudioProcessor.kt
rg -n 'maxEqFilters|maxEqGainDb|parseParametricEq' ui/lib/src/eq_profile.dart
rg -n 'MAX_FILTERS|MAX_GAIN_DB' core/crates/ncm-domain/src/eq_profile.rs
rg -n 'eqApplied|eqError' ui/lib/src                       # 预期：只有 Rust DTO，无 UI 消费

# 5) 生命周期 / 主题 / cookie（P-07/P-08/P-09）
rg -n 'onPause|stopPlayback|isFinishing' ui/android/app/src/main/kotlin/com/minincm/minincm/MvPlayerActivity.kt
rg -n 'removeAllCookies|loadUrl|HEADER_BG' ui/android/app/src/main/kotlin/com/minincm/minincm/{MainActivity,LoginActivity}.kt
rg -n 'android:theme|usesCleartextTraffic' ui/android/app/src/main/AndroidManifest.xml

# 6) CI / 打包 漂移（P-13..P-19）
rg -n 'exclude-tags' .github/workflows/*.yml .gitlab-ci.yml
rg -n 'flutter build apk' .github/workflows/*.yml .gitlab-ci.yml tools/*.sh
rg -n 'check-tokens' .github .gitlab-ci.yml tools/ci.sh
rg -n 'distributionUrl' ui/android/gradle/wrapper/gradle-wrapper.properties
rg -n 'curl -fsSL|appimagetool|extract-and-run' packaging/linux/build-appimage.sh
ls packaging/linux/ && rg -n 'build-tarball' packaging/linux/README.md
rg -n 'release version' packaging/linux/io.github.xiaquwan1001.MiniNCM.metainfo.xml

# 7) 窗口/应用 ID（P-18）
rg -n 'APPLICATION_ID|gtk_window_set_title|gtk_header_bar_set_title|gtk_window_set_default_size' \
   ui/linux/CMakeLists.txt ui/linux/runner/my_application.cc
rg -n 'Win32Window::Size|window.Create' ui/windows/runner/main.cpp

# 8) 轻量只读校验（本次实际跑过）
bash tools/check-tokens.sh --strict          # => OK(没有集合外的间距/圆角/字号)
cargo metadata --manifest-path core/Cargo.toml --no-deps --format-version 1 | head -c 400
ls ui/android/app/src/main/res/{values,values-night}

# 9) 需真机确认的两条（本次未跑，避免占用模拟器/资源）
#    P-12 通知点击是否打开 App：
#      adb shell dumpsys notification --noredact | rg -n 'contentIntent|MiniNCM|minincm'
#      # 若 contentIntent=null 则可确认为缺陷
#    P-06 冷启动调音是否生效（改过设置后）：
#      adb logcat -c; adb shell am force-stop com.minincm.minincm.dev; adb shell am start -n com.minincm.minincm.dev/.MainActivity
#      adb logcat -d | rg -n 'NCM-PLAYER|not_ready'
```

---

## 附录 A. 本次审计的执行记录（只读）

- 读取：6 个 Kotlin 文件全文、`ui/linux/runner/*`、`ui/windows/runner/{main,flutter_window}.cpp`、`ncm-playback/{lib,biquad,agc}.rs`（lib.rs 全文 728 行）、`tools/*.sh` 全部 10 个、4 份 CI 配置、3 份打包脚本 + 2 份 README、`AndroidManifest.xml`、`app/build.gradle.kts`、`settings.gradle.kts`、`gradle-wrapper.properties`。
- 交叉核对：`ui/lib/src/{playback,audio_tuning,eq_profile,settings_audio_page,mv_playback,notification_mode}.dart`、`main.dart`（节选 5 段）、`core/crates/ncm-ffi/src/api.rs`（播放/调音段）、`ncm-service/src/{identity,credential_store,credential_keyring}.rs`（节选）。
- 跑过的命令：`rg` / `find` / `wc` / `ls` / `git rev-parse` / `git log -1` / `bash tools/check-tokens.sh --strict` / `cargo metadata --no-deps` / `apt-cache policy libasound2`（本机 Ubuntu 26.04，仓库里没有该包名，**deb 的 `Depends: libasound2` 在 24.04+ 的可用性未验证**——这是本报告唯一"看到但没敢下结论"的点）。
- **未跑**：任何构建、任何 `flutter test`/`dart analyze`、任何模拟器操作（避免与进行中的 lane 抢 CPU/模拟器）。
