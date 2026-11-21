# LX 社区音源脚本 ↔ ncm-plugin QuickJS 宿主 兼容性对照(实测级取样)

> 日期: 2026-11-21 · 车道: 只读调研(静态对照, 未跑构建/测试)
> 对照基准: `core/crates/ncm-plugin/README.md` §1.2(事件) / §1.3(注入 API) / §4(缺口表)
> 上游契约权威: <https://lxmusic.toside.cn/desktop/custom-source>(官方文档, 本次已核对)
>
> **落地状态(2026-11-21, 切片 3 波次 2 D)**: §4 表的 **#1 request 事件适配 / #2 setTimeout / #3 回调式 lx.request /
> #6 lx.utils.buffer + btoa/atob / #7 lx.env** 已落地, 见
> `core/crates/ncm-plugin/README.md` §1.2/§1.3; #4(musicInfo 真实上下文)/#5(音质码透传)/#8(inited 回传宿主)/#9/#10 仍未做。
> 适配口径与本文件略有出入: 宿主**不改**已有 `musicUrl` 事件, 而是在脚本没注册 `musicUrl` 时由 prelude 翻译成
> `request` 事件(两者都注册时优先 `musicUrl`)。

## 1. 取样脚本表

| # | 脚本 | 来源(raw 直链) | 规模 | 使用的 lx.* API | 事件 |
|---|---|---|---|---|---|
| S1 | HelloWorld(四平台多 API 回退) | github.com/pdone/lx-music-source `main/helloworld/latest.js` | ~20KB 明文 | `globalThis.lx` 解构 `{EVENT_NAMES, request, on, send}`; `lx.request(url, options, callback)`(回调式!); `lx.utils.buffer.from/bufToString`(可选回退 btoa); `setTimeout/clearTimeout`; `Promise.any`; `new URL`; `info.name/singer/artist/songname` | `on(EVENT_NAMES.request)`(只 action=musicUrl) + `send(EVENT_NAMES.inited, {openDevTools, sources})` |
| S2 | 星海音乐源 v3.2.12 | github.com/cdyUuu/lx-music-xinghai-source `main/xinghai-music-source.js` | 18KB 明文 | 同上, 另加 `lx.env.platform`; `Buffer` 全局回退; `lx.utils.buffer.bufToString`; 顶层 IIFE 在**装载期**就发起 `fetchIp()`/`checkUpdate()` 异步请求 | `on(EVENT_NAMES.request)`(musicUrl/lyric/pic 三 action) + `send(inited)` + `send(EVENT_NAMES.updateAlert, {log, updateUrl})` |
| S3 | 独家音源(服务端下发+重度混淆) | github.com/pdone/lx-music-source `main/lx/latest.js` | ~40KB 混淆 | 混淆后可见: `typeof require/process` 探测、JSON/Date/console/Symbol/Promise 内建使用、`lx` 全局 | 无法静态确证注册事件; 属「反混淆才能跑」一类 |
| S4(参考) | 官方 demo(文档内嵌) | lxmusic.toside.cn/desktop/custom-source | — | `on(EVENT_NAMES.request)` + `apis[source].musicUrl(info.musicInfo, qualitys[source][info.type])`; `lyric` 返回 `{lyric,tlyric,rlyric,lxlyric}`; `lx.utils.crypto.{aesEncrypt,md5,randomBytes,rsaEncrypt}`; `lx.utils.zlib.{inflate,deflate}` | request + inited |

