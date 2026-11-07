# B4 搜索增强 · 接口实测(只读调研)

生成时间: 2026-11-07 · 二进制: core/target/debug/ncm(debug 构建, 已登录设备)
原始响应: 抓取时在 /tmp/b4/*.json(临时目录, 需要时按本文命令重抓) · 参数写法: `ncm raw <method> k=v ...`(位置参数 `key=value`, **不是** `--param`)

## 接口清单与可用性

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

## search_multimatch 真实响应

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

### 命中类型 key 与含义(据实测出现的 key)
| key | 实体 | 最小可用字段 |
|---|---|---|
| `artist` | 歌手 | id, name, alias[], trans/transNames, picUrl, albumSize, musicSize, fansSize |
| `playlist` | 歌单 | id, name, coverImgUrl, playCount, trackCount, playlistType, uiPlaylistType, creator, description |
| `voice` | 电台/播客节目 | resourceId, resourceName, resourceType, internalType, baseInfo{…大对象…} |
| `song`/`album`/`djRadio` | 未在本次 8 次探测中出现, 按 vendor 约定存在但不可依赖 |

## search_hot_detail

**本次未取得真实响应**(CLI 未接线), 仅静态契约:

```rust
// vendor/ncm-api/src/api/search_hot_detail.rs
POST /api/hotsearchlist/get   weapi   body = {}   // 无参数, 无分页
```

网络侧(历史 API 知识, 未经本仓库实测验证): 返回 `{code, data:[{searchWord, score, content, iconUrl, iconType, sourceUrl, alg}]}`,
即**热搜榜结构**(带热度 score 与排序), 与 `search_hot` 的 `{result:{hots:[{first,second,third,iconType}]}}` 不同 ——
后者只给词、无热度无排序字段。要用热度榜需先给 raw 分支加 `hotsearchlist` arm 或走 ncm-service 直调。
打正式接口前需重新实测(本报告不臆造响应)。

## search_hot

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

## search_suggest

### web 模式(`raw search_suggest keywords=晴天`)
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

### mobile 模式(`raw search_suggest keywords=晴天 type=mobile`)
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

## search_default

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

## search_match

**本次未取得真实响应**(CLI 未接线)。静态契约:

```rust
// vendor/ncm-api/src/api/search_match.rs
POST /api/search/match/new   CryptoType::default(明文)
body = {"songs": "[{\"title\":\"\",\"album\":\"\",\"artist\":\"\",\"duration\":0,\"persistId\":\"<md5>\"}]"}  // songs 是 JSON 字符串
```

语义是**本地文件→线上歌曲匹配**(云盘/导入), 与 B4 联想/热搜无关, 建议直接排除出 B4 范围。

## 建议 DTO 字段

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

## 坑

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
