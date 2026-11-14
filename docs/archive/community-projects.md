# 社区项目资源盘点与方向建议

> 目的: 为「体积小、启动占用少、能登录网易云的第三方安卓客户端」选定技术路线,
> 明确哪些社区资产可以直接复用(含许可约束), 哪些只作思路参考。
> 数据: 2026-10-31 GitHub 实时查询。

## 0. 目标与约束

| 维度 | 约束 |
|---|---|
| 体积 | APK 当前 **71KB**(壳+SPA+crypto-js+qrcode), 目标保持 <500KB |
| 运行占用 | 单 WebView + 一个前台 Service, 零 AndroidX/Kotlin/三方 Gradle 依赖 |
| 设备 | 目标真机 vivo X200 Ultra(Android 15); 参考机 P40 Pro ELS-AN00(HarmonyOS, API 31, WebView Chromium 114) |
| 功能 | v1 登录/搜索/播放; 之后插件化扩: 私人FM、心动模式、每日推荐、歌单 |
| 关键难点 | 网易云 2024+ 风控(xeapi + TLS/JA3 + 反作弊 token) |

## 1. 三条技术路线(先定这个, 再谈复用)

| 路线 | 做法 | 体积 | 风控暴露 | 许可 | 结论 |
|---|---|---|---|---|---|
| **A 纯 JS 直连(主线)** | WebView 里自己算 eapi/xeapi, 原生桥只做 HTTP | +15~30KB | 中(网页形态 UA + interface3) | 低(MIT 可移植) | 主线 |
| B 整体移植 api-enhanced | 456 个 module 的 Node 实现搬进 JS | +200KB~1MB | 同上 | MIT 可搬 | 只按需裁剪, 不整体搬 |
| C 远程 API 插件 | 自建 api-enhanced 服务, App 只当客户端 | 最小 | 最低(服务端兜底) | 无 | 保留为对照组 `provider/remote` |

支持 A 的已落地证据:
- 我们 v1 的 `provider/netease.js` 已跑通 eapi(AES-128-ECB) + `interface3.music.163.com` 网页形态;
- 社区侧 `midairlogn/ML-Netease_Android` 用同一形态(interface3 + Windows Chrome UA + `MUSIC_U` cookie)在真机上跑通搜索/歌词/播放地址, 说明安卓直连不必先上 xeapi。

## 2. 已拉到本地 `references/`(gitignored) 的资产

| 目录 | 项目 | 许可 | 用途 |
|---|---|---|---|
| `api-enhanced/` | NeteaseCloudMusicApiEnhanced/api-enhanced | **MIT** | 协议蓝本: 456 个 module + `util/crypto.js`(eapi/xeapi/weapi 全套) |
| `MusicFreePlugins/` | maotoumao/MusicFreePlugins | GPL-3.0 | 插件协议形态参考(只读思路) |
| `Netease-Music-VScode/` | SuperTairitsuFan/Netease-Music-VScode | **MIT** | 现代 TS 版 eapi 直连(`src/api/crypto.ts` 92 行 / `http.ts` 249 行), 最接近能直接改写成 WebView JS 的样本 |
| `ML-Netease_Android/` | midairlogn/ML-Netease_Android | GPL-3.0 | Java 安卓直连 eapi 实证 + 华为机型适配; 只读思路 |

## 3. 参考项目全表

### 3.1 直连/协议类(最重要)

| 项目 | 星 | 许可 | 最后推送 | 要点 | 我们怎么用 |
|---|---|---|---|---|---|
| api-enhanced | 2.1k | MIT | 10-27 | Node 服务端, eapi/weapi/xeapi 全覆盖, 456 模块 | 协议与加密第一依据, 按需移植 |
| Netease-Music-VScode | 0 | MIT | 10-31 | EAPI 直连(桌面 UA + eapi 指纹 payload), 无三方依赖 | 移植加密/请求骨架的首选样板 |
| ML-Netease_Android | 22 | GPL-3.0 | 10-31 | 安卓 eapi 直连 + MUSIC_U cookie; 含 HuaweiSafe*View 适配 | 验证「直连可播」, 华为适配思路 |
| Binaryify/NeteaseCloudMusicApi | 30.2k | MIT | 2024-02 归档 | 原版 API 服务(下架后归档) | 已被 api-enhanced 接棒, 仅查历史 |
| UnblockNeteaseMusic | 17.3k | MIT | 2023-06 | 灰歌解锁代理 | 不做, 与「小而干净」冲突 |

