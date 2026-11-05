use std::sync::RwLock;

use ncm_api_rs::{ApiClient, NcmError, Query};
use ncm_domain::{
    Album, AlbumDetail, Artist, Comment, CommentPage, FeedEvent, HotSearchTerm, Lyric, Playlist,
    PlaylistDetail, PodcastProgram, PodcastRadio, SearchPage, Session, Song, StreamUrl,
    SuggestItem, TrackId,
};
use ncm_provider::{
    BoxFuture, Capability, Provider, ProviderError, ProviderResult, SearchQuery, SongUrlRequest,
};
use serde_json::Value;

pub const CAPABILITIES: &[Capability] = &[
    Capability::Search,
    Capability::SongUrl,
    Capability::Lyric,
    Capability::Login,
    Capability::Profile,
    Capability::Playlist,
    Capability::DailyRecommend,
    Capability::PersonalFm,
    Capability::Album,
    Capability::Podcast,
    Capability::SearchSuggest,
    Capability::Recent,
    Capability::SearchHot,
    Capability::Feed,
    Capability::PlaylistDetail,
    Capability::Comment,
    Capability::Share,
    Capability::PodcastDetail,
];

/// 内置网易云直连 provider.
/// 协议与加解密全部委托给 vendor/ncm-api (api-enhanced 的 Rust 移植).
pub struct NeteaseProvider {
    inner: RwLock<Inner>,
}

struct Inner {
    client: ApiClient,
    session: Session,
    domain: Option<String>,
    ua: Option<String>,
}

impl Inner {
    fn new(session: Session, domain: Option<String>, ua: Option<String>) -> Self {
        let cookie = if session.cookie.is_empty() {
            None
        } else {
            Some(session.cookie.clone())
        };
        let mut client = ApiClient::new(cookie);
        if !session.device_id.is_empty() {
            client.set_device_id(session.device_id.clone());
        }
        Self { client, session, domain, ua }
    }

    fn query(&self) -> Query {
        let mut q = Query::new();
        q.domain = self.domain.clone();
        q.ua = self.ua.clone();
        q
    }
}

impl NeteaseProvider {
    /// 默认通道. NCM_DOMAIN / NCM_UA 是给风控实验用的临时旋钮(M0 spike),
    /// 正式实现应改成配置项而不是环境变量.
    pub fn new(session: Session) -> Self {
        let domain = std::env::var("NCM_DOMAIN").ok().filter(|s| !s.is_empty());
        // UA 必须与身份 cookie 的 os 形态配套(安卓 App UA / PC 客户端 UA);
        // vendor 库对 eapi 的默认值是 iPhone UA, 与我们的 os 声明不一致, 必须显式覆盖.
        let ua = std::env::var("NCM_UA")
            .ok()
            .filter(|s| !s.is_empty())
            .or_else(|| Some(crate::identity::platform_profile().ua.to_string()));
        Self { inner: RwLock::new(Inner::new(session, domain, ua)) }
    }

    /// 覆盖域名/UA (风控实验用): 例如切 interface3 + 网页 UA
    pub fn with_channel(session: Session, domain: Option<String>, ua: Option<String>) -> Self {
        Self { inner: RwLock::new(Inner::new(session, domain, ua)) }
    }

    pub fn update_session(&self, session: Session) {
        let mut guard = self.inner.write().unwrap_or_else(|e| e.into_inner());
        let domain = guard.domain.clone();
        let ua = guard.ua.clone();
        *guard = Inner::new(session, domain, ua);
    }

    /// 当前账号 uid(登录后由 profile 落盘); 没有就先拉一次资料
    async fn uid(&self) -> ProviderResult<u64> {
        let cached = {
            let guard = self.inner.read().unwrap_or_else(|e| e.into_inner());
            guard.session.profile.as_ref().map(|p| p.user_id)
        };
        if let Some(uid) = cached {
            return Ok(uid);
        }
        Ok(Provider::profile(self).await?.user_id)
    }

    /// 心动模式没有歌单上下文时的默认歌单: "我喜欢的音乐"(specialType=5).
    /// 用户至少要有这个歌单(登录后一定有), 否则给一条能看懂的错.
    async fn default_playlist_id(&self) -> ProviderResult<u64> {
        let uid = self.uid().await?;
        let (client, domain, ua, cookie) = self.snapshot();
        let q = make_query(&cookie, &domain, &ua)
            .param("uid", &uid.to_string())
            .param("limit", "200");
        let resp = client.user_playlist(&q).await.map_err(map_error)?;
        check_body(&resp.body)?;
        let list = resp
            .body
            .get("playlist")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        list.iter()
            .filter_map(parse_playlist)
            .find(|p| p.special)
            .map(|p| p.id)
            .ok_or_else(|| ProviderError::not_found("心动模式需要登录并至少有一个歌单"))
    }

    /// await 之前先把要用的东西克隆出来: 避免 std RwLock guard 跨 await (破坏 Send)
    fn snapshot(&self) -> (ApiClient, Option<String>, Option<String>, String) {
        let guard = self.inner.read().unwrap_or_else(|e| e.into_inner());
        let mut q = guard.query();
        q.cookie = None;
        (guard.client.clone(), guard.domain.clone(), guard.ua.clone(), guard.session.cookie.clone())
    }
}

fn make_query(cookie: &str, domain: &Option<String>, ua: &Option<String>) -> Query {
    let mut q = Query::new();
    if !cookie.is_empty() {
        q = q.cookie(cookie);
    }
    q.domain = domain.clone();
    q.ua = ua.clone();
    q
}

/// reqwest 会读 HTTPS_PROXY/ALL_PROXY 等环境变量。本机常见坑: 代理进程没起或换端口,
/// 报错却是笼统的 "error sending request for url (...)", 看起来像"接口挂了/设备风控"。
/// 这里附一句提示, 省掉一次误判。
fn proxy_hint() -> String {
    for key in ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy"] {
        if let Ok(v) = std::env::var(key) {
            if !v.trim().is_empty() {
                return format!(" (提示: 检测到 {key}={v}, 若代理未运行请 unset 后再试)");
            }
        }
    }
    String::new()
}

