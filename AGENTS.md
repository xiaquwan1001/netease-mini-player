# netease-mini-player — 项目说明

轻音 MiniNCM —— 极简第三方网易云音乐 Android 客户端：native shell + JS SPA +
provider 插件注册表。

- 项目专属技能（`.pi/skills/`）：`netease-cloud-music-api-reverse`。
- 项目记忆：`.pi/memory/`。

## 环境(已就绪, 用户级)
- 工具链 `~/android-dev/{jdk(Temurin21), gradle-8.9, sdk}`; 重装: `bash tools/setup-android-env.sh`;
  构建: `bash tools/build.sh`; adb 在 `~/.local/opt/platform-tools/adb`。
- 不要用系统 JDK 25(本机 only JRE) 或 JDK 17.0.2(validateSigningDebug NPE)。

## 规则
- 一切皆插件；provider 放 `js/plugins/provider/`。
- 保持 APK 精简：尽量不用 AndroidX/Kotlin/第三方 Gradle 依赖。
- 环境安装保持用户级（不装系统包）。
- 用户操作设备（扫码/点应用）；助手准备资产、给精确步骤、盯 `adb logcat`。
