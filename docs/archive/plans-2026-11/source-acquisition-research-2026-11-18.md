# 音源获取入口(多来源 / 出口 IP)调研 —— 2026-11-18

> 角色 R1 · 只做调查, 不改代码, 不 commit。
> 主线已按编排者澄清: **香港用户卡顿的归因**, 核心问题是「上游 API 是否暴露随网络 IP 切换 CDN 节点的能力」。
> 全部网络命令都套 `timeout -k`; 报告不含任何 cookie/token/账号/代理密钥; 文中域名只写官方 CDN 族(`*.music.126.net`)与官方接口。

## 0. 一句话结论

**换出口 IP 拿不到更多可播曲目, 也不是「选节点」的旋钮** —— 版权/试听判定只看登录态与曲目 privilege, 与实际出口 IP 无关
(实测: 同一首 VIP 曲在大陆直连与香港出口都回 `freeTrialInfo`); 而 **CDN 节点由网易 CDN 的 GSLB(DNS/ECS) 决定, 不由 API 参数决定**
(实测: 同一首歌连续取链, host 在 `{m7,m8}`/`{m702,m802}` 池内**随机**漂移, 与出口无关; 显式注入 `X-Real-IP` 直接被拒 `code=404`,
只带 `X-Forwarded-For` 被忽略)。所以「按地区换服务器」不是我们能加的架构能力, 我们真正缺的是三件事:
① **丢字段**(`freeTrialInfo`/实际 `level`/`type`/`md5` 全被丢弃 ⇒ 试听片段被当成整曲、静默降级用户不知情);
② **桌面走明文 http 且下载请求无 UA/Referer**(小样本实测 http:80 会被中间设备劫持成 HTML 重定向页, https 正常);
③ **没有「多候选 URL + 实测 TTFB 排序/回退」** 的结构(目前只有一个 url, 取链失败 = 整首失败)。
**推荐先做方案 A(信息无损 + 强制 https + 下载重试/换候选, 成本 S), 观察一轮再决定 B(SourceResolver 多候选, 成本 M)。**

---

## 1. 现状地图: 一首歌怎么拿到可播放 URL

### 1.1 调用链(逐层)

| # | 层 | 位置 | 事实 |
|---|---|---|---|
| 1 | UI 起播 | `ui/lib/src/home/playback_coordinator.dart:437` | `retryNetwork(() => rust.songUrl(trackId, level))`; 另有**内存预取** `:388`(`_prefetchedUrls`, key=trackId+level, TTL 4 分钟, 上限 8 条) |
| 2 | UI 下载 | `ui/lib/src/home/song_action_wiring.dart:424` | 同一个 `rust.songUrl`, 然后 `preferHttpsStreamUrl` 再交给平台下载 |
| 3 | FFI 导出 | `core/crates/ncm-ffi/src/api.rs:668-682` | `song_url(track_id, level)`: `providers.first_with(Capability::SongUrl)` → `SongUrlRequest{track, level}` → `provider.song_url()` |
| 4 | 路由 | `core/crates/ncm-provider/src/registry.rs:41-43` | `first_with` 只取**第一个**支持该能力的 provider(**单 provider、单结果**, 无候选列表) |
| 5 | 能力 trait | `core/crates/ncm-provider/src/caps/read.rs:39` | `fn song_url(&self, req: &SongUrlRequest) -> ProviderResult<StreamUrl>` —— 返回**单个** `StreamUrl` |
| 6 | provider 实现 | `core/crates/ncm-service/src/netease/song.rs:14-27` | `snapshot()` 拿 (client, domain, ua, cookie) → `client.song_url_v1(&q)` → `check_body` → `parse_stream` |
| 7 | 协议 | `core/vendor/ncm-api/src/api/song_url_v1.rs:20-27` | `POST /api/song/enhance/player/url/v1`, body `{ids:"[id]", level, encodeType:"flac"}`; 加密方式默认 eapi, 但 `ENCRYPT` 关闭时退化成**明文 `/api` 通道** |
| 8 | 请求装配 | `core/vendor/ncm-api/src/request.rs:196-241` | 注入 cookie: `os/appver/osver/deviceId/channel/_ntes_nuid/WNMCID/NMTID`; `MUSIC_U` 存在时才带登录态 |
| 9 | 解析 | `core/crates/ncm-service/src/netease/song.rs:605-637` | 取 `data[0]`; `code!=200` → `map_code`; 只取 `url/br/size/expi`; **`quality` 写的是「请求的 level」, 不是响应里的 `level`** |
| 10 | DTO | `core/crates/ncm-domain/src/lib.rs:411-429` | `StreamUrl{url, quality, br, size, expire_at}` + `is_playable()` |
| 11 | 桥镜像 | `core/crates/ncm-ffi/src/api.rs:293-300` | `#[frb(mirror(StreamUrl))]` 5 个字段, 与上一条一一对应 |
| 12 | 播放 | `ui/lib/src/playback.dart:317`(Android) / `:324-327`(桌面) | Android: `preferHttpsStreamUrl(url)` → Media3 + SimpleCache; **桌面: 直接把原始 url 交给 Rust**(不升级 https) |
| 13 | 桌面取流 | `core/crates/ncm-ffi/src/api.rs:1331-1373` | `AudioCache::start_progressive` + `download_progressive`(tokio spawn); 缓存命中直接 `play_file` |
| 14 | 下载实现 | `core/crates/ncm-service/src/cache.rs`(`stream_to_part`) | `reqwest::get(url)` —— **没有 UA、没有 Referer、没有显式超时**; 每个 chunk 都 `flush()`(为了让播放线程按文件长度感知) |
| 15 | 解码 | `core/crates/ncm-playback/src/lib.rs:580-625` | `GrowingFile`: 读到 EOF **阻塞等待**, 无新字节 **>90s 才判死**; 解码器 `with_seekable(false)` |
| 16 | 缓存 | `core/crates/ncm-service/src/read_cache.rs:46+` 白名单 | **`song_url` 不在白名单** ⇒ 每次取链都真打上游(只有 UI 层 4 分钟预取挡一下) |
| 17 | 磁盘缓存键 | `core/crates/ncm-service/src/cache.rs::path_for` | `{track_id}.{mp3|m4a|flac}` —— **键里没有来源、没有音质、没有地区** |
| 18 | 错误 | `core/crates/ncm-service/src/netease/mod.rs:263-276` | `code 301/401→auth`, `8821/-462→riskControl`, `-110/404→notFound`, 其余 `internal`; `Display = "[kind] detail"` 是跨桥文本协议 |