结论性事实:**没有任何一份真实脚本注册我们宿主的 `musicUrl` 或 `search` 事件**。上游唯一入口是
`lx.on(EVENT_NAMES.request, ({source, action, info}) => Promise)``, `action ∈ {musicUrl, lyric, pic}`;
`search` 从不在音源脚本里出现(搜索由客户端自己完成)。

## 2. 逐脚本命中/失败点

### S1 HelloWorld
- ✅ ES2020 语法、`Promise`、解构、模板串、`Object.fromEntries`、`Map`-风格缓存 —— QuickJS 全支持。
- ❌ **`request(url, options, callback(err, resp))` 回调式调用**: 我们是 `lx.request({url,...}) → Promise`。脚本第一行解构 `const {request} = globalThis.lx` 后直接以回调用 —— 在我们宿主会把 undefined 当回调 → TypeError。
- ❌ **`setTimeout/clearTimeout`**: 超时包装用, 我们沙箱没有 → ReferenceError(且没有可 polyfill 的定时器语义)。
- ⚠️ `lx.utils.buffer.from(str,'utf-8')` + `bufToString(buf,'base64')`: 脚本有 btoa 回退, 可容忍缺失。
- ⚠️ `info.name/singer/artist` 兜底 `{keyword}` 模板: 我们 musicInfo 只有 id, name/singer 全空 → 依赖 keyword 的 API(如 `a.aa.cab/qq.music?msg={keyword}`、咪咕 oiapi)必然取不到链。
- ⚠️ 音质码 `hires/atmos/atmos_plus/master`: 我们的音质映射只有 128k/320k/flac/flac24bit, 上游这些码我们永远传不出来, 但脚本侧 fallback 链最终落 320k/128k, 部分可用。
- ⚠️ `on(EVENT_NAMES.request)`: 我们 EVENT_NAMES.request='request' 字符串存在, 但宿主从不往 'request' 事件分发 → handler 永远不触发 → MissingHandler。
- ✅ `send(EVENT_NAMES.inited, {sources})`: `lx.send` 有, 只是不回传宿主(留痕)。

### S2 星海
- 覆盖 S1 全部差异, 另有:
- ❌ **`lx.env.platform`**: 我们没注入 `env` → 解构得 undefined, `buildClientHeader` 里有 try/catch 兜底 'unknown', 可容忍。
- ❌ **`send(EVENT_NAMES.updateAlert, ...)`**: `updateAlert` 不在我们 KNOWN_EVENTS → `EVENT_NAMES.updateAlert` = undefined, send(undefined,...) 不崩但更新提示丢失(可接受)。
- ❌ **装载期即发异步请求**(顶层 IIFE `fetchIp()/checkUpdate()`): 我们的 promise 泵只在调用期跑, 装载期 8s 里这些 job 是否被泵无保证(README 只说「promise -> job queue 泵」, 未验证装载期行为) —— 需宿主侧专项验证。
- ❌ **`Buffer` 全局探测**(typeof Buffer !== 'undefined'): 无则走 lx.utils.buffer → 仍缺 → 再回退 btoa; 实际会落到 btoa 路径, 可用但编码行为不同。
- ❌ **action=lyric/pic**: 我们宿主完全没有这两个 action 的概念(也不需要, 我们歌词不支持) → `unsupported`, 兜底 OK。
- ⚠️ `musicInfo._types[quality].hash`、`albumId`、`hash/songmid`: 我们只传 `{id}`(数字 trackId)且没有 hash/songmid 字段 —— kw/kg 系按 `hash` 取链的接口直接拿不到 id(`musicInfo.hash ?? songmid ?? id` 至少能落到 `id`)。

### S3 混淆源
- 静态不可判; 混淆器做 `typeof require === ?`、`typeof process` 探测, 我们两者都是 undefined(README §1.3 专项断言) —— 行为是「被判定为非 Node 环境」, 不一定崩。
- 这类脚本建议列为「明确不做」, 兼容成本不可控。

## 3. 差异总表(我们 §1.3 注入面 vs 真实脚本)

### 3.1 缺失 API
| API | 上游语义(官方文档/脚本实测) | 脚本容错 | 影响 |
|---|---|---|---|
| `lx.request(url, options, callback)` | **三参回调式**: resp={statusCode,headers,body,url(重定向后 URL)} | 无 | **致命**: 所有真实脚本第一入口 |
| `setTimeout/clearTimeout` | 全局定时器(仅桌面/移动宿主有) | 无 | **致命**: S1/S2 都包请求超时 |
| `lx.utils.buffer.from/bufToString` | Buffer codec(from/toString, base64/utf-8/hex) | S1/S2 有 btoa 回退 | 中 |
| `Buffer` 全局 | Node Buffer 子集 | 有回退 | 低-中 |
| `lx.env` (`{platform, env: 'desktop'/'mobile'}`) | 脚本探测运行端 | try/catch | 低 |
| `lx.currentScriptInfo` / `lx.version` | 脚本元信息 | 未见真实脚本用 | 低 |
| `lx.utils.crypto.{aesEncrypt,rsaEncrypt,randomBytes}` | buffer 进出 | md5 我们有; 其余只有部分脚本用 | 中(看要接哪些源) |
| `lx.utils.zlib.{inflate,deflate}` | Promise<Buffer> | 少数脚本 | 低 |
| `lx.utils.buffer.toString`(别名)/`btoa` | 全局 btoa(QuickJS 无 Web 全局) | S1/S2 直接用 btoa 且无 polyfill | 中 |

### 3.2 形状不一致
| 项 | 我们 | 上游真实 | 备注 |
|---|---|---|---|
| 事件入口 | `on('musicUrl', (source, info, quality))` 直接分发 | `on('request', ({source, action, info:{type, musicInfo}}))` 单入口 | **致命**: 宿主需把 songUrl 调用翻译成 `request` 事件 + `action:'musicUrl'` 分发(或兼容层适配) |
| `musicInfo` 字段 | `{id, name:'', singer:'', albumName:'', interval:0, type}` | 脚本按 `hash/songmid/rid/songId/id` 取 id; 用 `name/singer/artist`、`albumId`、`_types[quality].hash` | id 能兜底落到 `id`, 但 keyword 系 API 失效(README §4 第 6 项已列) |
| `quality` 代号 | 128k/320k/flac/flac24bit | 还有 192k/hires/atmos/atmos_plus/master/jyeffect/sky/jymaster | 未映射的音质上游会 fallback 降级, 我们传不出去; 至少应透传原码 |
| `search` 事件 | 自定义 `{keywords,limit,offset}` | **上游音源脚本无此事件**(搜索在客户端) | 形状无需对齐, 但注意真实脚本不会注册它 |
| resp.url | 无 | 回调 resp 带 `url`(最终重定向 URL), S1 用它解析 302 直链 | 补 request 适配时一并考虑 |

### 3.3 运行时差异
| 差异 | 后果 |
|---|---|
| 无 `setTimeout/clearTimeout` | S1/S2 顶层定义即 ReferenceError → **装载失败**(不是运行期才崩) |
| 无 `require/module/process` | 探测型使用不崩(undefined); Node 特征依赖的混淆脚本不跑 |
| 无 `fetch/XHR` | 真实脚本统一走 `lx.request`, 无影响 |
| 无事件循环定时器 → `lx.utils.sleep` 抛错 | 真实脚本未见用 sleep |
| **装载期异步 job 泵未验证** | S2 顶层就发请求; 若装载期不泵 job, 请求 promise 永不 settle |
| 内建冻结/Function.toString(移动版) | 我们 QuickJS 不冻结, 无影响(反而更宽松) |

### 3.4 事件缺口
| 事件 | 我们 | 真实脚本 | 处置 |
|---|---|---|---|
| `request`(musicUrl/lyric/pic) | 无(拆成 musicUrl) | **唯一入口** | 必须补 |
| `inited`(send, {sources, openDevTools, status}) | send 留痕, 不回宿主 | 装载完成握手, sources 决定支持平台 | 建议接: sources 是平台白名单与能力声明 |
| `updateAlert`(send, {log, updateUrl}) | 无 | S2 用于自更新提示 | 可忽略(只丢提示) |

## 4. 补齐清单(按影响排序)

| # | 缺什么 | 哪些脚本会因此失败 | 成本 | 建议 |
|---|---|---|---|---|
| 1 | **`request` 事件适配层**: 宿主 songUrl 调用翻译成 `{source, action:'musicUrl', info:{type, musicInfo}}` 分发给 `on(EVENT_NAMES.request)` 的 handler | S1/S2/S4(=全部非混淆脚本) | **M**(prelude 加适配 + worker 调用翻译; 可与现有 musicUrl 分发并存) | **必做**, 不做等于接不了任何真实脚本 |
| 2 | **`setTimeout/clearTimeout`**(最小实现: 泵循环里的到期任务队列, 不需要真实定时线程) | S1/S2 装载即崩 | **M**(prelude 任务表 + 泵循环推进; 边界: 只在泵间隙触发, 精度=泵周期) | **必做**; 至少提供「立即不崩」的 no-op 降级(register 成功不触发)可先救装载, S 之后做真触发 |
| 3 | **`lx.request` 回调式签名**(url, options, cb) 兼容: cb(err, {statusCode, headers, body, url}) | S1/S2 | **S**(prelude 里包一层: 判断第一参是字符串则走旧 Promise 路径再转回调) | **必做**, 便宜 |
| 4 | **musicInfo 字段补齐**(name/singer/albumName/interval 真实值 + songmid/hash 兼容字段) | keyword 系 API(oiapi 咪咕、a.aa.cab QQ); kw/kg hash 系稳定性 | **M**(上层 SongUrlRequest 带 Song 上下文, README §4 第 6 项) | **建议做**(对 wy id 系脚本非阻塞) |
| 5 | **音质码透传**(hires/atmos/master 等不再只映射四档, 未认识的原样传) | 高音质请求降级/失败 | **S** | **建议做** |
| 6 | **`lx.utils.buffer`**(from/bufToString/toString, base64/utf-8/hex) + 全局 `btoa/atob` | S1/S2 的 token 生成(有 btoa 回退, buffer 缺失仅退化) | **M**(纯 JS 可在 prelude 实现 codec, 不必真 Buffer) | **建议做**(低成本提兼容面) |
| 7 | **`lx.env`(`{platform, env}`)** | S2 探测端型 | **S** | **建议做**(一行常量) |
| 8 | **`inited` 握手回传宿主**(sources → 插件能力/平台白名单) | 平台分流脚本(`source: 'wy'` 等) | **M**(sends 已收集, 需回传 PluginRegistry 并决定 source 代号) | **建议做**, 与 §4 第 6 项同批 |
| 9 | `lx.utils.crypto.aesEncrypt/rsaEncrypt/randomBytes` | 部分直连协议脚本(非取样主流) | **L**(AES 需引入实现或 Rust 侧注入) | **缓**, 等有明确要接的源 |
| 10 | `lx.utils.zlib` | 少数脚本 | **L** | **缓** |
| 11 | `Buffer` 全局、`updateAlert`、`currentScriptInfo`、resp.url 重定向链 | 容错路径已覆盖 | S~M | **缓**(第 6 项做顺手给 btoa/atob) |
| 12 | 混淆/自校验脚本(S3 类)支持 | — | 不可控 | **明确不做** |

## 5. 明确不做
- **混淆源(如 S3 独家音源)**: 反混淆/模拟其检测环境不可维护, 且属他人付费服务前端。
- **`search` 事件对齐上游**: 上游音源脚本根本没有 search, 我们的自定义形状保留即可, 不算缺口。
- **桌面版 `openDevTools`、devTools 事件、内建冻结模拟**: 与我们沙箱模型无关。
- **Node `require/module` 环境**: 维持 undefined(README §1.3 断言不变); 真实明文脚本不依赖。
- **真实定时线程**: setTimeout 只求「泵间隙可触发」的近似语义, 不为精度上多线程。

## 6. 实测冒烟(2026-11-21, 兼容层落地后)

取样脚本**不入库**(第三方代码 + 内含他人接口地址), 只在本地跑; 出站一律走假 transport(全 200 + 假 JSON), 绝不联网。
做法: `curl -sS --noproxy '*' -o /tmp/lx_latest.js https://raw.githubusercontent.com/pdone/lx-music-source/main/helloworld/latest.js`
(星海同法取 `cdyUuu/lx-music-xinghai-source/main/xinghai-music-source.js`), 临时 `tests/real_script_smoke.rs` 用
`ScriptEngine::new` 装载 + 调一次 `musicUrl`, 断言 handlers / 返回值 / 出站记录, 跑完即删。

