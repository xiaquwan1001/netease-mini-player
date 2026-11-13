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

- 改 Rust API 固定三步：`flutter_rust_bridge_codegen generate --rust-input crate::api --rust-root core/crates/ncm-ffi --dart-output ui/lib/src/rust` → `cargo build -p ncm_ffi` → `flutter test`；漏第二步报 `Content hash on Dart side ... different from Rust side`。codegen 需 rustfmt。
- 静态检查门固定 `cd ui && dart analyze`（`flutter analyze` 本机会偶发 SIGSEGV，别重试或重装 Flutter）；Rust 侧 `cargo clippy --workspace --all-targets` 也执行 0 warning（2026-11-13 清零，别再引入）。
- `dart format` 用 Dart 3.13 的 tall style 会重排全仓（~10k 行 diff），**不要顺手跑**；要统一格式就单独立一次提交并同时加 CI 门。
- 代理/镜像：`tools/env.sh|ci.sh` 都不碰代理变量（2026-11-12 复核）；手工跑 vendor 联网测试前 unset 全部代理变量（原因与判据见 `.pi/memory/FAILURES.md`「手工跑 cargo test」条）。vendor 匿名 smoke 偶发风控失败不算回归，严格核验用 `NCM_VENDOR_SMOKE_STRICT=1`。
- cargokit 用 Rust package 名当产物名 ⇒ package 名必须是 `ncm_ffi`（下划线），不能带 `-`。
- 设备验证统一用模拟器 **a34**（`~/bin/avd headless a34`），别用 `-gpu host`。
- 细节**不放这里**：构建/工具链/CI/体积基线见 `.pi/memory/notes-build.md`；登录、取链、歌词、评论的协议语义见 `.pi/memory/notes-api.md`；失败教训见 `.pi/memory/FAILURES.md`。
