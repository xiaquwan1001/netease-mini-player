# netease-mini-player — 项目说明

轻音 MiniNCM —— 网易云音乐第三方客户端,**Android + Linux + Windows 三端**
(Windows 桌面版 2026-11-09 合入,产物只在 Windows 上构建)。

## 架构(2026-11 重启后)

- `core/` Rust workspace: `ncm-domain`(模型) / `ncm-provider`(Provider 抽象) /
  `ncm-service`(身份 + 网易云 provider) / `ncm-ffi`(Flutter 桥) / `ncm-cli`(headless 验证)。
- `core/vendor/ncm-api`: api-enhanced 的 Rust 移植,**锁定 commit**(见 `vendor/UPSTREAM.txt`),
  协议/加解密/风控细节都在这里,不要自己重写加密。
- `ui/` Flutter(android + linux + **windows** 一份 UI),桥接用 flutter_rust_bridge 2.13,
  由 `ui/rust_builder`(cargokit)在构建时编译 Rust;`ui/windows/**` 是 `flutter create` 产物,
  只有 `runner/main.cpp`(窗口标题/尺寸)与 `rust_builder/windows/CMakeLists.txt`(manifest 路径 + 库名
  `ncm_ffi`)是手改过的,别整体重新生成。
- 平台层: Android 用 Kotlin(Media3/MediaSession/登录 WebView),桌面(Linux/Windows)用 **rodio/CPAL**
  (纯 Rust + symphonia, 无系统依赖;Linux=ALSA、Windows=WASAPI,同一份代码两个 `cfg`)。
  MV 播放: Android 有独立 `MvPlayerActivity`(VideoView),桌面用系统播放器打开直链。
  早期设计写的 mpv + MPRIS **未实现**(见 `docs/architecture-restart.md` §3 的现状注记),不要再按 mpv 规划。
- `legacy/` 是 v1 的 WebView 实现,只读存档,不要再往里加功能。

## 环境(用户级, 已就绪)

- `~/android-dev/`: JDK21 / Gradle 8.9 / Android SDK(platform 36, build-tools 36, **NDK 28.2.13676358**) /
  **Flutter 3.47.9 stable**(Dart 3.13.7)。
- Rust 1.99 + 三个 Android target 已装。
- 统一入口: `source tools/env.sh`(会配好 PATH 与国内镜像)。
- 构建: `bash tools/build-linux.sh` / `bash tools/build-android.sh` / `bash tools/ci.sh`。
  **Windows 本机(本 Linux 机)编不了**(Flutter 桌面不支持交叉编译): 产物由 `.github/workflows/windows.yml`
  在 `windows-latest` 上出 `MiniNCM-<ver>-windows-x64.zip`(已验证 ~17 MB),别试图在 Linux 上 `flutter build windows`。

## 规则

- 协议/风控/加解密**只用 vendor 库**,我们只做包装、身份注入与 DTO 转换。
- 跨层只传 `ncm-domain` 里可序列化的类型;UI 不直接吃 `serde_json::Value`。
- 任何 provider 的外部错误都转成 `ProviderError{kind,retryable,detail}`,UI 按 `kind` 决策。
- 身份纪律:device_id 首启生成后**永久复用**;设备 cookie(`_ntes_nuid/_ntes_nnid/NMTID/WNMCID`)
  必须持久化,禁止每进程随机。
- 用户操作设备(扫码/点应用);助手准备资产、给精确步骤、盯 `adb logcat`。
- 项目记忆: `.pi/memory/`;项目技能: `.pi/skills/`。
  **`.pi/` 只在本地工作区, 已在 `.gitignore` 排除、不进公开仓库**(2026-11-10 起)。

## 项目记忆（2026-11-11 整理）