| 脚本 | 装载 | 注册事件 | 宿主 `musicUrl` 调用结果 | 出站 |
|---|---|---|---|---|
| S1 HelloWorld(21 KB, 明文) | ✅ | `["request"]` | ✅ 回直链字符串 | 1 次 `POST https://musicserver.haitangw.cc/v1/music/resolve-url`(body 里 `source=wy` + `rid=123456` + `level=lossless`) |
| S2 星海 v3.2.12(18 KB, 明文) | ✅ | `["request"]` | ✅ 回直链字符串 | 4 次: 装载期 2 次(`/ip.php`、版本检查 ×2 主机) + 取链 1 次 `.../api.php?...&source=netease&id=123456&br=740` |

结论(与 §4 补齐清单逐条对应):

- **#1 `request` 事件适配 / #2 `setTimeout` / #3 回调式 `lx.request`** 在真脚本上都生效 —— 三者任一缺失,S1/S2 装载或首次调用就会失败(§3.3 的「装载期 ReferenceError」风险已消除)。
- **#6 `lx.utils.buffer` / `btoa`** 被 S1 的 token 生成路径实际调用, 无异常(不再走 `catch` 回退)。
- **#7 `lx.env`** 被 S2 的 header 构造读取, 无异常。
- **音质代号**: 两家脚本的 `quality` 表都覆盖我方四档(`128k/320k/flac/flac24bit`), 我方音质映射不需要扩展即可命中。
- **`musicInfo` 真实字段有用**: S1 的 `wy` 接口按 `rid/songmid/id` 取 id, S2 直接 `id=`; 依赖 `{keyword}` 的接口在带 `name/singer` 后才可能命中(本轮假 transport 不验证结果质量)。
- **装载期异步**(§3.3 未验证项, 现已有结论): 顶层 IIFE 里的 `lx.request` 在**装载期就会真的发出**(同步实现), 但其 Promise 要等宿主泵才会 settle ——
  所以「装载期发请求」不会崩也不会静默丢弃, 只是那些 `await` 之后的分支要等第一次调用时的泵循环才继续。
- **仍不建议**接混淆/自校验源(§5), 本轮也未验证 `lyric/pic` 动作(宿主不做这两个能力)。

## 7. 方法与限制
## 6. 方法与限制
- 仅抓 raw 明文(github raw 直链), 未 clone、未执行; S3 混淆体只做字符串级特征扫描。
- 上游契约以官方文档(lxmusic.toside.cn)为准, 脚本实测与之吻合; 未覆盖 iOS/预加载脚本差异。
- 未跑任何沙箱实测(只读车道); 第 1/2/8 条落地后需用 S1/S2 原文做真机冒烟(建议把两份 raw 存进 tests/fixtures/ 作黄金样本, 注意其内含第三方 API 地址, 仅本地)。