### 1.2 已经存在的「多来源缝隙」

| 缝隙 | 位置 | 能做到什么 | 缺什么 |
|---|---|---|---|
| 能力路由 | `Capability::SongUrl`(`capability.rs:11`) + `registry.first_with` | 理论上可注册第二个 provider 顶同一能力 | 路由只取第一个, 无优先级/回退; 返回类型是单值 |
| 插件边界 | `core/crates/ncm-provider/src/lib.rs` 头注释(Provider trait + 可序列化 DTO + `ProviderError` 收口) | 第三方源可作为新 provider 接入, 调用点不变 | 需要 `Vec<候选>` 语义 + 校验(投毒) |
| 换源重建 | `core/crates/ncm-playback/P10-NOTES.md` + `lib.rs::upgrade_to_complete` | 已能「同一首歌换一个**数据源**再续播」(渐进 `.part` → 完整文件, 25ms 淡入, 保位置/音量/EQ) | 只能换**同一 URL** 的数据完整度; 换**另一个 URL/节点**没有入口 |
| 缓存键 | `cache.rs::path_for` / UI `_prefetchedUrls` | 复播不再走网 | 键不含 `level/source/region` ⇒ 换源或改音质后会命中错误文件(现有隐患) |
| 播放器 | rodio/CPAL + Media3 | 能直接吃任意 http(s) URL | 没有「候选列表 + 失败切换」的编排 |

---

## 2. 上游 API 有没有「按网络 IP/地区切服务器」的能力?

### 2.1 返回体: 单个 url, 没有备用域名/多节点

匿名实测(`POST /api/song/enhance/player/url/v1`, 明文通道, `ids=[33894312]`, `level=standard`)返回条目字段:

`id, url, br, size, md5, code, expi(1200s), type, gain, peak, closedGain, closedPeak, fee, uf, payed, flag, canExtend, freeTrialInfo, level, encodeType, channelLayout, freeTrialPrivilege{...}, freeTimeTrialPrivilege{...}, urlSource, rightSource, time, message, levelConfuse, musicId, sr, auEff, immerseType, beatType`

结论:
- **只有 1 个 `url`**, 没有任何「备用域名/IP/多 CDN」字段; 也没有 `type` 之外的多码率列表。
- **我们丢弃的、有价值但没用的字段**: `freeTrialInfo`(**关键**: 非空 = 试听片段)、`level`(服务端实际给的档位)、`encodeType`/`type`(容器)、`md5`(可做完整性校验, 防投毒)、`time`(真实时长, 可与 size/br 交叉校验片段)、`gain/peak/closedGain/closedPeak`(响度归一化, 项目已有响度功能却没用它)、`urlSource/rightSource`(可观测是否 CDN 回源)、`sr`(采样率)。
- 我们**保留但用错**的: `quality` 写的是请求档位。匿名请求 `level=lossless` 实测服务端**静默降级**回 `level=exhigh, br=320000, type=mp3`, `code` 仍是 200 —— 我们的 DTO 会声称无损, UI 也照此显示。

### 2.2 请求侧: 没有可用的「地区/节点」旋钮

