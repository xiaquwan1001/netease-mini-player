# 架构重启: 多端(Android + Linux + Windows) + 长期维护 + 低资源

> **2026-11-10 追加**: 本文写于 2026-11-03, 当时目标平台是 Android + Linux。
> **Windows 桌面版已于 2026-11-09 合入**(`feat/windows`, PR #1): 同一份 Flutter UI + 同一份 Rust core,
> 播放后端与 Linux 共用 `ncm-playback`(rodio + CPAL, **Linux=ALSA / Windows=WASAPI**),
> 产物由 `.github/workflows/windows.yml` 在 `windows-latest` 上构建。下文凡出现「双端」均按**三端**阅读。
>
> 2026-11-03 立项分析。目标不是继续给 v1 加功能,而是重定架构。
> 依据: 本仓 `build-vs-fork.md` 的真机实测、社区 benchmark(见各节引用)、
> 以及 Flutter/Tauri 官方文档现状(2026-11)。

## 0. 结论先行(TL;DR)

1. **Flutter 作为 UI 层: 合理**,一份 UI 跑 Android + Linux,生态与文档都够用。
2. **"Flutter + 插件化" 这个说法只对了一半**: Flutter 的 plugin 是**编译期**的原生能力桥接,
   AOT 下不能运行期加载 Dart 代码(AOT 无 `dart:mirrors`,`Isolate.spawnUri` 只在 VM 有)。
   产品级"插件"(音源脚本可导入/可热更)必须**自带脚本引擎**,不能指望 Flutter plugin 机制。
3. **"减少资源占用" 与 Flutter 有张力**: 体积从 96KB → 15MB+,内存从 126MB → 约 100~130MB。
   换 Flutter 的收益是**双端一份 UI + 摆脱 Chromium**,不是省内存。真正把内存压到 87MB 级别的是
   原生 UI(Ncrust 实测),那就没有"一份 UI"了。
4. **推荐主线(方案 A)**: `Rust core(协议/网络/缓存/插件宿主) + Flutter UI + JS 音源插件(QuickJS)`,
   播放后端按平台分治(Android=Media3 / Linux=mpv)。详见 §3~§5。
5. **决策门**: 若"Android 空闲 PSS < 100MB"是硬指标,方案 A 大概率不达标,应改方案 B
   (Rust core + Compose/GTK 双原生 UI)。这个指标请先拍板(§10)。

## 1. 需求 → 可验收指标

| 维度 | 建议指标 | 说明 |
|---|---|---|
| 平台 | Android 8+(API 26+) / Linux x86_64(Wayland/X11) | Linux 先 deb/AppImage,Flatpak 后置 |
| 功能 MVP | 登录、搜索、每日推荐、私人FM、歌单、播放(队列/音质/缓存)、歌词、喜欢 | v1 已有能力 + Ncrust 的最小集 |
| Android 空闲 PSS | ≤ 110MB(现有 126 / Ncrust 87 / Melodia 101) | 冷启动 ≤ 500ms |
| Android 安装包 | ≤ 25MB universal(按 ABI 拆分 ≤ 12MB) | Flutter 引擎 baseline 已 ~8-10MB |
| Linux 内存 | 空闲 RSS ≤ 180MB;安装体积 ≤ 40MB | Flutter + mpv 的合理区间 |
| 可维护性 | 协议层离线单测(fixture 回放)、UI 与协议零耦合、单仓 | 一条命令跑全量测试 |
| 扩展性 | 音源插件运行期导入/启停,双端同一脚本二进制兼容 | 兼容 LX 自定义源脚本 |

## 2. 关键认知: "插件化"要分三层,只有一层是真动态

| 扩展点 | 运行期可加 | 机制 | 要不要 |
|---|---|---|---|
| 音源 provider(搜索/取链/歌词/登录) | **是** | 嵌入 JS 引擎(QuickJS)+ 宿主 API | **要**(核心卖点) |
| 歌词源/封面源/歌单导入导出 | 是 | 同一 JS 宿主,按 capability 声明 | 要(顺手) |
| 主题/皮肤 | 是(数据,非代码) | 主题 JSON + 变量,不执行代码 | 要(便宜) |
| 音频解码/播放后端 | 否 | 编译期 feature + 平台实现 | 不要 |
| UI 页面/布局 | 否 | 编译期模块(Flutter widget 包) | 不要(代价高收益低) |

依据: Flutter AOT 的限制(官方 issue / AppFlowy 的经验文: 运行期加载代码的 OTA、版本兼容、
回滚成本极高)。而 **LX / MusicFree 的插件本来就是 JS**(ES6+,`lx.on`/`lx.request` 事件模型,
文件头 `@name/@description/@version` 元信息),宿主给沙箱 + 网络代理即可 —— 正是我们
`plugins/lx-music/ncm-wy.js` 已经验证过的那条路。

## 3. 方案矩阵(用实测数字打分)

| 方案 | 包体 | 空闲内存 | 双端一份 UI | 真·运行期插件 | 风控可控 | 长期维护 |
|---|---|---|---|---|---|---|
| 现状: 原生壳 + WebView SPA | **96KB** | **126MB** | 只 Android | 是(JS) | 中 | 低(无类型、桥多) |
| **A. Rust core + Flutter UI + QuickJS** | 15~25MB | 约 100~130MB | **是** | **是** | **高** | **高** |
| B. Rust core + 原生双 UI(Compose / GTK4) | 8~12MB | **87~100MB** | 否(两套 UI) | 是(同一 JS 宿主) | 高 | 中(UI 双份) |
| C. KMP + Compose MP(= Melodia 路线) | 22MB | 101MB(Android), 桌面 JVM 更重 | 是 | 是(WebView/GraalJS,两端不一致) | 中 | 中(依赖多、Gradle 重) |
| D. Tauri v2(保留现有 JS SPA) | 5~8MB + 系统 WebView | **126MB 量级** | 是 | 是 | 中高 | 中(两语言;Android 端仍偏新) |
| E. Flutter 全 Dart(无 Rust core) | 15~25MB | 100~130MB | 是 | 是(flutter_js/QuickJS) | 中(HTTP 头序/TLS 定制弱) | 中高 |

读法:
- **"依赖少 = 省内存" 已被自己的数据否证**(96KB 的 APK 却是 126MB): 内存由运行时决定 ——
  Chromium 贵、Flutter/Skia 中等、Compose 更省。
- 社区基准(2026): Flutter 全应用内存约 **80~120MB**,Compose MP 90~130MB,同一量级;
  Flutter Linux 空壳 bundle 里引擎本身 ~15MB 起。
- Tauri 的优势是体积与复用前端,但**移动端仍用系统 WebView** → 现在的内存问题一个都不解决,
  只是换了个原生后端语言。

排序(只能选一个): **A > B > E > D > C**。C 的坑已在 Melodia 验证(71 个 Gradle 依赖、22MB、
桌面 JVM 常驻),不适合"轻"。

## 4. 方案 A 的分层与职责

```
┌────────────────────────── Flutter UI (Dart) ──────────────────────────┐
│ 页面/组件/主题 · 路由 · 输入法 · 拖拽 · 本地化 · 无障碍                │
│ 只做「渲染 + 输入 + 短命视图状态」;不写协议、不写队列真相             │
└──────────────▲──────────────────────────────┬─────────────────────────┘
               │ flutter_rust_bridge(typed)   │ 事件流(播放/进度/状态)
┌──────────────┴──────────────────────────────▼─────────────────────────┐
│ core (Rust, 两端同一份, 无 UI)                                        │
│  net   : HTTP(cookie jar / 身份头序 / 重试 / 代理 / 连接复用)         │
│  proto : eapi/weapi/xeapi 加密 + 接口封装 + fixture 回放测试           │
│  domain: Song/Playlist/Queue 状态机 · 喜欢/历史 · 音质档位决策        │
│  store : SQLite(元数据) + 文件缓存(音频/歌词/封面, LRU)             │
│  plugin: QuickJS 宿主(rquickjs)+ 沙箱 + 超时中断 + capability 路由   │
└──────▲───────────────────────────────▲────────────────────────────────┘
       │ JNI / FFI                    │ FFI
┌──────┴─────────────┐      ┌─────────┴───────────────┐
│ Android 适配(Kotlin)│      │ Linux 适配(Rust/GTK)   │
│ Media3 ExoPlayer    │      │ mpv(libmpv) 播放        │
│ MediaSession/通知/  │      │ MPRIS(dbus) / 托盘      │
│ 音频焦点/前台服务   │      │ 文件关联 / 单实例       │
│ 登录用 WebView 壳   │      │ 登录用 WebKitGTK helper │
└─────────────────────┘      └─────────────────────────┘
```

四条设计约束(比选型更重要):
1. **真相只有一份**: 队列/播放状态/登录态在 core,UI 只订阅。否则双端行为漂移 + 状态 bug。
2. **播放后端不统一**: Android 必须走 Media3(MediaSession、通知、音频焦点、车机、厂商适配都在这一层);
   Linux 走 mpv(格式全、gapless、硬解)。
   > **实现现状(2026-11-09 校正, 2026-11-10 补 Windows)**: Linux **没有用 mpv/MPRIS**,实际是 `ncm-playback` 里的
   > **rodio 0.23 + symphonia**(纯 Rust, 无系统依赖;见 `core/crates/ncm-playback/Cargo.toml`)。
   > 同一份代码也服务 **Windows**(WASAPI);桩 backend 的 `cfg` 与桌面 backend 互斥。
   > 下文凡提 "mpv" 均按此替换阅读;MPRIS 未实现。
   core 只定义 `PlaybackBackend` trait,两端各实现,
   事件统一成 `PlaybackEvent`。
3. **协议层可离线测**: 每个接口一组 request/response fixture(脱敏),CI 不联网跑单测。
   Ncrust 的 `spec/` 就是干这个的,抄结构不抄代码。
4. **登录是平台差异点,单独抽象**: Android = 内嵌 WebView 抓 `MUSIC_U`(v1 已验证);
   Linux = 独立 WebKitGTK helper 窗口抓 cookie,或"手机端登录后导出 cookie 文件"兜底。
   原生扫码被 8821 拦死(v1 实测 + Ncrust 独立复现),不做。

## 5. 为什么 core 用 Rust,而不是全 Dart

| 关注点 | Rust core | 全 Dart |
|---|---|---|
| 双端行为一致性 | 同一份语义,插件宿主也一份 | 也一份,但 HTTP/加密细节在 Dart |
| TLS/头序/风控可控 | rustls/boringssl 可选,header 顺序可控 | `HttpClient` 定制面窄 |
| JS 插件宿主 | rquickjs(可中断、内存上限) | flutter_js/quickjs ffi,生态薄 |
| 内存 | core 常驻 ~10-20MB | Dart VM 已在 Flutter 里,增量小 |
| 构建复杂度 | 高: NDK + cargo-ndk + 交叉编译 + 桥生成 | **低** |
| 单人维护 | 中(协议/加密是纯函数,好测) | 中 |

结论: **选 A 的主因是"协议/风控/插件宿主双端完全一致 + 可离线测试"**,不是性能。
若更看重"一个人少踩构建坑",**方案 E(全 Dart + QuickJS)是可接受的降级**,代价是风控调试空间小。
本机 Rust 1.99 已就绪,Flutter SDK 尚未安装。

## 6. 插件契约 v1(草案)

脚本形态沿用 LX(现有 `plugins/lx-music/ncm-wy.js` 可直接当第一个真实用例):

```js
/**
 * @name 网易云(直连)
 * @description eapi 直连,支持搜索/取链/歌词
 * @version 1.0.0
 * @author you
 * @capabilities ["musicUrl","lyric","search"]
 * @apiVersion 1
 */
// 宿主注入: lx.request / lx.crypto / lx.storage / lx.log / lx.utils
lx.on('musicUrl', async (info) => {
  const res = await lx.request({ url: 'https://interface3.music.163.com/eapi/...', method: 'POST', body, headers })
  return { url: pick(res), quality: info.type, expireAt: Date.now() + 300000 }
})
```

契约要点(缺一条就会在真实用户手里出事):
- **能力声明** `capabilities`: 宿主只调声明过的动作,UI 只显示可用功能。
- **纯 JSON 边界**: 进出都是可序列化数据,不依赖宿主对象生命周期。
- **时间/内存预算**: 单次调用硬超时(建议 8s)+ QuickJS interrupt;单插件内存上限(如 32MB);
  连续失败 3 次自动禁用 + 可观测日志。
- **权限最小化**: 只给 `lx.request`(受控出站,带 UA/代理/超时)与 `lx.storage`(命名空间隔离),
  无文件系统、无进程、无任意 socket。
- **ABI 版本协商**: `apiVersion` 不兼容时拒绝加载并给明确文案,而不是静默崩。
- **来源可信**: 导入时展示作者/域名/权限;默认不自动远程更新。

## 7. 仓库布局(重启后的骨架)

```
netease-mini-player/
├── core/                  # Rust workspace
│   ├── crates/ncm-proto  # 加密 + 接口 + fixture 测试
│   ├── crates/ncm-net    # HTTP 客户端、cookie jar、身份注入
│   ├── crates/ncm-plugin # QuickJS 宿主 + lx 兼容层
│   └── crates/ncm-cli    # headless CLI: search/url/lyric —— 无 UI 也能验证全链路
├── ui/                    # Flutter app(Android + Linux + Windows 一份)
├── platform/
│   ├── android/           # Kotlin: Media3、MediaSession、登录 WebView、前台服务
│   └── linux/             # Rust/GTK: mpv、MPRIS、WebKitGTK 登录 helper、托盘
├── plugins/               # 内置 + 示例音源脚本(JS)
├── tools/                 # 构建/打包/CI/插件回归台(现有 harness 升级)
└── docs/                  # 协议技能文档、决策记录(现有资产)
```

保留: `docs/`(协议/风控/踩坑)、`.pi/skills/netease-cloud-music-api-reverse`、
`plugins/lx-music/ncm-wy.js`、`tools/lx-plugin-harness.mjs`(升级为插件契约回归台)、
v1 的 `LoginActivity` 思路(移动 UA + `/login` + 抓 `MUSIC_U`)。
不保留: WebView SPA 的 UI/桥代码(~380 行),只作行为参考。

## 8. 里程碑(每步都有可验收产物)

| 阶段 | 内容 | 验收 | 估时 |
|---|---|---|---|
| **M0 基建** | cargo workspace + Flutter 双端空壳 + rust↔dart 桥 smoke + CI(linux build / android assemble) | 两端启动空页面,桥调用往返成功;CI 绿 | 3~5d |
| **M1 协议引擎** | eapi、身份 cookie(deviceId 持久化)、搜索/取链/歌词、fixture 单测、`ncm-cli` | Linux 上 `ncm-cli search/url` 直接取到直链并下载播放;单测离线全绿 | 5~8d |
| **M2 播放** | Android Media3 + MediaSession + 前台服务;Linux mpv + MPRIS;队列/缓存 | 两端播放/暂停/上下曲/进度/系统媒体控制;断网重试 | 6~9d |
| **M3 UI 闭环** | 搜索 → 播放 → 歌词 → 迷你播放条 | 两端功能一致;冷启动与 PSS 出首版数字 | 6~8d |
| **M4 登录** | Android 内嵌 WebView;Linux WebKitGTK helper / cookie 导入;登录态持久化 | 两端都能登录看到"我喜欢的音乐";登出/换号不崩 | 4~6d |
| **M5 插件** | QuickJS 宿主、lx 兼容层、插件管理页、导入/启停/日志 | 现有 `ncm-wy.js` 双端同一文件可跑;超时/隔离用例通过 | 5~8d |
| **M6 达标发布** | 内存/包体优化、崩溃上报、deb/AppImage、APK 签名 | 达到 §1 指标;真机 + 桌面完整回归 | 5~7d |

合计约 **6~9 周**(单人、按裁剪过的 MVP)。M3 结束做指标复盘,决定是否继续 Flutter。

## 9. 风险与对应

| 风险 | 触发信号 | 对策 |
|---|---|---|
| 风控/接口变更 | 取链 403/-110/8821、搜索空结果 | 协议层隔离 + fixture 快速回归;身份 cookie 稳定;必要时插件层换源 |
| Flutter Linux 生态缺口(托盘/输入法/MPRIS/文件关联) | 桌面体验"不像 Linux 应用" | 平台层用 GTK/DBus 自己补;首版只做 deb |
| QuickJS 插件沙箱逃逸/死循环 | 客户端卡死 | interrupt + 超时 + 内存上限;二期可进程外隔离 |
| 内存不达标 | M3 PSS > 120MB | **决策门**: 保 core 换原生 UI(方案 B),只重写 `ui/` |
| 单人维护面积过大 | 双端 bug 交替出现 | MVP 砍到"能听歌 + 插件";其余功能延后 |
| 许可证污染 | 参考了 GPL 项目代码 | GPL/AGPL(netease-cloud-music-gtk、MusicFree、ML-Netease)只读思路不抄代码;本仓建议 MIT |

## 10. 需要拍板的 4 件事

1. **内存是否为硬指标?** 硬(<100MB)→ 方案 B;软(≤130MB 可接受)→ 方案 A。
2. **是否要 LX 脚本兼容?** 要 → 必须内嵌 JS 引擎(A/B/E 都满足),也是与 Melodia/MusicFree
   生态互通的关键;不要 → 插件可退化成"编译期 provider + JSON 配置",工程量减半。
3. **Linux 登录走哪条路?** WebKitGTK helper(体验好,多 40~80 行 C/Rust)/ 系统浏览器 + cookie 导入(最省)。
4. **Rust core 还是全 Dart?** 愿意承担 NDK + 交叉编译的一次性成本 → A;想最快出双端 → E。

拍板后出 M0 落地清单(具体 crate 划分、CI 配置、Flutter 版本锁定、Android 签名与 SDK 目标)。

## 11. 决策记录(2026-11-03)

| # | 决策 | 结论 |
|---|---|---|
| D1 | 内存要求 | **中等偏小即可**,不追求极致 → 采用方案 A(Flutter UI + Rust core) |
| D2 | 音源脚本插件 | **首版不做**,只留扩展缝(seam);音源走编译期 provider |
| D3 | Linux 登录 | **预留多入口,从最简单的开始**:cookie 导入 → 局域网配对导入 → 内嵌 WebKitGTK |
| D4 | 语言选型 | **Rust core + Dart UI + Kotlin(Android 平台层)+ Rust/GTK(Linux 平台层)**,按活选语言 |
| D5 | 风控/加解密 | **不自己写**:采用社区现成 API 库 `ncm-api-rs`(api-enhanced 的 Rust 移植),我们只做包装与身份持久化 |

### 11.1 预算随之放宽(避免过度优化)

| 指标 | 原目标 | 调整后 | 触发动作 |
|---|---|---|---|
| Android 空闲 PSS | ≤110MB | **≤130MB** | >140MB 才做专项优化 |
| Android 冷启动 | ≤500ms | ≤600ms | >1s 才查 |
| APK | ≤25MB | ≤30MB(universal) | >40MB 查依赖/符号 |
| Linux 空闲 RSS | ≤180MB | ≤200MB | >250MB 查 mpv/缓存 |
| 开发节奏 | — | 先能听歌,再谈瘦身 | 每阶段出一次实测数字 |

### 11.2 D2 的具体含义:留缝但不实现

首版**不引入 QuickJS**,也不做插件市场。但以下三点从第一天就按"将来能插"来写,成本几乎为零:

1. `Provider` trait + `ProviderRegistry`(能力声明 + id/name/priority),内置 provider 只是注册表里的一个实现;
2. 所有 provider 出入参用**可序列化 DTO**(serde struct),不传 `&dyn Any`、不传数据库句柄;
3. `Provider` 的错误类型统一 `ProviderError { kind, retryable, detail }`,UI 只按 `kind` 展示。

将来加脚本宿主 = 新增 `ScriptProvider` 实现 `Provider` + 一个 `rquickjs` crate,**不动 UI/domain**。

### 11.3 D3 的登录入口阶梯(从小到大)

统一出口:任何方式最终都产出 `Session { cookie, device_id, profile }` 落库,UI 不关心来源。

| 优先级 | 入口 | 平台 | 成本 | 说明 |
|---|---|---|---|---|
| P0 | 粘贴 cookie 导入(文本框 + 校验账号接口) | 双端 | ~半天 | Linux 首版必须有,也当调试入口 |
| P1 | 内嵌 WebView 网页登录(抓 `MUSIC_U`) | Android | 已有 v1 经验 | 移动 UA + `https://music.163.com/login` |
| P1 | 局域网配对:手机端出示一次性码/二维码,Linux 拉取会话 | Linux | ~1 天 | 体验最好且零 WebView;同 Wi-Fi,一次性 token,5 分钟过期 |
| P2 | 内嵌 WebKitGTK 登录窗口 | Linux | 40~80 行 + 依赖 | 需 webkit2gtk 运行时,作为可选 feature |
| 不做 | 原生扫码(eapi/weapi) | — | — | 8821 风控,已两次独立验证 |

### 11.4 D5 的落地:为什么是 `ncm-api-rs`

候选(2026-11 实抓 crates.io / GitHub):

| 库 | 形态 | 覆盖 | 加密 | TLS | 许可 | 维护 | 结论 |
|---|---|---|---|---|---|---|---|
| **SPlayer-Dev/ncm-api-rs** | Rust 库(axum 服务端特性已于 2026-11-09 裁剪删除) | **382 → 118 个 api 模块**(P1 裁剪, 见 `backend-prune.md`) | weapi/eapi/linuxapi | **rustls**(Android 友好) | WTFPL | 2026-03 起,64★,SPlayer 作者维护 | **采用** |
| two-mountains/ncmapi | Rust 库(强类型) | 搜索/曲库/账号/stream | eapi 等 | reqwest 默认 | MIT | 1.0 于 2026-08,17★ | 备选/类型设计参考 |
| api-enhanced(Node) | 服务端 | 456 | 全套(含 xeapi) | Node | MIT | 活跃 | **只做本地对照 oracle,不进产物** |
| SPlayer 本体 | Tauri 客户端 | — | — | — | — | 活跃 | 交互/功能参考 |

选用理由:
- 是 **api-enhanced 的 1:1 Rust 移植**(我们 `references/api-enhanced` 已熟),函数名/URI/参数一致,踩坑能对上;
- `song_url_v1` 里**已写死 `encodeType: "flac"`**,`request.rs` 会按 cookie 里的 `os` 注入 `os/appver/osver` —— 正是我们自己试出来的两条硬结论;
- rustls 无 OpenSSL 依赖,`cargo-ndk` 交叉编译到 `aarch64-linux-android` 无系统库坑;
- `#![deny(unsafe_code)]`,协议代码可审计。

必须由我们补的四件事(库不管):
1. **device_id 持久化**: 库默认进程级随机(`LazyLock<String>`),必须首启生成后落库,通过 `set_device_id()` 注入(cookie 里已有则不动);
2. **通道/域名选择**: 库默认 `interface.music.163.com`(App 形态)。若风控,切 `interface3` + 网页 UA(M1 spike 决定,`RequestOption.domain/ua` 可覆盖);
3. **DTO 化**: 库返回 `serde_json::Value`,我们转成带类型的领域模型 + 单测,UI 永不直接吃 Value;
4. **vendor + pin**: 复制进 `core/vendor/ncm-api`(WTFPL 允许),锁 commit、记录 patch;不跟上游大重构。

已知风险: 0.1.0 / 单人维护 / 无 xeapi(只声明 weapi·eapi·linuxapi)。缓解: 协议是纯函数,必要时自己修;
xeapi 需求出现时 `references/api-enhanced/util/crypto.js` 是现成蓝本。
