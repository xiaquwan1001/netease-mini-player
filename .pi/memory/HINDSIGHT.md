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
- 安装: vivo 的安装二次确认**无法绕过**,每次都要用户手上点「安装/继续安装」;`pm install` 会阻塞等待,
  不点/锁屏即返回 `INSTALL_FAILED_ABORTED: User rejected permissions`。`push + pm install` 只减少弹窗层级。
- Media3 1.9.4: `MediaSessionService` + ExoPlayer + MediaController(MethodChannel 桥)可正常初始化;
  通知/锁屏走 Media3 默认通道。
- 网易云直链是 plain-http 的 *.music.126.net:manifest 要 `usesCleartextTraffic="true"`,
  ExoPlayer 要显式设 UA(官方桌面端)与 Referer(`https://music.163.com/`)。
- Kotlin 块注释可嵌套:注释里出现 `/*`(例如写 URL `http://*`)会导致 Unclosed comment。
- 未解:设备上 reqwest/rustls 请求 `https://interface.music.163.com` 报 "error sending request";
  Linux 同样代码正常。排查顺序:打印完整错误链 → native-roots/native-tls → DNS/IPv6 → adb shell curl 对照。
- 电脑插多台设备后所有 adb 命令都要 `-s <serial>`(脚本用 `ANDROID_SERIAL`)。
<!-- created=2026-11-03, last=2026-11-03 -->

## 安卓模拟器环境（2026-11-03 本机建好，日常迭代默认用它）
- 位置：`$HOME/android-dev/sdk`（`emulator` + `system-images;android-34/36;google_apis;x86_64`）；
  AVD `a34`(API 34) / `a36`(API 36 = Android 16，与 vivo X200 Ultra 同 API)，均 pixel_7 1080x2400@420。
  快捷脚本 `~/bin/avd`（`list|start|headless|stop|stopall|status`，默认 `-gpu host` 用 RTX 4060）。
- 实测：a36 冷启动 20s；`adb install -r -t app-debug.apk` **0.6s 秒过**，绕开真机那条「vivo 二次确认阻塞」；
  debug apk 的 Rust `libncm_ffi.so` x86_64 正常加载、Flutter UI 正常渲染，无 UnsatisfiedLinkError。
- **x86_64 不是障碍**：cargokit 本就产出 x86_64/arm64-v8a/x86/armeabi-v7a 四份 `.so`，x86_64-linux-android target 已装，NDK 已有。
- 网络：模拟器内访问宿主服务用 `10.0.2.2`，宿主访问模拟器用 `adb forward`。
- 已查清（2026-11-03）：模拟器首启 debug apk 报 `Read-only file system (os error 30)` **不是模拟器问题**，
  是 **APK 比代码旧**：`ui/build/…/app-debug.apk` 是 12:47 构建，而 `main.dart` 里
  `await _playback.dataDir()` 是 14:31 才提交（685580a）。旧包 → Dart 不传 `dataDir` → Rust
  `data_dir_default()` 跑 `HOME`（安卓 app 进程无 HOME）→ 相对路径 `./.local/share/ncm` → cwd 是 `/`
  → EROFS。判定方法：UI 没显示 `device=… logged_in=…` 行（说明 `init` 失败）+ `files/ncm` 不存在。
  `bash tools/build-android.sh` 重编后重装即好（60s 增量），搜索出 10 条结果正常 —— **模拟器 https 通道可用**，
  真机那个 reqwest `error sending request` 不是通用的网络问题。
- 厂商 SystemUI/白名单（锁屏歌词、原子岛）、Play Integrity 类结论仍只能真机验，模拟器不背这些。
<!-- created=2026-11-03, last=2026-11-03 -->

## Android 模拟器验证闭环 + 播放链根因(2026-11-03 晚)
- 日常迭代用 a36 模拟器(`~/bin/avd headless a36`,15s 起;`adb install -r -t` 0.7s),
  真机只留给厂商特性/风控结论。驱动方式: `input tap/swipe` + `exec-out screencap`(读图看 UI)
  + `dumpsys media_session | grep metadata`(看曲目/播放态), 不需要 flutter drive。
- **明文 http 直链在本机被中间设备回 502(空 body)** → ExoPlayer 报
  `UnrecognizedInputFormatException: None of the available extractors could read the stream`。
  判定: 模拟器内 `nc www.baidu.com 80` 同样 502, https 全通, 而宿主 curl 走 80 是 200
  ⇒ 转发/NAT 路径拦截, 与解码器/UA 无关。修法: `preferHttpsStreamUrl()` 把直链升到 https
  (CDN 同路径 https 返回 audio/mpeg 200)。