/// 把错误链一路串起来(`外层 <- 内层 <- 根因`).
/// reqwest 的 Display 只有一句 "error sending request", 真正的原因(DNS/TCP/TLS)
/// 全在 source() 链里 —— 真机排障必须看到这一层。
fn error_chain(err: &(dyn std::error::Error + 'static)) -> String {
    let mut out = err.to_string();
    let mut depth = 0;
    let mut cursor = err.source();
    while let Some(source) = cursor {
        depth += 1;
        if depth > 5 {
            break;
        }
        out.push_str(" <- ");
        out.push_str(&source.to_string());
        cursor = source.source();
    }
    out
}

fn map_error(e: NcmError) -> ProviderError {
    match e {
        NcmError::AuthRequired(msg) => ProviderError::auth(msg),
        NcmError::RateLimited(msg) => ProviderError::risk_control(msg),
        NcmError::Api { code, msg } => map_code(code, msg),
        NcmError::Timeout(msg) => ProviderError::network(format!("timeout: {msg}")),
        NcmError::Http(err) => {
            ProviderError::network(format!("{}{}", error_chain(&err), proxy_hint()))
        }
        other => ProviderError::internal(other.to_string()),
    }
}

fn map_code(code: i64, msg: String) -> ProviderError {
    let detail = if msg.is_empty() {
        format!("code={code}")
    } else {
        format!("code={code}: {msg}")
    };
    match code {
        200 | 0 => ProviderError::internal(detail),
        301 | 401 => ProviderError::auth(detail),
        8821 | -462 => ProviderError::risk_control(detail),
        -110 | 404 => ProviderError::not_found(detail),
        _ => ProviderError::internal(detail),
    }
}

/// 业务 code 校验: 网易云常在 HTTP 200 里返回 code != 200
fn check_body(body: &Value) -> ProviderResult<()> {
    match body.get("code").and_then(Value::as_i64) {
        None => Ok(()),
        Some(200) | Some(0) => Ok(()),
        Some(code) => {
            let msg = body
                .get("message")
                .or_else(|| body.get("msg"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            Err(map_code(code, msg))
        }
    }
}

fn u64_of(v: &Value, key: &str) -> Option<u64> {
    v.get(key).and_then(|x| x.as_u64().or_else(|| x.as_str().and_then(|s| s.parse().ok())))
}

fn str_of(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).map(str::to_string)
}

/// 从响应里收集 `privileges[]`(key=曲目 id). 搜索/详情/歌单各接口给的位置不同,
/// 有的直接内嵌在 song 上(`privilege`), 两种都认。
fn parse_privileges(body: &Value) -> std::collections::HashMap<u64, bool> {
    let mut map = std::collections::HashMap::new();
    let arrays = [
        body.get("privileges").and_then(Value::as_array),
        body.get("result")
            .and_then(|r| r.get("privileges"))
            .and_then(Value::as_array),
        body.get("data")
            .and_then(|d| d.get("privileges"))
            .and_then(Value::as_array),
    ];
    for arr in arrays.into_iter().flatten() {
        for p in arr {
            if let Some(id) = u64_of(p, "id") {
                map.insert(id, privilege_playable(p));
            }
        }
    }
    map
}

/// st < 0 就是"这首在你这儿没版权/已下架"(实测 -200 最常见), pl=0 表示不可播。
fn privilege_playable(p: &Value) -> bool {
    let st = p.get("st").and_then(Value::as_i64).unwrap_or(0);
    if st < 0 {
        return false;
    }
    match p.get("pl").and_then(Value::as_i64) {
        // 匿名/未登录时 VIP 曲目 pl=0, 但那只是"要会员", 仍属可播范畴
        Some(_) => true,
        None => true,
    }
}

fn parse_song_with(
    v: &Value,
    privileges: &std::collections::HashMap<u64, bool>,
) -> Option<Song> {
    let id = u64_of(v, "id")?;
    // 优先级: song 自带的 privilege > 响应级 privileges[] > 默认可播
    let playable = v
        .get("privilege")
        .map(privilege_playable)
        .or_else(|| privileges.get(&id).copied())
        .unwrap_or(true);
    let artists = v
        .get("ar")
        .or_else(|| v.get("artists"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .map(|a| Artist {
                    id: u64_of(a, "id").unwrap_or(0),
                    name: str_of(a, "name").unwrap_or_default(),
                })
                .collect()
        })
        .unwrap_or_default();
    let album = v.get("al").or_else(|| v.get("album")).map(|a| Album {
        id: u64_of(a, "id").unwrap_or(0),
        name: str_of(a, "name").unwrap_or_default(),
        pic_url: str_of(a, "picUrl").or_else(|| str_of(a, "pic_url")),
    });
    Some(Song {
        id: TrackId::new(id),
        name: str_of(v, "name").unwrap_or_default(),
        artists,
        album,
        duration_ms: u64_of(v, "dt").or_else(|| u64_of(v, "duration")).unwrap_or(0),
        fee: v.get("fee").and_then(Value::as_i64),
        playable,
    })
}

/// 详情类接口(body 里 songs[] + privileges[])统一走这个
fn parse_song_list(body: &Value) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get("songs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| parse_song_with(s, &privileges))
                .collect()
        })
        .unwrap_or_default()
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

pub fn parse_stream(body: &Value, level: &str) -> ProviderResult<StreamUrl> {
    let entry = body
        .get("data")
        .and_then(Value::as_array)
        .and_then(|a| a.first())
        .ok_or_else(|| ProviderError::not_found("song_url: empty data"))?;
    let code = entry.get("code").and_then(Value::as_i64).unwrap_or(200);
    if code != 200 {
        let msg = entry
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        return Err(map_code(code, msg));
    }
    let url = entry
        .get("url")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let expi = u64_of(entry, "expi").unwrap_or(1200);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    Ok(StreamUrl {
        url,
        quality: level.to_string(),
        br: u64_of(entry, "br"),
        size: u64_of(entry, "size"),
        expire_at: Some(now + expi),
    })
}

pub fn parse_lyric(body: &Value) -> ProviderResult<Lyric> {
    let part = |key: &str| {
        body.get(key)
            .and_then(|x| x.get("lyric"))
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    };
    Ok(Lyric {
        lrc: part("lrc"),
        translated: part("tlyric"),
        romaji: part("romalrc"),
    })
}

impl Provider for NeteaseProvider {
    fn id(&self) -> &'static str {
        "netease"
    }

    fn name(&self) -> &str {
        "网易云音乐"
    }

    fn capabilities(&self) -> &'static [Capability] {
        CAPABILITIES
    }

    fn search<'a>(&'a self, query: &'a SearchQuery) -> BoxFuture<'a, ProviderResult<SearchPage>> {
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

    fn song_url<'a>(&'a self, req: &'a SongUrlRequest) -> BoxFuture<'a, ProviderResult<StreamUrl>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let level = req.level.as_str();
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &req.track.to_string())
                .param("level", level);
            let resp = client.song_url_v1(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_stream(&resp.body, level)
        })
    }

    fn lyric<'a>(&'a self, track: TrackId) -> BoxFuture<'a, ProviderResult<Lyric>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("id", &track.to_string());
            let resp = client.lyric(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_lyric(&resp.body)
        })
    }

    /// "我喜欢的音乐"曲目 id: 红心状态的唯一真相(不用每首去查详情)
    fn liked_ids<'a>(&'a self) -> BoxFuture<'a, ProviderResult<Vec<TrackId>>> {
        Box::pin(async move {
            let uid = self.uid().await?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("uid", &uid.to_string());
            let resp = client.likelist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(resp
                .body
                .get("ids")
                .and_then(Value::as_array)
                .map(|arr| arr.iter().filter_map(Value::as_u64).map(TrackId::new).collect())
                .unwrap_or_default())
        })
    }

    /// 红心/取消红心. 网易云用 HTTP 200 里的 code 表达结果(200 = 成功)
    fn set_like<'a>(&'a self, track: TrackId, liked: bool) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("未登录不能收藏"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &track.to_string())
                .param("like", if liked { "true" } else { "false" });
            let resp = client.like(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 我的歌单(含"我喜欢的音乐")
    fn user_playlists<'a>(&'a self) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            let uid = self.uid().await?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("uid", &uid.to_string())
                .param("limit", "200");
            let resp = client.user_playlist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let list = resp
                .body
                .get("playlist")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            Ok(list.iter().filter_map(parse_playlist).collect())
        })
    }

    /// 歌单曲目(vendor 内部先取 trackIds 再批量取详情)
    fn playlist_songs<'a>(&'a self, playlist_id: u64) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if playlist_id == 0 {
                return Err(ProviderError::not_found("playlist id 为空"));
            }
            let q = make_query(&cookie, &domain, &ua).param("id", &playlist_id.to_string());
            let resp = client.playlist_track_all(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_song_list(&resp.body))
        })
    }

    /// 批量曲目详情(红心列表要靠它补全元数据)
    fn songs_detail<'a>(&'a self, ids: &'a str) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("ids", ids);
            let resp = client.song_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_song_list(&resp.body))
        })
    }

    /// 每日推荐歌曲(原版每日推荐, 匿名也能取到; 登录后是个性化推荐)
    fn daily_recommend_songs(&self) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.recommend_songs(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_recommend_songs(&resp.body))
        })
    }

    /// 每日推荐歌单(需要登录; 未登录时网易云返回 301)
    fn daily_recommend_playlists(&self) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.recommend_resource(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_recommend_playlists(&resp.body))
        })
    }

    /// 心动模式: 以当前曲目为种子, 在指定歌单里续播.
    /// 网易云要求 pid 必须是一个**可用的歌单**(实测 pid=0 返回 400 歌单不存在);
    /// 用户从搜索/单曲直接进入时没有歌单上下文, 这里自动回落到"我喜欢的音乐".
    fn intelligence_songs(
        &self,
        song_id: u64,
        playlist_id: u64,
        count: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let mut pid = if playlist_id == 0 {
                self.default_playlist_id().await?
            } else {
                playlist_id
            };
            let mut retried = false;
            loop {
                let (client, domain, ua, cookie) = self.snapshot();
                let q = make_query(&cookie, &domain, &ua)
                    .param("id", &song_id.to_string())
                    .param("pid", &pid.to_string())
                    .param("sid", &song_id.to_string())
                    .param("count", &count.to_string());
                let resp = client.playmode_intelligence_list(&q).await.map_err(map_error)?;
                match check_body(&resp.body) {
                    Ok(()) => {
                        let mut songs = parse_intelligence(&resp.body);
                        // 接口会一次给一整队(实测 149 首), 按调用方要的条数截断
                        songs.truncate(count.max(1) as usize);
                        return Ok(songs);
                    }
                    Err(e) => {
                        // 有些自建歌单不被心动模式接受(实测 400 "不支持该歌单类型"):
                        // 第一次失败就回落到"我喜欢的音乐"再试一次.
                        let playlist_problem = e.detail.contains("歌单");
                        if !retried && playlist_problem {
                            retried = true;
                            let fallback = self.default_playlist_id().await?;
                            if fallback != pid {
                                pid = fallback;
                                continue;
                            }
                        }
                        return Err(e);
                    }
                }
            }
        })
    }

    /// 搜索建议(输入联想). 匿名可用.
    fn search_suggest<'a>(
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

    /// 最近播放(服务端记录, 需要登录)
    fn recent_songs(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("最近播放需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua).param("limit", &limit.to_string());
            let resp = client.record_recent_song(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_recent(&resp.body))
        })
    }

    /// 专辑详情(封面预览 + 曲目)
    fn album_detail(&self, album_id: u64) -> BoxFuture<'_, ProviderResult<AlbumDetail>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("id", &album_id.to_string());
            let resp = client.album(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_album(&resp.body)
        })
    }

    /// 热门播客/电台
    fn podcast_hot(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<PodcastRadio>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("limit", &limit.to_string());
            let resp = client.dj_hot(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_podcast_hot(&resp.body))
        })
    }

    /// 某个播客的节目列表
    fn podcast_programs(
        &self,
        radio_id: u64,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<PodcastProgram>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if radio_id == 0 {
                return Err(ProviderError::not_found("radio id 为空"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("rid", &radio_id.to_string())
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.dj_program(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_podcast_programs(&resp.body))
        })
    }

    /// 单个节目详情
    fn podcast_program(&self, program_id: u64) -> BoxFuture<'_, ProviderResult<PodcastProgram>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("id", &program_id.to_string());
            let resp = client.dj_program_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_podcast_program(&resp.body)
        })
    }

    /// 歌单详情(歌单页头部信息)
    fn playlist_detail(&self, playlist_id: u64) -> BoxFuture<'_, ProviderResult<PlaylistDetail>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if playlist_id == 0 {
                return Err(ProviderError::not_found("playlist id 为空"));
            }
            let q = make_query(&cookie, &domain, &ua).param("id", &playlist_id.to_string());
            let resp = client.playlist_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_playlist_detail(&resp.body)
        })
    }

    /// 收藏/取消收藏歌单(需登录; t=1 收藏, t=2 取消)
    fn set_playlist_subscribed(
        &self,
        playlist_id: u64,
        subscribed: bool,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("收藏歌单需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &playlist_id.to_string())
                .param("t", if subscribed { "1" } else { "2" });
            let resp = client.playlist_subscribe(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 评论列表: vendor 按 kind 分派到不同资源端点(song/playlist/album/podcast)
    fn comments<'a>(
        &'a self,
        kind: &'a str,
        id: u64,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &id.to_string())
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = match kind {
                "song" => client.comment_music(&q).await,
                "playlist" => client.comment_playlist(&q).await,
                "album" => client.comment_album(&q).await,
                "podcast" => client.comment_dj(&q).await,
                other => {
                    return Err(ProviderError::unsupported(format!(
                        "comments: 未知资源类型 {other} (应为 song|playlist|album|podcast)"
                    )));
                }
            };
            let resp = resp.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_comments(&resp.body)
        })
    }

    /// 分享资源到动态(需登录). kind 直接透传接口 type(song/playlist/album/podcast)
    fn share_resource<'a>(
        &'a self,
        kind: &'a str,
        id: u64,
        msg: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("分享到动态需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("type", kind)
                .param("id", &id.to_string())
                .param("msg", msg);
            let resp = client.share_resource(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 播客/电台详情
    fn podcast_radio(&self, radio_id: u64) -> BoxFuture<'_, ProviderResult<PodcastRadio>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if radio_id == 0 {
                return Err(ProviderError::not_found("radio id 为空"));
            }
            let q = make_query(&cookie, &domain, &ua).param("rid", &radio_id.to_string());
            let resp = client.dj_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_podcast_radio_detail(&resp.body)
        })
    }

    /// 搜索热词榜. type=1111 返回 result.hots(按热度排序), 没有特权/登录要求.
    fn hot_search(&self) -> BoxFuture<'_, ProviderResult<Vec<HotSearchTerm>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.search_hot(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_hot_search(&resp.body))
        })
    }

    /// 默认/推荐搜索词("猜你想搜")
    fn default_search(&self) -> BoxFuture<'_, ProviderResult<Option<String>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.search_default(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_default_search(&resp.body))
        })
    }

    /// 私人 FM: 登录后按口味连续推歌(/api/v1/radio/get), 匿名会返回 301.
    fn personal_fm(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("私人 FM 需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.personal_fm(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut songs = parse_fm_songs(&resp.body);
            songs.truncate(limit.max(1) as usize);
            Ok(songs)
        })
    }

    /// 已订阅的播客/电台
    fn subscribed_podcasts(
        &self,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<PodcastRadio>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("查看收藏播客需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.max(1).to_string())
                .param("offset", "0");
            let resp = client.dj_sublist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_subscribed_podcasts(&resp.body))
        })
    }

    /// 关注的艺人
    fn subscribed_artists(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Artist>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("查看关注艺人需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.max(1).to_string())
                .param("offset", "0");
            let resp = client.artist_sublist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_subscribed_artists(&resp.body))
        })
    }

    /// 关注动态: /api/v1/event/get 返回"我关注的人"的动态(含艺人发布).
    fn feed_events(
        &self,
        limit: u32,
        last_time: i64,
    ) -> BoxFuture<'_, ProviderResult<Vec<FeedEvent>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("查看关注动态需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("pagesize", &limit.max(1).to_string())
                .param("lasttime", &last_time.to_string());
            let resp = client.event(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_feed_events(&resp.body))
        })
    }

    /// 当前登录账号资料(用于多账号记忆: 登录成功后记住 uid/昵称)
    fn profile<'a>(&'a self) -> BoxFuture<'a, ProviderResult<ncm_domain::Profile>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("未登录"));
            }
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.user_account(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_profile(&resp.body)
        })
    }
}

