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


[Exact evidence: /home/xuqianhui/.pi/agent/sessions/--home-xuqianhui-netease-mini-player--/pi-fold-evidence/pi-session/sha256/8f/8f69d30e9492a0a696036416c39e5a84cd9968e33e17845480b0641263062679.txt; sha256=8f69d30e9492a0a696036416c39e5a84cd9968e33e17845480b0641263062679; bytes=18034]

## 收尾批实测(album_newest / toplist_detail_v2 / comment_mv+video)(2026-11-09)

- `album_newest`(`/api/album/newest`): `{code, albums[12]}`,固定 12 张编辑精选、**没有 total/分页**;
  专辑对象与 `album_new` 同构,但 id 集合与 `album_new` 前几张完全不同 ⇒ 两者不是重复接口。
- `toplist_detail_v2`: 响应 `{code, data:[{categoryCode, list:[{id,name,coverUrl,updateFrequency,
  targetType:"PLAYLIST",canPlay}]}]}`;分组顺序 TOPPING/OFFICIAL/FEATURE/MUSIC_STYLE/GLOBAL/LANGUAGE/MORE(7 组 45 榜)。
  **"更新 N 首 / 刚刚更新"只存在于 `updateFrequency` 文案里**,v1 的 `trackUpdateTime` 数字字段在 v2 没有;
  个别条目 `id=0` 且 `canPlay=false`(不可播)。
- `comment_mv`/`comment_video` 与歌曲评论**完全同形**(`{total, more, hotComments, comments, topComments}`),
  只有 thread 前缀不同(`R_MV_5_`/`R_VI_62_`) ⇒ 直接复用歌曲评论的 parse/DTO,不要新建结构。
- `simi_user` **实测恒空**(登录态下 id/userId 两种参数、多个 uid 都回 `{"code":200,"userprofiles":[]}`),
  判定不做;怀疑服务端已下线该能力。
- `dj_subscriber` 的分页游标是 `time` = **上一页最后一条的 subscribeTime(ms)**,首页传 `-1`;
  FFI 侧已加 `time_ms: Option<u64>`,Dart 传 null 表示首页。

## 后端形态调研结论(2026-11-09, 详见 docs/backend-service-options.md)

- **不换形态,只裁剪**:vendor 12,035 LOC / 382 endpoint(我们用 118, 31%),但它的**边际依赖为 0**
  (213-crate 服务树与去掉 vendor 后的差集为空),单独重编译仅 1.3s ⇒ vendor 不是编译或依赖瓶颈。
- 体积大头是网络栈(reqwest/tokio/rustls),换成 Node sidecar(api-enhanced 仓库 147MB,Android 还要带 Node runtime)
  或自写最小客户端都省不掉这部分,却会新增运行时/维护成本。
- 实测延迟(直连、proxy 已清):search 中位 **0.39s**、detail 中位 **0.14s**。
- 推荐 P1 删未接入的 264 个 endpoint 文件(vendor 10.3k→~3.2k LOC,验收=编译通过+延迟不劣化)、
  P2 `tokio` 去 `full` 按需 feature、P3 再量一次 release/strip 后的 `libncm_ffi.so` 各 ABI 体积,
  只有 vendor 相关 >5MB 才值得考虑自写客户端。

§

- **P1/P2 后端裁剪已落地(2026-11-09)**: vendor endpoint **382→118**(未接入 0)、LOC 12,035→4,069、体积 1.7M→564K;
  `tokio` 从 vendor 直接依赖**整体移除**(库本体只走 reqwest async, 只有 dev-deps 测试用);
  上游 `server` 特性(axum + `src/bin/server.rs` + 5 个可选依赖)是**死特性**(启用即因 endpoint 被删 E0599), 已整块删除。
  依赖数 213/279/257 → 207/274/252(口径: `cargo tree -p X --prefix none | sort -u | wc -l`),
  冷编 vendor 1.40→0.65 s, release `.so` 14,246,736→14,157,856(strip 8,971,718→8,918,104)。
  连带: vendor 联网 smoke **8→4 例**(删的 4 例打在未接入 endpoint), `ncm-cli raw` 少 9 个分支。见 `docs/backend-prune.md`。

§

- **`tools/api-coverage.sh` 的 UI 入口判定必须大小写不敏感**: frb 生成名不总是严格 camelCase
  (实测 `lyric_lines_i18n` → `lyricLinesI18N`, 大写 N), 原 camel 精确匹配把它误判成"无 UI 入口";
  改成小写化标识符集合比对后真实死导出为 **2**(`search` `api.rs:160` / `lyric_lines` `api.rs:607`)。
  另: 统计 endpoint 时必须排除 `api/mod.rs`(模块清单不是 endpoint, 否则永远显示"未接入 1")。

§

- **`tools/env.sh` 不导出 `ANDROID_NDK_HOME`**: 只有 PATH/镜像。任何带 C/asm 依赖的 crate
  (`ring`/`zstd-sys` 等)做 `--target aarch64-linux-android` 都要自己配
  `CC_/CXX_/AR_aarch64_linux_android`(= `$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android23-clang`)
  + `.cargo/config.toml` 的 linker, 否则末尾报 `Relocations in generic ELF (EM: 183) / file in wrong format`。
  现有 cargokit 链路不受影响(它自带这些)。