- **主机代理变量会毒化 Rust 侧请求**: clash 没起时 `HTTPS_PROXY=http://127.0.0.1:7890`
  让 reqwest 报 `error sending request for url (...)`, 与"接口变了/设备风控"极像。
  CLI/测试前 `env -u https_proxy ...`; `tools/ci.sh` 已默认清代理(`NCM_KEEP_PROXY=1` 可保留);
  `ncm-service` 在网络错误里附代理提示。
- 队列放 Dart 纯逻辑(`ui/lib/src/queue.dart`, 9 单测), 播放后端保持"一次一首"; 自动续播靠
  500ms 轮询 `wasPlaying→!playing && pos≈dur`。两个坑: (a) 拖动滑杆时换曲会让 duration 突跳,
  必须**冻结量程**(_dragMax), 否则新曲目被 seek 到末尾; (b) 续播要加 `_advancing` 临界区。
- 模拟器手势导航条会吞掉屏幕最底部 ~20dp 的点击(tap 与真手指都一样), UI 加了 8dp 边距。
- vendor `ncm-api` 自带的 integration 测试并行/连跑会被风控挂 2~3 条, 单跑即过, 别当回归。
<!-- created=2026-11-03, last=2026-11-03 -->

## 歌词 + FRB 改动闭环(2026-11-03 晚)
- 歌词解析放 `ncm-domain::lrc`(`LyricLine{time_ms,text,sub}` + `parse_lrc_with_translation`):
  支持 `[mm:ss.xx|.xxx|:xx]`、一行多标签、`[offset:±ms]`(正=提前)、按时间戳合并 `tlyric` 翻译;
  解析不了的行静默丢弃(歌词是"有则更好"的数据)。12 单测。
- UI 侧只要 `lyricIndexAt(times, position)`(二分) + 固定 itemExtent 的 `ListView` 居中滚动,
  不需要 WebView/第三方歌词控件。
- **改 Rust API 的固定三步**: `flutter_rust_bridge_codegen generate --rust-input crate::api
  --rust-root core/crates/ncm-ffi --dart-output ui/lib/src/rust` → `cargo build -p ncm_ffi` →
  `flutter test`。`frb_smoke_test` 直接加载 `core/target/debug/libncm_ffi.so`,漏第二步会报
  `Content hash on Dart side ... different from Rust side`(不是生成错)。
- codegen 需要 rustfmt(`rustup component add rustfmt`),否则生成文件不格式化但仍可用。
- 网易云 VIP 歌匿名只给 **30~45s 试听片段**(搜索结果的 duration 是完整时长),测试写断言别拿列表 duration。
<!-- created=2026-11-03, last=2026-11-03 -->

## 官方网页登录落地(2026-11-04)
- 形态: 原生 `LoginActivity` + `android.webkit.WebView`(零第三方依赖), 设备默认移动 UA,
  URL = `https://music.163.com/login`(302 到 `y.music.163.com/m/login` 官方授权页)。
  成功判据只有 **`MUSIC_U` cookie 出现**(页面文案/跳转都不可靠) → 每 1.5s 轮询
  `music.163.com` 与 `163.com` 两个域的 cookie, 取到就回传。返回键也要回传(可能已登录未跳转)。
- Dart `Auth.loginWeb()` → Kotlin Activity(for result) → `loginWithCookie` → Rust 与设备指纹合并落盘。
  CLI 可离线验证整条合并链: `NCM_DATA_DIR=/tmp/x ncm login-cookie "MUSIC_U=dummy"` + `ncm whoami`。
- **Kotlin 命名坑**: 在 `WebView(this).apply { ... }` 里写 `progress.visibility = ...` 会解析到
  `WebView.getProgress()`(Int) → "Unresolved reference 'visibility'"。字段改名 `loadingBar` 即好。
- **非导出 Activity 不能用 `adb shell am start` 直启**(Permission Denial, 且 `>/dev/null` 会让你误判
  "没起来")。要调试就留一个 in-app 入口(如 LoginActivity 支持 `--es url` 由 MainActivity 转发)。
