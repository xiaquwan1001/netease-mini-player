# 进度记录(Progress)

> 最近更新: 2026-11-02。里程碑式记录 "做到了什么 / 怎么验证的 / 下一步",
> 协议细节放 `.pi/skills/netease-cloud-music-api-reverse/SKILL.md`,
> LX 音源脚本工坊(插件契约 + 回归台 + 真机导入)见 `docs/lx-plugin.md`,
> 社区项目与路线选择见 `docs/community-projects.md`,
> fork/PR/自建对比见 `docs/build-vs-fork.md`,
> 给 Melodia 提 PR 的分支/构建/真机验证/截图流程见 `docs/melodia-pr-workflow.md`。

## 当前状态: v1 全链路可用(真机验证)

| 环节 | 状态 | 验证方式 |
|---|---|---|
| 构建环境 | ✅ | `bash tools/setup-android-env.sh` 一键装 JDK21 + Gradle8.9 + SDK34 |
| 构建 | ✅ | `bash tools/build.sh` → `app-debug.apk`,**96 KB** |
| 真机安装 | ✅ vivo X200 Ultra / Android 16 / WebView 138 | 冷启动 242ms,空闲 PSS 126MB |
| 登录 | ✅ 官方**移动端**网页授权(手机号/QQ/微信/扫码都在页内) | 抓到 `MUSIC_U` 自动落地并回主界面 |
| 搜索 | ✅ eapi `interface3` `/api/cloudsearch/pc` | 真机搜索 "jay" 返回列表 |
| 播放 | ✅ 原生 MediaPlayer | 免费歌与(VIP 登录后)会员歌均出直链并出声 |
| 歌词 | ⏳ provider 已实现 `lyric()`,UI 未接 | — |

## 本轮踩过并解决的坑(都已写进代码注释/技能)

1. **JDK 17.0.2 不能用于 AGP 8.5.2**:`validateSigningDebug` 抛
   `CgroupInfo.getMountPoint() ... anyController is null`(cgroup v2 探测 NPE)。换 **Temurin 21.0.9** 通过。
2. **下载源**:`api.adoptium.net`/github releases/cdn.azul.com 直连超时 → Temurin 走 USTC 镜像;
   `services.gradle.org` 仅 KB/s → Gradle 走腾讯云镜像;sdkmanager 要求 proxy 变量 **unset**(非空值)。
3. **vivo 装包**:`adb install` 被拒(`INSTALL_FAILED_ABORTED: User rejected permissions`)→
   `adb push /data/local/tmp/` + `adb shell pm install -r -t`;锁屏状态下必失败(需唤醒解锁)。
4. **登录按钮无响应**:`bridge.js` 没暴露 `Native.loginWeb` → JS 抛 TypeError。桥的每个 Native.*
   都要有 JS 包装 + try/catch + toast。
5. **二维码区是死 UI**:`#qr` 无 JS 驱动 → 永远"加载中"。
6. **播放地址 400 参数错误**:`/eapi/song/enhance/player/url/v1` 必须带 `encodeType:'flac'`。
7. **"数据非 json"**:该接口报错时返回**两个拼接 JSON**(`{..}{..}`),需容错解析;`-110` = 会员/版权受限。
8. **原生扫码被 8821 拦死**:eapi 与 weapi 两条通道都在用户确认后返回
   `8821 安全环境风险`。根因是**交互式风控挑战**,验证结果绑在"完成验证的那个客户端"的设备 cookie 上,
   不是 IP(与 Ncrust `spec/api/login.md` 的独立调研一致)。→ 登录改用官方网页。
9. **网页登录不能伪造桌面 UA**:`music.163.com/#/login` + Windows Chrome UA = 桌面 SPA(重、二维码小、
   手机号/QQ/微信二级页加载不出来)。**设备默认移动 UA + 无 hash 的 `/login`** → 302 到
   `https://y.music.163.com/m/login` = 官方移动端授权页(已修复 `LoginActivity`)。
10. **fetch 与原生桥的分工**:带 `Cookie` 头是 fetch 的 forbidden header,必抛 → `bridge.post`
    自动回退 `Native.httpPost`(OkHttp 风格 cipher);而登录成功后 `MUSIC_U` 只能从
    WebView CookieManager 读(fetch 对 JS 隐藏 Set-Cookie)。

## 关键协议事实(详细见技能文档)

- 播放地址: `/eapi/song/enhance/player/url/v1`,`ids` + `level` + **`encodeType`**;匿名下 VIP 歌 `-110`。
- 私人FM `/api/v1/radio/get`、每日推荐 `/api/v3/discovery/recommend/songs`:api-enhanced 标 weapi,
  但**实测 eapi 封装同样 200**(匿名 FM 返回 1 首,登录后为批量)。
- 心动模式 `/api/playmode/intelligence/list` 接受 eapi,需登录态(301)。
- 客户端身份 cookie 决定很多静默行为(见 `docs/build-vs-fork.md` 第 3 节):
  `os`/`appver`/`osver` 缺失会静默封顶音质,写操作会被 `403 illegal request!`。

## 待办(按优先级)

1. **设备身份持久化**(最高优先,影响所有请求的风控评级):
   首次启动生成一套 `deviceId` / `NMTID` / `_ntes_nuid` / `_ntes_nnid` / `WNMCID` / `WEVNSM`,
   **永久复用、登出也不换**。当前 `loadCookie()` 里 `genDeviceId()` 每次随机 = 每次"换一台新设备"。
2. **身份 cookie 规范化**:注入 `os=pc` / `appver=3.0.6` / `osver=10.0.19045`(对齐官方 PC 客户端),
   避免静默降音质与写操作 403。