| 旋钮 | 代码位置 | 实测 | 判定 |
|---|---|---|---|
| `X-Real-IP`(+`X-Forwarded-For`) | `vendor/.../request.rs:170-182`(`real_ip`/`random_cn_ip`), 服务层从不设置 | 注入 `X-Real-IP: <香港IP>` ⇒ 条目 `code=404` | **不可用**, 直接被拒 |
| 只带 `X-Forwarded-For` | 同上 | 忽略, 正常 200 | 无作用 |
| `NMTID` | `request.rs:232-236`(非登录接口随机注入) | 与节点无关 | 与节点无关 |
| `os` / `appver` / `osver` / `channel` | `request.rs:196-241` + `util/config.rs` | 决定**能不能拿到直链**(缺 `os/appver` 会被封顶音质), 不是节点旋钮(`docs/lx-plugin.md` §5.2 复测一致) | 身份闸门, 非地区 |
| `level` / `encodeType` | `song_url_v1.rs` | 决定档位/容器, 与节点无关 | 无关 |
| `domain` | `request.rs:260+` | 换**接口**域名(weapi/eapi 主机), 与 CDN 节点无关 | 无关 |
| 登录态 | `request.rs:243-250` | 只影响**可播性/音质**(匿名 VIP 曲 → 试听片段; 有 `MUSIC_U` → flac), 不影响节点 | 权限, 非地区 |
| 其它接口(`song/enhance/download/url/v1`) | 无 vendor 封装; 手工探测参数不全 ⇒ `code=400` | 同样单 url, 且需要 download 专用参数(未移植) | 不值得先做 |

### 2.3 真正的「选服务器」发生在 CDN 的 GSLB, 不在 API

- 同一首歌连续 3 次取链, host 在固定族内漂移: `33894312 → {m7,m8,m7}`, `19292984 → {m802,m702,m802}`; **大陆直连与香港出口得到的分布一样**。
- 这些 `mN.music.126.net` 都是 CNAME 到 `opencdnnetmusic.jomodns.com`(网易自建 GSLB), 实际 IP 由 DNS 解析位置决定。
- AliDNS(223.5.5.5) 带 **EDNS Client Subnet** 实测:

| 域名 | ECS = 校园(114.214.186.0/24) | ECS = 香港(203.198.0.0/16) | 无 ECS |
|---|---|---|---|
| `m7.music.126.net` | `122.205.109.35` 等(合肥边缘) | `163.181.35.180-204` 段(中国电信国际/骨干侧) | `117.66.17.x / 223.244.6.x / 60.171.255.x`(皖/沪) |
| `m702.music.126.net` | `122.205.109.41` | `61.147/175.12/106.225/218.94/183.60/111.225...` (江苏/广东等) | `183.131.62.41` |
| `m802.music.126.net` | `122.205.109.41` | `59.63.238.78-85`(江西) | `183.131.62.41` |

⇒ **ECS/解析位置确实改变边缘 IP**(说明 GSLB 按地域就近), 但**香港侧拿到的仍是大陆 IP** —— 该域名族没有(或极少有)香港本地边缘,
跨境时由 `163.181.35.x` 这类国际出口承担。**这就是「香港用户卡顿」最可能的机制: 不是「节点选错」, 而是「没有近的节点可选」。**

单点延迟佐证(`--resolve` 指定边缘, 只测 TLS/TTFB):

| 边缘 | 从校园直连 | 从香港出口 |
|---|---|---|
| `122.205.109.35`(合肥) | conn 0.053 / ttfb 0.158 | ~0.09 (代理侧解析) |
| `183.131.62.41`(浙江) | conn 0.026 / ttfb 0.176 | ~0.098 |
| `59.63.238.85`(江西) | conn 0.039 / ttfb 0.225 | ~0.091 |
| `163.181.35.187`(国际侧) | conn 0.384 / **ttfb 1.151** | ~0.099 |

同一 IP 从校园要 1.15s、从香港只要 0.099s(约 10 倍差) —— 距离错配的代价是实打实的。

---

## 3. 实测 A/B: 出口 × 歌曲 × 可播性(TTFB 交叉)

### 3.1 出口基线(先确认, 再下结论)

| 项 | 值 |
|---|---|
| `ip -4 route show default` | `192.168.42.129 dev enx027...` (metric 102, USB 共享) / `114.214.176.1 dev eno1` (metric 20500, 校园) |
| 代理变量 | `http(s)_proxy/HTTP(S)_PROXY/ALL_PROXY=127.0.0.1:7890` 全部存在; `no_proxy` 覆盖 ustc.edu.cn/edu.cn/内网 |
| 大陆出口 IP | `2001:da8:d800:4068:...`(中国 安徽 合肥 教育网), 直连测 `--noproxy '*'` |
| 香港出口 IP | `45.149.92.90`(Hong Kong, Wap.ac 机房) —— 经 Bettbox/mihomo `香港HK-A` |
| **本机配置陷阱** | mihomo 现有 profile 有 `DOMAIN-SUFFIX,music.163.com / music.126.net → cernet-eno1(DIRECT)` 规则(实测 hitCount 45/304) ⇒ **常规「经代理」测试其实走的是校园直连**; 真正测香港必须临时 `mode=global` + `GLOBAL=香港HK-A`(本轮已用, 结束已还原 `mode=rule` / `节点选择=自动选择` / `GLOBAL=DIRECT`) |

