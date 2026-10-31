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
