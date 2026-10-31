# 轻音 MiniNCM —— 网易云极简第三方安卓客户端

**架构一句话**: 原生壳(WebView + 播放前台服务, ~200KB) + 前端 SPA(UI/加密/业务全在 JS, 可热更新) + 插件注册表(音乐源可插拔)。

## 当前状态(2026-10-31)

真机(vivo X200 Ultra / Android 16 / WebView 138)已跑通 **登录 → 搜索 → 播放** 全链路,APK **96KB**,
冷启动 242ms,空闲 PSS 126MB。详见 `docs/PROGRESS.md`。

文档索引:

- `docs/PROGRESS.md` —— 进度、踩坑、待办
- `docs/community-projects.md` —— 社区项目盘点、协议实测、登录通道结论
- `docs/build-vs-fork.md` —— fork / PR / 自建 的资源实测与决策矩阵
- `.pi/skills/netease-cloud-music-api-reverse/SKILL.md` —— 协议与反爬细节

## 设计原则

- **功能与实现解耦**: 原生层只做三件事 —— HTTP IO(无 CORS 限制的桥)、SharedPreferences 存储、MediaPlayer 前台播放。所有业务逻辑(加密/接口/UI/状态机)都在 `assets/www` 的 JS 里。
- **一切皆插件**: `js/plugins/provider/` 是音乐源插件目录, 每个插件遵循统一接口(`loginQr/loginCheck/search/songUrl/lyric`)。当前只有 `provider/netease`(网易云直连), 后续可加远程 API 服务、其他音乐源、歌词插件、主题插件。
- **轻量**: 零 androidx、零 kotlin、零第三方 gradle 依赖; JS 库仅 crypto-js(63KB) + qrcode(20KB)。APK 目标 < 500KB。

## 目录结构

```
netease-mini-player/
├── android/                      # 安卓壳工程(纯 framework API)
│   ├── settings.gradle / build.gradle / gradle.properties / local.properties
│   └── app/
│       ├── build.gradle          # 零依赖
│       └── src/main/
│           ├── AndroidManifest.xml
│           ├── java/com/minincm/app/
│           │   ├── MainActivity.java          # WebView 壳
│           │   ├── bridge/AppBridge.java      # JS 桥(httpPost/store/play)
│           │   └── playback/PlaybackService.java  # 前台播放服务
│           └── assets/www/                    # 前端 SPA(全部业务)
│               ├── index.html / css/app.css
│               └── js/
│                   ├── lib/                   # crypto-js / qrcode
│                   ├── core/                  # bridge.js(桥封装) / app.js(入口)
│                   └── plugins/provider/      # 音乐源插件
│                       └── netease.js         # 网易云直连(eapi 加密)
└── references/api-enhanced/      # 协议蓝本: NeteaseCloudMusicApiEnhanced
```

## 构建

```bash
bash tools/setup-android-env.sh   # 首次: 用户级装 JDK21 + Gradle8.9 + Android SDK34 (~1GB, 无需 sudo)
bash tools/build.sh               # 构建: android/app/build/outputs/apk/debug/app-debug.apk (~70KB)
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

工具链位置(全部用户级, 在 `~/android-dev`, 可用 `ANDROID_DEV_ROOT` 覆盖):
`jdk`(Temurin 21) / `gradle-8.9` / `sdk`(platform-34, build-tools 34.0.0);
`android/local.properties` 写死 `sdk.dir`(已 gitignore)。

踩坑备查: JDK 17.0.2 会让 `validateSigningDebug` 因为
`CgroupInfo.getMountPoint() ... anyController is null`(JDK-8263560 一类 cgroup v2 探测 NPE)
直接崩 —— 这也是默认装 21 的原因; 下载源: Temurin 走 USTC 镜像, Gradle 走腾讯云镜像
(官方 services.gradle.org 本机只有 KB/s 级)。

## 接口/加密协议(v1, 基于 NeteaseCloudMusicApiEnhanced 2026-08)

| 项 | 值 |
|---|---|
| 加密 | eapi(AES-128-ECB, key=`e82ckenh8dichen8`), 响应明文 |
| 域名 | `https://interfacepc.music.163.com/eapi/...` |
| 请求头 | 加密 header 序列化为 Cookie + NeteaseMusic iPhone UA |
| 登录 | 扫码: `/api/login/qrcode/unikey` → 生成二维码 → `/api/login/qrcode/check` 轮询(803 成功) |
| 搜索 | `/api/cloudsearch/pc` |
| 播放地址 | `/api/song/enhance/player/url`(老 eapi 接口; 若被风控, 二期切 xeapi) |
| 歌词 | `/api/song/lyric` |

## 二期路线(从重要到次要)

1. **xeapi 加密**(X25519, @noble/curves) → 匿名注册 + 新播放接口, 彻底脱离风控
2. **播放体验**: 进度条 seek、锁屏控制(MediaSession)、耳机线控、后台通知完善
3. **歌单/收藏/每日推荐**: 播放列表 UI、登录态歌单同步
4. **歌词滚动显示**
5. **远程 API 插件**(`provider/remote-api`): 配置自建 api-enhanced 服务地址即用, 与直连插件平级
6. **本地缓存**: 播放过的歌落盘, 离线可用

## 参考

- **社区项目盘点与路线选择(先读这个)**: `docs/community-projects.md`

- 协议蓝本: https://github.com/neteasecloudmusicapienhanced/api-enhanced (社区接力维护版)
- 原版已应版权要求下架: Binaryify/NeteaseCloudMusicApi(README 仅剩声明)