### 3.2 取链: 匿名 `song/url/v1`, `level=standard`

| 歌曲 | 类型 | 出口 | code | 返回 host | br | freeTrialInfo |
|---|---|---|---|---|---|---|
| 33894312 情非得已(童声版) | 免费 fee=0 | 大陆直连 | 200 | m7/m8.music.126.net | 128000 | 无 |
| 33894312 | 免费 | 香港 | 200 | m7/m8.music.126.net | 128000 | 无 |
| 347230 海阔天空 | VIP fee=1 | 大陆直连 | 200 | m802/m702 | 128008 | **有(试听)** |
| 347230 | VIP | 香港 | 200 | m802/m702 | 128008 | **有(试听)** |
| 1330348068 起风了 | fee=8 | 大陆直连 | 200 | m801 | 128000 | 无 |
| 1330348068 | fee=8 | 香港 | 200 | m701 | 128000 | 无 |
| 19292984 Love Story | 付费专辑 fee=1 | 大陆直连 | 200 | m702/m802 | 128008 | **有(试听)** |
| 19292984 | 付费专辑 | 香港 | 200 | m802/m702 | 128008 | **有(试听)** |
| 2744403174 The Fate of Ophelia | 新付费 fee=1 | 大陆直连 | 200 | m802 | 128012 | **有(试听)** |
| 2744403174 | 新付费 | 香港 | 200 | m802 | 128012 | **有(试听)** |

**判定: 换出口 IP 不改变可播性/试听状态/码率, 只改变 host 在固定池内的随机落点。靠换出口拿更多可播曲目 —— 拿不到, 别为此做架构。**

补充(用项目自己的链路复核, 确认与 curl 等价):
`./target/release/ncm url 19292984 --level standard --json` → `br=128008, size=721023`。
`size 721KB @128kbps ≈ 45s` ⇒ 这条「能播」的 URL 实际是 **45 秒试听片段**, 而 `StreamUrl` 里**没有任何字段能告诉 UI 这件事**。

### 3.3 下载交叉实测(https, Range 2MB, 每格 2 次)

| 歌曲 | url 取自 | 下载经 | host | ttfb | 吞吐 |
|---|---|---|---|---|---|
| 33894312 | 大陆 | 大陆 | m7 | 0.121-0.138 | 5.5-5.7 MB/s |
| 33894312 | 大陆 | 香港 | m7 | 0.101-0.130 | 5.7-8.0 MB/s |
| 33894312 | 香港 | 大陆 | m7 | 0.106-0.126 | 7.0-8.0 MB/s |
| 33894312 | 香港 | 香港 | m7 | 0.098-0.124 | 7.5-8.0 MB/s |
| 347230(试听) | 大陆 | 大陆 | m702 | 0.037-0.121 | 3.0-10.5 MB/s |
| 347230 | 香港 | 香港 | m802 | 0.102-0.106 | 3.0-3.1 MB/s |
| 19292984 | 大陆 | 大陆 | m702 | 0.035 | 10.5-10.9 MB/s |
| 19292984 | 大陆 | 香港 | m702 | 0.117-0.118 | 2.8 MB/s |
| 19292984 | 香港 | 香港 | m802 | 0.112-**0.404** | 1.4-3.0 MB/s |

**要点**: 香港出口到这批边缘的 TTFB ≈ **0.10-0.40s**, 吞吐 **1.4-3.1 MB/s**; 对 128kbps(16 KB/s)需求是 100 倍余量。
⇒ **「带宽不够」在这个样本里不成立**; 但如果香港用户被解析到 `163.181.35.x` 这类国际侧边缘, TTFB 会跳到 **1s 量级**(校园侧同 IP 实测 1.15s),
那就属于「节点远」, 而不是「链路丢包」。

### 3.4 明文 http 的坑(必读)

同一 URL 用 **http:80** 从本机下载, 小样本里反复拿到 `HTTP/1.1 200 + Content-Type: text/html + Server: redir_url by james@ustc.edu.cn`(校园网重定向页),
换 **https://** 同一 host 立刻正常(`HTTP/2 200, content-length: 721023, audio/mpeg`)。
⇒ 桌面端(`playback.dart:324` 传原始 url、`cache.rs` 用 `reqwest::get`)走的正是**明文 http**。跨境/校园/移动网络下明文 http 被中间设备劫持不是理论风险。

---

## 4. 卡顿归因矩阵(香港用户「卡」)

