# 接口实测笔记快照(2026-11-19 合并)

> 本文件是 10 份「批次接口实测笔记」的**原文合并**:`b4/b5/b7/b10/b12/b13/c1/c2/c3/wave9`, 共 908 行 / 10 个文件。
> 2026-11-19 文档精简时合成一份(同一体裁、同一生命周期 —— 批次完工后不再更新), **每节保留原小节标题与原文, 一字未删**
> (合并时只把标题级别下移两级以便嵌进本文件; 合并脚本逐行断言 `missing=0` 才删原文件)。
> 协议/风控/加解密的**结论层**在 `.pi/memory/notes-api.md`; 这里只放「当时抓到的原始响应长什么样」,
> 数字与字段形状均为抓取当日快照。

## 索引(按原批次顺序)

| # | 原文件 | 主题 |
|---|---|---|
| 1 | `b4-search-notes.md` | B4 搜索增强 · 接口实测(只读调研) |
| 2 | `b5-word-lyric-notes.md` | B5 逐字歌词 · 实测 notes(契约层, 2026-11-09) |
| 3 | `b7-playlist-write-notes.md` | B7 歌单写接口 · 真实响应笔记(2026-11-10) |
| 4 | `b10-radio-notes.md` | B10 电台补充(只读) · 实测笔记(2026-11-09) |
| 5 | `b12-digital-album-notes.md` | B12 数字专辑只读 · 实测笔记(2026-11-09) |
| 6 | `b13-ttml-lyrics-notes.md` | B13: AMLL TTML 逐字歌词第二来源（实测笔记） |
| 7 | `c1-artist-page-notes.md` | C1 歌手详情页重构 — 接口实测笔记 |
| 8 | `c2-lyric-source-quality.md` | C2: 逐字歌词来源质量抽样对比(2026-11) |
| 9 | `c3-mv-playback-notes.md` | C3 — MV 播放 接口实测笔记(2026-11-10, ncm raw 实抓; 原写 2026-11-22 是笔误) |
| 10 | `wave9-endpoint-notes.md` | Wave 9 · §4 剩余只读 endpoint 收尾笔记(2026-11-09) |

---

<a id="b4-search-notes"></a>

## 1. B4 搜索增强 · 接口实测(只读调研)

> 原文件: `docs/b4-search-notes.md`(2026-11-19 合并前); 标题已下调两级。

生成时间: 2026-11-07 · 二进制: core/target/debug/ncm(debug 构建, 已登录设备)
原始响应: 抓取时在 /tmp/b4/*.json(临时目录, 需要时按本文命令重抓) · 参数写法: `ncm raw <method> k=v ...`(位置参数 `key=value`, **不是** `--param`)

#### 接口清单与可用性

| 接口 | vendor 路径 | CLI 可达 | 用途 | 匿名/登录 | 形状稳定性 |
|---|---|---|---|---|---|
| search_multimatch | /api/search/suggest/multimatch (weapi) | ✅ raw | 联想「精准命中」实体(歌手/歌单/电台), 不是模糊联想 | 登录态已测; 需 cookie(weapi) | 不稳定: 字段随命中类型变化, 常见 `orders` 为空 |
| search_suggest (web) | /api/search/suggest/web (weapi) | ✅ raw | 联想下拉: 歌曲/歌手/专辑/歌单**实体卡片** | 同上 | 稳定(固定 4 段) |
| search_suggest (mobile) | /api/search/suggest/keyword (weapi) | ✅ raw `type=mobile` | 联想下拉: **纯关键词串**列表 | 同上 | 稳定(6 条, 无分页) |
| search_hot | /api/search/hot (default/明文) | ✅ raw | 热门搜索词(10 条) | 已登录态返回 200 | 稳定但字段极瘦 |
| search_default | /api/search/defaultkeyword/get (default) | ✅ raw | 默认搜索词 + 推荐可搜实体 | 同上 | 稳定, 但含大量埋点串 |
| search_hot_detail | /api/hotsearchlist/get (weapi) | ❌ **未接入 raw** | 热搜榜(带热度/排序) | 未测 | **本次无法验证** |
| search_match | /api/search/match/new (明文) | ❌ **未接入 raw** | 本地文件匹配线上歌曲(云盘/本地导入) | 未测 | **本次无法验证** |

关键结论: `search_hot_detail` 与 `search_match` 在 `core/crates/ncm-cli/src/main.rs` 的 raw 分支里
**没有对应 match arm**(grep `search_hot_detail|search_match|hotsearchlist` 于 crates/ 零命中),
请求会落到 `unknown raw method`。vendor 里两者实现都在(`vendor/ncm-api/src/api/search_hot_detail.rs`、
`search_match.rs`), 只是 CLI 没接线。**未改代码**(批次禁令), 故这两项本节只有静态契约, 无实测响应。

#### search_multimatch 真实响应

请求: `raw search_multimatch keywords=周杰伦 type=1` → `/api/search/suggest/multimatch`, body `{type:1, s:"周杰伦"}`

```json
{
  "code": 200,
  "result": {
    "orders": ["artist"],            // 命中类型的展示顺序, 同时是「有哪些 key」的清单
    "artist": [                       // 数组, 元素 = 完整 artist 对象
      {
        "id": 6452, "name": "周杰伦", "trans": "", "alias": ["Jay Chou", "周董"], "transNames": null,
        "albumSize": 48, "musicSize": 591, "mvSize": 9, "videoSize": 0, "fansSize": 19192162,
        "img1v1Id": 109951169164936940, "img1v1Id_str": "109951169164936940",
        "img1v1Url": "https://p3.music.126.net/.../109951169164936940.jpg",
        "picId": 109951169164936450, "picId_str": "109951169164936450",
        "picUrl": "https://p4.music.126.net/.../109951169164936450.jpg",
        "occupation": "歌手", "briefDesc": "", "officialTags": [], "searchCircle": null,
        "alg": "alg_search_precision_bestmatch_normal_artist_rewrite_{...}"   // 埋点, 必须忽略
      }
    ]
  }
}
```

四种输入实测(`type=1`):

| keywords | code | result keys | 说明 |
|---|---|---|---|
| `晴天` | 200 | `orders: []` | 有实体(周杰伦《晴天》)但**不返回 song 类**; 完全无命中 |
| `周杰伦` | 200 | `artist`(1), `orders:["artist"]` | 精确歌手命中 |
| `Taylor` | 200 | `orders: []` | 半截英文不命中(需 `Taylor Swift` 全名) |
| `zzzzqqqq` | 200 | `orders: []` | 无命中 |
| ``(空) | **400** | 无 result | 空关键词返回 `{"code":400}` 无 message |
| `薛` | 200 | `artist`, `playlist`, `orders:["artist","playlist"]` | 单字能出歌单 |
| `Taylor Swift` | 200 | `artist`, `voice`, `orders:["artist","voice"]` | 新增 `voice`(电台/播客节目)类型 |
| `Chinese Football` | 200 | `orders: []` | 独立乐队不命中 |

**无命中形态**: `code=200` + `result = {"orders": []}`, **不是** 404 也不是空数组顶层。客户端必须按
`orders` 判空, 不能按 key 存在与否(空命中时 artist/playlist 等 key 直接不存在)。
**无分页字段**: 无 `total`/`more`/`limit`/`offset`, 每类最多 1 条(实测 artist 恒 1 条, playlist 1 条)。
**无高亮字段**: 没有 `<em>` 片段、没有 matchRange。
**type 参数**: 实测 type=1 与 type=4 对 `晴天` 都是 `orders:[]`; `周杰伦 type=4` 返回 artist 与 type=1 完全一致(1151 字节同);
type=0 / 6 空结果。**该 type 在本账号+weapi 下不改变返回内容**, 不能用于筛选单曲/歌手/专辑/歌单/电台。
→ 结论: multimatch 不是「多类型搜索」, 只是**精确实体改写器**, 不承担 B4 的多类型匹配。

##### 命中类型 key 与含义(据实测出现的 key)
| key | 实体 | 最小可用字段 |
|---|---|---|
| `artist` | 歌手 | id, name, alias[], trans/transNames, picUrl, albumSize, musicSize, fansSize |
| `playlist` | 歌单 | id, name, coverImgUrl, playCount, trackCount, playlistType, uiPlaylistType, creator, description |
| `voice` | 电台/播客节目 | resourceId, resourceName, resourceType, internalType, baseInfo{…大对象…} |
| `song`/`album`/`djRadio` | 未在本次 8 次探测中出现, 按 vendor 约定存在但不可依赖 |

#### search_hot_detail

**本次未取得真实响应**(CLI 未接线), 仅静态契约:

```rust
// vendor/ncm-api/src/api/search_hot_detail.rs
POST /api/hotsearchlist/get   weapi   body = {}   // 无参数, 无分页
```

网络侧(历史 API 知识, 未经本仓库实测验证): 返回 `{code, data:[{searchWord, score, content, iconUrl, iconType, sourceUrl, alg}]}`,
即**热搜榜结构**(带热度 score 与排序), 与 `search_hot` 的 `{result:{hots:[{first,second,third,iconType}]}}` 不同 ——
后者只给词、无热度无排序字段。要用热度榜需先给 raw 分支加 `hotsearchlist` arm 或走 ncm-service 直调。
打正式接口前需重新实测(本报告不臆造响应)。

#### search_hot

`raw search_hot` → `/api/search/hot`, body `{type:1111}`, CryptoType::default(明文 linuxapi?):

```json
{"code":200,"result":{"hots":[
  {"first":"他只是经过","second":1,"iconType":1,"third":null},
  {"first":"薛之谦","second":1,"iconType":1,"third":null}
  /* 共 10 条 */}
]}
```

固定 10 条, 无 score/无 rank 字段(`second` 恒 1), 无分页。`first` 是要展示的词; `third` 目前恒 null。
**首屏兜底足够, 撑不起「热搜榜排名/热度」UI**。

#### search_suggest

##### web 模式(`raw search_suggest keywords=晴天`)
`/api/search/suggest/web`, body `{s:"晴天"}`, 返回**实体卡片**, 9815 字节:

```json
{"code":200,"result":{
  "order":["songs","artists","albums","playlists"],   // 固定 4 段
  "songs":[{"id":2652820720,"name":"晴天(深情版)","alias":[],"duration":278961,"fee":8,
            "copyrightId":743010,"mvid":0,"mark":17179877504,"status":0,"ftype":0,"rtype":0,"rUrl":null,
            "artists":[{"id":96154669,"name":"Lucky小爱","alias":[],"picUrl":null,"img1v1Url":"…","albumSize":0,"musicSize":0}],
            "album":{"id":255723258,"name":"晴天(深情版)","picId":109951173569626660,"picUrl":null,"size":1,"publishTime":1733068800000}}],
  "artists":[{"id":95904730,"name":"晴天","accountId":…,"alias":[],"trans":null,"picUrl":"…","albumSize":4,"musicSize":10}],
  "albums":[{"id":24838,"name":"晴天娃娃","picId":…,"size":10,"publishTime":1227196800000,"artist":{…}}],
  "playlists":[{"id":464535304,"name":"大提琴 | 如晴天，似雨天。","coverImgUrl":…,"trackCount":66,"bookCount":52085,"playCount":…,"creator":null}]
}}
```

条数: songs 4 / artists 1 / albums 2 / playlists 1(**不固定**, 由服务端定), 无分页字段。
字段差异: 这里 song 直接给 `duration`, 不给 privilege; playlist 用 `bookCount`(收藏)而非 `subscribedCount`。
空命中: `zzzzqqqq` → `{"code":200,"result":{}}`(**result 为空对象, 无 order 数组**)。

##### mobile 模式(`raw search_suggest keywords=晴天 type=mobile`)
`/api/search/suggest/keyword`, 返回**纯联想词** 6 条, 1189 字节:

```json
{"code":200,"result":{"allMatch":[
  {"keyword":"晴天周杰伦","type":1,"alg":"alg_suggest_other_Consume;Song___{}","feature":"","lastKeyword":""},
  {"keyword":"晴天霹雳 Chinese Football","type":1,"alg":"alg_suggest_other_UserAction;Song+Artist__Heard_{}"}
  /* 共 6 条 */}
]}
```

**无高亮/无命中前缀标记**, 只有整串 keyword。`alg` 里能反推意图(Consume/Lyric/UserAction), 但属埋点不可依赖。
无分页。空命中未测(web 侧为 result:{})。

#### search_default

`raw search_default` → `/api/search/defaultkeyword/get`:

```json
{"code":200,"message":null,"data":{
  "realkeyword":"植物人",                       // 实际搜索词 —— 用于搜索框占位
  "showKeyword":"❤️植物人 - Chinese Football",  // 展示文案(可带装饰)
  "searchType":1,
  "styleKeyword":{"keyWord":"❤️植物人","descWord":"Chinese Football"},
  "imageUrl":null, "source":null, "action":0, "gap":0, "logInfo":null,
  "bizQueryInfo":"{\"showQuery\":\"❤️植物人 - Chinese Football\",\"source\":\"default_search\",…}",  // JSON 字符串!
  "alg":"dq_0_…","trp_id":null,"trp_type":null
}}
```

注意: **顶层用 `data` 而不是 `result`**(各接口不一致); `bizQueryInfo` 是二次编码的 JSON 字符串, 内含
`bizIntentList[{searchQuery,itemType:"song",itemID,bestMatch}]`, 可直接点进对应实体但解析成本高。
无分页。每日变化, 不适合做静态文案。

#### search_match

**本次未取得真实响应**(CLI 未接线)。静态契约:

```rust
// vendor/ncm-api/src/api/search_match.rs
POST /api/search/match/new   CryptoType::default(明文)
body = {"songs": "[{\"title\":\"\",\"album\":\"\",\"artist\":\"\",\"duration\":0,\"persistId\":\"<md5>\"}]"}  // songs 是 JSON 字符串
```

语义是**本地文件→线上歌曲匹配**(云盘/导入), 与 B4 联想/热搜无关, 建议直接排除出 B4 范围。

#### 建议 DTO 字段

```rust
// ---- search_multimatch:/api/search/suggest/multimatch ----
#[derive(Deserialize)]
pub struct MultiMatchResp {
    pub code: i32,
    #[serde(default)]
    pub result: Option<MultiMatchBody>,
}
#[derive(Deserialize, Default)]
pub struct MultiMatchBody {
    #[serde(default)]
    pub orders: Vec<String>,          // 判空唯依据
    #[serde(default)]
    pub artist: Vec<MmArtist>,
    #[serde(default)]
    pub playlist: Vec<MmPlaylist>,
    #[serde(default)]
    pub voice: Vec<MmVoice>,
    // song/album/djRadio: 实测未出现, 用 #[serde(flatten)] extra: BTreeMap<String,Value> 兜底
}
pub struct MmArtist { pub id: u64, pub name: String, #[serde(default)] pub alias: Vec<String>,
    pub trans: Option<String>, #[serde(default)] pub trans_names: Vec<String>, /*rename transNames*/
    pub pic_url: Option<String>, /*rename picUrl*/ pub album_size: Option<i64>,
    pub music_size: Option<i64>, pub fans_size: Option<i64> }
