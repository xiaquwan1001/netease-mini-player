//! 搜索域: 综合搜索/建议/精确/热词/默认搜索词.

use super::*;

impl NeteaseProvider {
    pub(super) fn search<'a>(
        &'a self,
        query: &'a SearchQuery,
    ) -> BoxFuture<'a, ProviderResult<SearchPage>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("keywords", &query.keywords)
                .param("limit", &query.limit.to_string())
                .param("offset", &query.offset.to_string())
                .param("type", "1");
            let resp = client.cloudsearch(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_search(&resp.body)
        })
    }

    /// 搜索建议(输入联想). 匿名可用.
    pub(super) fn search_suggest<'a>(
        &'a self,
        keywords: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<SuggestItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("keywords", keywords);
            let resp = client.search_suggest(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_suggest(&resp.body))
        })
    }

    /// 联想下拉的纯关键词候选(type=mobile 分支, /api/search/suggest/keyword).
    pub(super) fn search_suggest_keywords<'a>(
        &'a self,
        keywords: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<String>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("type", "mobile")
                .param("keywords", keywords);
            let resp = client.search_suggest(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_suggest_keywords(&resp.body))
        })
    }

    /// 精确实体改写(/api/search/suggest/multimatch). vendor 内部固定发 {type:1, s:<kw>}.
    pub(super) fn search_exact<'a>(
        &'a self,
        keywords: &'a str,
    ) -> BoxFuture<'a, ProviderResult<SearchExact>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("keywords", keywords);
            let resp = client.search_multimatch(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_search_exact(&resp.body))
        })
    }

    /// 综合搜索: 单曲/歌手/专辑/歌单/播客 五个板块并发拉取.
    /// 单曲失败直接报错(主板块); 其余板块失败只留空, 不让一个类型拖垮整页.
    pub(super) fn search_all<'a>(
        &'a self,
        query: &'a SearchQuery,
    ) -> BoxFuture<'a, ProviderResult<SearchBundle>> {
        Box::pin(async move {
            let kw = query.keywords.as_str();
            let song_limit = query.limit.max(1);
            let side_limit = 10u32;
            let (song_body, artist_body, album_body, playlist_body, podcast_body) =
                futures::future::join5(
                    self.cloudsearch_body(kw, 1, song_limit, query.offset),
                    self.cloudsearch_body(kw, 100, side_limit, 0),
                    self.cloudsearch_body(kw, 10, side_limit, 0),
                    self.cloudsearch_body(kw, 1000, side_limit, 0),
                    self.cloudsearch_body(kw, 1009, side_limit, 0),
                )
                .await;
            let song_body = song_body?;
            let page = parse_search(&song_body)?;
            let result_of = |b: ProviderResult<Value>| -> Option<Value> {
                b.ok().and_then(|v| v.get("result").cloned())
            };
            let artists = result_of(artist_body)
                .map(|r| parse_search_artists(&r))
                .unwrap_or_default();
            let albums = result_of(album_body)
                .map(|r| parse_search_albums(&r))
                .unwrap_or_default();
            let playlists = result_of(playlist_body)
                .map(|r| parse_search_playlists(&r))
                .unwrap_or_default();
            let podcasts = result_of(podcast_body)
                .map(|r| parse_search_podcasts(&r))
                .unwrap_or_default();
            Ok(SearchBundle {
                songs: page.songs,
                song_total: page.total,
                artists,
                albums,
                playlists,
                podcasts,
            })
        })
    }

    /// 搜索热词榜. type=1111 返回 result.hots(按热度排序), 没有特权/登录要求.
    pub(super) fn hot_search(&self) -> BoxFuture<'_, ProviderResult<Vec<HotSearchTerm>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.search_hot(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_hot_search(&resp.body))
        })
    }

    /// 热搜榜详情(/api/hotsearchlist/get, weapi, 无参数): 带 score + 榜位.
    pub(super) fn hot_search_detail(
        &self,
    ) -> BoxFuture<'_, ProviderResult<Vec<HotSearchDetailItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.search_hot_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_hot_search_detail(&resp.body))
        })
    }

    /// 默认/推荐搜索词("猜你想搜")
    pub(super) fn default_search(&self) -> BoxFuture<'_, ProviderResult<Option<DefaultSearch>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.search_default(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_default_search(&resp.body))
        })
    }

    /// cloudsearch 的通用调用: type = 1 单曲 / 10 专辑 / 100 歌手 / 1000 歌单 / 1009 播客
    pub(super) async fn cloudsearch_body(
        &self,
        keywords: &str,
        kind: u32,
        limit: u32,
        offset: u32,
    ) -> ProviderResult<Value> {
        let (client, domain, ua, cookie) = self.snapshot();
        let q = make_query(&cookie, &domain, &ua)
            .param("keywords", keywords)
            .param("limit", &limit.to_string())
            .param("offset", &offset.to_string())
            .param("type", &kind.to_string());
        let resp = client.cloudsearch(&q).await.map_err(map_error)?;
        check_body(&resp.body)?;
        Ok(resp.body)
    }
}

