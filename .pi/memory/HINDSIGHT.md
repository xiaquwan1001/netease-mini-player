# Hindsight — netease-mini-player

API/protocol details and anti-bot technique live in the
`netease-cloud-music-api-reverse` skill. Durable lessons:

- 网易云 2024+ 反爬：`xeapi` + TLS/JA3 指纹 + 反作弊 token；标准安卓 TLS 栈全被拦。
  可行解法 = 模拟网页端形态读接口；登录走官方网页（WebView + `MUSIC_U` cookie）零风控。
- 分离调试变量：先用远程 API 服务（本地起 api-enhanced）验证 App 逻辑，再压直连风控，
  否则会把"App bug"误当"风控"排查。
- 内部 URI ≠ 路由路径：路由路径可能 404，按文档用内部 URI。
- 响应默认明文（`encryptResponse=false`）；`login_qr_key` 的 unikey 在顶层 `res.unikey`。
- 播放 URL 走 `linuxapi`（`/api/song/enhance/player/url/v1`）。
- 架构验证：原生壳 + JS SPA + provider 注册表可把 APK 压到几十 KB 并保持可热更新。

## Environment
- 构建：`gradle assembleDebug`；安卓环境纯用户级安装。
- 真机优先；`adb logcat` + grep 是最顺的排查方式。
## 构建环境(2026-10-31 落地)
- 用户级工具链 `~/android-dev`: Temurin **JDK 21.0.9** + **Gradle 8.9** + SDK(platform-34/build-tools 34.0.0)。
  脚本: `tools/setup-android-env.sh`(装) / `tools/build.sh`(build)。
- JDK 17.0.2 不可用于 AGP: `validateSigningDebug` 抛
  `NullPointerException: Cannot invoke "jdk.internal.platform.CgroupInfo.getMountPoint()" because "anyController" is null`
  (cgroup v2 探测 NPE, 新版 JDK 已修)。同版本号无关, 换 21.0.9 即通。
- 下载源实测(本机直连, `--noproxy '*' `): USTC adoptium 镜像有 temurin21 (huaweicloud openjdk 只有 17.0.2);
  services.gradle.org ~KB/s -> 用 `mirrors.cloud.tencent.com/gradle` (5MB/s); dl.google.com SDK 正常。
- api.adoptium.net / github.com releases / cdn.azul.com 直连超时, 不可用。
- sdkmanager 要求 proxy 变量 **unset** 而非空字符串(`export https_proxy=` 会 MalformedURLException)。
- 产物: app-debug.apk ≈ 71KB。
<!-- created=2026-10-31, last=2026-10-31 -->

## v1 真机跑通(2026-10-31, vivo X200 Ultra / Android 16 / WebView 138)
- 链路: 官方网页登录(WebView→LoginActivity 抓 MUSIC_U)→ eapi 搜索/取地址 → 原生 MediaPlayer。
- vivo 安装坑: `adb install` 被系统拒(`INSTALL_FAILED_ABORTED: User rejected permissions`),
  改用 `adb push` 到 `/data/local/tmp/` + `adb shell pm install -r -t` 成功。
- 桥缺方法会静默失效: `B.loginWeb()` 之前没在 `js/core/bridge.js` 暴露 → 点击登录毫无反应(无异常提示)。
  教训: 桥的每个 Native.* 都要有 JS 包装 + try/catch + toast。
- 登录后带 Cookie 的请求会自动从 fetch 退回原生桥: `Cookie` 是 fetch 的 forbidden header,
  带它必抛 TypeError → `bridge.post` 的 fetch 分支失败后走 `Native.httpPost`(OkHttp 风格 cipher, 可用)。
- 播放地址必须 `encodeType:'flac'`; 登录后 fee=1 的 VIP 歌也能拿到直链(匿名时是 -110)。
- **2026-11 更正**: 匿名取链的真实语义是「缺 os/appver → VIP 曲 code=200 但 url=null;
  补 os/appver → 128k 试听」。音质档位只由 MUSIC_U 决定, os=pc / os=android(9.0.90) 无差异。
<!-- created=2026-10-31, last=2026-10-31 -->

## 登录通道的硬结论(2026-10-31, 真机实测 + Ncrust spec 交叉验证)
- 原生扫码(eapi 或 weapi)在用户确认后必返 **8821 安全环境风险**; 换成 weapi + 预置
  NMTID/WEVNSM/__csrf + 登录页 Referer 也一样。`-462/8821` 是**交互式风控挑战**, 验证结果
  绑定在"完成验证的那个客户端"的设备 cookie 上, 不绑 IP; 脚本每次换设备 cookie 反而更像机器人。
  → 结论: 第三方 App 的原生登录接口不可靠, **官方网页登录是最低风险路径**(Ncrust 也这么决定)。
- **不要伪造桌面 UA 打开登录页**: `music.163.com/#/login` + Windows Chrome UA = 桌面 SPA(重、二维码小、
  手机号/QQ/微信二级页加载不出来)。设备默认移动 UA + 无 hash `https://music.163.com/login` 会 302 到
  `https://y.music.163.com/m/login` = 官方移动端授权页(手机号/微信/QQ/扫码全有)。
- 待办: **设备 cookie 持久化**(NMTID/_ntes_nuid/_ntes_nnid/WNMCID/WEVNSM + deviceId 首启生成永久复用),
  我们现在的 `genDeviceId()` 每次随机, 是风控特征。