pub struct MmPlaylist { pub id: u64, pub name: String, pub cover_img_url: Option<String>,
    pub play_count: Option<i64>, pub track_count: Option<i64>,
    pub playlist_type: Option<String>, pub ui_playlist_type: Option<String> }
pub struct MmVoice { pub resource_id: Option<i64>, pub resource_name: Option<String>,
    pub resource_type: Option<i64>, pub internal_type: Option<i64> } // baseInfo 大对象先丢

// ---- search_suggest(web):/api/search/suggest/web ----
pub struct SuggestResp { pub code: i32, pub result: Option<SuggestBody> } // 空命中 result == Some({}) 无 order
#[derive(Deserialize, Default)]
pub struct SuggestBody {
    #[serde(default)] pub order: Vec<String>,
    #[serde(default)] pub songs: Vec<SuggestSong>,
    #[serde(default)] pub artists: Vec<SuggestArtist>,
    #[serde(default)] pub albums: Vec<SuggestAlbum>,
    #[serde(default)] pub playlists: Vec<SuggestPlaylist>,
}
pub struct SuggestSong { pub id: u64, pub name: String, #[serde(default)] pub alias: Vec<String>,
    pub duration: Option<i64>, pub fee: Option<i32>, pub mvid: Option<i64>, pub status: Option<i32>,
    #[serde(default)] pub artists: Vec<BriefArtist>, pub album: Option<BriefAlbum> }
pub struct BriefArtist { pub id: u64, pub name: String, pub pic_url: Option<String> }
pub struct BriefAlbum { pub id: u64, pub name: String, pub pic_id: Option<i64>, pub size: Option<i64>,
    #[serde(default)] pub artists: Vec<BriefArtist> }
pub struct SuggestPlaylist { pub id: u64, pub name: String, pub cover_img_url: Option<String>,
    pub track_count: Option<i64>, pub book_count: Option<i64>, pub play_count: Option<i64> }

// ---- search_suggest(mobile):/api/search/suggest/keyword ----
pub struct SuggestKeywordResp { pub code: i32, pub result: Option<SuggestKeywordBody> }
pub struct SuggestKeywordBody { #[serde(default)] pub all_match: Vec<SuggestKeywordItem> } // rename allMatch
pub struct SuggestKeywordItem { pub keyword: String, #[serde(default)] pub r#type: i32 }

// ---- search_hot:/api/search/hot ----
pub struct HotSearchResp { pub code: i32, pub result: Option<HotSearchBody> }
pub struct HotSearchBody { #[serde(default)] pub hots: Vec<HotWord> }
pub struct HotWord { pub first: String, pub second: Option<i64>,
    pub third: Option<String>, pub icon_type: Option<i64> } // 无 rank/score

// ---- search_default:/api/search/defaultkeyword/get ----
pub struct DefaultKeywordResp { pub code: i32, pub message: Option<String>, pub data: Option<DefaultKeyword> }
pub struct DefaultKeyword { pub realkeyword: String, pub show_keyword: String,
    pub search_type: Option<i32>, pub style_keyword: Option<StyleKeyword>,
    pub image_url: Option<String> }
pub struct StyleKeyword { pub key_word: String, pub desc_word: Option<String> }
// bizQueryInfo 二次编码 JSON: 需要时 serde_json::from_str 二次解析, 不建议进 DTO

// ---- search_hot_detail(未实测, 仅按 vendor 路径预留) ----
pub struct HotSearchDetailResp { pub code: i32, #[serde(default)] pub data: Vec<HotSearchDetailItem> }
pub struct HotSearchDetailItem { pub search_word: String, pub score: Option<i64>,
    pub content: Option<String>, pub icon_url: Option<String>, pub icon_type: Option<i64>,
    pub source_url: Option<String> } // 字段名待实测校正
```

#### 坑

1. **最大坑: `search_multimatch` 不是多类型搜索, 且空命中伪装成成功。** `晴天`/`Taylor`/`zzzzqqqq`
   全部返回 `{"code":200,"result":{"orders":[]}}`, 与「确实命中 0 条」不可区分; 而 `code=200` 会让
   只看 code 的代码误判成功。B4 的多类型匹配必须走 `search_suggest(web)`(有 songs/artists/albums/playlists
   四类实体)或 cloudsearch, **不能**拿 multimatch 当数据源。另外 `type` 参数实测无效(1 与 4 同响应), 别用它做类型筛选。
2. `search_multimatch` 空关键词返回 `code=400` 且**无 message 字段**, 必须先本地 trim 判空再请求。
3. 顶层容器不一致: search_hot / search_suggest / search_multimatch 用 `result`; search_default 用 `data`;
   search_hot_detail 用 `data`(数组)。DTO 不能共用一个 envelope。
4. 空响应有两种形态: multimatch 是 `result.orders: []`; suggest(web) 是 `result: {}`(对象存在但无任何 key)。
   `Option<Body>` + `orders.is_empty()` 双判, 别只判 `result.is_none()`。
5. 所有响应都带 `alg` 埋点串(内含 `cvrUv/impressUv30d/strategy/fea` 与 hex), 体积常占一半;
   `voice.baseInfo` 单条可达数 KB。DTO 必须显式忽略, 否则解析慢且易因上游改字段炸掉。
6. 数值型 id 有 int64 精度风险: 同时给 `picId`(number, 109951173569626660) 与 `picId_str`/`img1v1Id_str`;
   Dart 侧 must 用 `*_str`, Rust 侧一律 u64->String 后再下发。
7. `search_hot_detail`/`search_match` 在 CLI raw 分支缺失, 想实测必须先解锁(改 main.rs 的 match arm 或
   ncm-service 直调), 本次按禁令未改。hot_detail 是唯一带热度/排序的接口, 做「热搜详情」绕不开它。
8. vendor 注释与实际路径不一致(`/// 对应 /search/hot/detail` 但实际 `/api/hotsearchlist/get`), 别照注释写测试。
9. multimatch 单次每类只回 1 条且无分页; 想翻页/要多候选只能换 suggest 或 cloudsearch。

<a id="b5-word-lyric-notes"></a>

## 2. B5 逐字歌词 · 实测 notes(契约层, 2026-11-09)

> 原文件: `docs/b5-word-lyric-notes.md`(2026-11-19 合并前); 标题已下调两级。

#### 端点与开关
- 逐字歌词走 vendor `lyric_new`(`/api/song/lyric/v1`), body 由 vendor 写死
  `cp:false, tv/lv/rv/kv/yv/ytv/yrv 全 0` + `id`。实测 yv:0 即会返回 `yrc`(有则给);
  query 里传其它参数无效(vendor 不读)。
- 对比旧 `lyric`(`/api/song/lyric`): 只有 lrc/tlyric/romalrc/klyric, **永远没有 yrc**。

#### 响应形状(实测 id=1901371647 / 5264842 / 418602084 / 516076896)
顶层: `code, klyric, lrc, qfy, sfy, sgc, tlyric, romalrc, yrc, ytlrc, yromalrc,
lyricUser, transUser`。各歌词子对象是 `{version, lyric}`;`version:0 / lyric:""` = 无。
- 晴天(186016, 2004): **无 yrc**(老歌没有逐字);新歌榜歌曲基本都有。
- `ytlrc`(yrc 翻译)与 `yromalrc`: 抽样 8+ 首全部为空(实测恒空), 翻译仍只能靠
  `tlyric`(普通 LRC, 时间戳为行首 ms, 可与 yrc 行 start 对齐)。

#### yrc 两种行格式(同一份文本混排)
1. 元数据/署名行(JSON): `{"t":0,"c":[{"tx":"作词: "},{"tx":"方文山","li":"...jpg","or":"orpheus://..."}]}`
   - `t` 是行首 ms, 可为负(实测 -1000/-667);无数词级时间;无行尾时长。
2. 逐字行: `[start,duration](wStart,wDur,0)字(wStart,wDur,0)字...`
   - 实测样例:
     ```
     [25120,7400](25120,1190,0)你(26380,450,0)陪(26830,340,0)我(27170,300,0)步(27470,350,0)入(27820,360,0)蝉(28180,470,0)夏 (29400,440,0)越...
     [21960,7590](21960,470,0)让(22430,2610,0)我(25400,280,0)与(25680,640,0)你(26320,1940,0)握(28290,750,0)别
     ```
   - 词文本可含空格/标点(`夏 `带尾空格);第三元恒 0(语义未知)。
   - 词 start 可与行 start 不等(前奏对齐), 词时长可为 0。

#### song_lyrics_mark(只读 dump, 未接)
`/api/song/play/lyrics/mark/song`, body `{"songId": id}`;已加进 CLI `ncm raw song_lyrics_mark id=..`。
add/del(`/add` `/del`)是写操作, 本批禁接。

#### 实现事实(契约层)
- domain: `WordItem{start_ms,end_ms,text}` / `WordLyricLine{start_ms,end_ms,words}` /
  `WordLyric{lines, translation_lines, has_word_timing, raw}`;全部 serde(default)。
- 解析失败退化: 逐字行头 `[..]` 解析不出 → 整行原文作为单个整词(start/end=0),
  绝不 panic、绝不丢行;JSON 署名行保留为单词行(`has_word_timing=false`)。
- 翻译: `tlyric` 按 LRC 解析后按行 start_ms 精确对齐到 `WordLyric.translation_lines`。
- provider: trait 新增 `word_lyric`, 默认 `unsupported`;netease 实现(复用 `Capability::Lyric`),
  内部调 `client.lyric_new`;CAPABILITIES 不变。
- FFI 导出 `word_lyric(track)`;CLI `ncm yrc <songId>`。
- 已知遗留: `ytlrc/yromalrc` 实测恒空;负时间戳按 clamp 0 处理;klyric 实测恒 ver0。

#### CLI 验证实录
- `ncm yrc 5264842`: 24 行 / 162 词 / 逐字有 / 翻译行 0;逐字行与署名行混排均正确。
- `ncm yrc 186016`(晴天): "(no yrc: 该曲无逐字歌词)" —— 退化路径符合预期。
- `ncm raw song_lyrics_mark id=186016`: `{"code":200,"data":{"markCountList":[],"markVOList":[]}}`(本账号未标记过)。

#### 门禁(2026-11-09)
- `cargo test --workspace --exclude ncm-api-rs`: 全绿(domain 22 / service 92(+3) / provider 2 / playback 1)。
- `cargo build -p ncm_ffi`: 通过(0 warning)。
- codegen 一次通过;ui/lib/src/rust/* 仅生成物。
- `cd ui && dart analyze`: **0 error**(30 info, 全部为既有 lint 风格)。
- `cd ui && flutter test`: **215 passed**(含 frb_smoke, 未复现偶发挂)。
- 未跑 tools/ci.sh / flutter build / 未 commit。

#### 改动文件清单
- core/crates/ncm-domain/src/word_lyric.rs(新) + lib.rs(导出)
- core/crates/ncm-provider/src/lib.rs(trait word_lyric 默认 unsupported)
- core/crates/ncm-service/src/netease.rs(parse_word_lyric_body + 实现 + 3 单测)
- core/crates/ncm-ffi/src/api.rs(WordItemDto/WordLyricLineDto/WordLyricDto + word_lyric_lines)
- core/crates/ncm-cli/src/main.rs(`ncm yrc` + raw 补 song_lyrics_mark + 用法清单)
- ui/lib/src/rust/*(codegen)
- 本文件(新)

<a id="b7-playlist-write-notes"></a>

## 3. B7 歌单写接口 · 真实响应笔记(2026-11-10)

> 原文件: `docs/b7-playlist-write-notes.md`(2026-11-19 合并前); 标题已下调两级。

> 批次: 歌单写接口 + 播放队列「存为歌单」(B2④ 最后一项)。
> 抓包方式: 临时 example `core/crates/ncm-service/examples/b7_probe.rs`(跑完已删)直连 vendor `ApiClient`,
> 登录态为本地测试号(#1822714196),数据目录 `~/.local/share/ncm`。**必须清代理直连**(clash 7890 会把
> weapi TLS 握手掐成 `tls handshake eof`);Query 必须带 `platform_profile().ua`(与 cookie os 形态配套),
> 否则服务端回 `{code:500, msg:"请求异常,请稍后重试"}`。

#### 1. playlist_create(/api/playlist/create, weapi)

请求参数: `name` / `privacy`(0=公开) / `type`="NORMAL"。

```json
{"code":200,"id":18580697682,"playlist":{"id":18580697682,"name":"B7抓包临时歌单 20261110-023344","privacy":0,
"trackCount":0,"userId":1822714196,"subscribedCount":0,"playCount":0,"coverImgUrl":"https://p1.music.126.net/...",
"createTime":1794278024690,"tags":[],"subscribers":[],"tracks":null,"description":null,...}}
```

- **新歌单 id 字段名: 顶层 `id`(数字)**,`playlist.id` 是同值冗余(现有 `create_playlist` 的 `u64_of(body,"id").or_else(playlist.id)` 双路提取正确)。
- `playlist.privacy` 回显 0;`trackCount`=0。

#### 2. playlist_tracks(/api/playlist/manipulate/tracks, op=add)

请求参数: `op`="add" / `pid`=<歌单id> / `tracks`="186016,26305527"(vendor 内部拆逗号后 JSON 序列化成
**字符串数组** 再放 `trackIds` 字段)/ `imme`="true"。

```json
{"cloudCount":0,"code":200,"count":2,"coverImgId":"109951167894836691",
"coverImgUrl":"http://p3.music.126.net/.../109951167894836691.jpg","trackIds":"[186016,26305527]"}
```

- **响应里的 `trackIds` 是字符串**(数组 JSON 文本),不是数组——不要当数组解析。
- `count`=2 = 服务端接受的成功数;批量去重后返回的 count 可小于提交数。
- 成功时**没有** message/msg 字段。
- 判定成功只看 `code==200`。

#### 3. playlist_delete(/api/playlist/delete)

```json
{"code":200,"data":null,"message":null,"msg":null}
```

#### 4. 清理记录

- 抓包新建 `B7抓包临时歌单 20261110-023344`(id=18580697682)→ add 2 首(186016/26305527)→
  `playlist_delete` 返回 code=200,**已删除**(只删了本次自建的这个)。

#### 5. 现状与本批落地(防复述过时结论)

- provider/FFI **已有一组**歌单写接口(v0.2.2 收藏到歌单流程接的): `create_playlist(name)` /
  `add_to_playlist(pid, 单首)` / `delete_playlist` / `rename_playlist` / `update_playlist_desc` /
  `remove_from_playlist`,能力键 `Capability::PlaylistEdit` 已在 `CAPABILITIES`。
- 本批新增: ①`create_playlist` 签名扩展 `privacy` 参数(vendor 默认 0,不传会撞上「请求异常」的
  隐式默认——显式传更稳); ②**批量** `playlist_tracks_add(pid, song_ids)`(vendor `playlist_tracks` 原生支持
  逗号分隔多 id,现有 `add_to_playlist` 只有一首); ③domain `CreatedPlaylist`/`PlaylistEditResult` + parse 单测;
  ④FFI `createPlaylist(name, privacy)` / `playlistTracksAdd(pid, songIds)`; ⑤队列面板「存为歌单」。

#### 6. 落地清单(本批终稿)

- **domain** `ncm-domain/src/playlist_edit.rs`(新): `CreatedPlaylist{id,name}` / `PlaylistEditResult{code,message,count,ok}`,全字段
  `serde(default)`。**parse 函数放 `ncm-service/src/netease.rs`**(`parse_created_playlist`/`parse_playlist_edit_result`)——
  ncm-domain 是纯数据 crate 不依赖 serde_json(与 ttml.rs 手写解析同一纪律),任务书里「parse 单测在 domain」按此口径落在 service。
- **provider**: `create_playlist` 扩展 `privacy: u8` 参数(改签名,调用点: FFI + main.dart 各 1);
  新增 `playlist_tracks_add(playlist_id, &[u64])`(默认 unsupported)。`Capability::PlaylistEdit` 已在
  `CAPABILITIES` 且 `capabilities_include_new_apis` 已覆盖,无需新增能力键。
- **FFI**: `createPlaylist(name, privacy)`(Dart privacy: int)/ `playlistTracksAdd(playlistId: BigInt, songIds: Uint64List)`
  (frb 把 `Vec<u64>` 映射成 frb 自带的 `Uint64List`,**不是** `dart:typed_data` 的,import 要走
  `package:flutter_rust_bridge/flutter_rust_bridge.dart show Uint64List`)。codegen 已跑一次。
- **UI**: `PlayQueueSheet` 头部新增「存为歌单」(`Icons.playlist_add`,空队列不渲染、挂起置灰);面板只把
  **去重后**的快照经 `onSaveAsPlaylist` 回调交宿主(可脱机单测);宿主 `main.dart` `_saveQueueAsPlaylist`
  = 列我的歌单 sheet(新建行 + myPlaylists)→ 新建对话框(默认名「来自播放队列 M-D HH:mm」,
  create(privacy=0) → playlistTracksAdd)或选已有歌单直接批量加 → toast「已存入《名字》, N 首」/失败 friendlyError。
  「我喜欢的音乐」(special)也走 playlistTracksAdd(官方网页端同一接口)。
- **测试**: Rust +6(netease.rs parse 单测,真实响应片段); Dart +6(`ui/test/queue_sheet_save_test.dart`:
  空队列无按钮 / 非空出现 / 成功回调收到快照 / 去重 / 防重复点击 / 失败不崩可重试)。
  **2026-11-18 更新**: 「存为歌单」整条链路已按用户反馈删除, 该测试文件与宿主 `_saveQueueAsPlaylist` 一并移除;
  本节其余接口结论(create / 加曲 / code=500 半成功)仍有效。
- **门禁数字(2026-11-10 本批实测)**: `cargo test --offline --workspace --exclude ncm-api-rs`
  218(HEAD 基线)→ **224**(+6,零删除;vendor smoke 4 例联网项按记录在案口径 WARN 不阻塞);
  `dart analyze` **0 error/0 warning**(41 info 均为既有 lint);`flutter test --exclude-tags network`
  504 → **510**(+6);`tools/api-coverage.sh`: vendor 123/123(100%)不变,FFI 导出 139→**140**
  (`playlistTracksAdd`,有 UI 入口),无 UI 入口维持 4(`cache_stats`/`eq_profile_normalize`/`player_tuning`/`word_lyric_with_fallback`)。

#### 7. 模拟器实测(emulator-5554, 2026-11-10)

- **前提修复**: 模拟器 App 登录态随快照回滚丢失 → 用宿主 CLI 测试号(#1822714196 下去玩)的 `identity.json`
  `run-as` 灌入 `files/ncm/`(重启 App 生效),全程无凭据明文操作。
- **路径**: 搜索 The Weeknd → 「下一首播放」×2(队列恰好 2 首,播放条 1/2)→ 详情页「队列 2」→ 面板头部
  「存为歌单」→ sheet(新建行 + 真实 myPlaylists)→ 新建对话框(**默认名已预填**「来自播放队列 11-10 11:52」)→ 创建。
- **结果(双重验证)**:
  - toast「已存入《来自播放队列 11-10 11:52》, 2 首」;
  - sheet 列表立即出现「来自播放队列 11-10 11:52 | 2 首」;
  - CLI `ncm playlists`:`[18580899619] 来自播放队列 11-10 11:52 (2 首)`;
  - CLI `ncm playlist 18580899619`:song_count=2,**正是队列两首**(After Hours 1424460203 + Hong Kong 3456047164)。
- **幂等**: 再走「选已有歌单」把同 2 首重复添加 → 服务端跳过已存在(本批实测与协议预期一致),歌单仍 2 首。
- **logcat**: 全流程 0 崩溃(FATAL/SIGSEGV 扫描为空)。
- **实测顺带修的缺陷**: `_saveQueueAsPlaylist` 里 `retryNetwork(myPlaylists)` 失败原本被面板 catch 静默吞掉
  → 补 try/catch + toast「存为歌单失败: ...」(任务书「失败给可读文案」口径)。
- **已知观察(非本批 bug)**: 创建成功后连续两层 sheet(选择 sheet + 队列面板)偶发渲染空白(语义树空、无异常、
  进程活),force-stop 重启即恢复;功能与数据无影响,模拟器 Impeller/OpenGLES 环境的已知类问题,后续批次观察。
- **清理**: 实测歌单「来自播放队列 11-10 11:52」与抓包孤儿「B7抓包临时歌单 20261110-023224」(后者是
  create 返回 code=500 但服务端实际入库的**孤儿**——「请求异常」也可能半成功,删号见此)均已 `playlist_delete`
  (ok=true),CLI 复核 grep=0。截图 5 张在 `.pi/artifacts/b7/`。
- **代码层落地小结**: 任务书「FFI 无歌单写接口」的口径已过时——v0.2.2 已有单首版收藏到歌单(`add_to_playlist`)
  与 `create_playlist(name)`;本批实际增量 = create 加 `privacy` 参数 + **批量** `playlist_tracks_add` +
  domain DTO/parse + UI「存为歌单」,vendor 侧零改动(mod.rs 早已注册)。

<a id="b10-radio-notes"></a>

## 4. B10 电台补充(只读) · 实测笔记(2026-11-09)

> 原文件: `docs/b10-radio-notes.md`(2026-11-19 合并前); 标题已下调两级。

> 用 `ncm raw <method> k=v`(本批给 CLI raw 分支补了 10 个接线)实测;登录态 = 本机已登录账号,匿名 = 空 NCM_DATA_DIR。
> 全部接口匿名都通(无登录门槛);所有调用均为只读 GET/查询,不做任何写操作。

#### 实测响应形状

##### dj_catelist(`/api/djradio/category/get`, weapi, 无入参)
```json
{"categories":[{"id":3,"name":"情感","pic56x56Url":"https://…","pic56x56IdStr":"…","picWebUrl":"https://…",…}]}
```
- **顶层直接 `categories` 数组,没有 `code`**(不查 code,判断空数组即可)。
- 每类 10 个 pic 字段,实际只用 `id/name/pic56x56Url`(有 https)。
- 匿名/登录形状一致。

##### dj_category_recommend(`/api/djradio/home/category/recommend`, weapi, 无入参)
```json
{"code":200,"data":[{"categoryId":3,"categoryName":"情感","radios":[
  {"id":526564706,"name":"伴听FM","picUrl":"https://…","playCount":6555956,"programCount":18,
   "subCount":0,"subed":false,"lastProgramName":"…","rcmdText":"用小半的我筑温暖的你",
   "radioFeeType":0,"feeScope":0,"alg":"featured","icon":{"type":"text","value":"独家",…}|"icon":null}]}]}
```
- `data` 是**数组**,每项一个分类 + 该分类下 3 个推荐电台。
- `icon` 可为 null(独家标签);radioFeeType 0=免费。
- 匿名也通(返回同一批精选)。

##### dj_recommend_type(`/api/djradio/recommend`, weapi, 入参 type=cateId)
- **默认 `type=0` 时 `djRadios` 为空数组**(type=0 不是"全部");传真实分类 id(如 `type=2001` 创作翻唱)才有数据。
```json
{"code":200,"djRadios":[{"id":…,"name":"…","picUrl":"https://…","playCount":…,"programCount":…,
  "subCount":…,"desc":"…","descPicList":[…],"category":"创作翻唱","categoryId":2001,"dj":{…}}],
 "hasMore":false}
```
- 字段与现有 `dj_hot` 形状一致(可复用 DjRadio DTO 的宽松解析);分页字段 `hasMore`(实测 false,推荐接口页很小)。

##### dj_toplist(`/api/djradio/toplist`, weapi, 入参 limit/offset/type(0=新/1=热, vendor 把 "new"→0 "hot"→1))
```json
{"code":200,"toplist":[{"rank":1,"lastRank":3,"score":116563,"category":"创作翻唱","categoryId":2001,
  "id":792868378,"name":"一条小团团OvO的翻唱合集","picUrl":"http://…","playCount":131838544,
  "programCount":56,"subCount":456521,"creatorName":"…","dj":{"nickname":"…","avatarUrl":"http://…"},
  "rcmdtext":"…","createTime":…,"radioFeeType":0,"feeScope":0}]}
```
- **顶层 `toplist`**;元素是 DjRadio 超集,`rank/score/lastRank` 是榜单特有。
- `type=hot`(1)也实测通;限 100 条。注意 `rcmdtext` 全小写(不是 rcmdText)。

##### dj_toplist_hours(`/api/dj/toplist/hours`, weapi, 入参 limit) · dj_toplist_newcomer(`/api/dj/toplist/newcomer`, limit/offset) · dj_toplist_popular(`/api/dj/toplist/popular`, limit)
```json
{"code":200,"data":{"list":[{"rank":1,"lastRank":2,"id":287921940,"nickName":"开心锤锤",
  "avatarUrl":"http://…","score":3581801,"userFollowedCount":79757,"userType":4,
  "avatarDetail":{"identityIconUrl":"…","identityLevel":1,"userType":4}|"avatarDetail":null,
  "liveId":0,"liveStatus":-1,"mainAuthDesc":"","roomNo":0}]}}
```
- 三个榜**同形状**:`data.list` 里是**主播**(用户)不是电台;字段 `nickName`(驼峰)、`avatarUrl`、`score`。
- newcomer 的条目 `avatarDetail` 常 null;popular 第一名实测是薛之谦(2157万粉)。

##### dj_toplist_pay(`/api/djradio/toplist/pay`, weapi, 入参 limit)
```json
{"code":200,"data":{"list":[{"rank":1,"lastRank":1,"id":988499285,"name":"猫小九历险记 | 大型奇幻冒险剧",
  "picUrl":"https://…","creatorName":"奇喵君故事","score":11104632}]}}
```
- 付费精品榜是**电台**不是主播:有 `name/picUrl/creatorName`,无 playCount/programCount。

##### dj_program_toplist(`/api/program/toplist/v1`, weapi, 入参 limit/offset)
```json
{"code":200,"toplist":[{"rank":1,"lastRank":3,"program":{"id":…,"name":"…","coverUrl":"https://…",
  "duration":92400,"description":"…","dj":{"nickname":"…"},"commentThreadId":"A_DJ_1_…",
  "createTime":…,"auditStatus":10,…}}]}
```
- 顶层 `toplist`,每项 `{rank,lastRank,program}`,program 与现有 `dj_program` 元素同形状(可复用宽松解析)。

##### dj_subscriber(`/api/djradio/subscriber`, weapi, 入参 id(电台id)/limit/offset(用 time=-1 游标)/total=true)
```json
{"code":200,"hasMore":true,"subscribers":[{"userId":1594251132,"nickname":"…","avatarUrl":"http://…",
  "signature":"…","subscribeTime":1793611157940,"userType":0,"gender":1,…}]}
```
- 顶层 `hasMore` + `subscribers`(完整 user 对象);分页游标 vendor 用 `time`(取上一页最后 subscribeTime),不是 offset。

#### 匿名 vs 登录
- 10 个接口匿名全部 200 通,字段一致;B10 全部入口**不要求登录**(与 B12 数字专辑相反)。

#### 文档口径 vs 实测差异
1. Node 文档说 `dj_recommend_type` 不传 type 也行 —— 实测 type=0 返回空 `djRadios`,必须传真实分类 id。
2. 官方文档把 hours/newcomer/popular 说成"电台榜" —— 实测是**主播(用户)榜**;只有 pay 榜是电台。
3. `dj_toplist` 的 `type` Node 版给 "new"/"hot" 字符串,vendor 映射成 0/1;UI 侧直接传数字语义。
4. `dj_catelist` 无 code 字段,与绝大多数接口不同,解析不能依赖 code==200。
5. `dj_toplist` 元素的推荐语字段是 `rcmdtext`(全小写),与 `dj_category_recommend` 的 `rcmdText`(驼峰)不一致。

#### 决策
- 10 个接口全部只读接入。**不做**:`dj_sub`(订阅,写)、`dj_difm_channel_subscribe/unsubscribe`(写,语义未验证)、
  `dj_paygift`(付费礼包,导购性质)、`dj_difm_*` 其余 4 个(私人电台语义未验证,不碰)。
- provider 新增聚合:
  - `radio_categories` → dj_catelist + dj_category_recommend(首页一次拉分类+精选)。
  - `radio_recommend(cate_id)` → dj_recommend_type。
  - `radio_toplist(kind)` → 按 kind 分发 hot/newcomer/pay/popular/hours(主播榜统一 DTO)/program(节目榜)。
  - `radio_subscribers(id)` → dj_subscriber。
- UI:`radio_explore_page.dart` 分类胶囊 → 推荐电台 → 榜单页签;入口 = discover.dart「推荐播客」标题行「更多」。
- CLI:`ncm radio-cats` / `ncm radio-top <kind>` / `ncm radio-sub <id>`。

#### 落地与回归(2026-11-09)

| 步骤 | 结果 |
|---|---|
| Rust 单测 | `ncm-service` 83→**89** 全绿(+6: categories 实测形状/缺 categories 兜底、picks 实测/缺 data、toplist radios 实测+pay 形状+lastRank=-1、主播榜实测/缺 data.list、节目榜实测/缺 program 跳过、订阅者实测/空页) |
| CLI | `ncm radio-cats`(19 分类) / `radio-rec 2001`(10 台) / `radio-top popular`(87 条主播) / `radio-top program`(100 条) / `radio-sub 526564706` 全链路实测通过 |
| codegen | `flutter_rust_bridge_codegen generate` 一次成功 + `cargo build -p ncm_ffi` 通过 |
| analyze / test | `dart analyze` 0 error(仅 info); `flutter test` **203 通过 +1 skip 全绿**(新增 radio_explore_page_test 6 例: 首页渲染/分类切换与切回精选/推荐空态+主播榜/错误态可重试/行点击回调/300dp+1.25 不溢出); recommend_view_test 的「更多」计数 2→3(新入口) |
| 设备 | 见下 |

#### 设备实测(a36 / emulator-5554, 1080x2400)

| 步骤 | 结果 |
|---|---|
| 入口 | 推荐 → 推荐播客标题行「更多」→ 电台广场页打开 |
| 精选 | 分类胶囊(精选/情感/音乐播客/有声书/脱口秀…) + 各分类精选列表(伴听FM 18集·656万 等), 图片/计数正常 |
| 分类切换 | 点「情感」→ `dj_recommend_type` 拉到「情感」推荐电台 10 条, 标题「情感」推荐电台 |
| 榜单 | 热门(带 rank 角标 1/2/3 高亮, 一条小团团OvO 13184万) / 主播(薛之谦 热度 259万 · 粉丝 2158万) 实测通过 |
| 行点击 | 点精选行 → showPodcastDetail(伴听FM, 18 个节目 · 播放 6555957 次, 节目列表加载) |
| 空态/错误态 | `svc wifi disable + svc data disable` 后进页: 「加载失败: 网络不稳定, 已自动重试仍失败, 请稍后重试」+ 重试按钮; 恢复网络点重试正常回填(截图 /tmp/b10_empty.png → /tmp/b10_retry.png) |

截图: /tmp/b10_explore.png(精选) /tmp/b10_category.png(分类推荐) /tmp/b10_cat_bottom.png(热门榜) /tmp/b10_dj.png(主播榜) /tmp/b10_detail.png(电台详情) /tmp/b10_empty.png(错误态) /tmp/b10_retry.png(重试恢复)

#### 改动文件清单
- core/crates/ncm-domain/src/lib.rs: +12 个 Radio* DTO(serde default)
- core/crates/ncm-provider/src/lib.rs: +Capability::RadioExplore + 4 个默认 unsupported 方法
- core/crates/ncm-service/src/netease.rs: +6 个 parse_* + 4 个 provider 实现 + 6 个单测; CAPABILITIES +1
- core/crates/ncm-ffi/src/api.rs: +7 个 DTO + 4 个 FFI 函数(radioExploreHome/radioRecommend/radioToplist/radioSubscribers)
- core/crates/ncm-cli/src/main.rs: raw 分支 +10 接线; 新命令 radio-cats/radio-rec/radio-top/radio-sub; 文件头用法注释
- ui/lib/src/rust/*(codegen 一次) + ui/lib/src/radio_explore_page.dart(新) + ui/lib/src/recommend_view.dart(「更多」入口) + ui/test/radio_explore_page_test.dart(新, 6 例) + ui/test/recommend_view_test.dart(「更多」计数 2→3)

#### 遗留
- dj_program_toplist 的节目榜 UI 没放页签(榜单页签只做了 热门/新晋/付费/主播), Rust/FFI/CLI 已通(`ncm radio-top program` 实测 100 条), 后续可加「节目」页签。
- `dj_toplist` 实测返回 100 条且无 hasMore 字段, 未做翻页(够展示)。
- 主播榜行为只读展示, 不跳用户主页(现有 UI 无用户主页路由)。
- `dj_difm_*`(6 个)与 `dj_sub`/`dj_paygift` 判定不做(见上「决策」)。

<a id="b12-digital-album-notes"></a>

## 5. B12 数字专辑只读 · 实测笔记(2026-11-09)

> 原文件: `docs/b12-digital-album-notes.md`(2026-11-19 合并前); 标题已下调两级。

> 用 `ncm raw <method> k=v`(本批给 CLI raw 分支补了 4 个接线)实测;登录态 = 本机已登录账号,匿名 = 空 NCM_DATA_DIR。

#### 实测响应形状

##### digital_album_purchased(`/api/digitalAlbum/purchased`, weapi, 入参 limit/offset, total 固定 true)
登录态:
```json
{"code":200,"total":2,"paidAlbums":[{"albumId":120605500,"albumName":"冀西南林路行",
  "artist":{"id":13223,"name":"万能青年旅店"},"cover":"https://p3.music.126.net/…",
  "paidTime":1638063971559,"boughtCount":1,"sub":false,"channel":0,"valid":99,
  "aliasName":"","transName":null,"fromUser":null,"artists":[…]}]}
```
- **顶层是 `paidAlbums` + `total`**,没有 `data` 包装;分页字段只有 `total`(不是 hasMore/more)。
- `paidTime` 是毫秒时间戳;`boughtCount` 是购买数量;封面字段叫 `cover`(不是 picUrl)。
- 匿名:服务端直接报错(vendor 抛 `Authentication required`,HTTP 301 族)。

##### song_purchased(`/api/single/mybought/song/list`, weapi, 入参 limit/offset)
```json
{"code":200,"data":{"count":0,"hasMore":false,"list":[]},"message":""}
```
- `data.{count,hasMore,list}`;本账号没有已购单曲,`list` 元素形状未实测到(宽松取 id/name/artist 常见字段)。

##### digital_album_detail(`/api/vipmall/albumproduct/detail`, weapi, 入参 id)
```json
{"code":200,"hasAlbum":true,"boughtCnt":1,"canBuy":true,"vipType":11,
 "album":{"albumId":120605500,"albumName":"冀西南林路行","artistName":"万能青年旅店",
   "artistId":13223,"artistNames":"万能青年旅店","coverUrl":"https://…","coverDocId":"…"},
 "product":{"price":22.0,"pubTime":1608566401510,"saleNum":0,"tags":["独家","无损品质收听＆下载"],
   "descr":[{"resource":"…","type":1}],"buynotes":[…],"albumfee":4,"finished":true},
 "singleSongProductId":5933052,"board":{…}}
```
- 专辑字段在 **`album`**(不是 detail 本体),价格/上架时间/标签在 `product`。
- `descr` 是分段文案数组(`resource`+`type`),`</br>` 是分隔占位,拼简介时要过滤。
- `product.saleNum` 这里恒 0,真实销量走 sales 接口。

##### digital_album_sales(实际端点 `/api/vipmall/albumproduct/album/query/sales`, weapi)
- vendor 入参键是 **`albumIds`**(CLI query 键名 `ids`,即 `ncm raw digital_album_sales ids=120605500`)。
```json
{"code":200,"data":{"120605500":1300052}}
```
- `data` 是 **专辑id字符串 → 销量数字** 的 map;不是数组,没有 bizType/limit/offset(工单里的说法与 vendor 不符,以 vendor 为准)。

#### 决策
- 4 个接口全部只读;`digital_album_ordering`(下单)不做。
- 分页:`purchased` 用 `total` 与已取条数判没有更多;`song_purchased` 用 `data.hasMore`。
- UI:已购专辑 + 已购单曲两个列表;详情用页内 BottomSheet 展开(封面+价格+销量+标签)。
- 匿名下 purchased/song_purchased 服务端报 auth 错,UI 未登录不显示入口。

#### 落地与回归(2026-11-09)

| 步骤 | 结果 |
|---|---|
| Rust 单测 | `ncm-service` 78→83 全绿(+5: purchased 实测形状 / 缺 paidAlbums / song_purchased 分页+空 / detail 实测+缺 product+缺 album 报错 / sales map) |
| CLI | `ncm digital 120605500` / `digital-purchased` / `purchased-songs` / `digital-sales` 全链路实测通过;`digital-sales` 实测返回 1300053(销量每天在涨) |
| codegen | `flutter_rust_bridge_codegen generate` 一次成功 + `cargo build -p ncm_ffi` 通过(content hash 一致) |
| analyze / test | `flutter analyze --no-fatal-infos` 28 条全 info、0 error 0 warning;`flutter test` 192 通过 +1 skip 全绿(新增 digital_album_page_test 5 例:空态/列表/错误态/BottomSheet/窄屏 300dp+1.25 字号) |
| 设备 | a36(5554) 走查:我的页 → 「数字专辑(只读)」→ 已购 2 张(伍六七 2023-06-17 / 冀西南林路行 2021-11-28)→ BottomSheet 详情(¥22.0 · 独家/无损 · 销量 130.0万 · 简介)。截图 `/tmp/b12_purchased.png`、`/tmp/b12_detail.png` |
| 未登录 | 入口按 `widget.loggedIn` 过滤不显示;provider 侧另有 MUSIC_U 检查兜底(auth 错误) |

#### 遗留
- `song_purchased` 本账号 list 为空,元素真实形状未实测(DTO 字段已做两种命名兼容,等有已购单曲的账号再核)。
- `tools/build-android.sh` 在本机报 `BUILD FAILED in 1s`(疑似 gradle/环境收口问题);本批改用 `cd ui && flutter build apk --debug` 构建,产物可装可用;ci.sh 收口由编排者复核。

<a id="b13-ttml-lyrics-notes"></a>

## 6. B13: AMLL TTML 逐字歌词第二来源（实测笔记）

> 原文件: `docs/b13-ttml-lyrics-notes.md`(2026-11-19 合并前); 标题已下调两级。

日期：2026-11-10

#### API 实测

- 端点：`GET https://api.amll.dev/v1/lyrics/get?ncmMusicId=<id>`
- 响应为 JSON：`{"status":200,"data":{...}}`；**内联 TTML 全文在 `data.lyrics` 字段**（字符串）。
- `data` 其他字段：id/filename/createdAt/musicNames/artistNames/albumNames/ncmMusicIds/qqMusicIds/appleMusicIds/spotifyIds/isrcs/authorIds/authorUsernames。
- 无 TTML 的曲目（如 ncmMusicId=99999999）：HTTP 404，body `{"status":404,"error":"Not Found","message":"No lyrics found for the provided query."}` ⇒ 我们映射为 `Ok(None)`。
- 未观察到 rate limit 头；客户端仍设 5s 超时 + 磁盘缓存兜底。

##### curl 复现

```bash
curl -s --noproxy '*' 'https://api.amll.dev/v1/lyrics/get?ncmMusicId=186016'   # 晴天，200
curl -s --noproxy '*' 'https://api.amll.dev/v1/lyrics/get?ncmMusicId=99999999' # 404
```

#### TTML schema 实测（晴天片段，截断）

```xml
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="..." xmlns:itunes="..." xmlns:amll="...">
  <head><metadata xmlns=""><ttm:agent type="person" xml:id="v1"/>
    <amll:meta key="ncmMusicId" value="186016"/> ...</metadata></head>
  <body dur="04:25.541">
    <div xmlns="" begin="00:29.231" end="04:25.541">
      <p begin="00:29.231" end="00:32.723" ttm:agent="v1" itunes:key="L1">
        <span begin="00:29.231" end="00:29.692">故</span>
        <span begin="00:29.692" end="00:30.057">事</span> ...
      </p> ...
    </div>
  </body>
</tt>
```

要点：
- 时间格式 `m:ss.mmm`（也可能出现纯秒，解析器两种都支持）。
- 逐字在 `<p>` 内联 `<span begin end>text</span>`；无文本的 span（纯计时/间奏）跳过。
- `ttm:role="x-translation"` 的 `<p>` 为行译文、`x-roman` 为罗马音（解析保存，UI 暂不用）；`x-bg` 背景声跳过。
- 缺 end 的行/span 用下一行 begin 兜底。

#### 质量/回退策略

`word_lyric_with_fallback(song_id)`：yrc 优先 → yrc 无逐字或逐字 span 覆盖率 < 0.6（覆盖行数比例，阈值见代码注释）→ 试 TTML（磁盘缓存）→ 都没有回退行级歌词。

#### 缓存

- 命中：`dataDir/ttml/<id>.ttml`
- 无数据/解析失败：`dataDir/ttml/<id>.none` 标记，避免反复打 API。

<a id="c1-artist-page-notes"></a>

## 7. C1 歌手详情页重构 — 接口实测笔记

> 原文件: `docs/c1-artist-page-notes.md`(2026-11-19 合并前); 标题已下调两级。

日期: 2026-11-09(原写 2026-11-22 是笔误, 该文件提交 `b67f9d6` 在 2026-11-09)。探测方式: 临时 example `core/crates/ncm-service/examples/probe_artist.rs`
(**该探针已删**, 下面复跑命令只作留档: `cargo run --offline --manifest-path core/Cargo.toml -p ncm-service --example probe_artist`),
账号为本地已登录 session(`~/.local/share/ncm`)。样例歌手: 周杰伦 id=6452。

#### 模块恢复

从 `git show 5cfc301^:core/vendor/ncm-api/src/api/<module>.rs` 恢复:

- `artist_songs`(全部歌曲, weapi `/api/v1/artist/songs`)
- `artist_mv`(MV, `/api/artist/mvs`)
- **动态: 未实现**。vendor(含 5cfc301^ 裁剪前全量)只有用户动态 `event`(/api/v1/event/get, 走登录用户自己)与
  `user_event`(/api/event/get/{uid}); **不存在“歌手动态”接口**, 不能用用户动态接口按歌手过滤。
  故 UI 不出现“动态”Tab, provider trait 也不加 artist_events 方法。

#### artist_songs 实测响应(截断)

请求: `{"id":"6452","private_cloud":"true","work_type":1,"order":"hot","offset":0,"limit":5}`

```json
{
  "code": 200,
  "more": true,
  "songs": [
    {
      "id": 298317, "name": "屋顶", "dt": 319039, "fee": 0, "mv": 0, "pop": 100.0,
      "ar": [{"id":9612,"name":"温岚"},{"id":6452,"name":"周杰伦"}],
      "al": {"id":29597,"name":"有点野","picUrl":"https://p4.music.126.net/....jpg"},
      "privilege": {"st":-53918, "dl":999000, "dlLevel":"jyeffect"}
    }
  ]
}
```

我们真正用的字段: `songs[]`(id/name/ar/al/dt/fee + 每首歌自带 privilege 判 playable — 直接复用
`parse_song_list`)、`more`(hasMore)。`order` 默认 hot。

#### artist_mv 实测响应(截断)

请求: `{"artistId":"6452","limit":3,"offset":0,"total":true}`(weapi)

```json
{
  "code": 200,
  "hasMore": true,
  "mvs": [
    {
      "id": 22695250, "name": "任性 (5525 Live版)",
      "artistName": "周杰伦", "duration": 266000,
      "playCount": 106722, "publishTime": "2025-02-23",
      "imgurl": "http://p3.music.126.net/....jpg",
      "imgurl16v9": "http://p4.music.126.net/....jpg",
      "status": 0, "subed": false
    }
  ],
  "time": 1469116800007
}
```

我们用的字段: `mvs[]`(id/name/duration/playCount/publishTime/imgurl16v9)、`hasMore`。offset/limit 分页。
MV 播放首期不在范围(只展示)。

#### 分页语义(实测确认 page1/page2 不重叠)

- artist_songs: offset/limit, `more`=true 还有下一页。
- artist_mv: offset/limit, `hasMore`=true 还有下一页。

#### UI 决策

- Tab: 热门歌曲 / 全部歌曲 / 专辑 / MV(无 MV 或失败时不显示); 动态 tab 不存在(见上)。
- 页内搜索: 仅过滤 热门歌曲 + 全部歌曲 两个 tab(就地过滤, 不发请求)。
- 相似歌手保留在头部之下(非 tab), 用 Wrap 防溢出。

<a id="c2-lyric-source-quality"></a>

## 8. C2: 逐字歌词来源质量抽样对比(2026-11)

> 原文件: `docs/c2-lyric-source-quality.md`(2026-11-19 合并前); 标题已下调两级。

> 一次性真实抽样, 不入测试。复现: `cargo run --release -p ncm-service --example c2_sampling`
> (需登录态数据目录与代理; AMLL 走 api.amll.dev, yrc/行级走网易云接口)。
>
> 打分口径与 `ncm_service::ttml_source::score_word_lyric` 完全一致:
> 覆盖率 0.3 + 时间单调 0.2 + 首字贴行首 0.15 + 每行粒度 0.15 + 行级 LRC 一致性 0.2。

#### 样本(17 首)

晴天/老歌/冷门/韩语/翻唱/纯音乐混合, 覆盖: 周杰伦老歌 6 首(含晴天 186016)、
流行 4 首、韩语 2 首、冷门 3 首、钢琴/纯音乐 2 首。

#### 逐曲结果

| 曲目 | id | yrc 得分 | TTML 得分 | 纯比较选择 | 理由 |
|---|---|---|---|---|---|
| 晴天(周杰伦) | 186016 | -(无 yrc) | 0.842 | AMLL | (单来源) |
| 江南(林俊杰) | 26305527 | - | - | 无逐字 | |
| 听海(张惠妹) | 327584 | 0.947 | - | yrc | |
| 泡沫(邓紫棋) | 233931 | 0.958 | 0.988 | AMLL | TTML 得分更高 |
| 好运来(祖海) | 1996312557 | - | - | 无逐字 | |
| 강남스타일(PSY) | 29848188 | - | - | 无逐字 | |
| Dynamite(BTS Live) | 2028319804 | 0.886 | - | yrc | |
| 后来 Live(刘若英) | 254406 | 0.823 | - | yrc | |
| 龙驹岛(冷门) | 74466 | - | - | 无逐字 | |
| 柬埔寨的夜(冷门) | 1818568343 | - | - | 无逐字 | |
| 夜曲(翻唱) | 3396657990 | - | - | 无逐字 | |
| 晴天 钢琴版 | 1945894789 | - | - | 无逐字 | |
| 晴天 Jay(短) | 3440441479 | - | - | 无逐字 | |
| 将军(周杰伦) | 186004 | 0.863 | 0.870 | AMLL | TTML 得分更高 |
| 园游会(周杰伦) | 186008 | 0.969 | 1.000 | AMLL | TTML 得分更高 |
| 止战之殇(周杰伦) | 186009 | 0.947 | 0.984 | AMLL | TTML 得分更高 |
| 断了的弦(周杰伦) | 186011 | 0.930 | 0.993 | AMLL | TTML 得分更高 |

#### 数字结论

- **AMLL TTML 覆盖率(能查到 TTML 的比例): 6/17 ≈ 35%**。冷门歌/翻唱/韩语(样本内)几乎全 404;
  周杰伦专辑曲与热门单曲覆盖较好。**用户歌源主体仍是 yrc**。
- **纯比较口径**(两来源都在, 6 首): **AMLL 被选中 6/6 = 100%**。TTML 得分一致地更高
  (yrc 常见扣分: 行数与行级 LRC 不齐、个别行首字偏移), 但差距都不大(≤0.07)。
- **真实 auto 口径**(含 yrc ≥ 0.9 短路, 不打 TTML 请求): **AMLL 被选中 2/17 ≈ 12%,
  yrc 15/17 ≈ 88%**(其中 4 首因 yrc 得分 ≥ 0.9 直接短路省掉网络请求;
  9 首两来源皆无逐字, 走行级)。
- 结论: auto 默认策略合理 —— AMLL 只在 yrc 缺失或确实更优时上位, 不会无谓增加请求;
  想强制逐字精度的用户可切「AMLL 优先」。

#### 对 auto 择优规则的印证

- 「晴天 186016 无 yrc、TTML 可用」验证了回退链价值(旧逻辑同样受益)。
- 泡沫/园游会等 yrc 得分 ≥ 0.9 的曲目被短路, 说明 0.9 阈值有效抑制无谓请求。
- 样本中未出现「yrc 时间错乱/覆盖低」实曲(打分单测里以构造数据覆盖对抗样例)。

<a id="c3-mv-playback-notes"></a>

## 9. C3 — MV 播放 接口实测笔记(2026-11-10, ncm raw 实抓; 原写 2026-11-22 是笔误)

> 原文件: `docs/c3-mv-playback-notes.md`(2026-11-19 合并前); 标题已下调两级。

#### mv_detail(`/api/v1/mv/detail`, weapi, 参数 mvid)

id=5436712(莫文蔚/张洪量《广岛之恋》)真实形状:

- 顶层: `code`, `data{...}`, `subed`, `mp{...}`(版权: pl=480 可播档, dl 下载档, fee/mvFee=0 免费)。
- `data` 关键字段:
  - `id`, `name`(标题), `duration`(毫秒), `publishTime`("1997-10-01")
  - `playCount`, `shareCount`, `subCount`, `commentCount`
  - `cover`(http://p4.music.126.net/...jpg 封面), `coverId`
  - `artistName`, `artistId`, `artists[]`{id,name,img1v1Url}
  - `desc`/`briefDesc`(可 null/空), `videoGroup[]`{id,name}
  - `brs[]`: 多清晰度数组 `{br:240,size}`, `{br:480,size}` — 本 MV 最高 480; 新 MV 常见 240/480/720/1080 分档。
- 解析策略: 以 `data.name`/`data.cover`/`data.artistName` 为准, brs 取最大 br 作可用最高清晰度参考。

#### mv_url(`/api/song/enhance/play/mv/url`, weapi, 参数 id + r)

请求 r=1080 与 r=480 实测(免费 MV):

- 顶层 `code`=200, `data` 是**单个对象**(不是数组; video 版才是数组)。
- `data.url`: `http://vodkgeyttp8.vod.126.net/cloudmusic/.../<hash>.mp4?wsSecret=<md5>&wsTime=<ts>`
  - **带签名直链, 有效期 `expi`=3600 秒**, 应即取即播, 不持久化。
  - http 与 https 直链都实测可访问(206, video/mp4)。
  - `data.r` 回的是**实际给的档位**(请求 1080 返回 r=480, 该 MV 无 1080)。
  - `data.size` 字节数; `md5` 为空; `code`=200 表示取链成功。
- 无需额外 header/身份即可播; 免登录可用(测试时已登录但该接口匿名通常也可)。

#### 播放侧结论

- Android: VideoView 直接吃 http(s) mp4 直链; AndroidManifest 需 `usesCleartextTraffic` 或直接把 http→https 替换(已验证 https 可用, 采用替换)。
- url 带 wsTime 签名, 过期会 403 ⇒ 播放失败时提示「链接过期, 请重试」并重新取链。
- Linux: 无视频能力, 用系统播放器/浏览器打开 url(openUrl), UI 明示。

<a id="wave9-endpoint-notes"></a>

## 10. Wave 9 · §4 剩余只读 endpoint 收尾笔记(2026-11-09)

> 原文件: `docs/wave9-endpoint-notes.md`(2026-11-19 合并前); 标题已下调两级。

> 实测通道: weapi, 登录态(device BF448268...); 匿名与登录对下列只读接口响应形状一致。
> 命令: `source tools/env.sh && unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY`
> 后 `cargo run -q -p ncm-cli -- raw <method> k=v` / `ncm <新子命令>`。

#### 1. album_newest(已接入, `ncm album-newest`, FFI `newest_albums`)

vendor `album_newest`(`/api/album/newest`)。实测顶层 `{code, albums:[...]}`,
**固定 12 张, 无 total, 不翻页**; 专辑对象与 `album_new` 同构(吃现成 `parse_album_item`)。

与已接入 `album_new`(`/api/album/new`)的差异: **不是重复接口** ——
- album_new: 带 `total=500`, limit/offset 翻页, 内容偏"分地区新碟"(与 top_album 同族);
- album_newest: 恒 12 张编辑精选, 与 album_new 前 5 的 id 集合完全不同(实测对比 404764114… vs 408291414…),
  额外字段无(awardTags/displayTags/mark 是 album_new 有、newest 没有的)。
判定: 保留两者, newest 作"最新专辑"入口(12 张), album_new 继续当新碟广场数据源。

单测: `album_newest_parses_real_shape` / `album_newest_missing_albums_is_empty`。

#### 2. toplist_detail_v2(已接入, `ncm toplist-v2`, FFI `toplist_catalog`)

vendor `toplist_detail_v2`(`/api/toplist/detail/v2`)。实测顶层 `{code, data:[...], message, msg}`,
`data` 是分组数组(顺序 TOPPING(6)/OFFICIAL(7)/FEATURE(9)/MUSIC_STYLE(6)/GLOBAL(6)/LANGUAGE(7)/MORE(4)),
每项 `{categoryCode, displayType, list:[榜单卡]}`; 榜单卡关键字段:
`id, name, coverUrl, updateFrequency, targetType(实测恒 "PLAYLIST"), canPlay`。

**文档口径 vs 实测差异**:
- 计划里说 v2 给"更新 N 首"增强字段 —— 实测**没有** v1 的 `trackUpdateTime`/`trackNumberUpdateTime`
  数字字段; "更新18首/刚刚更新"只以**字符串**混在 `updateFrequency` 里(且 v1 也有同样的字符串)。
- v1(`toplist_detail`)是平铺 34 张榜的 `list`; v2 的增量是 categoryCode 分组 + canPlay。
- 个别卡片 `id=0 且 canPlay=false`(如 FEATURE 里的"实体专辑榜"), 解析器保留但 UI 不可点。

解析: `parse_toplist_catalog` → `ToplistCatalogGroup{code, items}`; data 缺失/空数组返空目录。
单测: `toplist_catalog_parses_real_shape` / `toplist_catalog_missing_data_is_empty`。

#### 3. simi_user(只 dump, 不实现)

vendor `simi_user`。实测(登录态, id=32953014 / 78473939, `id` 与 `userId` 两种参数名都试过):

```json
{ "code": 200, "userprofiles": [] }
```

多次恒空 —— 该接口对当前账号/这些 uid 不再返回相似用户(疑似服务端已下线或灰度关闭)。
判定: 无可解析的真实形状, 按"实测恒空"记档不做 DTO/FFI; 相似推荐族已有
simi_song/simi_playlist/simi_artist 三兄弟, 缺口留待接口恢复。

#### 4. comment_mv / comment_video(已接入, 复用 CommentPage)

vendor `comment_mv` = `/api/v1/resource/comments/R_MV_5_<id>`(weapi, rid/limit/offset/beforeTime);
`comment_video` = `R_VI_62_<id>`。响应与歌曲评论同形
(`{code, total, more, hotComments, comments, topComments, cnum, isMusician, userId}`),
**直接复用现有 `parse_comments` → `CommentPage`**, 不需要新 DTO。

落地: provider `comments()` 新增 kind `"mv"`/`"video"`(thread_id_for 本来就有 R_MV_5_/R_VI_62_ 前缀),
FFI `comments()` 的 kind 参数透传, CLI `ncm comments mv <id>` / raw 补 `comment_mv`/`comment_video` 接线。
实测: `comments mv 5436712` → total=689, 热评在前; raw comment_video id=144634 → 200 + 空 comments
(该视频 id 无评论, 形状已确认)。
单测: `mv_video_comments_share_comment_page_shape`。

#### 门禁记录

- cargo test --workspace --exclude ncm-api-rs: 全绿(service 96→102)
- cargo build -p ncm_ffi / codegen 一次通过(frb_generated.* + ui/lib/src/rust/*)
- dart analyze / flutter test 见 PROGRESS 后续记录
