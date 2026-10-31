# fork / PR / 自建:资源与架构实测对比

> 2026-10-31 在 vivo X200 Ultra(Android 16)上实测,三个应用均已安装。
> 结论在最后一节。

## 1. 资源实测(冷启动 + 空闲 25s 稳态)

| 应用 | APK | 冷启动 TotalTime | 稳态 PSS | 包内进程 RSS 合计 | 技术栈 |
|---|---|---|---|---|---|
| **Ncrust 1.4.1** | **3.9 MB** | 255 ms | **87 MB** | 169 MB | Kotlin + Compose + Media3,原生 |
| **Melodia 2.1.0-beta.1** | 22 MB | **172 ms** | 101 MB | 213 MB | KMP(Android+桌面)+ Compose,原生 |
| **MiniNCM(我们)** | **96 KB** | 242 ms | **126 MB** | 270 MB | 原生壳 + WebView SPA(JS) |

读法:
- **APK 我们赢 40 倍**(96KB vs 3.9MB),这是 WebView+JS 架构唯一但确实巨大的优势;
- **内存我们输**:空闲态 126MB,比 Ncrust 多 39MB(+45%),比 Melodia 多 25MB。Chromium 常驻
  (V8 + Blink + 渲染管线)在移动端并不便宜 —— "WebView 更省资源"这个直觉是错的;