/// `/api/nuser/account/get` 的响应形如
/// `{code:200, account:{id,...}, profile:{userId, nickname, avatarUrl}}`
fn parse_profile(body: &Value) -> ProviderResult<ncm_domain::Profile> {
    let profile = body.get("profile").filter(|v| !v.is_null());
    let account = body.get("account").filter(|v| !v.is_null());
    let user_id = profile
        .and_then(|p| p.get("userId").and_then(Value::as_u64))
        .or_else(|| account.and_then(|a| a.get("id").and_then(Value::as_u64)))
        .ok_or_else(|| ProviderError::auth("profile: 没有 userId(多半是未登录)"))?;
    let nickname = profile
        .and_then(|p| p.get("nickname").and_then(Value::as_str))
        .unwrap_or("")
        .to_string();
    let avatar_url = profile
        .and_then(|p| p.get("avatarUrl").and_then(Value::as_str))
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    // vipType: 0 普通 / 10 音乐包 / 11 黑胶VIP; 账号与资料上都有, 任一大于 0 即会员
    let vip_type = profile
        .and_then(|p| p.get("vipType").and_then(Value::as_i64))
        .or_else(|| account.and_then(|a| a.get("vipType").and_then(Value::as_i64)))
        .unwrap_or(0);
    Ok(ncm_domain::Profile { user_id, nickname, avatar_url, vip: vip_type > 0 })
}