- 同类项目可用性: Ncrust(3.9MB, MIT, 官方网页登录) 可用且最值得抄; Melodia(22MB, MIT, 原生扫码+Cookie导入)
  功能最全但没处理 8821; JetMelo 2025-03 归档, 已不适合依赖。
<!-- created=2026-10-31, last=2026-10-31 -->

## vivo 锁屏歌词 / 原子岛（2026-11-02，X200 Ultra / OriginOS 6 实测）
- 第三方 MediaSession 应用**无法**接入 vivo 锁屏歌词与原子岛音乐卡片，不是开关、也不是 extras 写错。
- 系统侧链路：SystemUI → `IMusicWidgetMixService.getLrcPath`（`SystemUIPlugin.apk`）→ `com.vivo.musicwidgetmix`。
- 卡片准入：`VivoMusicMixCard` 的 `WhitelistManager` 硬编码 ~50 个包名，另有
  `/data/bbkcore/NanoMusicPlayer_white_app_lists_2.5.xml` 云控增补；`com.lin0721.linmusic` 在两个 dex 里 0 命中。
- 歌词来源：白名单内再分「深度适配」8 家（`initCooperationList`）。网易云走它自己的
  `com.netease.cloudmusic.third.api.contract.ICMApi`（`execute(String, Bundle)`，歌词命令 `CMD_GET_COMPLETE_LYRIC`）；
  白名单内非深度适配的应用由 vivo 内置酷狗 SDK 按歌名搜词（`LyricQueryStrategy`）。
- Melodia 的 `lyricInfo` extras 是 **ColorOS 锁屏岛** 约定（LyricInfo 模块 README），OriginOS 不读；
  Android 16 promoted notification 在 vivo SystemUI 未实现（SystemUIPlugin 0 处 promoted 引用）。
- 结论：只能等 vivo 白名单/厂商合作，或在已 root/LSPosed 设备上装系统级模块；应用侧无解。
<!-- created=2026-11-02, last=2026-11-02 -->

## v2 架构落地(2026-11-03)
- 形态: `core/` Rust workspace + `ui/` Flutter(android+linux) + `platform/`(待建)。
  协议/加密全部来自 `core/vendor/ncm-api`(api-enhanced 的 Rust 移植, 382 模块, rustls),
  锁定 commit 见 `core/vendor/UPSTREAM.txt`;我们只做身份注入 + DTO 化。
- 身份: device_id 首启生成 52 hex 落盘复用; `_ntes_nuid/_ntes_nnid/NMTID/WNMCID/deviceId`
  也必须持久化(库默认每进程随机, 等于每次换设备)。见 `ncm-service/src/identity.rs`。
- 通道: `interface`(App 形态)与 `interface3`(网页 UA)都通, 默认用前者; 见 `docs/api-channel.md`。
- 播放: Linux = rodio 0.23(`DeviceSinkBuilder::open_default_sink` + `Player::connect_new`),
  换曲用 `clear()` 而不是 `stop()`(stop 后不可复用); Android 计划 Media3。
  编译期需要 `libasound2-dev`(系统包, 已装)。
- 构建坑:
  - cargokit 用 **Rust package 名**当产物名: crate 名带 `-` 时生成 `libncm_ffi.so` 但找 `libncm-ffi.so` → 链接失败。**package 名必须用下划线**。
  - Gradle wrapper 从 services.gradle.org 拉 9.3.1-all 会卡死在 KB/s → 换腾讯镜像 `-bin.zip` 并预置到 `~/.gradle/wrapper/dists`。
  - cargokit 自动 `rustup target add` 不走代理/镜像 → `tools/env.sh` 里导出 `RUSTUP_DIST_SERVER`(USTC)。
  - FRB: Rust `u64` 在 Dart 是 `BigInt`。
  - Flutter 3.47.9 默认 NDK = 28.2.13676358,需预装(否则 gradle 静默去下载)。
- 实测数字: release arm64 APK 21.1MB; Linux debug bundle 可跑; rodio 真实播放 pos 前进。
<!-- created=2026-11-03, last=2026-11-03 -->

## Android 真机(vivo X200 Ultra, 2026-11-03)
- 安装: `adb install` 会 `INSTALL_FAILED_ABORTED: User rejected permissions`;改用
  `adb push /data/local/tmp/x.apk` + `pm install -r -t`。**手机必须亮屏解锁**,否则 pm install 同样被拒。
- Media3 1.9.4: `MediaSessionService` + ExoPlayer + MediaController(MethodChannel 桥)可正常初始化;
  通知/锁屏走 Media3 默认通道。
- 网易云直链是 plain-http 的 *.music.126.net:manifest 要 `usesCleartextTraffic="true"`,
  ExoPlayer 要显式设 UA(官方桌面端)与 Referer(`https://music.163.com/`)。
- Kotlin 块注释可嵌套:注释里出现 `/*`(例如写 URL `http://*`)会导致 Unclosed comment。
- 未解:设备上 reqwest/rustls 请求 `https://interface.music.163.com` 报 "error sending request";
  Linux 同样代码正常。排查顺序:打印完整错误链 → native-roots/native-tls → DNS/IPv6 → adb shell curl 对照。
- 电脑插多台设备后所有 adb 命令都要 `-s <serial>`(脚本用 `ANDROID_SERIAL`)。
<!-- created=2026-11-03, last=2026-11-03 -->