| # | 可能因 | 判据 | 怎么测(我们能做/需用户) | 本机实测结果 |
|---|---|---|---|---|
| 1 | **节点距离错配**(拿到远端边缘) | 取链 url 的 host → `dig` 出 IP → 查属地; 与用户属地比 | 需香港用户: 出问题时抓一次 url host + `dig <host> +short` + `curl -w '%{time_starttransfer}'` | 本机证实 GSLB 按地域给边缘(ECS 换 IP 段), 且香港侧拿到的仍是大陆 IP 段; 近/远边缘 TTFB 差 **10 倍**(0.099s vs 1.15s) |
| 2 | **跨境链路 RTT/丢包** | `ttfb` 与 `conn` 的 P50/P95; 若 P95 抖动 >> P50 或伴随重传 ⇒ 链路 | 同一 URL 连续 5-10 次 TTFB; 香港侧需用户配合 | 香港出口样本 TTFB 0.098-0.404s(有一次 0.404 尖峰), 方差存在但未到「卡顿」级 |
| 3 | **吞吐不足** | `speed_download` < 32 KB/s(128kbps 的 2 倍安全线) | 同上, Range 2MB | 香港出口 1.4-3.1 MB/s ⇒ **本样本排除** |
| 4 | **播放器缓冲水位策略** | 一次断流触发 Media3 默认 rebuffer(起播 2.5s / 重缓冲 **5s**) ⇒ 表现为 5 秒静音; 桌面 `GrowingFile` 10ms 轮询 + **90s** 才判死 | Android: logcat 抓 `ExoPlayer` Buffering 事件; 桌面: `[playback] growing file stalled` 日志 | 代码事实: `PlaybackService.kt:496` 构建 ExoPlayer **未设 LoadControl**(全默认); 桌面无低水位/预取, 靠下载速度硬扛 |
| 5 | **风控限速/频控** | 取链 `code=405/8821`、或 url 正常但下载 403/极慢 | 连续取链 5 次看 code; 下载首包是否 200 但 body 极小 | 本轮 30+ 次匿名取链全部 200, 未见限速; 未做登录态大批量 |
| 6 | **明文 http 被劫持** | 下载首包是 `text/html` 或 `Server: redir_url...` | `curl -D -` 看响应头 / 对比 https | 已复现(本机校园网); https 正常 ⇒ **桌面应强制 https** |
| 7 | **缓存键错位导致重复下载** | 同曲每次改音质/换源后重新整段下载 | 看 `audio/` 目录文件命名 | 代码事实: `path_for = {track_id}.{ext}`, 不含 level/source ⇒ 换音质会**误命中**旧文件或重复写 |
| 8 | **上游接口本身慢(取链而非取流)** | 取链耗时(POST 往返) vs 下载耗时 | `curl -w '%{time_total}'` 打取链接口 | 本机取链往返 ~0.1-0.3s; 与「播放中途卡」无关 |

**当前最可能的组合**: #1(节点远) + #4(缓冲策略把一次 200ms 抖动放大成 5s 静音) + 桌面上的 #6。
**决定性证据只需一条**(需香港用户): 卡顿时的 url host + 该 host 的 `dig +short` + 一次 TTFB。

---

## 5. 播放器侧缓冲/超时/重试(与节点问题必须分开看)

| 侧 | 事实 | 位置 |
|---|---|---|
| Android 数据源 | `DefaultHttpDataSource`: connect **15s**、read **20s**、允许跨协议重定向; UA 由 Rust 注入, Referer 固定 `https://music.163.com/` | `ui/android/app/src/main/kotlin/com/minincm/minincm/PlaybackService.kt:519-535` |
| Android 缓冲 | **没有自定义 `LoadControl`** ⇒ media3 默认(音频: 起播 2.5s、重缓冲 5s、最大 50s) | 同上 `:496-505` |
| Android 缓存 | `CacheDataSource`(streamCache 开关) + `SimpleCache` LRU 上限; 与 Rust `AudioCache` **刻意隔离**(一个分片、一个整文件) | `:533-560` |
| 桌面下载 | `reqwest::get(url)`: **无 UA/Referer/无显式超时**; 每 chunk `flush()` | `core/crates/ncm-service/src/cache.rs::stream_to_part` |
| 桌面解码 | `GrowingFile::read` 无数据时 `sleep(10ms)` 轮询, `done` 或 **90s** 才返 EOF; 解码器非 seekable | `core/crates/ncm-playback/src/lib.rs:580-625` |
| 换源 | 只有「渐进 `.part` → 完整文件」这一条(25ms 淡入、保位置/EQ/音量) | `P10-NOTES.md` `:689-810` |
| 取链重试 | Dart `retryNetwork` 包住 `songUrl`(网络类 3 次) | `ui/lib/src/home/playback_coordinator.dart:437` |
| **缺的** | ① 下载失败/过慢**不会**重取链或换候选 url; ② 首包前没有「多久算慢」的判定; ③ 桌面明文 http 不升级; ④ 桌面下载无 UA/Referer | - |