- **冷启动**三家都在 200~260ms 量级,我们没有明显劣势(WebView 预热 + 本地 file:// 加载快);
- 三者都只跑一个主进程(登录用的 WebView 会短暂起 Chromium sandbox 进程,用完释放)。

> 注:我们的 126MB 里包含 WebView 渲染进程。若后续把 WebView 改成 `setRendererPriorityPolicy` 降级
> 或长期挂在落地页,可压到 90MB 附近,但仍高于原生 Compose 方案。

## 2. 架构对比

| 维度 | Ncrust | Melodia | MiniNCM(我们) |
|---|---|---|---|
| 代码规模 | 27.6k 行 Kotlin | 152k 行 Kotlin(KMP shared + 双端 UI) | ~700 行 JS + ~1.5k 行 Java |
| Gradle 依赖 | 31 | 71 | **0**(零三方依赖) |
| 模块划分 | `app` / `benchmark` / `spec`(协议规格+夹具) / `ncrust-api` / windows / lumia | `shared`(KMP) / `app` / `desktopApp` / `baselineprofile` | `android/app` 单模块 + `assets/www` |
| 网络层 | Retrofit + eapi 直连,`ClientIdentity` 统一注入客户端身份 | Ktor/Retrofit(KMP)+ 自研加密拦截器 | 手写 eapi/weapi(JS),原生桥只做 IO |
| 登录 | 内嵌**官方移动端网页**登录 | 原生扫码(weapi)+ Cookie 导入 | 官方移动端网页登录 + 自绘扫码(被 8821 拦) |
| 播放 | Media3/ExoPlayer + MediaSession + Android Auto | 自研播放器控制器 + Media3 | MediaPlayer + 前台 Service(最简) |
| 扩展性 | 编译期(Rust/C#/Kotlin 各端自己实现) | 编译期(KMP 共享) | **运行期插件注册表**(JS,可热更新) |
| 更新代价 | 装新 APK(3.9MB) | 装新 APK(22MB) | 换 assets 里几个 JS 文件即可,APK 不必重装 |
| 维护强度 | 30 天 63 commit,6 open issue | 30 天 100 commit,27 open issue | 我们自己 |

## 3. 两家值得直接抄的"硬知识"(比代码更值钱)

**Ncrust `network/ClientIdentity.kt`** —— 客户端身份 cookie 的语义:
- 写操作(歌单增删改)只带 `MUSIC_U`/`__csrf` 会被回 `403 illegal request!`;
- ~~取链缺 `os`/`appver` 会**静默封顶音质**(code 仍是 200,客户端看不出异常);~~
  **2026-11 更正(实测)**:缺 `os`/`appver` 时 VIP 曲目是 `code=200` 但 **`url=null`**(连试听都不给);
  带上身份后才降级为 128k 试听。**音质档位只由 `MUSIC_U` 决定**,`os=pc` 与 `os=android;appver=9.0.90`
  在三首样本(含 hires 2.83 Mbps)上**完全无差异**。详见 `docs/lx-plugin.md` 第 6 节。
- 实测可用身份: `os=pc`、`appver=3.0.6`(2026-09 官方 PC 版)、`osver=10.0.19045`;
- `deviceId` **用户 cookie 里已有就不动**,没有才补本机持久 id(换掉等于换会话指纹)。

**Ncrust `spec/api/login.md`** —— 8821/-462 是交互式风控挑战,验证结果绑在完成验证的客户端
设备 cookie 上;因此内嵌官方网页登录是唯一稳的路(他们已搁置原生登录)。

**Melodia** —— `PlaybackApi` 里 `/eapi/playmode/intelligence/list`(心动模式)的参数形态、
`PlaybackController` 的 `CONTEXT_INTELLIGENCE` 队列上下文;歌词侧接 AMLL。

## 4. fork / PR / 自建

| 方案 | 得到什么 | 失去什么 | 真实成本 |
|---|---|---|---|
| **fork Ncrust** | 立刻拥有完整可用产品(每日推荐/FM/7 级音质/车机/8 语言),MIT 可闭源改 | WebView+JS 插件架构(要重写才有),以及上游更新(30 天 63 commit,分叉即落后) | 27.6k 行 Kotlin,Compose 生态,合并上游 = 常态冲突 |
| **fork Melodia** | 功能最全(心动模式/歌词/平板/桌面,KMP 一份协议双端) | 同上,且更重 | 152k 行 + 71 依赖,22MB APK |
| **PR 到上游** | 修协议 bug、补能力,回报社区 | 我们的"插件化/热更新/百 KB"设计跟他们不是一条路 | 单点改动可行,架构级需求必然被拒 |
| **自建(现状)** | 96KB APK、运行期插件、热更新、几乎零依赖 | 内存比原生高 45%,功能要自己长 | 每个功能从零实现,协议坑自己踩 |

## 5. 建议

**主线继续自建,但把两家的"硬知识"和少量模块级实现搬进来,不做整体 fork。**

理由(按权重):
1. **目标不同**。你要的是「小而可插拔、能热更新音源」,Ncrust/Melodia 都是「编译期集成的完整体验
   App」。fork 过来第一件事就是删掉它们的 UI 与网络层换成插件架构,等于把 27.6k / 152k 行当脚手架。
2. **我们的真实短板是内存不是体积**。126MB idle 已经比 Ncrust 高 45%;如果这个数字不可接受,
   那么真正的选择是"放弃 WebView,改原生 Compose"(= 直接 fork Ncrust),而不是在 WebView 上继续加功能。
   **这条需要你拍板**,因为它决定后面所有工作量。
3. **协议知识可以搬,而且必须搬**:`os=pc/appver=3.0.6/osver=10.0.19045` 身份注入、
   `deviceId` 持久化、写操作 403 的成因、心动模式 URI。这些几十行代码能省掉我们几周的试错。
4. PR 只做单点:比如把「移动端登录页 URL + 不伪造 UA」这类通用修正回馈上游是可以的,但不要指望
   上游接受插件架构。

**分化建议**:
- 若首要目标是「尽快有一个真好用的客户端」→ fork Ncrust(3.9MB、原生、已完整),我们的插件想法作为二阶段。
- 若首要目标是「极小、可热更新、插件化」→ 自建继续,但先做两件事:设备身份持久化 + 内存优化
  (登录 WebView 复用、`setRendererPriorityPolicy`、SPA 懒加载)。

## 6. 第二轮定论(2026-11):PR 为主,不做整体 fork

### 6.1 PR 通道实测(近 90 天)

| 项目 | 合并 PR | 开放 PR | 外部贡献者 | 通道是否可用 |
|---|---|---|---|---|
| **Ncrust** | **0** | 0 | 无 | **不可用**(单人独占,6 个 issue 会回但代码只在自己侧仓演进) |
| **Melodia** | **30** | 5 | dongyvu(7k 行 QQ 歌词源)、cyanrhythm、poesein(4 个待合) | **可用** |

### 6.2 fork 成本实测(Ncrust)

- `settings.gradle.kts` 里 `includeBuild("../Kanesumi-sec-a")`:`Kanesumi-sec-a` 是作者另一个
  **0 star** 的 UI 库,32 个 `.kt` import 它,注释明写"迁移期间来回改两边 API"。
  **只 clone Ncrust 构建不起来**,fork 等于同时分叉一个 0★ 库。
- 已扩散到 5 条产品线(Android Kotlin / Windows C# / Lumia C++ / Rust Linux / Android4),
  单作者垄断 → 分叉即永久分叉,没有回收上游的可能。
- 插件化改造面:`network` 包 fan-in **51 个文件**,其中 **22 个**直接调 `RetrofitClient`。
  这不是"换个网络层",是重做。

### 6.3 Melodia 已经把我们想做的三件事做完了

| 我们的设想 | Melodia 现成实现 |
|---|---|
| 运行期 provider 插件 | `core/source/`: `AudioSourceProvider` / `AudioSourceRouter`(官方直链失败或试听 → 自动换源) / `LxPluginRuntime`(Android=WebView 沙箱,桌面=GraalJS) / `LxPluginManager`(导入/启停/批量去重) / `LxArchiveReader` |
| WebView 内存治理 | `feature/source/plugin/LxPluginEngine.kt`:沙盒**按需创建 + 空闲自动回收**("避免不换源时常驻 WebView") |
| 身份/风控硬知识 | `HeaderInterceptor`:`os=android;appver=9.0.90` 与 `os=pc;appver=3.0.1…` 双身份、`NeteaseDeviceId` 持久化、cookie 合并;另加 xeapi 公钥/设备注册(比我们更远) |

MIT、346★、22MB / 101MB、插件层约 **1.8k 行**(不是 152k)。

### 6.4 结论

1. **PR 为主,且只对 Melodia**;Ncrust 只当"低资源参照实现 + 阅读源"(无 PR 通道,不回馈)。
2. **不做整体 fork**。唯一考虑 fork 的触发条件:上游明确拒绝音源/插件方向且我们必须长期改 provider;
   即使那样,改动面也只有 `core/source/`(~1.8k 行)。
3. **自建 MiniNCM 重新定位**:降级为「协议/风控实验台 + provider 脚本工坊」,
   目标是产出 **LX 插件脚本 + PR + 结论文档**,不再追 App 功能对齐(UI/播放器/本地库不自己长)。
4. **"最小依赖 = 省资源"被自己的数据否证**:96KB APK 却 126MB PSS,3.9MB/35 依赖的 Ncrust 只 87MB。
   开销由**运行时选型**(Chromium vs Compose)决定,不由依赖个数决定;
   零依赖只有在"没有 WebView 的原生壳"里成立 —— 而那就是 Ncrust 已经做完的事。