- 模拟器出网差异(2026-11-04 早): 同一 guest 里 **rustls/reqwest 正常, chromium/WebView 的 TLS 握手被重置**
  (`ssl_client_socket_impl.cc handshake failed, net_error -100`),系统 Chrome 同样打不开网抑云页面
  ⇒ 是宿主 NAT/中间设备的 SNI 级拦截, 不是我们的 WebView 代码。判定不要只看一个栈。
<!-- created=2026-11-04, last=2026-11-04 -->

## 模拟器 WebView/Chrome 打不开 https: 是 virtio-wifi(2026-11-04 查明)
- 症状: 同一 guest 里 rustls/reqwest 的 https 全通, 但 `WebView`/系统 Chrome 一律
  `net::ERR_CONNECTION_RESET`(`ssl_client_socket_impl.cc handshake failed, net_error -101`);
  宿主 `curl` 正常 ⇒ 不是站点、不是我们代码。
- 真因: Android 的默认网络是 **wlan0(netsim 虚拟 wifi, 10.0.2.16)** 时 chromium 的 TLS 会被重置;
  `adb shell svc wifi disable` 之后走 **eth0(cellular, 10.0.2.15)** 立刻正常
  —— 官方移动端登录页完整渲染(手机号/微博/QQ 都在)。
- 处理: `~/bin/avd headless` 现在会在启动完成时自动 `svc wifi disable`(注释里写了原因)。
  手上有活的模拟器: `adb shell svc wifi disable` 即可。
- 顺带两条: (a) `-gpu host` 在 Chrome 渲染重页面时会把 gfxstream 打崩(`glGenTextures: null ctx`),
  headless 验证用 `-gpu swiftshader_indirect` 稳; (b) 该路径 MTU < 1500(`ping -M do -s 1472` 不通,
  1400 通), 但把 guest MTU 降到 1400 并不能救 chromium, 所以 MTU 不是主因。
<!-- created=2026-11-04, last=2026-11-04 -->