- `tools/env.sh` 只配 PATH/镜像，**不导出 `ANDROID_NDK_HOME`**；直接交叉编译带 C/asm 的 crate（ring/zstd-sys）要自配 `CC_/CXX_/AR_aarch64_linux_android=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android23-clang` + `.cargo/config.toml` linker，否则报 `Relocations in generic ELF`。cargokit 自带这些，不受影响。
- cargokit 用 **Rust package 名**当产物名：package 名必须 `ncm_ffi`（下划线），带 `-` 会生成 .so 却找 `libncm-ffi.so` → 链接失败。
- `tools/ci.sh` 默认清代理（`NCM_KEEP_PROXY=1` 可保留）；手工跑 `cargo test --manifest-path core/Cargo.toml` 前必须 `unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY`，否则 vendor 联网测试走死代理必挂。
- vendor 的 4 例匿名联网 smoke 连跑偶发 1~3 条风控失败、每轮集合不同，单跑即过 → 不当回归；严格核验用 `NCM_VENDOR_SMOKE_STRICT=1 tools/ci.sh`。
- 改 Rust API 固定三步：`flutter_rust_bridge_codegen generate --rust-input crate::api --rust-root core/crates/ncm-ffi --dart-output ui/lib/src/rust` → `cargo build -p ncm_ffi` → `flutter test`；漏第二步报 `Content hash on Dart side ... different from Rust side`。codegen 需 rustfmt。
- analyze 门固定 `cd ui && dart analyze`：`flutter analyze` 本机会偶发 SIGSEGV（DAS 并发标记，重启后自愈），别反复重试或重装 Flutter。
- Android 增量产物损坏（`ld.lld: error: ... (.debug_str) offset is outside the section`，只在 i686 debug）：`rm -rf ui/build/rust_lib_minincm/build/i686-linux-android` 后重编即可，别清 core/target。
- Linux 桌面 GLib 钉版本：`ui/linux/CMakeLists.txt` 里 `GLIB_VERSION_MIN_REQUIRED`/`MAX_ALLOWED` 都设 `2.72`（只钉 MAX 会 #error）；判据 `objdump -T bundle/minincm | grep g_once` 出现 `*_pointer` 就是坏包。
- 签名：release 走 `ui/android/key.properties`→`~/.android/keys/minincm-release.jks`（alias minincm），缺失回落 debug 且产物不可当发布包；debug 带 `applicationIdSuffix=".dev"`；版本单源 `pubspec version X.Y.Z+N` + `tools/bump-version.sh` + `ui/test/version_consistency_test.dart`。
- CI 别用 `android-actions/setup-android@v3`（镜像已无 `tools` 包必挂），直接用 `$ANDROID_HOME/cmdline-tools/*/bin/sdkmanager` 装 `ndk;28.2.13676358`；联网用例用 `@Tags(['network'])`+`ui/dart_test.yaml`，CI 跑 `flutter test --exclude-tags network`。
- 体积基线：release arm64 APK ~27.9MB，Linux bundle tar.gz ~14.7MB；vendor 裁剪后 endpoint 118 / LOC 4,069 / 体积 564K，`tokio` 已移除、上游 `server` 特性已删。
- `tools/api-coverage.sh` 的 UI 入口比对必须**大小写不敏感**，且统计 endpoint 要排除 `api/mod.rs`。
- 原生扫码登录（eapi/weapi）用户确认后必返 **8821**；官方网页登录是唯一低风险路径。Android 是 `LoginActivity` + WebView，成功判据只有 `MUSIC_U` cookie 出现。
- 桌面端 `MUSIC_U` 是 HttpOnly、拿不到 → 走官方网页扫码通道 `ncm login-qr`：`unikey {type:1}` → 二维码 `https://music.163.com/login?codekey=<unikey>` → 轮询 `client/login`（801/802/803/800）；**803 的凭据只在 Set-Cookie 头里**。
- 登录复用纪律：只落 `LOGIN_KEYS`（MUSIC_U/MUSIC_A/__csrf/JSESSIONID-WYYY/_iuqxldmzr_/__remember_me）；设备指纹由本地 identity.json 提供。
- 客户端形态必须成套：`os/appver/osver/channel` + UA + 网页入口版式一致；桌面扫码用 weapi + PC 浏览器 UA。
- 手机号+短信登录（网页通道）：`/api/sms/captcha/sent` + `/api/login/cellphone`；400→Auth、503→可重试、8821→RiskControl；凭据同样只在 Set-Cookie。
- 直链：明文 http 的 *.music.126.net 在本机会被中间设备回 502 → `preferHttpsStreamUrl()` 升 https；manifest 需 `usesCleartextTraffic`，ExoPlayer 显式设 UA + `Referer: https://music.163.com/`。
- 取链语义：VIP 曲缺 `os/appver` 是 code=200 但 url=null；音质档位只由 `MUSIC_U` 决定；匿名 VIP 只给 30~45s，断言别用列表 duration。
- 逐字歌词只有 `lyric_new`（`/api/song/lyric/v1`）的 `yrc` 给；`ytlrc`/`yromalrc` 恒空，翻译只能行级 `tlyric`；老歌无 yrc 要保留行级滚动 + 纯文本回落。
- 评论/电台/数字专辑：`comment_mv`/`comment_video` 与歌曲评论同形（thread 前缀 `R_MV_5_`/`R_VI_62_`）；`simi_user` 恒空不做；`dj_subscriber` 游标是上一页末条 `subscribeTime`(ms)、首页传 -1；`dj_catelist` 顶层只给 `categories`；`dj_recommend_type` 的 type=0 返回空；`digital_album_sales` 的 `data` 是 `{专辑id: 销量}` map，`product.saleNum` 恒 0。
- 他人主页匿名可取：`GET /api/v1/user/detail/<uid>`（顶层 `profile`）+ `/api/user/playlist`（只公开歌单）；`profile.level` 恒 0，等级走 `user/level`。
- 账号簿：未登录不渲染 VIP 标；启动校验只在错误含 `[auth]` 时登出；`accounts.json` 的 MUSIC_U 仍是明文 0600，上钥匙串未做。
- 模拟器：本项目统一用 **a34**（`adb -s emulator-5556`）；启动用 `~/bin/avd headless a34`，别用 `-gpu host`，headless 用 `-gpu swiftshader_indirect`。
- 模拟器 chromium/WebView 打不开 https 是 **wlan0(netsim)** 造成，`adb shell svc wifi disable`（`~/bin/avd` 已自动做）即好。