pub fn parse_search(body: &Value) -> ProviderResult<SearchPage> {
    let result = body
        .get("result")
        .ok_or_else(|| ProviderError::internal("search: missing result"))?;
    let privileges = parse_privileges(body);
    let songs = result
        .get("songs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| parse_song_with(s, &privileges))
                .collect()
        })
        .unwrap_or_default();
    Ok(SearchPage {
        songs,
        total: u64_of(result, "songCount").unwrap_or(0),
        has_more: result
            .get("hasMore")
            .and_then(Value::as_bool)
            .or_else(|| result.get("more").and_then(Value::as_bool))
            .unwrap_or(false),
    })
}

/// 综合搜索各板块的解析. 入参是 cloudsearch 的 `result` 对象.
pub fn parse_search_artists(result: &Value) -> Vec<SearchArtist> {
    result
        .get("artists")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|a| {
                    let id = u64_of(a, "id")?;
                    let name = str_of(a, "name").unwrap_or_default();
                    if id == 0 || name.is_empty() {
                        return None;
                    }
                    let avatar = str_of(a, "picUrl")
                        .or_else(|| str_of(a, "img1v1Url"))
                        .filter(|s| !s.is_empty());
                    let alias = a
                        .get("alias")
                        .and_then(Value::as_array)
                        .map(|x| {
                            x.iter()
                                .filter_map(Value::as_str)
                                .filter(|s| !s.is_empty())
                                .collect::<Vec<_>>()
                                .join(" / ")
                        })
                        .unwrap_or_default();
                    Some(SearchArtist {
                        id,
                        name,
                        avatar_url: avatar,
                        alias,
                        album_count: u64_of(a, "albumSize").unwrap_or(0),
                        music_count: u64_of(a, "musicSize").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn parse_search_albums(result: &Value) -> Vec<SearchAlbum> {
    result
        .get("albums")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|a| {
                    let id = u64_of(a, "id")?;
                    let name = str_of(a, "name").unwrap_or_default();
                    if id == 0 || name.is_empty() {
                        return None;
                    }
                    let cover = str_of(a, "picUrl")
                        .or_else(|| str_of(a, "blurPicUrl"))
                        .filter(|s| !s.is_empty());
                    let artist = str_of(a, "artist")
                        .or_else(|| a.get("artist").and_then(|x| str_of(x, "name")))
                        .or_else(|| {
                            a.get("artists").and_then(Value::as_array).map(|x| {
                                x.iter()
                                    .filter_map(|v| str_of(v, "name"))
                                    .collect::<Vec<_>>()
                                    .join(" / ")
                            })
                        })
                        .unwrap_or_default();
                    Some(SearchAlbum {
                        id,
                        name,
                        cover_url: cover,
                        artist,
                        track_count: u64_of(a, "size").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn parse_search_playlists(result: &Value) -> Vec<SearchPlaylistItem> {
    result
        .get("playlists")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|p| {
                    let id = u64_of(p, "id")?;
                    let name = str_of(p, "name").unwrap_or_default();
                    if id == 0 {
                        return None;
                    }
                    Some(SearchPlaylistItem {
                        id,
                        name,
                        cover_url: str_of(p, "coverImgUrl").filter(|s| !s.is_empty()),
                        creator_name: p
                            .get("creator")
                            .and_then(|c| str_of(c, "nickname"))
                            .unwrap_or_default(),
                        track_count: u64_of(p, "trackCount").unwrap_or(0),
                        play_count: u64_of(p, "playCount").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn parse_search_podcasts(result: &Value) -> Vec<SearchPodcast> {
    result
        .get("djRadios")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|r| {
                    let id = u64_of(r, "id")?;
                    let name = str_of(r, "name").unwrap_or_default();
                    if id == 0 {
                        return None;
                    }
                    Some(SearchPodcast {
                        id,
                        name,
                        cover_url: str_of(r, "picUrl").filter(|s| !s.is_empty()),
                        dj_name: r
                            .get("dj")
                            .and_then(|d| str_of(d, "nickname"))
                            .unwrap_or_default(),
                        program_count: u64_of(r, "programCount").unwrap_or(0),
                        play_count: u64_of(r, "playCount").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 搜索建议的响应形如
/// {code:200, result:{order:[songs,artists,albums,playlists], songs:[], artists:[], albums:[], playlists:[]}}
/// 按 order 顺序扁平化成 UI 直接可渲染的条目.
pub fn parse_suggest(body: &Value) -> Vec<SuggestItem> {
    let Some(result) = body.get("result") else {
        return Vec::new();
    };
    let order: Vec<String> = result
        .get("order")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_else(|| {
            vec![
                "songs".to_string(),
                "artists".to_string(),
                "albums".to_string(),
                "playlists".to_string(),
            ]
        });
    let mut out = Vec::new();
    for key in order {
        let kind = match key.as_str() {
            "songs" => "song",
            "artists" => "artist",
            "albums" => "album",
            "playlists" => "playlist",
            _ => continue,
        };
        let Some(arr) = result.get(&key).and_then(Value::as_array) else {
            continue;
        };
        for v in arr.iter().take(3) {
            let Some(id) = u64_of(v, "id") else { continue };
            let title = str_of(v, "name").unwrap_or_default();
            if title.is_empty() {
                continue;
            }
            let (subtitle, cover_url) = match kind {
                "song" => (
                    artists_line_of(v),
                    v.get("album")
                        .and_then(|a| str_of(a, "picUrl"))
                        .or_else(|| str_of(v, "picUrl")),
                ),
                "artist" => ("歌手".to_string(), str_of(v, "picUrl")),
                "album" => (
                    v.get("artist")
                        .and_then(|a| str_of(a, "name"))
                        .unwrap_or_default(),
                    v.get("artist")
                        .and_then(|a| str_of(a, "picUrl"))
                        .or_else(|| str_of(v, "picUrl")),
                ),
                _ => (
                    format!(
                        "歌单 · {} 首",
                        u64_of(v, "trackCount")
                            .or_else(|| u64_of(v, "bookCount"))
                            .unwrap_or(0)
                    ),
                    str_of(v, "coverImgUrl"),
                ),
            };
            out.push(SuggestItem {
                kind: kind.to_string(),
                id,
                title,
                subtitle,
                cover_url,
            });
        }
    }
    out
}

/// 搜索热词榜的响应形如
///   {code:200, result:{hots:[{first:"...", keyword:"晴天", iconType:1}, ...]}}
/// 老版本/其它通道也可能给 result.hotKeywords 或 data[] 字符串.
pub fn parse_hot_search(body: &Value) -> Vec<HotSearchTerm> {
    let arr = body
        .get("result")
        .and_then(|r| r.get("hots").or_else(|| r.get("hotKeywords")))
        .or_else(|| body.get("data"))
        .and_then(Value::as_array);
    let Some(arr) = arr else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for v in arr {
        let keyword = str_of(v, "keyword")
            .or_else(|| str_of(v, "first"))
            .or_else(|| v.as_str().map(str::to_string))
            .unwrap_or_default();
        let keyword = keyword.trim().to_string();
        if keyword.is_empty() {
            continue;
        }
        out.push(HotSearchTerm {
            rank: out.len() as u32 + 1,
            keyword,
        });
    }
    out
}

/// 联想下拉的纯关键词候选(vendor `search_suggest` 的 mobile 分支).
///
/// 请求: `client.search_suggest(&q.param("type","mobile").param("keywords", kw))`
/// → vendor 打 `/api/search/suggest/keyword`, 响应形如
///   {code:200, result:{allMatch:[{keyword:"晴天周杰伦", type:1, alg:"…", feature:"", lastKeyword:""}]}}
/// (实测固定 6 条, 无分页). 只有 `keyword` 可用, alg/feature 是埋点, 忽略.
///
/// 处理: 去掉首尾空白 + 丢弃空串 + **去重保序**(服务端可能给重复词), 最多 6 条.
pub fn parse_suggest_keywords(body: &Value) -> Vec<String> {
    const MAX: usize = 6;
    let Some(arr) = body
        .get("result")
        .and_then(|r| r.get("allMatch"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    let mut out: Vec<String> = Vec::new();
    for v in arr {
        let Some(kw) = str_of(v, "keyword") else {
            continue;
        };
        let kw = kw.trim().to_string();
        if kw.is_empty() || out.iter().any(|x| x == &kw) {
            continue;
        }
        out.push(kw);
        if out.len() >= MAX {
            break;
        }
    }
    out
}

/// 精确实体改写(vendor `search_multimatch`, POST /api/search/suggest/multimatch w/ eapi).
///
/// 响应形如(实测 2026-11-07):
///   {code:200, result:{
///      orders:["artist","playlist"],                    // 命中类型顺序, 同时是「有哪个 key」的清单
///      artist:[{id,name,picUrl,alias:[…],…}],           // 最多 1 条, picUrl 是头像(http)
///      playlist:[{id,name,coverImgUrl,trackCount,…}],   // 最多 1 条
///      voice:[{resourceId,resourceName,baseInfo:{…}}]    // 电台/播客节目, id/name 在 baseInfo 里
///   }}
///
/// **空命中伪装成功**: 无命中回 `{"code":200,"result":{"orders":[]}}`, 各类型 key 直接不存在.
/// 这里按 orders 判空 → 返回 [`SearchExact::default()`], 绝不报错.
pub fn parse_search_exact(body: &Value) -> SearchExact {
    let Some(result) = body.get("result") else {
        return SearchExact::default();
    };
    let orders: Vec<String> = result
        .get("orders")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    if orders.is_empty() {
        return SearchExact::default();
    }
    let arr_of = |key: &str| -> Vec<Value> {
        result
            .get(key)
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    };
    let artists = arr_of("artist")
        .iter()
        .filter_map(|v| {
            let id = u64_of(v, "id")?;
            let name = str_of(v, "name").unwrap_or_default();
            Some(Artist {
                id,
                name,
                avatar_url: str_of(v, "picUrl").filter(|s| !s.is_empty()),
            })
        })
        .collect();
    let playlists = arr_of("playlist")
        .iter()
        .filter_map(|v| {
            let id = u64_of(v, "id")?;
            Some(Playlist {
                id,
                name: str_of(v, "name").unwrap_or_default(),
                cover_url: str_of(v, "coverImgUrl").filter(|s| !s.is_empty()),
                track_count: u64_of(v, "trackCount").unwrap_or(0),
                special: u64_of(v, "specialType").map(|t| t == 5).unwrap_or(false),
                subscribed: v
                    .get("subscribed")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            })
        })
        .collect();
    let podcasts = arr_of("voice")
        .iter()
        .filter_map(parse_voice_radio)
        .collect();
    SearchExact {
        orders,
        artists,
        playlists,
        podcasts,
    }
}

/// 热搜榜详情(vendor `search_hot_detail`, POST /api/hotsearchlist/get w/ eapi, body 空).
///
/// 实测响应(2026-11-07):
///   {code:200, message:null, trp:null, data:[
///      {searchWord:"天龙八部之宿敌", score:91197, iconType:4,
///       iconUrl:"https://p1.music.126.net/….png", content:"", source:0, url:"", alg?:…}
///      … 固定 20 条 …]}
/// 注意: **服务端不给 rank 字段**, 榜位就是数组顺序(rank = 下标 + 1);
/// iconType 0 = 无图标, 2/4/5 = 不同角标; content/url/source 目前恒空.
pub fn parse_hot_search_detail(body: &Value) -> Vec<HotSearchDetailItem> {
    let Some(arr) = body.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for v in arr {
        let keyword = str_of(v, "searchWord")
            .or_else(|| str_of(v, "keyword"))
            .unwrap_or_default()
            .trim()
            .to_string();
        if keyword.is_empty() {
            continue;
        }
        out.push(HotSearchDetailItem {
            keyword,
            rank: out.len() as u32 + 1,
            score: u64_of(v, "score").unwrap_or(0),
            icon_type: u64_of(v, "iconType").unwrap_or(0) as u32,
        });
    }
    out
}

/// 默认搜索词的响应形如
/// {code:200, data:{showKeyword:"🔥The Weeknd 最近很火哦", realkeyword:"The Weeknd", imageUrl:null}}
///
/// 线上(2026-11-06 实测)只有这一条: showKeyword 是"关键词 + 推荐理由"拼成的
/// 展示文案, realkeyword 才是应该拿去搜的词。两者必须分开交给 UI,
/// 否则点一下会把"最近很火哦"也当成关键词搜出去。
pub fn parse_default_search(body: &Value) -> Option<DefaultSearch> {
    let data = body.get("data").unwrap_or(body);
    // showKeyword 只在没有 realkeyword 时兜底(它的文案里带推荐理由)
    let keyword = ["realkeyword", "defaultKeyword", "keyword", "showKeyword"]
        .iter()
        .find_map(|key| str_of(data, key))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())?;
    let show = str_of(data, "showKeyword")
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| keyword.clone());
    Some(DefaultSearch {
        show_text: show,
        keyword,
        image_url: str_of(data, "imageUrl").filter(|s| !s.is_empty()),
    })
}