/// 用户歌单列表里的一项. specialType=5 是"我喜欢的音乐"。
fn parse_playlist(v: &Value) -> Option<Playlist> {
    let id = u64_of(v, "id")?;
    Some(Playlist {
        id,
        name: str_of(v, "name").unwrap_or_default(),
        cover_url: str_of(v, "coverImgUrl")
            .or_else(|| str_of(v, "coverUrl"))
            .or_else(|| str_of(v, "picUrl")),
        track_count: u64_of(v, "trackCount").unwrap_or(0),
        special: v.get("specialType").and_then(Value::as_i64) == Some(5),
    })
}

/// 每日推荐歌曲的响应形如 {code:200, data:{dailySongs:[...], privileges:[...]}}
pub fn parse_recommend_songs(body: &Value) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get("data")
        .and_then(|d| d.get("dailySongs"))
        .or_else(|| body.get("recommend"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| parse_song_with(s, &privileges))
                .collect()
        })
        .unwrap_or_default()
}

/// 每日推荐歌单的响应形如 {code:200, recommend:[{id,name,picUrl,trackCount,...}]}
pub fn parse_recommend_playlists(body: &Value) -> Vec<Playlist> {
    body.get("recommend")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_playlist).collect())
        .unwrap_or_default()
}

/// 心动模式/智能播放的响应.
/// 实测(2026-11-04, 登录态)形如:
///   {code:200, data:[{alg, id, recommended, songInfo:{...完整 song 对象...}}, ...]}
/// 早期/其它变体也可能直接是 song 数组, 两种都认.
pub fn parse_intelligence(body: &Value) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get("data")
        .and_then(Value::as_array)
        .or_else(|| {
            body.get("data")
                .and_then(|d| d.get("songs"))
                .and_then(Value::as_array)
        })
        .map(|arr| {
            arr.iter()
                .filter_map(|item| {
                    let song = item
                        .get("songInfo")
                        .or_else(|| item.get("song"))
                        .or_else(|| item.get("data"))
                        .unwrap_or(item);
                    parse_song_with(song, &privileges)
                })
                .collect()
        })
        .unwrap_or_default()
}

fn artists_line_of(v: &Value) -> String {
    v.get("artists")
        .or_else(|| v.get("ar"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|a| a.get("name").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join(" / ")
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

/// 最近播放的响应形如 {code:200, data:{list:[{data:{song}, playCount, ...}]}}
pub fn parse_recent(body: &Value) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get("data")
        .and_then(|d| d.get("list"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|item| parse_song_with(item.get("data").unwrap_or(item), &privileges))
                .collect()
        })
        .unwrap_or_default()
}

/// 专辑详情的响应形如 {code:200, album:{id,name,picUrl,artist,description}, songs:[...]}
pub fn parse_album(body: &Value) -> ProviderResult<AlbumDetail> {
    let album = body
        .get("album")
        .ok_or_else(|| ProviderError::not_found("album: missing album"))?;
    let artist = album
        .get("artist")
        .and_then(|a| str_of(a, "name"))
        .or_else(|| {
            album
                .get("artists")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .and_then(|a| str_of(a, "name"))
        })
        .unwrap_or_default();
    Ok(AlbumDetail {
        id: u64_of(album, "id").unwrap_or(0),
        name: str_of(album, "name").unwrap_or_default(),
        cover_url: str_of(album, "picUrl").or_else(|| str_of(album, "blurPicUrl")),
        artist,
        description: str_of(album, "description").unwrap_or_default(),
        songs: parse_song_list(body),
    })
}

fn parse_radio(v: &Value) -> Option<PodcastRadio> {
    let id = u64_of(v, "id")?;
    Some(PodcastRadio {
        id,
        name: str_of(v, "name").unwrap_or_default(),
        cover_url: str_of(v, "picUrl").or_else(|| str_of(v, "coverUrl")),
        description: str_of(v, "desc")
            .or_else(|| str_of(v, "rcmdtext"))
            .unwrap_or_default(),
        dj_name: v
            .get("dj")
            .and_then(|d| str_of(d, "nickname"))
            .unwrap_or_default(),
        program_count: u64_of(v, "programCount").unwrap_or(0),
        play_count: u64_of(v, "playCount").unwrap_or(0),
    })
}

/// 热门播客的响应形如 {code:200, djRadios:[...]}
pub fn parse_podcast_hot(body: &Value) -> Vec<PodcastRadio> {
    body.get("djRadios")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_radio).collect())
        .unwrap_or_default()
}