**结论**: 高 RTT 下真正伤听感的是 #4 —— 一次 200-400ms 的首包延迟不致命, 但**一次 5 秒的 rebuffer 就是用户嘴里的「卡」**。
所以除了「选节点」, **降低 rebuffer 触发后的恢复时间**(或换候选 url 立即续播)收益可能更大。

---

## 6. 候选音源来源盘点(类别级, 不含任何第三方的域名/令牌)

| 类别 | 可得性 | 需要的凭据/基础设施 | 合规风险 | 维护成本 | 对本轮「香港卡顿」的作用 |
|---|---|---|---|---|---|
| ① 官方接口 + 不同出口 | 高(已有链路) | 无 | 无 | 低 | **无**(实测不解锁、不选节点) |
| ② 自建/现有代理出口做取链/取流代理 | 中 | 一个境外出口(云主机/机场节点), 密钥必须不落盘 | 低(仍是官方协议), 但**代理流量计费/被封风险** | 中(节点维护、密钥分发) | 对**香港用户**无效(他们本来就在香港); 只对**大陆用户**有用(绕开明文 http 劫持/慢边缘) |
| ③ lx 风格第三方音源插件(社区源) | 中(生态活跃) | 插件宿主(QuickJS) + 每个源各自账号/接口 | **高**: 公开仓库不宜内置具体源; 侵权与投毒 | 高(源会长期失效) | 间接(能拿到别的 CDN, 但音质/时长可信度低) |
| ④ 公开聚合 API / 其它平台搜索兜底 | 低-中 | 通常需要 key, 稳定性差 | 中-高(条款/版权) | 中 | 弱(跨平台匹配错误率高) |
| ⑤ 本地已缓存/已下载优先 | 高 | 无 | 无 | **最低** | **强**: 已缓存直接播, 不受任何节点影响 —— 应作为 resolver 的第一优先级 |

设计取向: **⑤ 先命中 → ① 官方(带实测 TTFB 选候选) → ② 代理官方(可选开关) → ③④ 只在用户显式启用时**。
任何第三方候选都要过 `md5/time/br/size` 一致性校验(官方返回体里现成就给了 `md5` 与 `time`, 我们目前全丢了)。

---

## 7. 入接口设计: `SourceResolver`(草案)

### 7.1 Rust 侧形状

```rust
// ncm-provider/src/caps/source.rs (建议新增能力域; 先不新 crate)
pub struct SourceQuery {
    pub track: TrackId,
    pub level: AudioLevel,
    pub allow_trial: bool,        // 是否接受「试听片段」作为候选(默认 false)
    pub allow_third_party: bool,  // 默认 false, 由设置开关打开
    pub max_candidates: u8,       // 默认 2
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceKind { LocalCache, Official, OfficialViaProxy, ThirdParty }

pub struct SourceCandidate {
    pub url: String,
    pub kind: SourceKind,
    pub quality: AudioLevel,      // **服务端实际给的**档位(修掉现在「写着请求档位」)
    pub bitrate: Option<u64>,
    pub size: Option<u64>,
    pub duration_ms: Option<u64>, // 来自响应 time, 用于识别试听片段
    pub md5: Option<String>,      // 完整性校验
    pub trial: bool,              // freeTrialInfo 非空
    pub expires_at: Option<u64>,
    pub region: Option<String>,   // 出口/解析地区标签, 仅用于缓存键与诊断
    pub measured_ttfb_ms: Option<u32>, // 探针结果(排序依据)
}

pub trait SourceResolver: Send + Sync {
    fn resolve<'a>(&'a self, q: &'a SourceQuery)
        -> BoxFuture<'a, ProviderResult<Vec<SourceCandidate>>>;   // 已按优先级+TTFB 排好序
}
```

### 7.2 放哪儿 / 与现有路由的关系

- **不新建 crate**: 先作为 `ncm-provider/src/caps/source.rs` 的**第 14 个能力域** + `Capability::SourceResolve`,
  实现放在 `ncm-service`(官方/代理官方/本地缓存) + 未来插件源各自实现 `SourceResolver`。
  只有当真的引入脚本宿主(QuickJS/lx 兼容层)时, 才拆 `ncm-source` —— 现在拆是过度设计。
- **与 `ReadProvider::song_url` 的关系**: 保留旧方法不动(`ncm-cli` / 现有调试点继续用), 新 resolver **内部**调用它 + 多一次候选/TTFB 逻辑。FFI 新导出走固定三步(codegen → `cargo build -p ncm_ffi` → `flutter test`), 不改旧签名最安全。
- **Dart 侧**: 新导出 `resolveSource(trackId, level, {allowTrial, allowThirdParty}) -> Vec<SourceCandidateDto>`,
  `playback_coordinator` 用它替换 `rust.songUrl` 的单值调用(可保留旧路径做 A/B)。

### 7.3 优先级 / 并发 / 超时 / 错误