### 3.2 客户端(功能/交互参考, 多是大栈)

| 项目 | 星 | 许可 | 最后推送 | 栈 | 可借鉴点 |
|---|---|---|---|---|---|
| YesPlayMusic | 33.5k | MIT | 10-10 | Vue/Electron | 内置 API 的登录/播放状态机、信息架构 |
| lx-music-mobile | 19k | Apache-2.0 | 10-30 | RN | 音源脚本生态、队列与音质降级 |
| MusicFree | 28.1k | AGPL-3.0 | 10-15 | RN | 插件协议设计(声明式元信息 + 函数接口) |
| lx-music-desktop | 54.9k | Apache-2.0 | 10-26 | Electron | 自定义源脚本规范 |
| PiliPlus | 20k | GPL-3.0 | 10-31 | Flutter | 第三方客户端登录/风控/播放器架构(非音乐域) |
| Melodia | 345 | MIT | 10-30 | Kotlin/Compose | 功能矩阵=路线图(歌词/下载/音质/收藏) |
| listen1_desktop | 11.4k | MIT | 04-07 | JS | 多平台音源适配层抽象 |
| CurrentMusic | 5 | MIT | 10-29 | JS/WebView 壳 | 同为前端壳架构, 看壳与页面组织 |

### 3.3 归档/停更(读思路, 不跟)

| 项目 | 星 | 停更 | 说明 |
|---|---|---|---|
| boyan01/flutter-netease-music | 3.4k | 2024-01 | Flutter 仿网易云, 完整度最高的历史参考 |
| fluttercandies/NeteaseCloudMusic | 1.7k | 2020 | Flutter 老实现 |
| trazyn/ieaseMusic | 8.7k | 2023-02 | Electron, 当年最佳体验 |
| jsososo/NeteaseMusic | 1.3k | 2021 | Web 端(可播 VIP/下架), 接口组合参考 |
| Moriafly/DsoMusic | 1.5k | 2023-01 | Kotlin 安卓, 多音源 |
| rcmiku/JetMelo | 142 | 2025-03 | Kotlin M3, 最新一代写法 |
| aa112901/remusic | 6.4k | 2018 | 老接口时代安卓仿网易云 |
| sunzongzheng/music | 2.7k | 2022 | Electron 多源 |

## 4. api-enhanced 移植清单(路线 A 的具体动作)

`util/crypto.js`(419 行)按依赖拆解:

| 段 | Node 依赖 | 移植方案 | 现在需要? |
|---|---|---|---|
| eapi(AES-128-ECB + md5 digest) | crypto / CryptoJS | CryptoJS 现成(已在 `js/lib`) | 是, v1 已用 |
| weapi(AES-CBC + RSA) | node-forge | 纯 JS 大数 RSA ~2KB, 或试 eapi 变体 | **是**: 私人FM `/api/v1/radio/get` 与每日推荐 `/api/v3/discovery/recommend/songs` 都走 weapi |
| xeapi(X25519 + AES-GCM + 签名) | crypto(X25519)、zlib/zstd | @noble/curves(~8KB) + WebCrypto AES-GCM + DecompressionStream | 二期兜底 |
| 响应解密/解压 | zlib/zstd | 默认明文(encryptResponse=false) | 暂不需要 |

`util/request.js`(622 行): axios/代理/文件上传全部丢弃, 只留「加密参数拼装 -> POST -> cookie 维护」。

目标功能到模块的对照(照搬 URI 与参数形态):