§

- **`netease-music` 0.1.1 换库裁决 = 暂不切(2026-11-09 spike)**: 搜索/歌词与现实现逐字节一致、
  Android 交叉编译配 NDK 即过; 但取链匿名态被风控(ncm 404 / crate -460)、且 crate **每进程随机**
  `device_id/sDeviceId`(`client.rs:61,63`), 必须自建 identity.json 回灌层(`ensure_cookie`=`or_insert` 可回灌),
  `login_qr_url()` 还会重复拼 `codekey=` 产生畸形 URL。净收益仅"少 2.4k 行加解密"。
  复测门槛见 `docs/backend-service-options.md` §6; 报告 `docs/spikes/2026-11-09-netease-music-spike.md`。

§

- **播放条合并 + 歌曲详情页(2026-11-08)**: 播放条只剩 **一行**(封面 52 + 4×40dp 紧凑图标: 喜欢/上一首/播放/下一首),
  播放模式·心动·队列挪到详情页底部横条(`_buildDetailActionStrip`, 横向可滚防 300dp 挤爆);
  行尾 "..." (`SongOverflowButton`) 从播放条挪进详情页 AppBar。
- **详情页就是原来的歌词叠层**(`_showLyrics` / `_toggleLyrics`, 仍在 body 内 Stack, 不是新路由), 因此返回键优先级
  (`resolveHomeBackAction`) 不变; 多选歌词时返回键先退多选。
- **分享链路不引插件**: 二维码用 `qr_flutter`(纯 Dart, 带 `qr`), 卡片是普通 widget + `RepaintBoundary.toImage`
  导出 PNG(预览即导出, 没有第二套排版); Android 走自建 `ncm/share` 通道(`shareImage` = FileProvider +
  cache/shared + ACTION_SEND, `saveImage` = MediaStore Q+/公共 Pictures), Linux 直接落 `~/Pictures/MiniNCM`。
  新增 `res/xml/file_paths.xml` + manifest provider(`${applicationId}.fileprovider`); 坑: FileProvider 的 paths
  必须覆盖真正写文件的目录(cache/shared), 否则 `getUriForFile` 直接抛 IllegalArgumentException。
- **歌词跟随**: 自动滚动只在换行时触发; 手指拖动(`ScrollUpdateNotification.dragDetails != null`)即暂停跟随,
  **必须只认 dragDetails** —— 自动跟随用的 `animateTo` 也发 ScrollNotification, 只看 UserScrollNotification 会误判自锁。
  "定位到当前歌词"按钮同时恢复跟随 + 滚到当前行; 翻译开关存 `AppSettings.lyricTranslation`, 只在该曲歌词确有
  tlyric 时才显示开关。歌词长按进多选 → 右上角 "分享所选歌词"。

§

- **模拟器实测踩坑(2026-11-08, a34)**:
  - 213MB debug APK 用 `adb install` **streamed install 会失败**
    (`INSTALL_PARSE_FAILED_NO_CERTIFICATES: SHA-256 digest of contents did not verify`),
    换 `adb install --no-streaming -r -t` 必成。
  - `uiautomator dump` 报 `ERROR: could not get idle state` 的原因是**App 一直在出帧**:
    播放中每 500ms `setState` + 输入框光标闪烁。对策: 先点播放条的播放/暂停键暂停(并让输入框失焦),
    dump 立刻成功; 用 `adb shell input keyevent 4` 直接把 App 退到后台会导致 dump 拿到 launcher。
  - Flutter 的语义树能用 uiautomator 读到(`content-desc`), 前提是
    `adb shell settings put secure accessibility_enabled 1`; 驱动脚本已入库 `tools/devui/`
    (`uix` 列 desc+bounds / `uitap` / `uilong` / `shot` / `shotmap` 灰度 ASCII / `cropmap` RGB),
    `~/bin/` 下是同一批的个人副本。脚本默认 `DEV=emulator-5554`, 另一台在跑时要显式传。
  - 别用窗口模式起 a34(`-gpu host` 下 gles_v2 满屏 `error null ctx`), 用 `~/bin/avd headless a34`。
  - a36 常被**另一个项目**占用(5554), 本项目统一用 a34, 一律 `adb -s emulator-5556`。
- **Flutter SDK 文件会被写坏**: 崩溃/突然关机后 `packages/flutter/lib/src/material/animated_icons/data/home_menu.g.dart`
  第 1405 行多出一个 `  (` 前缀, 症状是所有 widget test 编译失败报
  `Can't find ')' to match '('`(报错指向 SDK 自身)。修法: `git -C ~/android-dev/flutter status --porcelain`
  看被改的文件, 逐个 `git checkout -- <file>`(本机 SDK 是干净 checkout, 改动一律视为损坏)。
- **Android 分享图片必须带 clipData**: ACTION_SEND 只放 `EXTRA_STREAM` 时, 系统选择器
  (com.android.intentresolver) 预览会报 `Permission Denial: opening provider ... FileProvider ... not exported`;
  加 `clipData = ClipData.newRawUri("image", uri)` + `FLAG_GRANT_READ_URI_PERMISSION` 才正常。

<!-- created=2026-11-09, last=2026-11-09 -->