## 客户端形态必须成套(2026-11-04, 用户提醒后修正)
- 规则: **安卓端一切按安卓形态, 桌面端一切按桌面形态** —— API 的
  `os/appver/osver/channel` + UA + 网页入口版式必须成套; 混着用最坏是**假通过**
  (静默降权


[Exact evidence: /home/xuqianhui/.pi/agent/sessions/--home-xuqianhui-netease-mini-player--/pi-fold-evidence/pi-session/sha256/cf/cfd10c9eba2d4736c437536d0ed30e6ad61c713909f42de9fc8d677ef83952fd.txt; sha256=cfd10c9eba2d4736c437536d0ed30e6ad61c713909f42de9fc8d677ef83952fd; bytes=33641]
## 搜索分板块 / 图片 / 歌曲菜单(2026-11-06)
- **cloudsearch type**: 1 单曲 / 10 专辑 / 100 歌手 / 1000 歌单 / 1009 播客(电台); **2000(声音/节目)返回空 result**, 本接口不支持节目搜索。各板块响应分别读 `result.songs/albums/artists/playlists/djRadios`。
- **fee 语义**: 0 免费 / 1 VIP / 4 付费专辑 / 8 **低音质(128k)免费**。`is_vip` 只能认 1 —— 把 8 也算进来会让大部分免费歌被标 VIP(实测 30 条搜索结果 21 条 fee=8)。
- **我喜欢的音乐排序**: `likelist` 的 ids 顺序不可靠; 用 `/api/v6/playlist/detail` 的 `playlist.trackIds[].at`(收藏时间 ms) 倒序, 再 `song/detail` 批量补全。
- **网易云图片 CDN**: 对 `Dart/3.x (dart:io)` 默认 UA 直接回 **403**(同 URL 浏览器 UA 200), Flutter 的 Image.network/NetworkImage 全要显式 `headers: {'User-Agent': 浏览器UA, 'Referer': 'https://music.163.com/'}`。
  缩略图用 `?param=NxN`(服务端裁剪, 1.8MB→几 KB); **`width: double.infinity` 不能参与 round()**, 会抛 `Unsupported operation: Infinity or NaN toInt`。
- **模拟器图片 403 的另一半**: Dart UA 修好后, a36 上同一 URL 仍偶发 403(Chrome 也提示 No internet), 而 Linux 桌面同代码正常 ⇒ 是模拟器 NAT/中间设备问题, 不要误判成应用 bug; 验证图片优先用 Linux Xvfb。
- **下载**: 不引第三方包。Android 用 DownloadManager(`setDestinationInExternalPublicDir(DIRECTORY_DOWNLOADS, "MiniNCM/...")`, 免存储权限) + UA/Referer 头; Linux 用 curl 到 `~/Downloads`。
- **评论面板复用**: detail_page 的 `_CommentsSection` 通过 `showCommentsSheet(context, kind:, resourceId:)` 暴露, 供歌曲菜单/动态使用。
- **AppActions**: 动作回调挂在 `MaterialApp.builder`(Navigator 之上)才能被 pushed route 取到; 宿主用全局 `ValueNotifier<SongActionHost?>` 随登录态刷新。
<!-- created=2026-11-06, last=2026-11-06 -->

## 听歌排行 / 曲风推荐 接入(2026-11-06)
- 新能力: `Capability::ListeningRank` + `Capability::StyleRecommend`; domain 新增
  `PlayRankEntry` / `StyleTag`; FFI `play_ranking(period)` / `style_preference()` /
  `style_songs(tagId,limit)` / `style_playlists(tagId,limit)`.
- 实测响应形状(匿名也能验的用 `ncm raw` 打过):
  - 听歌排行 `/api/v1/play/record`(weapi, 需登录): `{code,allData:[{playCount,score,song}],weekData:[...]}`,
    type=0/1 选区间。未登录是 code≠200("无权限访问")。
  - 曲风偏好 `/api/tag/my/preference/get`: `{code:200,data:{tagPreferenceVos:[],tags:[]}}`,
    **匿名恒为空** ⇒ 后端必须退化到 `/api/tag/list/get`(style_list) 的二级标签, 否则推荐页没有入口。
  - 曲风歌曲 `/api/style-tag/home/song`: `{data:{songs:[完整 song],page}}`;
    曲风歌单 `/api/style-tag/home/playlist`: `{data:{playlist:[{id,name,cover,songCount,playCount}]}}`
    —— 注意歌单字段是 **cover/songCount**, 不是用户歌单的 coverImgUrl/trackCount。
- "关注动态"按艺人分类的排序是纯 UI 侧聚合(一页 30 条): 分数 = 动态条数*6 + 点赞 + 评论*2 + 转发*2,
  同分按首次出现(≈最近时间)排; 分类行只放前 8 个, 末尾"进入全部"面板再合并 `subscribedArtists`
  (关注但本页没发动态的艺人也能选)。

## 最近播放 / 签到 / 评论删除 / 歌曲百科 接入(2026-11-06)

- **`daily_signin` 只有 `type=1` 能签**: `type=0`(安卓通道) 回 `code=200 msg=功能暂不支持`,
  `type=1`(web) 回 `{code:200,point:N}` 并真到账; 重复签到抛 `Invalid parameter: 重复签到`。
  所以 provider 先看 `signin_progress.data.today.todaySignedIn`, 再决定发不发写请求。
- 签到进度三套计数在 `data.stats[]`, **id 6001 累计 / 4001 每周 / 5001 连续(28 天循环)**, 取 `currentProgress`;
  `data.records[]` 是最近 N 天 `{day,signed}`(新的在前)。
- `record_recent_album|playlist|dj` 形状统一 `{code, data:{list:[{data:{...}}]}}`(外层还带 lastSong/uiPlaylistType),
  **最近播放歌单不带 trackCount** → UI 别显示 "0 首"。
- `song_wiki_summary` 是装修块富文本 `data.blocks[]`, 只要 `code==SONG_PLAY_ABOUT_SONG_BASIC` 那个块;
  label 取 `creative.uiElement.mainTitle.title`, 值取 `resources[].uiElement.mainTitle.title` +
  `subTitles[].title` 或 `textLinks[].text`。桌面/安卓身份 eapi 都能过, 仍保留 weapi 兜底。
- **模拟器点按坐标别忘 1.2 倍换算**: 截图显示 900x2000, 实际 1080x2400。把"歌曲百科"按显示坐标点下去
  实际落在"不感兴趣"上, 于是看到 `code=432`, 一度误判成 eapi 在安卓身份下挂了;
  交叉验证方法: 把同一份 identity.json 和 cross-compiled probe(`--target x86_64-linux-android`)
  `adb push` 进模拟器跑, 结果 200 —— 说明不是身份/网络问题, 是点错了。
- 非日推/非 FM 的歌点"不感兴趣"服务端回 `code=432 Unknown error`(接口只认日推/FM 上下文),
  暂时原样弹错; 要友好就得在 UI 侧只对日推/FM 队列显示该入口。

## 消息中心接入(2026-11-06)

- 未读计数 `/api/pl/count`(weapi) 的键是 **`msg` / `notice` / `comment` / `forward`**, 不是私有消息那套命名;
  `pushMsg` 字段只是给推送用的文案。
- 私信会话 `/api/msg/private/users`: `{code, msgs:[{fromUser:{userId,nickname,avatarUrl}, lastMsg, lastMsgTime, newMsgCount}], newMsgCount}`;
  `lastMsg` 是 **JSON 字符串**, 富消息(会员/活动卡片)没有 `msg`, 只有 `generalMsg{title,inboxBriefContent,noticeMsg}` 和 `pushMsg`。
- 私信历史 `/api/msg/private/history?uid=&limit=&time=`: `msgs[]` **倒序**, 单条 `{id, fromUser, toUser, msg(JSON 字符串), time}`;
  按 `fromUser.userId == my_uid` 判断是否我方气泡。
- 通知 `/api/msg/notices?limit=&lasttime=`: `notices[].notice` 又是 JSON 字符串 →
  `generalNotice.actionDesc`(动作) + `user.nickname/avatarUrl`; 解析不出时退 `pushMsg`/"系统通知"。
- 评论消息 `/api/v1/user/comments/<uid>?uid=&limit=&before=-1`: `comments[].{commentId,content,beRepliedContent,time,user,resourceJson}`;
  `resourceJson` 也是 JSON 字符串, `name` 是被评论的资源名。
- vendor 没有私信发送接口 → UI 明确标"只读"; 已读上报也没做。

## 新歌/新碟分地区 + 歌手榜(2026-11-06)

- `top_song`(`/api/v1/discovery/new/songs`) 的 `type` 实为 **areaId**, 只有
  **0 全部 / 7 华语 / 8 日语 / 16 韩语 / 96 欧美** 有数据; 1..6、17、18 都是空数组(别按"0-4 五种语言"的旧文档写)。
- `top_album`(`/api/discovery/new/albums/area`): `area` 是 **字符串** ALL/ZH/EA/JP/KR;
  **部分地区 weekData 空、monthData 有货**(ZH 就是), 必须两桶合并去重, 否则华语新碟显示为空。
- `top_artists`(`/api/artist/top`): 顺序是服务端热度序, **不是 fansCount 倒序**; 前端别重排。
- `top_song` 的 `data[]` 是完整 song 对象但字段是 `artists`/`album`/`duration`
  (cloudsearch 是 `ar`/`al`/`dt`), 现有 `parse_song_with` 两种都认, 直接复用即可。

<!-- created=2026-11-06, last=2026-11-06 -->

## 评论热门 / IP 归属(2026-11-07)

- 普通评论页 `/api/v1/resource/comments/<threadId>` 同时回 `hotComments` 和 `comments`:
  热评**没有 IP 归属地**(`ipLocation.location` 为空串), 且同一条评论可能在两处重复;
  去重时先保留热评版本, 再用后一份把 `ipLocation` 补上。
- 热门评论页 `/api/v1/resource/hotcomments/<threadId>?type=&id=&limit=&offset=`:
  分页字段是 **`hasMore`**(普通页是 `more`), `total` 是热门评论总数(孤勇者 9405, 全部 31 万)。
- 客户端"全部"列表翻页的 offset 只能数**非热评项**(热评每次都随首页返回), 用 items.length
  会重复拉热评并跳过若干条最新。
- 动态 `A_EV_2_<eventId>_<uid>` 不能直接喂热门接口(只认 eventId), UI 对动态隐藏热门页签。
- CLI 新增 `ncm hotcomments <kind> <id> [limit]`, 便于脱离 UI 验证。

<!-- created=2026-11-07, last=2026-11-07 -->

## 剩余待办的批次与派发规划(2026-11-07)

- 规划文档: `docs/remaining-batches.md`(S/M/L/X 分级、Wave 流水线、派工模板、编排者收口清单)。
- 关键硬约束: `netease.rs`/`api.rs`/`frb_generated.*` 是单写者文件, **codegen 全局串行**;
  同仓同工作树安全并行度 = 2(Rust 桥 + 纯 Dart); 构建串行, 设备实测单台内串行、两台模拟器(a34/a36)可并行。
- 新批开工前先在本文件 §3 查并行矩阵, 收口一律由编排者重跑 `tools/ci.sh` 与模拟器走查。

<!-- created=2026-11-07, last=2026-11-07 -->