| 功能 | module | 内部 URI | 加密 |
|---|---|---|---|
| 扫码登录 | login_qr_key / login_qr_create / login_qr_check | `/api/login/qrcode/unikey`, `/api/login/qrcode/client/login` | eapi |
| 搜索 | cloudsearch | `/api/cloudsearch/pc` | eapi |
| 播放地址 | song_url_v1 | `/api/song/enhance/player/url/v1` | eapi |
| 歌词 | lyric | `/api/song/lyric` | eapi |
| **私人FM** | personal_fm (+fm_trash) | `/api/v1/radio/get` | ~~weapi~~ → **实测 eapi 可用** |
| **心动模式** | playmode_intelligence_list | `/api/playmode/intelligence/list` | eapi |
| 每日推荐 | recommend_songs | `/api/v3/discovery/recommend/songs` | ~~weapi~~ → **实测 eapi 可用** |
| 喜欢/红心 | like / likelist | `/api/radio/like`, `/api/song/like/get` | eapi |
| 歌单详情 | playlist_detail / playlist_track_all | `/api/v6/playlist/detail` | eapi |

**weapi 在关键路径上**: 私人FM 与每日推荐这两个最想要的功能在 api-enhanced 里都用 weapi 封装。
两个选择: (a) 补 weapi(RSA + AES-CBC, 纯 JS ~2KB); (b) 实验这两个 URI 是否也接受 eapi 封装
(都是对称 AES + 明文响应, 差异只在参数封装形式)。建议先在本地脚本花 30 分钟做 (b), 失败再上 (a)。

## 4.1 实测结论(2026-10-31, 匿名 eapi 直连 interface3)

用我们的 eapi 封装(AES-128-ECB + md5 digest)直接 POST 到 `interface3.music.163.com`:

| 接口 | HTTP | code | 结论 |
|---|---|---|---|
| `/api/cloudsearch/pc`(对照) | 200 | 200 | 通道正常 |
| `/api/v3/discovery/recommend/songs` | 200 | 200 | **接受 eapi**, 匿名即返回 `dailySongs/recommendReasons` 结构 |
| `/api/v1/radio/get`(私人FM) | 200 | 200 | **接受 eapi**, 匿名返回 1 首(登录后为批量) |
| `/api/playmode/intelligence/list`(心动模式) | 200 | 301 | **接受 eapi**, 仅需登录态 |
| `/api/song/like/get` | 200 | 301 | 接受 eapi, 需登录 |
| `/api/song/enhance/player/url/v1` | 200 | 200 | **必须带 encodeType**(缺了返回 参数错误 400, 且响应是两个拼接 JSON); 匿名下 fee=1(VIP) 返回 code -110 无地址, fee=8 免费歌曲返回真实直链 |

**结论: api-enhanced 里标注 weapi 的接口, 换成 eapi 封装同样通** → 不必移植 weapi(RSA + AES-CBC),
省 ~2KB 与整块 node-forge 依赖, 全套只需 eapi 一种封装。
风险提示: 这是服务端「宽松接受」而非契约; 若哪天收紧, 再补 weapi 兜底(api-enhanced `util/crypto.js` 里有现成实现可抄)。


## 5. 插件化设计建议(抄形状, 不抄代码)

MusicFree 协议值得借鉴的是**形状**: 插件 = 一个导出「平台信息 + 函数集」的模块, 宿主只按能力调用。映射到现有 provider:

```js
// js/plugins/provider/<name>.js —— 现有 5 个基础方法 + 能力声明
export default {
  id: 'netease',
  name: '网易云(直连)',
  capabilities: ['login','search','songUrl','lyric','personalFm','heartMode','dailyRecommend'],
  loginQr(), loginCheck(unikey),
  search(kw, page), songUrl(id, level), lyric(id),
  personalFm(), heartMode(songId, playlistId), dailyRecommend(),
}
```

好处: 加功能只新增能力键, 不动核心; `provider/remote` 与未来其它音源天然平级; 网络与加密细节留在插件内部。

## 6. 推进顺序建议

1. 真机跑通 v1(登录 -> 搜索 -> 播放 -> 歌词), 设备 vivo X200 Ultra。
2. 插件接口 v2: 能力声明 + 注册表 + 设置开关(不增体积)。
3. 私人FM + 每日推荐(感知价值最高; 先做「eapi 封装能否替代 weapi」的可行性试验, 不行就补 weapi/RSA)。
4. 心动模式(依赖 playlistId 上下文, 放播放队列重构之后)。
5. xeapi(仅当直连被风控时才做, 代价 +8KB @noble/curves 与新加密路径)。

## 7. 登录通道实测与三个同类项目(2026-10-31)