fn parse_program(v: &Value) -> Option<PodcastProgram> {
    let id = u64_of(v, "id")?;
    let radio = v.get("radio");
    Some(PodcastProgram {
        id,
        name: str_of(v, "name").unwrap_or_default(),
        cover_url: str_of(v, "coverUrl").or_else(|| str_of(v, "blurCoverUrl")),
        duration_ms: u64_of(v, "duration").unwrap_or(0),
        dj_name: v
            .get("dj")
            .and_then(|d| str_of(d, "nickname"))
            .unwrap_or_default(),
        radio_id: radio.and_then(|r| u64_of(r, "id")).unwrap_or(0),
        radio_name: radio.and_then(|r| str_of(r, "name")).unwrap_or_default(),
        description: str_of(v, "description").unwrap_or_default(),
        // 节目音频本体; 用它的 id 走 song_url 取直链(实测匿名可播)
        song: v
            .get("mainSong")
            .and_then(|s| parse_song_with(s, &std::collections::HashMap::new())),
    })
}

/// 节目列表的响应形如 {code:200, programs:[...], more}
pub fn parse_podcast_programs(body: &Value) -> Vec<PodcastProgram> {
    body.get("programs")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_program).collect())
        .unwrap_or_default()
}

/// 节目详情的响应形如 {code:200, program:{...}}
pub fn parse_podcast_program(body: &Value) -> ProviderResult<PodcastProgram> {
    body.get("program")
        .and_then(parse_program)
        .ok_or_else(|| ProviderError::not_found("program: missing program"))
}

/// 歌单详情的响应形如 {code:200, playlist:{id,name,coverImgUrl,description,creator:{nickname},
/// trackCount,playCount,subscribed,subscribedCount,shareCount,commentCount,tags:[]}}
pub fn parse_playlist_detail(body: &Value) -> ProviderResult<PlaylistDetail> {
    let pl = body
        .get("playlist")
        .ok_or_else(|| ProviderError::not_found("playlist_detail: missing playlist"))?;
    Ok(PlaylistDetail {
        id: u64_of(pl, "id").unwrap_or(0),
        name: str_of(pl, "name").unwrap_or_default(),
        cover_url: str_of(pl, "coverImgUrl").or_else(|| str_of(pl, "picUrl")),
        description: str_of(pl, "description").unwrap_or_default(),
        creator_name: pl
            .get("creator")
            .and_then(|c| str_of(c, "nickname"))
            .unwrap_or_default(),
        track_count: u64_of(pl, "trackCount").unwrap_or(0),
        play_count: u64_of(pl, "playCount").unwrap_or(0),
        subscribed: pl.get("subscribed").and_then(Value::as_bool).unwrap_or(false),
        subscribed_count: u64_of(pl, "subscribedCount").unwrap_or(0),
        share_count: u64_of(pl, "shareCount").unwrap_or(0),
        comment_count: u64_of(pl, "commentCount").unwrap_or(0),
        tags: pl
            .get("tags")
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default(),
    })
}

/// 评论条目形如 {commentId, user:{nickname,avatarUrl}, content, time, likedCount, liked}
fn parse_comment(v: &Value) -> Option<Comment> {
    let id = u64_of(v, "commentId")?;
    let user = v.get("user");
    Some(Comment {
        id,
        user_name: user.and_then(|u| str_of(u, "nickname")).unwrap_or_default(),
        avatar_url: user.and_then(|u| str_of(u, "avatarUrl")),
        content: str_of(v, "content").unwrap_or_default(),
        time_ms: u64_of(v, "time").unwrap_or(0),
        liked_count: u64_of(v, "likedCount").unwrap_or(0),
        liked: v.get("liked").and_then(Value::as_bool).unwrap_or(false),
    })
}

/// 评论列表的响应形如 {code:200, total, more, hotComments:[...], comments:[...]}
/// 精彩评论在前(hotComments), 其后是最新评论, 按 commentId 去重.
pub fn parse_comments(body: &Value) -> ProviderResult<CommentPage> {
    let mut seen = std::collections::HashSet::new();
    let mut comments = Vec::new();
    for key in ["hotComments", "comments"] {
        let Some(arr) = body.get(key).and_then(Value::as_array) else {
            continue;
        };
        for v in arr {
            let Some(c) = parse_comment(v) else { continue };
            if seen.insert(c.id) {
                comments.push(c);
            }
        }
    }
    Ok(CommentPage {
        comments,
        total: u64_of(body, "total").unwrap_or(0),
        has_more: body.get("more").and_then(Value::as_bool).unwrap_or(false),
    })
}

/// 电台详情(dj_detail)的响应形如 {code:200, data:{id,name,picUrl,desc,dj:{nickname},programCount,playCount}}
pub fn parse_podcast_radio_detail(body: &Value) -> ProviderResult<PodcastRadio> {
    body.get("data")
        .and_then(parse_radio)
        .ok_or_else(|| ProviderError::not_found("podcast_radio: missing data"))
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
        out.push(HotSearchTerm { rank: out.len() as u32 + 1, keyword });
    }
    out
}

/// 默认搜索词的响应形如 {code:200, data:{showKeyword:"...", realkeyword:"..."}}
pub fn parse_default_search(body: &Value) -> Option<String> {
    let data = body.get("data").unwrap_or(body);
    ["showKeyword", "realkeyword", "defaultKeyword", "keyword"]
        .iter()
        .find_map(|key| str_of(data, key))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// 私人 FM 的响应形如 {code:200, data:[{id,name,ar,al,dt,fee,...}, ...]}
pub fn parse_fm_songs(body: &Value) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get("data")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|item| {
                    let song = item.get("songInfo").or_else(|| item.get("song")).unwrap_or(item);
                    parse_song_with(song, &privileges)
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 已订阅播客的响应形如 {code:200, djRadios:[{id,name,picUrl,...}]}
/// 部分通道返回 data:[{radio:{...}}], 两种都认.
pub fn parse_subscribed_podcasts(body: &Value) -> Vec<PodcastRadio> {
    let arr = body
        .get("djRadios")
        .or_else(|| body.get("data"))
        .or_else(|| body.get("radios"))
        .and_then(Value::as_array);
    let Some(arr) = arr else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| parse_radio(v.get("radio").unwrap_or(v)))
        .collect()
}

/// 关注艺人的响应形如 {code:200, data:[{id,name,picUrl,albumSize,...}]}
pub fn parse_subscribed_artists(body: &Value) -> Vec<Artist> {
    let arr = body
        .get("data")
        .or_else(|| body.get("artists"))
        .and_then(Value::as_array);
    let Some(arr) = arr else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| {
            let name = str_of(v, "name")?;
            if name.is_empty() {
                return None;
            }
            Some(Artist { id: u64_of(v, "id").unwrap_or(0), name })
        })
        .collect()
}

