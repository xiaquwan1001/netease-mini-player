# netease-mini-player — 项目说明

轻音 MiniNCM —— 网易云音乐第三方客户端,**Android + Linux 双端**。

## 架构(2026-11 重启后)

- `core/` Rust workspace: `ncm-domain`(模型) / `ncm-provider`(Provider 抽象) /
  `ncm-service`(身份 + 网易云 provider) / `ncm-ffi`(Flutter 桥) / `ncm-cli`(headless 验证)。
- `core/vendor/ncm-api`: api-enhanced 的 Rust 移植,**锁定 commit**(见 `vendor/UPSTREAM.txt`),
  协议/加解密/风控细节都在这里,不要自己重写加密。
- `ui/` Flutter(android + linux 一份 UI),桥接用 flutter_rust_bridge 2.13,
  由 `ui/rust_builder`(cargokit)在构建时编译 Rust。
- 平台层: Android 用 Kotlin(Media3/MediaSession/登录 WebView),Linux 用 **rodio/CPAL**(纯 Rust + symphonia, 无系统依赖)。
  早期设计写的 mpv + MPRIS **未实现**(见 `docs/architecture-restart.md` §3 的现状注记),不要再按 mpv 规划。
- `legacy/` 是 v1 的 WebView 实现,只读存档,不要再往里加功能。

## 环境(用户级, 已就绪)

- `~/android-dev/`: JDK21 / Gradle 8.9 / Android SDK(platform 36, build-tools 36, **NDK 28.2.13676358**) /
  **Flutter 3.47.9 stable**(Dart 3.13.7)。
- Rust 1.99 + 三个 Android target 已装。
- 统一入口: `source tools/env.sh`(会配好 PATH 与国内镜像)。
- 构建: `bash tools/build-linux.sh` / `bash tools/build-android.sh` / `bash tools/ci.sh`。

## 规则

- 协议/风控/加解密**只用 vendor 库**,我们只做包装、身份注入与 DTO 转换。
- 跨层只传 `ncm-domain` 里可序列化的类型;UI 不直接吃 `serde_json::Value`。
- 任何 provider 的外部错误都转成 `ProviderError{kind,retryable,detail}`,UI 按 `kind` 决策。
- 身份纪律:device_id 首启生成后**永久复用**;设备 cookie(`_ntes_nuid/_ntes_nnid/NMTID/WNMCID`)
  必须持久化,禁止每进程随机。
- 用户操作设备(扫码/点应用);助手准备资产、给精确步骤、盯 `adb logcat`。
- 项目记忆: `.pi/memory/`;项目技能: `.pi/skills/`。