### 8.1 原生扫码被 8821 拦死(结论: 不可作为唯一入口)

实测链路: eapi `interface3` 取 unikey → 200/801; 官方 App 侧扫码 → 802(带昵称头像) → 下一次轮询返回
`code 8821 "请切换其他登录方式或升级新版本再试"`(带 captchaId + redirectUrl `qa-yyy.igame.163.com/anquanhuanjingfengxian`)。
换成 weapi(PC 网页形态)+ 预置 NMTID/WEVNSM/__csrf cookie + 登录页 Referer 后**同样 8821**。

同一结论被 `GuitaristRin/Ncrust` 的 `spec/api/login.md`(2026-10-15 调研)独立复现:
- weapi `/api/login/qrcode/unikey`(type=1) → `-462`; eapi interfacepc(type=3) → 200 可出码(在被风控标记前)
- `-462/8821` 是**需要交互验证的挑战**, 验证结果绑定在**完成验证的那个客户端的设备 cookie(NMTID、_ntes_nuid、_ntes_nnid、WNMCID、WEVNSM)**上, 不绑定 IP; 脚本每次随机设备 cookie ⇒ 验证过了也没用, 且频繁换设备本身就是风控特征。
- 他们的决定: **暂时放弃原生登录, 继续用内嵌官方网页登录**(风险最低)。

### 8.2 关键修正: 登录页不要伪装桌面 UA

同一句 `music.163.com/#/login`:
- **伪装 Windows Chrome UA**(我们旧实现) → 桌面 SPA 登录页: 又重、二维码小、手机号/QQ/微信 二级页加载不出来。
- **设备默认(移动)UA + 无 hash 的 `/login`** → 服务端 302 到 `https://y.music.163.com/m/login` = **官方移动端授权页**(App 风格, 手机号/QQ/微信/扫码都在里面)。

已按此修正 `LoginActivity`(去掉 `setUserAgentString`, 改 `loadUrl("https://music.163.com/login")`, cookie 轮询 800ms 自动收 MUSIC_U)。

### 8.3 三个同类项目现状(能否直接用)

| 项目 | 星 | 许可 | 最后推送 | APK | 技术栈/登录 | 能用吗 |
|---|---|---|---|---|---|---|
| GuitaristRin/Ncrust | 223 | MIT | 10-28 (1.4.1) | 3.9MB universal, API24+ | Kotlin+Compose+Media3, eapi 直连, **内嵌官方网页登录** | **能**, 且工程化最强: 有 `spec/` 协议规格与测试、每日推荐/私人FM/7 级音质/Android Auto/8 语言 |
| rinchao0721/Melodia | 346 | MIT | 10-28 (v2.1.0-beta.1) | 22MB | Kotlin Multiplatform(Android+桌面), 原生加密, 登录=原生扫码(weapi)+Cookie 导入 | **能**, 功能最全(心动模式/歌词/平板侧栏), 但扫码同样没处理 8821, 遇风控只能手动粘 cookie |
| rcmiku/JetMelo | 142 | GPL-3.0 | **2025-03 归档** | 4.7MB (1.0) | Kotlin M3 客户端 | **基本不能用**: 停更 19 个月, 2026 的接口/风控变更后登录链路大概率失效, 只当代码参考 |

共同点(值得抄的只有前两条):
1. **没有一家靠原生接口稳稳登录** — Ncrust 明确回退官方网页; Melodia 留了 cookie 导入后门。
2. **设备 cookie 持久化**是降风控的直接手段(一台设备一套, 登出也不换)。我们当前 `loadCookie()` 里 `genDeviceId()` **每次随机**, 这在风控眼里就是“每次换一台新设备”, 必须改成首启生成、永久复用。
3. 都不做密码登录。

## 8. 许可红线

- MIT/Apache(api-enhanced, Netease-Music-VScode, YesPlayMusic): 可移植代码, 保留版权声明。
- GPL/AGPL(MusicFree, MusicFreePlugins, ML-Netease_Android, PiliPlus, DsoMusic): 只读思路, 不复制代码, 否则本项目须整体 GPL。
- 本仓库暂无 LICENSE; 若发布, 建议 MIT(与可复用资产一致)。