fn event_kind(event_type: i64) -> &'static str {
    match event_type {
        18 => "song",
        13 => "playlist",
        19 => "album",
        17 | 22 => "program",
        // 35 是"发动态/文字+图", 5..8 是更老版本的文字动态
        5..=8 | 35 => "text",
        _ => "other",
    }
}

fn parse_event_images(value: &Value) -> Vec<String> {
    let Some(arr) = value.as_array() else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| {
            v.as_str()
                .map(str::to_string)
                .or_else(|| str_of(v, "url"))
                .or_else(|| str_of(v, "thumbUrl"))
        })
        .filter(|s| !s.is_empty())
        .take(3)
        .collect()
}

/// 关注动态的响应形如
///   {code:200, events:[{id, eventType, eventTime, user:{nickname,avatarUrl},
///                       json:{song:{...}, comment:"..."}|"...", pics:[...]}], lasttime}
/// json 有时是字符串(需要再解析一次), 各种 eventType 的字段名也不统一,
/// 这里只提取 UI 能直接展示的最小集合.
pub fn parse_feed_events(body: &Value) -> Vec<FeedEvent> {
    // 线上实测(2026-11-05, /api/v1/event/get)顶层字段叫 event(单数);
    // 旧包装/其它通道可能给 events, 两种都认.
    let Some(arr) = body
        .get("event")
        .or_else(|| body.get("events"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    let privileges = parse_privileges(body);
    let mut out = Vec::new();
    for event in arr {
        let Some(id) = u64_of(event, "id") else { continue };
        // 线上字段是 type, 老接口叫 eventType
        let event_type = event
            .get("type")
            .or_else(|| event.get("eventType"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        // json 可能是对象, 也可能是字符串
        let payload_owned = event.get("json").and_then(|j| match j {
            Value::String(s) => serde_json::from_str::<Value>(s).ok(),
            other => Some(other.clone()),
        });
        let payload = payload_owned.as_ref();
        let info = event.get("info");
        let song_value = payload
            .and_then(|p| p.get("song").or_else(|| p.get("songInfo")))
            .or_else(|| info.and_then(|i| i.get("song")));
        let song = song_value.and_then(|s| parse_song_with(s, &privileges));
        let text = payload
            .and_then(|p| {
                str_of(p, "msg")
                    .or_else(|| str_of(p, "comment"))
                    .or_else(|| str_of(p, "description"))
            })
            .or_else(|| info.and_then(|i| str_of(i, "comment")))
            .unwrap_or_default();
        let images = payload
            .and_then(|p| p.get("pics").or_else(|| p.get("imgs")))
            .or_else(|| event.get("pics"))
            .map(parse_event_images)
            .unwrap_or_default();
        let cover_url = song.as_ref().and_then(Song::cover_url).or_else(|| {
            payload.and_then(|p| {
                str_of(p, "coverUrl")
                    .or_else(|| str_of(p, "coverImgUrl"))
                    .or_else(|| p.get("album").and_then(|a| str_of(a, "picUrl")))
                    .or_else(|| p.get("playlist").and_then(|x| str_of(x, "coverImgUrl")))
            })
        }).or_else(|| images.first().cloned());
        let user = event.get("user");
        let user_name = user
            .and_then(|u| str_of(u, "nickname"))
            .or_else(|| payload.and_then(|p| str_of(p, "nickname")))
            .unwrap_or_default();
        let avatar_url = user.and_then(|u| str_of(u, "avatarUrl"));
        let time_ms = u64_of(event, "eventTime")
            .or_else(|| u64_of(event, "time"))
            .unwrap_or(0);
        out.push(FeedEvent {
            id,
            kind: event_kind(event_type).to_string(),
            user_name,
            avatar_url,
            text,
            song,
            cover_url,
            images,
            time_ms,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use ncm_provider::ProviderErrorKind;
    use serde_json::json;

    #[test]
    fn search_mapping() {
        let body = json!({
            "code": 200,
            "result": {
                "songCount": 42,
                "hasMore": true,
                "songs": [{
                    "id": 186016,
                    "name": "晴天",
                    "ar": [{"id": 6452, "name": "周杰伦"}],
                    "al": {"id": 1, "name": "叶惠美", "picUrl": "http://p/1.jpg"},
                    "dt": 269000,
                    "fee": 1
                }]
            }
        });
        let page = parse_search(&body).unwrap();
        assert_eq!(page.total, 42);
        assert!(page.has_more);
        assert_eq!(page.songs.len(), 1);
        assert_eq!(page.songs[0].artist_line(), "周杰伦");
        assert_eq!(page.songs[0].album.as_ref().unwrap().name, "叶惠美");
    }

    /// 无版权判定: 搜索响应把 privilege 内嵌在 song 上, 详情响应是独立 privileges[],
    /// 两种都要能标出 playable=false(st=-200).
    #[test]
    fn unlicensed_tracks_are_marked_unplayable() {
        let search = json!({
            "code": 200,
            "result": {
                "songCount": 1,
                "hasMore": false,
                "songs": [{
                    "id": 186016,
                    "name": "晴天",
                    "ar": [{"id": 6452, "name": "周杰伦"}],
                    "al": {"id": 1, "name": "叶惠美"},
                    "dt": 269000,
                    "fee": 0,
                    "privilege": {"id": 186016, "st": -200, "pl": 0, "dl": 0}
                }]
            }
        });
        let page = parse_search(&search).unwrap();
        assert!(!page.songs[0].playable, "st=-200 应判为不可播");

        let detail = json!({
            "code": 200,
            "songs": [
                {"id": 186016, "name": "晴天", "ar": [], "dt": 1, "fee": 0},
                {"id": 347230, "name": "海阔天空", "ar": [], "dt": 1, "fee": 1}
            ],
            "privileges": [
                {"id": 186016, "st": -200, "pl": 0, "dl": 0},
                {"id": 347230, "st": 0, "pl": 999000, "dl": 999000}
            ]
        });
        let songs = parse_song_list(&detail);
        assert_eq!(songs.len(), 2);
        assert!(!songs[0].playable);
        assert!(songs[1].playable);
    }

    #[test]
    fn stream_mapping_and_expiry() {
        let body = json!({
            "code": 200,
            "data": [{"id": 1, "url": "http://m/1.flac", "br": 999000, "size": 12345, "expi": 1200, "code": 200}]
        });
        let s = parse_stream(&body, "exhigh").unwrap();
        assert!(s.is_playable());
        assert_eq!(s.br, Some(999000));
        assert!(s.expire_at.unwrap() > 0);
    }

    #[test]
    fn stream_vip_without_login_has_no_url() {
        let body = json!({"code": 200, "data": [{"id": 1, "url": null, "code": 200, "expi": 1200}]});
        let s = parse_stream(&body, "exhigh").unwrap();
        assert!(!s.is_playable());
    }

    #[test]
    fn code_8821_is_risk_control() {
        let body = json!({"code": 8821, "message": "安全环境风险"});
        let err = check_body(&body).unwrap_err();
        assert_eq!(err.kind, ProviderErrorKind::RiskControl);
    }

    #[test]
    fn lyric_mapping() {
        let body = json!({"code": 200, "lrc": {"lyric": "[00:00.00]hi"}, "tlyric": {"lyric": "[00:00.00]嗨"}});
        let l = parse_lyric(&body).unwrap();
        assert_eq!(l.lrc.as_deref(), Some("[00:00.00]hi"));
        assert_eq!(l.translated.as_deref(), Some("[00:00.00]嗨"));
        assert!(l.romaji.is_none());
    }

    #[test]
    fn daily_recommend_mapping() {
        let body = json!({
            "code": 200,
            "data": {
                "dailySongs": [
                    {"id": 1, "name": "A", "ar": [{"name": "x"}], "al": {"id": 9, "name": "al", "picUrl": "http://p/a.jpg"}, "dt": 1000, "fee": 0},
                    {"id": 2, "name": "B", "ar": [{"name": "y"}], "al": {"id": 10, "name": "al2"}, "dt": 2000, "fee": 1}
                ],
                "privileges": [{"id": 2, "st": -200, "pl": 0}]
            }
        });
        let songs = parse_recommend_songs(&body);
        assert_eq!(songs.len(), 2);
        assert!(songs[0].playable);
        assert!(!songs[1].playable);
        assert_eq!(songs[0].album_id(), 9);
        assert_eq!(songs[0].cover_url().as_deref(), Some("http://p/a.jpg"));
    }

    #[test]
    fn daily_playlists_mapping() {
        let body = json!({"code": 200, "recommend": [
            {"id": 11, "name": "pl", "picUrl": "http://p/1.jpg", "trackCount": 30, "playCount": 99}
        ]});
        let lists = parse_recommend_playlists(&body);
        assert_eq!(lists.len(), 1);
        assert_eq!(lists[0].id, 11);
        assert_eq!(lists[0].cover_url.as_deref(), Some("http://p/1.jpg"));
        assert!(!lists[0].special);
    }

    #[test]
    fn intelligence_mapping() {
        // 实测形态: data[].songInfo 里才是完整 song(还带内嵌 privilege)
        let body = json!({"code": 200, "data": [
            {
                "alg": "x", "id": 3, "recommended": true,
                "songInfo": {
                    "id": 3, "name": "C", "ar": [{"name": "z"}],
                    "al": {"id": 1, "name": "a", "picUrl": "http://p/c.jpg"}, "dt": 500,
                    "privilege": {"id": 3, "st": -200, "pl": 0}
                }
            }
        ]});
        let songs = parse_intelligence(&body);
        assert_eq!(songs.len(), 1);
        assert_eq!(songs[0].name, "C");
        assert_eq!(songs[0].album_id(), 1);
        assert!(!songs[0].playable);

        // 兼容 data 直接是 song 数组
        let plain = json!({"code": 200, "data": [
            {"id": 4, "name": "D", "ar": [], "al": {"id": 1, "name": "a"}, "dt": 1}
        ]});
        assert_eq!(parse_intelligence(&plain).len(), 1);
        // 兼容 data.songs 变体
        let alt = json!({"code": 200, "data": {"songs": [
            {"id": 5, "name": "E", "ar": [], "al": {"id": 1, "name": "a"}, "dt": 1}
        ]}});
        assert_eq!(parse_intelligence(&alt).len(), 1);
    }

    #[test]
    fn suggest_mapping_follows_order() {
        let body = json!({
            "code": 200,
            "result": {
                "order": ["songs", "artists", "albums", "playlists"],
                "songs": [{"id": 1, "name": "晴天", "artists": [{"name": "周杰伦"}], "album": {"picUrl": "http://p/s.jpg"}}],
                "artists": [{"id": 2, "name": "周杰伦", "picUrl": "http://p/ar.jpg"}],
                "albums": [{"id": 3, "name": "叶惠美", "artist": {"name": "周杰伦", "picUrl": "http://p/al.jpg"}}],
                "playlists": [{"id": 4, "name": "歌单", "coverImgUrl": "http://p/pl.jpg", "trackCount": 12}]
            }
        });
        let items = parse_suggest(&body);
        assert_eq!(items.len(), 4);
        assert_eq!(items[0].kind, "song");
        assert_eq!(items[0].title, "晴天");
        assert_eq!(items[1].kind, "artist");
        assert_eq!(items[1].subtitle, "歌手");
        assert_eq!(items[2].kind, "album");
        assert_eq!(items[2].subtitle, "周杰伦");
        assert_eq!(items[3].kind, "playlist");
        assert!(items[3].subtitle.contains("12"));
    }

    #[test]
    fn recent_mapping() {
        let body = json!({"code": 200, "data": {"list": [
            {"playCount": 3, "data": {"id": 7, "name": "R", "ar": [{"name": "q"}], "al": {"id": 2, "name": "a"}, "dt": 1000}}
        ]}});
        let songs = parse_recent(&body);
        assert_eq!(songs.len(), 1);
        assert_eq!(songs[0].id.0, 7);
    }

    #[test]
    fn album_mapping() {
        let body = json!({
            "code": 200,
            "album": {"id": 9, "name": "叶惠美", "picUrl": "http://p/al.jpg", "artist": {"name": "周杰伦"}, "description": "d"},
            "songs": [{"id": 1, "name": "以父之名", "ar": [{"name": "周杰伦"}], "al": {"id": 9, "name": "叶惠美"}, "dt": 1}]
        });
        let d = parse_album(&body).unwrap();
        assert_eq!(d.id, 9);
        assert_eq!(d.name, "叶惠美");
        assert_eq!(d.artist, "周杰伦");
        assert_eq!(d.songs.len(), 1);
    }

    #[test]
    fn podcast_mapping() {
        let hot = json!({"code": 200, "djRadios": [
            {"id": 5, "name": "电台", "picUrl": "http://p/r.jpg", "desc": "d", "dj": {"nickname": "主播"}, "programCount": 33, "playCount": 100}
        ]});
        let radios = parse_podcast_hot(&hot);
        assert_eq!(radios.len(), 1);
        assert_eq!(radios[0].dj_name, "主播");
        assert_eq!(radios[0].program_count, 33);

        let programs = json!({"code": 200, "programs": [{
            "id": 6, "name": "单集", "coverUrl": "http://p/c.jpg", "duration": 22125,
            "dj": {"nickname": "主播"}, "radio": {"id": 5, "name": "电台"}, "description": "dd",
            "mainSong": {"id": 1442398087, "name": "单集", "artists": [{"name": "主播"}], "album": {"id": 0, "name": ""}, "duration": 22125, "fee": 0}
        }]});
        let list = parse_podcast_programs(&programs);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].radio_id, 5);
        assert_eq!(list[0].duration_ms, 22125);
        assert_eq!(list[0].song.as_ref().unwrap().id.0, 1442398087);
    }

    #[test]
    fn capabilities_include_personal_fm() {
        // 漏掉这项时 UI 会报 "no provider supports personalFm"(模拟器实测踩过)
        assert!(CAPABILITIES.contains(&Capability::PersonalFm));
        assert!(CAPABILITIES.contains(&Capability::SearchHot));
        assert!(CAPABILITIES.contains(&Capability::Feed));
    }

    #[test]
    fn playlist_detail_mapping() {
        let body = json!({
            "code": 200,
            "playlist": {
                "id": 9, "name": "歌单", "coverImgUrl": "http://p/pl.jpg",
                "description": "desc", "creator": {"nickname": "作者"},
                "trackCount": 30, "playCount": 999, "subscribed": true,
                "subscribedCount": 12, "shareCount": 3, "commentCount": 45,
                "tags": ["流行", "华语"]
            }
        });
        let d = parse_playlist_detail(&body).unwrap();
        assert_eq!(d.id, 9);
        assert_eq!(d.name, "歌单");
        assert_eq!(d.cover_url.as_deref(), Some("http://p/pl.jpg"));
        assert_eq!(d.creator_name, "作者");
        assert_eq!(d.track_count, 30);
        assert_eq!(d.play_count, 999);
        assert!(d.subscribed);
        assert_eq!(d.subscribed_count, 12);
        assert_eq!(d.comment_count, 45);
        assert_eq!(d.tags, vec!["流行".to_string(), "华语".to_string()]);
        // 缺 playlist 字段要报 NotFound 而不是 panic
        let err = parse_playlist_detail(&json!({"code": 200})).unwrap_err();
        assert_eq!(err.kind, ProviderErrorKind::NotFound);
    }

    #[test]
    fn comments_mapping_hot_first_and_dedup() {
        let body = json!({
            "code": 200,
            "total": 123,
            "more": true,
            "hotComments": [
                {"commentId": 1, "user": {"nickname": "A", "avatarUrl": "http://p/a.jpg"},
                 "content": "好", "time": 1700000000000u64, "likedCount": 10, "liked": true},
                {"commentId": 2, "user": {"nickname": "B"}, "content": "赞"}
            ],
            "comments": [
                {"commentId": 2, "user": {"nickname": "B"}, "content": "赞"},
                {"commentId": 3, "user": {"nickname": "C"}, "content": "三"}
            ]
        });
        let page = parse_comments(&body).unwrap();
        assert_eq!(page.total, 123);
        assert!(page.has_more);
        // 精彩评论在前, 跨列表按 commentId 去重
        let ids: Vec<u64> = page.comments.iter().map(|c| c.id).collect();
        assert_eq!(ids, vec![1, 2, 3]);
        assert_eq!(page.comments[0].user_name, "A");
        assert_eq!(page.comments[0].avatar_url.as_deref(), Some("http://p/a.jpg"));
        assert_eq!(page.comments[0].time_ms, 1700000000000);
        assert_eq!(page.comments[0].liked_count, 10);
        assert!(page.comments[0].liked);
        assert!(!page.comments[2].liked);
    }

    #[test]
    fn podcast_radio_detail_mapping() {
        let body = json!({
            "code": 200,
            "data": {"id": 5, "name": "电台", "picUrl": "http://p/r.jpg", "desc": "d",
                     "dj": {"nickname": "主播"}, "programCount": 33, "playCount": 100}
        });
        let r = parse_podcast_radio_detail(&body).unwrap();
        assert_eq!(r.id, 5);
        assert_eq!(r.name, "电台");
        assert_eq!(r.cover_url.as_deref(), Some("http://p/r.jpg"));
        assert_eq!(r.dj_name, "主播");
        assert_eq!(r.program_count, 33);
        let err = parse_podcast_radio_detail(&json!({"code": 200})).unwrap_err();
        assert_eq!(err.kind, ProviderErrorKind::NotFound);
    }

    #[test]
    fn capabilities_include_new_apis() {
        // 漏加这项时 FFI 会报 "no provider supports xxx"(项目踩过)
        assert!(CAPABILITIES.contains(&Capability::PlaylistDetail));
        assert!(CAPABILITIES.contains(&Capability::Comment));
        assert!(CAPABILITIES.contains(&Capability::Share));
        assert!(CAPABILITIES.contains(&Capability::PodcastDetail));
    }

    #[test]
    fn search_hot_and_default() {
        let hot = json!({"code": 200, "result": {"hots": [
            {"first": "晴天", "keyword": "晴天", "iconType": 1},
            {"first": "", "keyword": "周杰伦", "iconType": 0},
            {"keyword": "  "}
        ]}});
        let terms = parse_hot_search(&hot);
        assert_eq!(terms.len(), 2);
        assert_eq!(terms[0].rank, 1);
        assert_eq!(terms[0].keyword, "晴天");
        assert_eq!(terms[1].rank, 2);

        let def = json!({"code": 200, "data": {"showKeyword": "周杰伦", "realkeyword": "周杰伦"}});
        assert_eq!(parse_default_search(&def).as_deref(), Some("周杰伦"));
        assert_eq!(parse_default_search(&json!({"code": 200, "data": {}})), None);
    }

    #[test]
    fn fm_songs_mapping() {
        let body = json!({"code": 200, "data": [
            {"id": 11, "name": "FM 曲", "ar": [{"name": "A"}], "al": {"id": 3, "name": "al"}, "dt": 1000, "fee": 0}
        ]});
        let songs = parse_fm_songs(&body);
        assert_eq!(songs.len(), 1);
        assert_eq!(songs[0].id.0, 11);
        assert_eq!(songs[0].artist_line(), "A");
    }

    #[test]
    fn subscribed_podcasts_and_artists() {
        let subs = json!({"code": 200, "djRadios": [
            {"id": 5, "name": "订阅电台", "picUrl": "http://p/r.jpg", "dj": {"nickname": "主播"}, "programCount": 3}
        ]});
        let radios = parse_subscribed_podcasts(&subs);
        assert_eq!(radios.len(), 1);
        assert_eq!(radios[0].name, "订阅电台");

        let artists = json!({"code": 200, "data": [
            {"id": 6452, "name": "周杰伦", "picUrl": "http://p/a.jpg"},
            {"id": 0}
        ]});
        let list = parse_subscribed_artists(&artists);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name, "周杰伦");
    }

    #[test]
    fn feed_event_mapping() {
        let body = json!({"code": 200, "event": [
            {
                "id": 100,
                "type": 18,
                "eventTime": 1700000000000u64,
                "user": {"nickname": "某艺人", "avatarUrl": "http://p/u.jpg"},
                "json": {
                    "msg": "分享一首歌",
                    "song": {
                        "id": 7, "name": "新歌", "ar": [{"name": "某艺人"}],
                        "al": {"id": 3, "name": "专辑", "picUrl": "http://p/c.jpg"}, "dt": 1000, "fee": 1
                    }
                }
            },
            {
                "id": 101,
                "eventType": 13,
                "eventTime": 1700000001000u64,
                "user": {"nickname": "好友"},
                "json": "{\"playlist\":{\"coverImgUrl\":\"http://p/pl.jpg\"},\"comment\":\"推荐歌单\"}"
            }
        ]});
        let events = parse_feed_events(&body);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].kind, "song");
        assert_eq!(events[0].user_name, "某艺人");
        assert_eq!(events[0].song.as_ref().unwrap().name, "新歌");
        assert_eq!(events[0].cover_url.as_deref(), Some("http://p/c.jpg"));
        assert_eq!(events[0].time_ms, 1700000000000);
        assert_eq!(events[1].kind, "playlist");
        assert_eq!(events[1].text, "推荐歌单");
        assert_eq!(events[1].cover_url.as_deref(), Some("http://p/pl.jpg"));
    }
}