```
1) 本地缓存命中(整文件存在且 >=64KB)        → 直接返回, 0 网络
2) 官方取链(1 次)                           → 若 trial && !allow_trial 则记为「不可用」, 继续
3) 官方取链再取 1 次(同接口, 拿第二个 host)  → 与 2) 并发 2 路, 每路 deadline 2.5s
4) 对候选并发测速(Range 0-64KB, HEAD 不够)   → 2 路并发, 各自 deadline 2s, 取 ttfb 最小
5) (可选) 代理官方 / 第三方                   → 串行在 2)-4) 全失败后, 总预算 +4s
总预算: 用户可感知上限 6s; 超过先播已知最好候选, 其余后台补
```
- **并发上限 2**(取链 2 路 + 测速 2 路), 因为上游有 `405 操作频繁` 的风控, 现有 `read_cache` 也是靠「同 key 单飞」压并发的。
- **错误映射**(沿用 `ProviderError{kind,retryable,detail}`):
  - 全部候选都不存在 → `notFound`(不可重试) —— UI 文案「该曲目暂无可播音源」
  - 有候选但全部网络失败 → `network`(`retryable=true`)
  - 只有 `trial` 候选且 `allow_trial=false` → `forbidden`(不可重试), detail「仅试听片段, 需登录或会员」
  - 上游 `8821/-462` → `riskControl`(不重试, 不要立刻再打)
  - 第三方候选校验失败(md5/时长/大小不符) → `internal`(不重试) + 丢弃该候选
- **静默降级要可见**: `quality != requested` 时不算错误, 但要在候选里如实写 `quality`, 由 UI 提示「已降级为 极高」。

### 7.4 缓存键: 要不要带地区?

| 缓存 | 现在 | 建议 |
|---|---|---|
| 取链结果(内存/磁盘) | **没有**持久缓存(只有 UI 4 分钟预取) | 若加缓存: key = `track + level + logged_in + region_tag + source`; TTL ≤ `expire_at - 60s` |
| 音频文件 | `{track_id}.{ext}` | **必须改**: `{track_id}-{level}-{source_tag}.{ext}`。现状换音质/换源会**误命中**别的码率文件(可能表现为「卡」或音质不对) |
| identity 纪律 | device_id 首启生成后永久复用 | 不动。地区标签只做**诊断/排序**, **不参与身份**(不要为不同地区造不同 device_id —— 那是风控特征) |
| uid 隔离 | `read_cache` 只缓存账号无关白名单, 会话变化整表清空 | 候选缓存同样要「登录态变化即清」(同曲匿名=试听、登录=整曲, 混用会把试听钉住) |

### 7.5 Dart/UI 需要什么

- `AsyncView` 四态照旧; 新增两个错误分类文案: 「仅试听片段(需登录/会员)」、「音源异常, 已切换备用源」。
- 播放条/详情页一个轻量提示位(卡片/`AdaptiveText`): 当前源类型 + 实际音质(降级时提示)。
- 设置项: 「允许试听片段(默认关)」、「音源优先级(本地缓存/官方/代理官方/第三方)」、「自动测速选源(默认开, 2 路探针)」。
- 按 `notes-ui-rules.md` 的数量/容器纪律, 开关进现有设置页分区, 不新开页面。

---

## 8. 三个候选方案

| 方案 | 内容 | 成本 | 改动面 | 验收口径 | 什么时候值得做 |
|---|---|---|---|---|---|
| **A. 信息无损 + 强制 https + 重取链**(推荐先做) | ① `StreamUrl` 增 `actual_level/type/trial/duration_ms/md5`(codegen 三步); ② 桌面下载/播放强制 https; ③ 桌面下载补 UA/Referer/超时; ④ 试听片段识别 + UI 提示; ⑤ AudioCache 键加 `level`; ⑥ 下载失败(非 2xx/首包超时)重取链 1 次 | **S**(≈1 天) | `ncm-domain` + `ncm-ffi`(mirror) + `ncm-service`(parse/cache) + Dart(文案/提示) | 匿名付费曲显示「仅试听」; 请求 lossless 被降级时 UI 显示「极高」; 桌面不再出现 `text/html` 首包; `flutter test` + `cargo clippy` 0 warning | **无条件做** —— 用户报「卡顿」, 这里有两个独立可疑项(明文 http、试听误当整曲)成本极低 |
| **B. `SourceResolver` 多候选 + TTFB 排序/回退** | §7 的 resolver: 2 路取链 + 2 路 Range 探针 + 失败换候选 + 地区感知缓存键; 保留旧 `songUrl` 路径 | **M**(2-3 天) | 新能力域 + FFI 新导出 + Dart 换调用点 + 缓存键迁移(要做旧文件兼容) | 同曲 TTFB 方差 >3x 时能自动选更快的; 主候选 403/超时能无感切到备选(日志可证); 缓存键不再串码率 | 当①用户反馈「换网络/换节点就好」或②我们的日志显示同曲不同次 TTFB 方差大(需先做 A 的观测字段) |
| **C. 多 provider 音源 + 插件宿主** | 官方 / 代理官方 / 第三方(lx 兼容层) 三 provider + 设置页排序 + 完整性校验 | **L**(≥1 周) | 新 crate/脚本宿主 + 宿主权限 + 合规审查 | 第三方源可插拔且校验失败必丢弃; 默认关闭 | 仅当用户明确接受第三方源的**合规边界**且 A/B 都做完仍不满足 |