3. **插件能力声明 v2**:`capabilities: ['login','search','songUrl','lyric','personalFm','heartMode','dailyRecommend']`,
   宿主只调声明过的能力。
4. **私人FM / 每日推荐**(eapi 已验证,只需加能力键 + 列表页)。
5. ~~**内存优化**:登录 WebView 复用、`setRendererPriorityPolicy` 降级、SPA 懒加载(目标 ≤ 90MB idle)。~~
   降级为低优先:实验台形态不追求 idle 指标(Melodia 的 `LxPluginEngine` 已有按需创建+空闲回收的现成做法)。
6. 心动模式(依赖 playlistId 上下文,放队列重构之后)、歌词滚动、seek/进度条。


## 对外贡献(Melodia,2026-10-31)

| 类型 | 编号 | 内容 | 状态 |
|---|---|---|---|
| Issue | [#134](https://github.com/rinchao0721/Melodia/issues/134) | 社区源插件应可优先于官方直链(VIP 账号下插件完全不可达);附探针实测 | 待回应 |
| PR | [#135](https://github.com/rinchao0721/Melodia/pull/135) | `docs/netease-playurl-identity.md`:播放直链接口身份/音质实测语义 | 待合并 |
| PR | [#136](https://github.com/rinchao0721/Melodia/pull/136) | 修复 #128 心动模式 400:未指定上下文时挑选红心歌单(`specialType==5`),附 3 例单测 | 待合并 |
| 评论 | [#133](https://github.com/rinchao0721/Melodia/issues/133#issuecomment-6544358387) | 社区源 VIP 歌听不了的实测定位(12s 超时偏紧、kg 平台脚本自身报错、四类失败形态) | 已发 |
| PR | [#137](https://github.com/rinchao0721/Melodia/pull/137) | 社区源解析超时可配置(12s/30s)+ 各平台失败原因汇总回传 | 待合并 |
| PR | [#139](https://github.com/rinchao0721/Melodia/pull/139) | 播放器级增益(0~-40 dB,逐档 0.4 dB):与系统音量/音量平衡相乘,压低蓝牙耳机最小档;已在真机验证 | 待合并 |
| PR | [#140](https://github.com/rinchao0721/Melodia/pull/140) | 音乐库顶栏常驻设置入口:设置与账号解耦,未登录也能进设置(真机验证:未登录可达「播放与下载」) | 待合并 |

#136 的根因实测(同一登录态只换 `playlistId`):红心歌单 200;自建/收藏歌单 400
「不支持该歌单类型」;`0` 400「歌单不存在」。原实现取歌单列表**首项**当上下文,
红心歌单不置顶的账号必挂 —— 这解释了 #128「换账号就正常」。


## 收尾状态(2026-11-01)

**本地可复现的最小验证**(不需要设备):

```bash
node tools/lx-plugin-harness.mjs      # 匿名:inited 握手 / 直链可取 / 试听拒绝,全 PASS
```

**对外产出**(全部在 Melodia 上游,非本仓库):

| 编号 | 内容 | 状态 |
|---|---|---|
| issue #134 | 社区源插件应可优先于官方直链(VIP 账号下不可达) | 待回应 |
| PR #135 | 播放直链身份/音质实测语义(文档) | MERGEABLE |
| PR #136 | 修复 #128 心动模式 400(红心歌单 `specialType==5`)+ 3 单测 | MERGEABLE |
| PR #137 | 社区源超时可配置(12s/30s)+ 失败原因汇总回传 | 待合并 |
| #133 评论 | 社区源 VIP 歌听不了的实测定位 | 已发 |
| PR #139 | 播放器级增益(0~-40 dB,逐档 0.4 dB),与系统音量/音量平衡相乘;真机蓝牙耳机验证 | 待合并 |
| PR #140 | 设置入口与登录态解耦(音乐库顶栏常驻);真机未登录状态验证可达「播放与下载」 | 待合并 |

**下次接着做**(按价值排序):

1. 等上游 review #139 / #140:若维护者更希望用「guest 侧边栏」而不是顶栏齿轮,
   改 `ProfileSidebar + MelodiaApp` 的 nullable 化即可(已在 `docs/melodia-pr-workflow.md` 记录现状)。
2. #139 的两个可选延伸(都还没做):音量键细调(拦截 `KEYCODE_VOLUME_*`,1/4 档虚拟音量梯)、
   桌面端(桌面已有 mpv 0~100,不需要)。
3. 等上游对 #134 表态 → 决定是否补沙盒契约缺口(见 `docs/lx-plugin.md` 第 6 节:
   `utils.crypto.aesEncrypt/rsaEncrypt/randomBytes`、`utils.buffer` 正确语义、`statusCode` 透传)。
4. 若 #137 被接受,同款诊断可推广到 UNM 分支(目前只汇总了社区源侧)。
5. 本仓库的 MiniNCM 保持「协议实验台」定位:新协议结论先在这里测,再以 issue/PR 形式回流上游。

## 未决问题(需要决策)

- ~~**路线**:继续 WebView 插件化(96KB APK / 126MB RAM)还是转向原生(= fork Ncrust 3.9MB / 87MB)。~~
  **已定(2026-11):PR 为主,只对 Melodia;不 fork 任何一方。** MiniNCM 降级为协议/风控实验台
  + LX 插件脚本工坊,Ncrust 仅作低资源参照。见 `docs/build-vs-fork.md` 第 6 节。
- 原生扫码是否还值得保留:目前保留为"快捷尝试",命中 8821 时提示改用官方网页登录。