**注意**: 三个方案都**不包含**「按出口 IP 切节点」 —— 实测该旋钮不存在于 API 侧。

---

## 9. 风险与明确不做

**风险**
1. **版权/合规**: 公开仓库不得内置任何具体第三方音源域名/令牌/接口密钥; 插件层只能留「接口形状 + 校验规则」, 具体源由用户自填(与 `docs/lx-plugin.md` 的 cookie 处理口径一致)。
2. **凭据与出口代理密钥管理**: 代理地址/订阅/密钥**一律不落盘、不进仓库、不进报告**; 运行期从用户环境或 OS keyring 取; 设置页只存「是否启用」, 不存凭据。
3. **风控封号**: 用代理出口 + 固定 device_id 打官方接口, 在网易侧是「异地设备」特征; 高频多候选探针会放大 `405` 风控。对策: 并发上限 2、探针只在「首播失败/超时」时触发、绝不为不同地区造不同 device_id。
4. **第三方源投毒**: 必须做 `md5 + duration + br/size` 三向一致性校验(官方响应里现成有 `md5`/`time`, 现在被我们丢弃), 且只信 https。
5. **跨地区计费**: 代理取流会把整首歌的流量算在出口上(1 首歌 ≈ 3-10MB), 与「只代理取链」成本差一个量级 —— 默认只代理**取链**, 取流不经代理。

**明确不做**
- ❌ 不做「按地区切换 device_id / 伪造 `X-Real-IP`」(前者是风控特征, 后者实测被 404)。
- ❌ 不做「用不同出口解锁 VIP/付费曲」(实测无效, 且是绕过付费, 合规上不可接受)。
- ❌ 不把任何具体第三方源写进仓库/报告。
- ❌ 不在本轮改 `docs/PROGRESS.md` / `docs/remaining-batches.md`。

---

## 10. 需要用户拍板(≤6)

1. **决定性证据**: 香港卡顿发生时, 能否配合抓一次「url 里的 host + `dig <host> +short` + 该 url 的一次 TTFB」? 没有这条, 归因矩阵只能停在「可能」。
2. **桌面是否强制 https**(现状 http 明文, 已复现被劫持成 HTML) —— 有无保留 http 的理由?
3. **是否识别并提示「试听片段」**(会改变现在「能播就播、45 秒后跳下一首」的行为)?
4. **方案顺序**: 先 A(信息无损 + https + 重试, S), 还是直接上 B(多候选 + TTFB 排序, M)?
5. **第三方音源口径**: 只做「官方 + 可选代理官方」, 还是允许用户自填第三方源(默认关)?
6. **缓存键迁移**: 允许把 `audio/{track_id}.{ext}` 改成带音质/来源(会有一次旧文件失配, 需不需要保留迁移逻辑)?

---

## 附: 本轮实测命令与状态(可复现)

```bash
# 出口基线
ip -4 route show default; ip -6 route show default; env | grep -i proxy
curl --noproxy '*' -s https://myip.ipip.net                                       # 校园 IPv6 出口
curl --noproxy ''   -x http://127.0.0.1:7890 -s https://api.ip.sb/geoip           # 香港 45.149.92.90

# 取链(A/B 与候选探测, 匿名, 每个组合 <=2 次)
curl -s -X POST https://interface3.music.163.com/api/song/enhance/player/url/v1 \
  -H 'User-Agent: ...' -H 'Cookie: os=pc; appver=3.0.6; deviceId=<固定伪指纹>' \
  --data 'ids=[19292984]&level=standard&encodeType=flac'

# 项目链路复核
./target/release/ncm url 19292984 --level standard --json

# 节点/边缘
curl -s "https://223.5.5.5/resolve?name=m7.music.126.net&type=A&edns_client_subnet=203.198.0.0/16"
curl --noproxy '*' -k --resolve m7.music.126.net:443:163.181.35.187 -w '%{time_starttransfer}' https://m7.music.126.net/

# 香港出口测流(Range 2MB) —— 需临时 mode=global + GLOBAL=香港HK-A, 测完已还原
curl --noproxy '' -x http://127.0.0.1:7890 -o /dev/null -r 0-2097151 \
  -w 'ttfb=%{time_starttransfer} speed=%{speed_download}' '<https url>'
```

代理状态已还原并核验: `mode=rule`、`节点选择=自动选择`、`GLOBAL=DIRECT`。
