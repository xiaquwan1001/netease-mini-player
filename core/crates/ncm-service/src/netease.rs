use std::sync::RwLock;

use ncm_api_rs::{ApiClient, NcmError, Query};
use ncm_domain::{
    Album, AlbumBrief, AlbumDetail, AlbumItem, Artist, ArtistDetail, ChartSummary, Comment, CommentPage,
    DefaultSearch, FeedEvent, FollowCount, ForwardItem, HotArtist, HotSearchTerm, InboxItem, Lyric, MessageCounts,
    PlayRankEntry,
    Playlist, PlaylistCategory, PlaylistDetail, PodcastProgram, PodcastRadio, PrivateMessage,
    PrivateSession, ProfileDetail, RecentContact, SearchAlbum, SearchArtist, SearchBundle, SearchPage, SearchPlaylistItem,
    SearchPodcast, Session, SigninDay, SigninStatus, Song, StreamUrl, StyleTag, SuggestItem, TrackId,
    UserItem, WikiFact,
};
use ncm_provider::{
    BoxFuture, Capability, Provider, ProviderError, ProviderResult, RankingPeriod, SearchQuery,
    SongUrlRequest,
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
    Capability::SearchAll,
    Capability::Artist,
    Capability::ProfileDetail,
    Capability::PlaylistEdit,
    Capability::ListeningRank,
    Capability::StyleRecommend,
    Capability::Chart,
    Capability::AlbumSub,
    Capability::Follow,
    Capability::NewRelease,
    Capability::Similar,
    Capability::Signin,
    Capability::Wiki,
    Capability::Message,
];

/// 最近播放的三种资源(专辑/歌单/电台)
#[derive(Debug, Clone, Copy)]
enum RecentBucket {
    Album,
    Playlist,
    Podcast,
}

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

    /// 传 0 表示"用当前账号"
    async fn resolve_uid(&self, uid: u64) -> ProviderResult<u64> {
        if uid > 0 {
            return Ok(uid);
        }
        self.uid().await
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

    /// "我喜欢的音乐"歌单 id(specialType=5). 未登录时给能看懂的错.
    async fn liked_playlist_id(&self) -> ProviderResult<u64> {
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
            .ok_or_else(|| ProviderError::not_found("登录后才能读取我喜欢的音乐"))
    }

    /// cloudsearch 的通用调用: type = 1 单曲 / 10 专辑 / 100 歌手 / 1000 歌单 / 1009 播客
    async fn cloudsearch_body(
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

    /// 同步拿已缓存的当前账号 uid(不触发网络请求)
    fn uid_cached(&self) -> Option<u64> {
        let guard = self.inner.read().unwrap_or_else(|e| e.into_inner());
        guard.session.profile.as_ref().map(|p| p.user_id)
    }

    /// 最近播放三类(专辑/歌单/电台)共用的取数: 响应都是 {code, data:{list:[{data:{...}}]}}
    async fn recent_bucket(
        &self,
        bucket: RecentBucket,
        limit: u32,
    ) -> ProviderResult<Vec<Value>> {
        let (client, domain, ua, cookie) = self.snapshot();
        if !cookie.contains("MUSIC_U=") {
            return Err(ProviderError::auth("最近播放需要登录"));
        }
        let q = make_query(&cookie, &domain, &ua).param("limit", &limit.to_string());
        let resp = match bucket {
            RecentBucket::Album => client.record_recent_album(&q).await,
            RecentBucket::Playlist => client.record_recent_playlist(&q).await,
            RecentBucket::Podcast => client.record_recent_dj(&q).await,
        }
        .map_err(map_error)?;
        check_body(&resp.body)?;
        Ok(recent_items(&resp.body))
    }

    /// 签到进度原始结构 → SigninStatus
    async fn fetch_signin_progress(&self) -> ProviderResult<SigninStatus> {
        let (client, domain, ua, cookie) = self.snapshot();
        if !cookie.contains("MUSIC_U=") {
            return Err(ProviderError::auth("签到需要登录"));
        }
        let q = make_query(&cookie, &domain, &ua);
        let resp = client.signin_progress(&q).await.map_err(map_error)?;
        check_body(&resp.body)?;
        Ok(parse_signin_progress(&resp.body))
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

/// 资源类型 → 评论 threadId 前缀(与 vendor 的 RESOURCE_TYPE_MAP 对齐)
pub fn thread_id_for(kind: &str, id: u64) -> Option<String> {
    let prefix = match kind {
        "song" => "R_SO_4_",
        "mv" => "R_MV_5_",
        "playlist" => "A_PL_0_",
        "album" => "R_AL_3_",
        "podcast" | "djradio" => "A_DJ_1_",
        "video" => "R_VI_62_",
        "event" => "A_EV_2_",
        "program" => "A_DR_14_",
        _ => return None,
    };
    Some(format!("{prefix}{id}"))
}

/// threadId → (vendor 的 type 参数, id 段). 用于点赞/楼层这类"只吃 type+id"的接口.
/// 动态的 threadId 是 A_EV_2_<eventId>_<userId>, id 段要原样保留这两段.
pub fn split_thread_id(thread_id: &str) -> Option<(&'static str, String)> {
    const MAP: &[(&str, &str)] = &[
        ("R_SO_4_", "0"),
        ("R_MV_5_", "1"),
        ("A_PL_0_", "2"),
        ("R_AL_3_", "3"),
        ("A_DJ_1_", "4"),
        ("R_VI_62_", "5"),
        ("A_EV_2_", "6"),
        ("A_DR_14_", "7"),
    ];
    for (prefix, ty) in MAP {
        if let Some(rest) = thread_id.strip_prefix(prefix) {
            if rest.is_empty() {
                return None;
            }
            return Some((ty, rest.to_string()));
        }
    }
    None
}

/// 楼层回复: {code, data:{comments:[...], hasMore, time}}
pub fn parse_comment_floor(body: &Value) -> ProviderResult<CommentPage> {
    let data = body.get("data").unwrap_or(body);
    let arr = data.get("comments").and_then(Value::as_array);
    let Some(arr) = arr else {
        return Ok(CommentPage::default());
    };
    Ok(CommentPage {
        comments: arr.iter().filter_map(|v| parse_comment(v, false)).collect(),
        total: u64_of(data, "total").unwrap_or(0),
        has_more: data.get("hasMore").and_then(Value::as_bool).unwrap_or(false),
        thread_id: String::new(),
    })
}

/// 关注/粉丝列表: {code, follow:[{userId,nickname,avatarUrl,signature}]} /
/// 粉丝接口把数组放在 "followeds"
pub fn parse_user_items(body: &Value, key: &str, followed: bool) -> Vec<UserItem> {
    let arr = body
        .get(key)
        .or_else(|| body.get("data"))
        .and_then(Value::as_array);
    let Some(arr) = arr else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| {
            let id = u64_of(v, "userId").or_else(|| u64_of(v, "id"))?;
            let name = str_of(v, "nickname")
                .or_else(|| str_of(v, "name"))
                .unwrap_or_default();
            if name.is_empty() {
                return None;
            }
            Some(UserItem {
                id,
                name,
                avatar_url: str_of(v, "avatarUrl")
                    .or_else(|| str_of(v, "picUrl"))
                    .filter(|s| s.starts_with("http")),
                signature: str_of(v, "signature").unwrap_or_default(),
                followed,
            })
        })
        .collect()
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
                    avatar_url: str_of(a, "picUrl")
                        .or_else(|| str_of(a, "img1v1Url"))
                        .filter(|s| !s.is_empty()),
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

/// 歌手详情: 头部(data.artist) + 热门歌曲(songs) + 专辑(hotAlbums)
pub fn parse_artist_detail(detail: &Value, top: &Value, albums: &Value) -> ArtistDetail {
    let info = detail.get("data").and_then(|d| d.get("artist")).or_else(|| detail.get("artist"));
    let id = info.and_then(|a| u64_of(a, "id")).unwrap_or(0);
    let name = info.and_then(|a| str_of(a, "name")).unwrap_or_default();
    let alias = info
        .and_then(|a| a.get("alias"))
        .and_then(Value::as_array)
        .map(|x| x.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default();
    let privileges = parse_privileges(top);
    let songs = top
        .get("songs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| parse_song_with(s, &privileges))
                .collect()
        })
        .unwrap_or_default();
    let album_list = albums
        .get("hotAlbums")
        .or_else(|| albums.get("albums"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|a| {
                    let id = u64_of(a, "id")?;
                    Some(AlbumBrief {
                        id,
                        name: str_of(a, "name").unwrap_or_default(),
                        cover_url: str_of(a, "picUrl").filter(|s| !s.is_empty()),
                        track_count: u64_of(a, "size").unwrap_or(0),
                        publish_time: u64_of(a, "publishTime").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    ArtistDetail {
        id,
        name,
        avatar_url: info
            .and_then(|a| str_of(a, "avatar"))
            .or_else(|| info.and_then(|a| str_of(a, "picUrl")))
            .filter(|s| !s.is_empty()),
        cover_url: info
            .and_then(|a| str_of(a, "cover"))
            .or_else(|| info.and_then(|a| str_of(a, "coverUrl")))
            .filter(|s| !s.is_empty()),
        alias,
        brief_desc: info.and_then(|a| str_of(a, "briefDesc")).unwrap_or_default(),
        album_count: info.and_then(|a| u64_of(a, "albumSize")).unwrap_or(0),
        music_count: info.and_then(|a| u64_of(a, "musicSize")).unwrap_or(0),
        songs,
        albums: album_list,
    }
}

/// 账号资料详情: user_detail 的 `profile` 对象
pub fn parse_profile_detail(body: &Value) -> ProfileDetail {
    let p = body.get("profile").unwrap_or(body);
    ProfileDetail {
        user_id: u64_of(p, "userId").unwrap_or(0),
        nickname: str_of(p, "nickname").unwrap_or_default(),
        avatar_url: str_of(p, "avatarUrl").filter(|s| !s.is_empty()),
        background_url: str_of(p, "backgroundUrl").filter(|s| !s.is_empty()),
        signature: str_of(p, "signature").unwrap_or_default(),
        vip: p.get("vipType").and_then(Value::as_i64).unwrap_or(0) > 0,
        follows: u64_of(p, "follows").unwrap_or(0),
        followeds: u64_of(p, "followeds").unwrap_or(0),
        level: u64_of(p, "level").unwrap_or(0),
    }
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

    /// 听歌排行(需要登录): type=0 全部时间 / type=1 最近一周.
    /// 响应形如 {code:200, allData:[{playCount,score,song:{...}}], weekData:[...]}
    fn play_ranking(
        &self,
        period: RankingPeriod,
    ) -> BoxFuture<'_, ProviderResult<Vec<PlayRankEntry>>> {
        Box::pin(async move {
            let uid = self.uid().await?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("uid", &uid.to_string())
                .param("type", period.type_param());
            let resp = client.user_record(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_play_ranking(&resp.body, period))
        })
    }

    /// 我的曲风偏好: 系统按听歌口味算出来的风格(登录才有).
    /// 未登录/接口给空时退化成通用曲风表(style_list 的二级标签), 保证推荐页总有入口.
    fn style_preference(&self) -> BoxFuture<'_, ProviderResult<Vec<StyleTag>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.style_preference(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut tags = parse_style_preference(&resp.body);
            if tags.is_empty() {
                let fallback = client.style_list(&q).await.map_err(map_error)?;
                check_body(&fallback.body)?;
                tags = parse_style_list(&fallback.body, 12);
            }
            Ok(tags)
        })
    }

    /// 某个曲风下的歌曲: 响应形如 {code:200, data:{songs:[...], page:{...}}}
    fn style_songs<'a>(
        &'a self,
        tag_id: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            if tag_id.is_empty() {
                return Err(ProviderError::not_found("曲风 id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("tagId", tag_id)
                .param("size", &limit.to_string())
                .param("cursor", "0");
            let resp = client.style_song(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_style_songs(&resp.body))
        })
    }

    /// 某个曲风下的歌单: 响应形如 {code:200, data:{playlist:[...], page:{...}}}
    fn style_playlists<'a>(
        &'a self,
        tag_id: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            if tag_id.is_empty() {
                return Err(ProviderError::not_found("曲风 id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("tagId", tag_id)
                .param("size", &limit.to_string())
                .param("cursor", "0");
            let resp = client.style_playlist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_style_playlists(&resp.body))
        })
    }

    /// 排行榜列表: 榜单就是歌单, 详情直接走 playlist_songs / playlist_detail.
    /// 响应形如 {code, list:[{id,name,coverImgUrl,updateFrequency,trackCount,playCount,tracks}]}
    fn charts(&self) -> BoxFuture<'_, ProviderResult<Vec<ChartSummary>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.toplist_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_charts(&resp.body))
        })
    }

    /// 歌单分类: 响应形如 {code, categories:{0:"语种",...}, sub:[{category:0,name:"华语"},...]}
    fn playlist_categories(&self) -> BoxFuture<'_, ProviderResult<Vec<PlaylistCategory>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.playlist_catlist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_playlist_categories(&resp.body))
        })
    }

    /// 分类歌单: /api/playlist/list, 响应 {code, playlists:[{id,name,coverImgUrl,trackCount}], total, more}
    fn playlists_by_category<'a>(
        &'a self,
        cat: &'a str,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("cat", if cat.is_empty() { "全部" } else { cat })
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string())
                .param("order", "hot");
            let resp = client.top_playlist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_playlist_bucket(&resp.body, "playlists"))
        })
    }

    /// 精品歌单: /api/playlist/highquality/list, 响应 {code, playlists:[...], more, lasttime}
    fn high_quality_playlists<'a>(
        &'a self,
        cat: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("cat", if cat.is_empty() { "全部" } else { cat })
                .param("limit", &limit.to_string());
            let resp = client.top_playlist_highquality(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_playlist_bucket(&resp.body, "playlists"))
        })
    }

    /// 我收藏的专辑: 响应 {code, data:[{id,name,picUrl,artist:{name},size}], hasMore}
    fn subscribed_albums(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("查看收藏的专辑需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("offset", "0");
            let resp = client.album_sublist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_album_items(&resp.body))
        })
    }

    /// 收藏/取消收藏专辑: t=1 收藏, 0 取消
    fn set_album_subscribed(
        &self,
        album_id: u64,
        subscribed: bool,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("收藏专辑需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &album_id.to_string())
                .param("t", if subscribed { "1" } else { "0" });
            let resp = client.album_sub(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 新建歌单: 响应 {code, id, playlist:{id,...}}
    fn create_playlist<'a>(&'a self, name: &'a str) -> BoxFuture<'a, ProviderResult<u64>> {
        Box::pin(async move {
            let name = name.trim();
            if name.is_empty() {
                return Err(ProviderError::internal("歌单名不能为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("新建歌单需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua).param("name", name);
            let resp = client.playlist_create(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let body = &resp.body;
            u64_of(body, "id")
                .or_else(|| body.get("playlist").and_then(|p| u64_of(p, "id")))
                .ok_or_else(|| ProviderError::internal("新建歌单: 响应里没有 id"))
        })
    }

    /// 删除歌单
    fn delete_playlist(&self, playlist_id: u64) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("删除歌单需要登录"));
            }
            if playlist_id == 0 {
                return Err(ProviderError::not_found("playlist id 为空"));
            }
            let q = make_query(&cookie, &domain, &ua).param("id", &playlist_id.to_string());
            let resp = client.playlist_delete(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    fn rename_playlist<'a>(
        &'a self,
        playlist_id: u64,
        name: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let name = name.trim();
            if name.is_empty() {
                return Err(ProviderError::internal("歌单名不能为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("修改歌单需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &playlist_id.to_string())
                .param("name", name);
            let resp = client.playlist_name_update(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    fn update_playlist_desc<'a>(
        &'a self,
        playlist_id: u64,
        desc: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("修改歌单需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &playlist_id.to_string())
                .param("desc", desc);
            let resp = client.playlist_desc_update(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 把一首歌移出歌单
    fn remove_track(
        &self,
        playlist_id: u64,
        track: TrackId,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("修改歌单需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &playlist_id.to_string())
                .param("ids", &track.to_string());
            let resp = client.playlist_track_delete(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 评论点赞: vendor 用 (type,id) 拼 threadId, 这里反解 threadId
    fn like_comment<'a>(
        &'a self,
        thread_id: &'a str,
        comment_id: u64,
        liked: bool,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let (resource_type, owner) = split_thread_id(thread_id)
                .ok_or_else(|| ProviderError::unsupported(format!("无法识别的 threadId: {thread_id}")))?;
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("点赞评论需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("type", resource_type)
                .param("id", &owner)
                .param("cid", &comment_id.to_string())
                .param("t", if liked { "1" } else { "0" });
            let resp = client.comment_like(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 楼层回复: 某条评论下的回复列表
    fn comment_replies<'a>(
        &'a self,
        thread_id: &'a str,
        parent_comment_id: u64,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        Box::pin(async move {
            let (resource_type, owner) = split_thread_id(thread_id)
                .ok_or_else(|| ProviderError::unsupported(format!("无法识别的 threadId: {thread_id}")))?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("type", resource_type)
                .param("id", &owner)
                .param("parentCommentId", &parent_comment_id.to_string())
                .param("limit", &limit.to_string());
            let resp = client.comment_floor(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut page = parse_comment_floor(&resp.body)?;
            page.thread_id = thread_id.to_string();
            Ok(page)
        })
    }

    /// 回复评论(需要登录)
    fn reply_comment<'a>(
        &'a self,
        thread_id: &'a str,
        comment_id: u64,
        content: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let content = content.trim();
            if content.is_empty() {
                return Err(ProviderError::internal("回复内容不能为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("回复评论需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("threadId", thread_id)
                .param("commentId", &comment_id.to_string())
                .param("content", content);
            let resp = client.comment_reply(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 某人关注的人. 响应形如 {code, follow:[{userId,nickname,avatarUrl,signature}]}
    fn user_follows(
        &self,
        uid: u64,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<UserItem>>> {
        Box::pin(async move {
            let uid = self.resolve_uid(uid).await?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("uid", &uid.to_string())
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.user_follows(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            // 这个列表里的人都是我关注的
            Ok(parse_user_items(&resp.body, "follow", true))
        })
    }

    /// 某人的粉丝
    fn user_followeds(
        &self,
        uid: u64,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<UserItem>>> {
        Box::pin(async move {
            let uid = self.resolve_uid(uid).await?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("uid", &uid.to_string())
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.user_followeds(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            // 粉丝列表里接口不给"我有没有关注 ta", 在 UI 里按需点关注
            Ok(parse_user_items(&resp.body, "followeds", false))
        })
    }

    /// 关注/取关某人: t=1 关注, 0 取关
    fn set_follow(&self, uid: u64, follow: bool) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            if uid == 0 {
                return Err(ProviderError::not_found("用户 id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("关注需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &uid.to_string())
                .param("t", if follow { "1" } else { "0" });
            let resp = client.follow(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 我的关注/粉丝数: {code, follow, fans, ...}
    fn follow_counts(&self) -> BoxFuture<'_, ProviderResult<FollowCount>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("关注数需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.user_subcount(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(FollowCount {
                follows: u64_of(&resp.body, "follow").unwrap_or(0),
                fans: u64_of(&resp.body, "fans").unwrap_or(0),
            })
        })
    }

    /// 新歌速递: {code, result:[{id,name,picUrl,song:{完整歌曲}}]}
    fn new_songs(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("limit", &limit.to_string());
            let resp = client.personalized_newsong(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_new_songs(&resp.body))
        })
    }

    /// 新碟上架: {code, albums:[{id,name,picUrl,artist:{name},size}]}
    fn new_albums(
        &self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.album_new(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_album_items(&resp.body))
        })
    }

    /// 相似歌曲: {code, songs:[完整歌曲]}
    fn similar_songs(
        &self,
        song_id: u64,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            if song_id == 0 {
                return Err(ProviderError::not_found("song id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &song_id.to_string())
                .param("limit", &limit.to_string());
            let resp = client.simi_song(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_song_bucket(&resp.body, "songs"))
        })
    }

    /// 相似歌单: {code, playlists:[...]}
    fn similar_playlists(
        &self,
        song_id: u64,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            if song_id == 0 {
                return Err(ProviderError::not_found("song id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &song_id.to_string())
                .param("limit", &limit.to_string());
            let resp = client.simi_playlist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_playlist_bucket(&resp.body, "playlists"))
        })
    }

    /// 相似歌手: {code, artists:[{id,name,picUrl}]}(需要登录)
    fn similar_artists(&self, artist_id: u64) -> BoxFuture<'_, ProviderResult<Vec<Artist>>> {
        Box::pin(async move {
            if artist_id == 0 {
                return Err(ProviderError::not_found("artist id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("相似歌手需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua).param("id", &artist_id.to_string());
            let resp = client.simi_artist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_similar_artists(&resp.body))
        })
    }

    /// 每日推荐"不感兴趣": /api/v2/discovery/recommend/dislike
    fn dislike_recommend_song(&self, song_id: u64) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            if song_id == 0 {
                return Err(ProviderError::not_found("song id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("不感兴趣需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua).param("id", &song_id.to_string());
            let resp = client.recommend_songs_dislike(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 私人 FM"不再播放": /api/radio/trash/add
    fn trash_fm_song(&self, song_id: u64) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            if song_id == 0 {
                return Err(ProviderError::not_found("song id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("不感兴趣需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua).param("id", &song_id.to_string());
            let resp = client.fm_trash(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 历史日推日期列表: {code, data:{dates:[...], noHistoryMessage, purchaseUrl}}
    /// 非 VIP 时 dates 为空并给一句提示, 当成"没有历史"处理.
    fn history_recommend_dates(&self) -> BoxFuture<'_, ProviderResult<Vec<String>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("历史日推需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.history_recommend_songs(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_history_dates(&resp.body))
        })
    }

    /// 某个日期的历史日推: {code, data:{songs:[...]}}
    fn history_recommend_songs<'a>(&'a self, date: &'a str) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            if date.trim().is_empty() {
                return Err(ProviderError::not_found("日期为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("历史日推需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua).param("date", date);
            let resp = client.history_recommend_songs_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_song_bucket(
                resp.body.get("data").unwrap_or(&resp.body),
                "songs",
            ))
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

    /// 最近播放-专辑(服务端记录, 需要登录)
    fn recent_albums(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async move {
            let items = self.recent_bucket(RecentBucket::Album, limit).await?;
            Ok(items.iter().filter_map(parse_album_item).collect())
        })
    }

    /// 最近播放-歌单(服务端记录, 需要登录)
    fn recent_playlists(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        Box::pin(async move {
            let items = self.recent_bucket(RecentBucket::Playlist, limit).await?;
            Ok(items.iter().filter_map(parse_playlist).collect())
        })
    }

    /// 最近播放-播客/电台(服务端记录, 需要登录)
    fn recent_podcasts(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<PodcastRadio>>> {
        Box::pin(async move {
            let items = self.recent_bucket(RecentBucket::Podcast, limit).await?;
            Ok(items.iter().filter_map(parse_radio).collect())
        })
    }

    /// 云贝签到状态(需要登录)
    fn signin_status(&self) -> BoxFuture<'_, ProviderResult<SigninStatus>> {
        Box::pin(async move { self.fetch_signin_progress().await })
    }

    /// 签到(需要登录). 已签到时不重复请求(接口会回 "重复签到" 错误).
    fn sign_in(&self) -> BoxFuture<'_, ProviderResult<SigninStatus>> {
        Box::pin(async move {
            let before = self.fetch_signin_progress().await?;
            if before.signed_today {
                return Ok(before);
            }
            let (client, domain, ua, cookie) = self.snapshot();
            // type=0 实测回 "功能暂不支持"(安卓端通道), 只有 type=1(web) 真的签到成功.
            let q = make_query(&cookie, &domain, &ua).param("type", "1");
            let resp = client.daily_signin(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let point = resp
                .body
                .get("point")
                .and_then(Value::as_u64)
                .unwrap_or(0) as u32;
            let mut status = self.fetch_signin_progress().await?;
            status.signed_today = true;
            status.today_point = point;
            Ok(status)
        })
    }

    /// 删除自己的评论(需要登录)
    fn delete_comment<'a>(
        &'a self,
        thread_id: &'a str,
        comment_id: u64,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("删除评论需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("threadId", thread_id)
                .param("commentId", &comment_id.to_string());
            let resp = client.comment_delete(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 歌曲百科: 曲风/语种/BPM/获奖成就, 压成 label/value 对.
    ///
    /// vendor 的 song_wiki_summary 走 eapi: 桌面身份(PC UA + os=pc)实测正常,
    /// 安卓身份(官方安卓 UA + os=android)实测回 code=432 Unknown error;
    /// 同一个 path 换 weapi 通道两边都正常, 所以先用 weapi, 失败再退回 vendor 的 eapi 实现。
    fn song_wiki(&self, song_id: u64) -> BoxFuture<'_, ProviderResult<Vec<WikiFact>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let mut opt = ncm_api_rs::RequestOption::default();
            opt.crypto = ncm_api_rs::CryptoType::Weapi;
            if !cookie.is_empty() {
                opt.cookie = Some(cookie.clone());
            }
            opt.ua = ua.clone();
            opt.domain = domain.clone();
            let body = serde_json::json!({ "songId": song_id.to_string() });
            let weapi = client
                .request("/api/song/play/about/block/page", body, opt)
                .await
                .map_err(map_error)
                .and_then(|r| {
                    check_body(&r.body)?;
                    Ok(r)
                });
            if let Ok(resp) = weapi {
                return Ok(parse_song_wiki(&resp.body));
            }
            let q = make_query(&cookie, &domain, &ua).param("id", &song_id.to_string());
            let resp = client.song_wiki_summary(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_song_wiki(&resp.body))
        })
    }

    /// 新歌速递(按地区). area → areaId 是服务端的枚举: 0 全部 / 7 华语 / 8 日语 / 16 韩语 / 96 欧美
    fn new_songs_by_area<'a>(
        &'a self,
        area: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("type", &song_area_id(area).to_string());
            let resp = client.top_song(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut songs = parse_top_songs(&resp.body);
            songs.truncate(limit as usize);
            Ok(songs)
        })
    }

    /// 新碟上架(按地区). `top_album` 的 weekData 在部分地区为空, monthData 才有货,
    /// 所以两边合并(按 id 去重)再截断。
    fn new_albums_by_area<'a>(
        &'a self,
        area: &'a str,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("area", album_area_code(area))
                .param("limit", &limit.to_string())
                .param("offset", "0");
            let resp = client.top_album(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_new_albums(&resp.body, limit))
        })
    }

    /// 热门歌手榜
    fn hot_artists(
        &self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<HotArtist>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.top_artists(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_hot_artists(&resp.body))
        })
    }

    /// 未读消息计数(需登录)
    fn message_counts(&self) -> BoxFuture<'_, ProviderResult<MessageCounts>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("消息需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.pl_count(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let n = |key: &str| -> u32 {
                resp.body.get(key).and_then(Value::as_u64).unwrap_or(0) as u32
            };
            Ok(MessageCounts {
                private: n("msg"),
                notices: n("notice"),
                comments: n("comment"),
                forwards: n("forward"),
            })
        })
    }

    /// 私信会话列表(需登录)
    fn private_sessions(
        &self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<PrivateSession>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("私信需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.msg_private(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_private_sessions(&resp.body))
        })
    }

    /// 私信历史(需登录)
    fn private_history(
        &self,
        user_id: u64,
        limit: u32,
        before_ms: u64,
    ) -> BoxFuture<'_, ProviderResult<Vec<PrivateMessage>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("私信需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("uid", &user_id.to_string())
                .param("limit", &limit.to_string())
                .param("before", &before_ms.to_string());
            let resp = client.msg_private_history(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let me = self.uid_cached().unwrap_or(0);
            Ok(parse_private_history(&resp.body, me))
        })
    }

    /// 通知(需登录)
    fn message_notices(
        &self,
        limit: u32,
        last_time_ms: u64,
    ) -> BoxFuture<'_, ProviderResult<Vec<InboxItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("通知需要登录"));
            }
            let before = if last_time_ms == 0 { -1 } else { last_time_ms as i64 };
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("lasttime", &before.to_string());
            let resp = client.msg_notices(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_notices(&resp.body))
        })
    }

    /// 评论/回复消息(需登录)
    fn comment_messages(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<InboxItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("评论消息需要登录"));
            }
            let uid = self.uid().await?;
            let q = make_query(&cookie, &domain, &ua)
                .param("uid", &uid.to_string())
                .param("limit", &limit.to_string())
                .param("before", "-1");
            let resp = client.msg_comments(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_comment_messages(&resp.body))
        })
    }

    /// 消息中心"@我"(需登录). vendor 的 msg_forwards 只发 offset/limit, 没有
    /// lasttime 游标 → last_time_ms 保留参数形状, 当前恒取最新一页.
    fn forward_messages(
        &self,
        limit: u32,
        _last_time_ms: u64,
    ) -> BoxFuture<'_, ProviderResult<Vec<ForwardItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("@我需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("offset", "0");
            let resp = client.msg_forwards(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_forwards(&resp.body))
        })
    }

    /// 最近联系人(需登录). vendor 的 msg_recentcontact 发空 body, limit 只能客户端截断.
    fn recent_contacts(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<RecentContact>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("最近联系人需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.msg_recentcontact(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut list = parse_recent_contacts(&resp.body);
            if (limit as usize) < list.len() {
                list.truncate(limit as usize);
            }
            Ok(list)
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
            let mut page = parse_comments(&resp.body)?;
            page.thread_id = thread_id_for(kind, id).unwrap_or_default();
            Ok(page)
        })
    }

    /// 精彩评论(单独接口). threadId 反解出 vendor 的 type + id, 再按资源查。
    /// 动态(A_EV_2_)的 id 段是 `eventId_userId`, 热门接口只认 eventId, 这里不支持。
    fn hot_comments<'a>(
        &'a self,
        thread_id: &'a str,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        Box::pin(async move {
            let (ty, rid) = split_thread_id(thread_id).ok_or_else(|| {
                ProviderError::unsupported(format!("hot_comments: 无法识别的 threadId {thread_id}"))
            })?;
            if ty == "6" {
                return Err(ProviderError::unsupported("hot_comments: 动态暂不支持热门评论"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("type", ty)
                .param("id", &rid)
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.comment_hot(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut page = parse_comments(&resp.body)?;
            page.thread_id = thread_id.to_string();
            Ok(page)
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

    /// 综合搜索: 单曲/歌手/专辑/歌单/播客 五个板块并发拉取.
    /// 单曲失败直接报错(主板块); 其余板块失败只留空, 不让一个类型拖垮整页.
    fn search_all<'a>(
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

    /// 歌手详情: 头部资料 + 热门歌曲 + 专辑. 专辑接口失败只影响专辑板块.
    fn artist_detail(&self, artist_id: u64) -> BoxFuture<'_, ProviderResult<ArtistDetail>> {
        Box::pin(async move {
            if artist_id == 0 {
                return Err(ProviderError::not_found("artist id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let base = || {
                make_query(&cookie, &domain, &ua).param("id", &artist_id.to_string())
            };
            let (detail, top, albums) = futures::future::join3(
                async { client.artist_detail(&base()).await.map_err(map_error) },
                async { client.artist_top_song(&base()).await.map_err(map_error) },
                async {
                    client
                        .artist_album(&base().param("limit", "20"))
                        .await
                        .map_err(map_error)
                },
            )
            .await;
            let detail = detail?;
            check_body(&detail.body)?;
            let top = top?;
            check_body(&top.body)?;
            // 专辑走 weapi, 匿名/风控下可能失败: 不是致命错误
            let albums_body = match albums {
                Ok(resp) if check_body(&resp.body).is_ok() => resp.body,
                _ => Value::Null,
            };
            Ok(parse_artist_detail(&detail.body, &top.body, &albums_body))
        })
    }

    /// 个人主页资料(背景图/头像/签名/关注数). 需要登录.
    fn profile_detail(&self) -> BoxFuture<'_, ProviderResult<ProfileDetail>> {
        Box::pin(async move {
            let uid = self.uid().await?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("uid", &uid.to_string());
            let resp = client.user_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_profile_detail(&resp.body))
        })
    }

    /// 收藏曲目到歌单(需要登录)
    fn add_to_playlist(
        &self,
        playlist_id: u64,
        track: TrackId,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            if playlist_id == 0 {
                return Err(ProviderError::not_found("playlist id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("收藏到歌单需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("op", "add")
                .param("pid", &playlist_id.to_string())
                .param("tracks", &track.to_string());
            let resp = client.playlist_tracks(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// "我喜欢的音乐"曲目, 按收藏时间从新到旧.
    /// likelist 的 id 顺序不可靠(实测体感随机); 歌单详情的 trackIds[].at 才是加入时间(ms).
    fn liked_songs_ordered(&self) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async move {
            let playlist_id = self.liked_playlist_id().await?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &playlist_id.to_string())
                .param("s", "8");
            let resp = client.playlist_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut entries: Vec<(u64, i64)> = resp
                .body
                .get("playlist")
                .and_then(|p| p.get("trackIds"))
                .and_then(Value::as_array)
                .map(|arr| {
                    arr.iter()
                        .filter_map(|t| {
                            Some((
                                u64_of(t, "id")?,
                                t.get("at").and_then(Value::as_i64).unwrap_or(0),
                            ))
                        })
                        .collect()
                })
                .unwrap_or_default();
            if entries.is_empty() {
                return Ok(Vec::new());
            }
            // at 大 = 更晚收藏; at 缺失(0) 保持服务端顺序
            entries.sort_by(|a, b| b.1.cmp(&a.1));
            let ids: Vec<u64> = entries.into_iter().map(|(id, _)| id).collect();
            let mut by_id: std::collections::HashMap<u64, Song> =
                std::collections::HashMap::new();
            for chunk in ids.chunks(500) {
                let joined = chunk
                    .iter()
                    .map(|id| id.to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                let q = make_query(&cookie, &domain, &ua).param("ids", &joined);
                let detail = client.song_detail(&q).await.map_err(map_error)?;
                check_body(&detail.body)?;
                for s in parse_song_list(&detail.body) {
                    by_id.insert(s.id.0, s);
                }
            }
            Ok(ids.iter().filter_map(|id| by_id.remove(id)).collect())
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
    fn default_search(&self) -> BoxFuture<'_, ProviderResult<Option<DefaultSearch>>> {
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

    /// 动态评论: vendor 走 /api/v1/resource/comments/<threadId>.
    fn event_comments<'a>(
        &'a self,
        thread_id: &'a str,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("threadId", thread_id)
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.comment_event(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut page = parse_comments(&resp.body)?;
            page.thread_id = thread_id.to_string();
            Ok(page)
        })
    }

    /// 动态点赞: vendor resource_like, type=6 表示动态, 传 threadId.
    fn like_event<'a>(
        &'a self,
        thread_id: &'a str,
        liked: bool,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("点赞动态需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("type", "6")
                .param("threadId", thread_id)
                .param("t", if liked { "1" } else { "0" });
            let resp = client.resource_like(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 转发动态: /api/event/forward
    fn forward_event<'a>(
        &'a self,
        event_id: u64,
        user_id: u64,
        msg: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("转发动态需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("evId", &event_id.to_string())
                .param("uid", &user_id.to_string())
                .param("forwards", msg);
            let resp = client.event_forward(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
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
        creator_id: pl
            .get("creator")
            .and_then(|c| u64_of(c, "userId"))
            .or_else(|| u64_of(pl, "userId"))
            .unwrap_or(0),
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
fn parse_comment(v: &Value, hot: bool) -> Option<Comment> {
    let id = u64_of(v, "commentId")?;
    let user = v.get("user");
    Some(Comment {
        id,
        user_id: user.and_then(|u| u64_of(u, "userId")).unwrap_or(0),
        user_name: user.and_then(|u| str_of(u, "nickname")).unwrap_or_default(),
        avatar_url: user.and_then(|u| str_of(u, "avatarUrl")),
        content: str_of(v, "content").unwrap_or_default(),
        time_ms: u64_of(v, "time").unwrap_or(0),
        liked_count: u64_of(v, "likedCount").unwrap_or(0),
        liked: v.get("liked").and_then(Value::as_bool).unwrap_or(false),
        reply_count: v
            .get("showFloorComment")
            .and_then(|f| u64_of(f, "replyCount"))
            .or_else(|| u64_of(v, "replyCount"))
            .unwrap_or(0),
        // 精彩评论的 ipLocation.location 是空串, 只有普通评论才有归属地
        ip_location: v
            .get("ipLocation")
            .and_then(|ip| str_of(ip, "location"))
            .map(|s| s.trim().to_string())
            .unwrap_or_default(),
        hot,
    })
}

/// 评论列表的响应形如 {code:200, total, more, hotComments:[...], comments:[...]}
/// 精彩评论在前(hotComments), 其后是最新评论, 按 commentId 去重.
pub fn parse_comments(body: &Value) -> ProviderResult<CommentPage> {
    let mut seen = std::collections::HashMap::new();
    let mut comments: Vec<Comment> = Vec::new();
    for (key, hot) in [("hotComments", true), ("comments", false)] {
        let Some(arr) = body.get(key).and_then(Value::as_array) else {
            continue;
        };
        for v in arr {
            let Some(c) = parse_comment(v, hot) else { continue };
            match seen.get(&c.id).copied() {
                Some(idx) => {
                    // 同一条评论在热评和最新里各出现一次: 保留先到的(hot 版),
                    // 但热评常常没有 IP 归属地, 从后面那份补上
                    let existing: &mut Comment = &mut comments[idx];
                    if existing.ip_location.is_empty() {
                        existing.ip_location = c.ip_location;
                    }
                }
                None => {
                    seen.insert(c.id, comments.len());
                    comments.push(c);
                }
            }
        }
    }
    Ok(CommentPage {
        thread_id: String::new(),
        comments,
        total: u64_of(body, "total").unwrap_or(0),
        // 普通评论页用 more, 热门评论页(comment_hot)用 hasMore
        has_more: body
            .get("more")
            .or_else(|| body.get("hasMore"))
            .and_then(Value::as_bool)
            .unwrap_or(false),
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
            Some(Artist {
                id: u64_of(v, "id").unwrap_or(0),
                name,
                avatar_url: str_of(v, "picUrl")
                    .or_else(|| str_of(v, "img1v1Url"))
                    .or_else(|| str_of(v, "avatar"))
                    .filter(|s| !s.is_empty()),
            })
        })
        .collect()
}

/// 历史日推日期: {code, data:{dates:["2024-06-20", ...]}}.
/// 兼容两种形态: 纯字符串数组 或 [{date: "..."}] 对象数组.
pub fn parse_history_dates(body: &Value) -> Vec<String> {
    let data = body.get("data").unwrap_or(body);
    let Some(arr) = data.get("dates").and_then(Value::as_array) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| {
            v.as_str()
                .map(str::to_string)
                .or_else(|| str_of(v, "date"))
                .or_else(|| str_of(v, "day"))
        })
        .filter(|s| !s.trim().is_empty())
        .collect()
}

/// 新歌速递: {code, result:[{id,name,picUrl,song:{完整歌曲}}]} —— 曲目在 item.song 里
pub fn parse_new_songs(body: &Value) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get("result")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                // 只认 song 字段里的完整歌曲; 外层的 id/name 是推荐位元数据
                .filter_map(|item| parse_song_with(item.get("song")?, &privileges))
                .collect()
        })
        .unwrap_or_default()
}

/// 通用"songs 数组"桶: 相似歌曲/搜索结果等
pub fn parse_song_bucket(body: &Value, key: &str) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get(key)
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| parse_song_with(s, &privileges))
                .collect()
        })
        .unwrap_or_default()
}

/// 相似歌手: {code, artists:[{id,name,picUrl,img1v1Url}]}
pub fn parse_similar_artists(body: &Value) -> Vec<Artist> {
    let arr = body
        .get("artists")
        .or_else(|| body.get("data"))
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
            Some(Artist {
                id: u64_of(v, "id").unwrap_or(0),
                name,
                avatar_url: str_of(v, "picUrl")
                    .or_else(|| str_of(v, "img1v1Url"))
                    .filter(|s| s.starts_with("http")),
            })
        })
        .collect()
}

/// 排行榜列表: {code, list:[{id,name,coverImgUrl,updateFrequency,trackCount,playCount,tracks}]}.
/// 只取摘要, 曲目进榜单详情时再拉(接口本来也只给前 3 首做预览).
pub fn parse_charts(body: &Value) -> Vec<ChartSummary> {
    body.get("list")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|v| {
                    let id = u64_of(v, "id")?;
                    let name = str_of(v, "name")?;
                    if name.is_empty() {
                        return None;
                    }
                    Some(ChartSummary {
                        id,
                        name,
                        cover_url: str_of(v, "coverImgUrl").filter(|s| s.starts_with("http")),
                        update_frequency: str_of(v, "updateFrequency").unwrap_or_default(),
                        track_count: u64_of(v, "trackCount").unwrap_or(0),
                        play_count: u64_of(v, "playCount").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 歌单分类: {code, categories:{0:"语种",1:"风格",...}, sub:[{category:0,name:"华语"},...]}
/// 结果按 categories 的 key 顺序给出, 同一一级分类下的子分类按接口顺序.
pub fn parse_playlist_categories(body: &Value) -> Vec<PlaylistCategory> {
    let mut groups: Vec<(String, Vec<String>)> = Vec::new();
    let mut index_of = std::collections::HashMap::new();
    let categories = body.get("categories").and_then(Value::as_object);
    if let Some(cats) = categories {
        let mut keys: Vec<(&String, &Value)> = cats.iter().collect();
        // key 是 "0".."4" 的数字字符串, 按数值排才和图上的顺序一致
        keys.sort_by_key(|(k, _)| k.parse::<u32>().unwrap_or(u32::MAX));
        for (k, v) in keys {
            let name = v.as_str().unwrap_or(k).to_string();
            index_of.insert(k.clone(), groups.len());
            groups.push((name, Vec::new()));
        }
    }
    if let Some(subs) = body.get("sub").and_then(Value::as_array) {
        for sub in subs {
            let name = str_of(sub, "name").unwrap_or_default();
            if name.is_empty() {
                continue;
            }
            let key = sub
                .get("category")
                .map(|c| c.to_string().trim_matches('"').to_string())
                .unwrap_or_default();
            match index_of.get(&key) {
                Some(&i) => groups[i].1.push(name),
                None => groups.push((String::new(), vec![name])),
            }
        }
    }
    groups
        .into_iter()
        .filter(|(group, subs)| !group.is_empty() && !subs.is_empty())
        .map(|(group, subs)| PlaylistCategory { group, subs })
        .collect()
}

/// 歌单桶: {code, playlists:[{id,name,coverImgUrl,trackCount}]}
pub fn parse_playlist_bucket(body: &Value, key: &str) -> Vec<Playlist> {
    body.get(key)
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_playlist).collect())
        .unwrap_or_default()
}

/// 地区简写 → 新歌接口的 areaId(服务端枚举, 实测只有这五个有货)
fn song_area_id(area: &str) -> i64 {
    match area {
        "zh" => 7,
        "jp" => 8,
        "kr" => 16,
        "ea" => 96,
        _ => 0,
    }
}

/// 地区简写 → 新碟接口的 area 参数
fn album_area_code(area: &str) -> &'static str {
    match area {
        "zh" => "ZH",
        "jp" => "JP",
        "kr" => "KR",
        "ea" => "EA",
        _ => "ALL",
    }
}

/// 新歌速递: {code, data:[完整 song 对象(ar/artists + al/album + duration + privilege)]}
pub fn parse_top_songs(body: &Value) -> Vec<Song> {
    let privileges = parse_privileges(body);
    body.get("data")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| parse_song_with(s, &privileges))
                .collect()
        })
        .unwrap_or_default()
}

/// 新碟: {code, weekData:[album], monthData:[album]} —— 两边合并去重后截断
pub fn parse_new_albums(body: &Value, limit: u32) -> Vec<AlbumItem> {
    let mut out: Vec<AlbumItem> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for key in ["weekData", "monthData"] {
        let Some(arr) = body.get(key).and_then(Value::as_array) else {
            continue;
        };
        for v in arr {
            let Some(item) = parse_album_item(v) else {
                continue;
            };
            if seen.insert(item.id) {
                out.push(item);
                if out.len() >= limit as usize {
                    return out;
                }
            }
        }
    }
    out
}

/// 热门歌手榜: {artists:[{id,name,picUrl,fansCount}]}
pub fn parse_hot_artists(body: &Value) -> Vec<HotArtist> {
    body.get("artists")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|a| {
                    let id = u64_of(a, "id")?;
                    let name = str_of(a, "name")?;
                    if name.is_empty() {
                        return None;
                    }
                    Some(HotArtist {
                        id,
                        name,
                        avatar_url: str_of(a, "picUrl")
                            .or_else(|| str_of(a, "img1v1Url"))
                            .filter(|s| s.starts_with("http")),
                        fans: u64_of(a, "fansCount").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 私信/通知里那段 JSON 字符串(`"{\"msg\":\"...\"}"`)抽成一句纯文本。
/// 富消息(卡片/会员通知)没有 `msg`, 就退到 generalMsg 的标题/摘要/pushMsg。
pub fn msg_text(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let Ok(v) = serde_json::from_str::<Value>(trimmed) else {
        return trimmed.to_string();
    };
    if let Some(s) = v.get("msg").and_then(Value::as_str) {
        if !s.trim().is_empty() {
            return s.to_string();
        }
    }
    // 富消息(会员/活动卡片): 标题比 pushMsg 长文案更适合当列表摘要
    if let Some(g) = v.get("generalMsg") {
        for key in ["title", "inboxBriefContent", "noticeMsg", "subTitle"] {
            if let Some(s) = str_of(g, key) {
                if !s.trim().is_empty() {
                    return s;
                }
            }
        }
    }
    if let Some(s) = v.get("pushMsg").and_then(Value::as_str) {
        if !s.trim().is_empty() {
            return s.to_string();
        }
    }
    String::new()
}

/// 私信会话列表: {code, msgs:[{fromUser:{userId,nickname,avatarUrl},
/// lastMsg(JSON 字符串), lastMsgTime, newMsgCount}], newMsgCount}
pub fn parse_private_sessions(body: &Value) -> Vec<PrivateSession> {
    body.get("msgs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|m| {
                    let user = m.get("fromUser").or_else(|| m.get("toUser"))?;
                    let user_id = u64_of(user, "userId")?;
                    Some(PrivateSession {
                        user_id,
                        nickname: str_of(user, "nickname").unwrap_or_default(),
                        avatar_url: str_of(user, "avatarUrl"),
                        last_message: str_of(m, "lastMsg")
                            .map(|s| msg_text(&s))
                            .unwrap_or_default(),
                        last_time_ms: u64_of(m, "lastMsgTime").unwrap_or(0),
                        unread: u64_of(m, "newMsgCount").unwrap_or(0) as u32,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 私信历史: {code, msgs:[{id, fromUser:{userId,nickname,avatarUrl}, toUser, msg(JSON 字符串), time}]}
/// 接口按时间倒序给, 这里翻成正序(老的在前), 方便 UI 直接往下排。
pub fn parse_private_history(body: &Value, my_uid: u64) -> Vec<PrivateMessage> {
    let mut out: Vec<PrivateMessage> = body
        .get("msgs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|m| {
                    let from = m.get("fromUser").or_else(|| m.get("realFromUser"));
                    let from_user = from.and_then(|u| u64_of(u, "userId")).unwrap_or(0);
                    let content = str_of(m, "msg").map(|s| msg_text(&s)).unwrap_or_default();
                    if content.is_empty() {
                        return None;
                    }
                    Some(PrivateMessage {
                        id: u64_of(m, "id").unwrap_or(0),
                        from_me: my_uid != 0 && from_user == my_uid,
                        nickname: from
                            .and_then(|u| str_of(u, "nickname"))
                            .unwrap_or_default(),
                        avatar_url: from.and_then(|u| str_of(u, "avatarUrl")),
                        content,
                        time_ms: u64_of(m, "time").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    out.reverse();
    out
}

/// 通知: {code, notices:[{id, time, notice(JSON 字符串:
/// {generalNotice:{actionDesc,content,nativeUrl}, user:{userId,nickname,avatarUrl}})}]}
pub fn parse_notices(body: &Value) -> Vec<InboxItem> {
    body.get("notices")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|n| {
                    let raw = str_of(n, "notice").unwrap_or_default();
                    let inner: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);
                    let general = inner.get("generalNotice");
                    let user = inner.get("user");
                    let mut text = general
                        .and_then(|g| str_of(g, "actionDesc"))
                        .unwrap_or_default();
                    let detail = general
                        .and_then(|g| str_of(g, "content"))
                        .unwrap_or_default();
                    if text.is_empty() {
                        // 没 actionDesc 的系统通知: 用 pushMsg/notice 兜底
                        text = str_of(n, "pushMsg")
                            .filter(|s| !s.trim().is_empty())
                            .unwrap_or_else(|| "系统通知".to_string());
                    }
                    Some(InboxItem {
                        id: u64_of(n, "id").unwrap_or(0),
                        kind: "notice".to_string(),
                        actor: user
                            .and_then(|u| str_of(u, "nickname"))
                            .unwrap_or_default(),
                        avatar_url: user.and_then(|u| str_of(u, "avatarUrl")),
                        text,
                        detail,
                        time_ms: u64_of(n, "time").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 评论/回复消息: {code, comments:[{commentId, content, beRepliedContent, time,
/// user:{userId,nickname,avatarUrl}, resourceJson(JSON 字符串:{name,...})}]}
pub fn parse_comment_messages(body: &Value) -> Vec<InboxItem> {
    body.get("comments")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|c| {
                    let text = str_of(c, "content").unwrap_or_default();
                    if text.is_empty() {
                        return None;
                    }
                    let user = c.get("user");
                    // 附注优先级: 被回复的资源名 > 我方原评论("我: 「...」")
                    let resource = str_of(c, "resourceJson")
                        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
                        .and_then(|v| str_of(&v, "name"))
                        .unwrap_or_default();
                    let replied = str_of(c, "beRepliedContent").unwrap_or_default();
                    let detail = if !resource.is_empty() { resource } else { replied };
                    Some(InboxItem {
                        id: u64_of(c, "commentId").unwrap_or(0),
                        kind: "comment".to_string(),
                        actor: user
                            .and_then(|u| str_of(u, "nickname"))
                            .unwrap_or_default(),
                        avatar_url: user.and_then(|u| str_of(u, "avatarUrl")),
                        text,
                        detail,
                        time_ms: u64_of(c, "time").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// @我: {code, forwards:[...], lasttime, more, newCount}
/// 真实空账号响应(2026-11 实测): {"code":200,"forwards":[],"lasttime":0,"more":false,"newCount":0}
/// 非空条目形状未实测(空账号拿不到), 按邻近接口(msg_private/notices)风格做防御式解析,
/// 兼容: {id|msgId, time|forwardTime, type, content|comment, json(JSON 字符串),
/// user|fromUser:{userId,nickname,avatarUrl}, eventId|event.id, picUrl|json.pics[].picUrl}.
/// 解析不出任何 id 的条目直接跳过.
pub fn parse_forwards(body: &Value) -> Vec<ForwardItem> {
    body.get("forwards")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|f| {
                    let event = f.get("event");
                    let id = u64_of(f, "id").or_else(|| u64_of(f, "msgId"));
                    let event_id =
                        u64_of(f, "eventId").or_else(|| event.and_then(|e| u64_of(e, "id")));
                    if id.is_none() && event_id.is_none() {
                        return None;
                    }
                    let user = f.get("user").or_else(|| f.get("fromUser"));
                    let mut comment = str_of(f, "content")
                        .or_else(|| str_of(f, "comment"))
                        .map(|s| msg_text(&s))
                        .unwrap_or_default();
                    if comment.is_empty() {
                        comment = str_of(f, "json").map(|s| msg_text(&s)).unwrap_or_default();
                    }
                    // 图片: 顶层 picUrl > 顶层对象/转发原动态(pics[].picUrl|urlCommon)
                    let pic_url = str_of(f, "picUrl")
                        .or_else(|| pics_of(f))
                        .or_else(|| event.and_then(pics_of))
                        .or_else(|| {
                            str_of(f, "json")
                                .and_then(|s| serde_json::from_str::<Value>(&s).ok())
                                .and_then(|v| pics_of(&v))
                        });
                    Some(ForwardItem {
                        id,
                        event_id,
                        user_id: user.and_then(|u| u64_of(u, "userId")),
                        nickname: user.and_then(|u| str_of(u, "nickname")),
                        avatar_url: user.and_then(|u| str_of(u, "avatarUrl")),
                        comment: if comment.is_empty() { None } else { Some(comment) },
                        time_ms: u64_of(f, "time")
                            .or_else(|| u64_of(f, "forwardTime"))
                            .map(normalize_ms),
                        forward_type: u64_of(f, "type").map(|t| t as u32),
                        pic_url,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 转发/动态载荷里的首图: pics[].picUrl|urlCommon
fn pics_of(v: &Value) -> Option<String> {
    v.get("pics")
        .and_then(Value::as_array)
        .and_then(|p| p.first())
        .and_then(|p| str_of(p, "picUrl").or_else(|| str_of(p, "urlCommon")))
}

/// 网易部分接口给秒级时间戳(10 位), 统一归一成毫秒.
/// 阈值 1e11(约 5138 年的秒数 / 1973 年的毫秒数), 两侧都不会误伤.
fn normalize_ms(t: u64) -> u64 {
    if t > 0 && t < 100_000_000_000 {
        t * 1000
    } else {
        t
    }
}

/// 最近联系人: {code, data:{follow:[{userId, nickname, avatarUrl, mutual, onlined,
/// vipType, gender, userType, remarkName, py, avatarDetail{...}}]}}
/// 实测(2026-11): 只有 data.follow 一个数组, 是"可发起私信的联系人/关注列表",
/// 不是"最近聊天"; 顺序是服务端顺序.
pub fn parse_recent_contacts(body: &Value) -> Vec<RecentContact> {
    body.get("data")
        .and_then(|d| d.get("follow"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|c| {
                    let user_id = u64_of(c, "userId")?;
                    Some(RecentContact {
                        user_id,
                        nickname: str_of(c, "nickname").unwrap_or_default(),
                        avatar_url: str_of(c, "avatarUrl").filter(|s| s.starts_with("http")),
                        mutual: c.get("mutual").and_then(Value::as_bool).unwrap_or(false),
                        onlined: c.get("onlined").and_then(Value::as_bool).unwrap_or(false),
                        vip_type: u64_of(c, "vipType").unwrap_or(0) as u32,
                        remark_name: str_of(c, "remarkName").filter(|s| !s.trim().is_empty()),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 收藏的专辑: {code, data:[{id,name,picUrl,artist:{name},size,subTime}], hasMore}
pub fn parse_album_items(body: &Value) -> Vec<AlbumItem> {
    body.get("data")
        .or_else(|| body.get("albums"))
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_album_item).collect())
        .unwrap_or_default()
}

/// 单个专辑对象(收藏专辑/最近播放专辑/新碟共用)
pub fn parse_album_item(v: &Value) -> Option<AlbumItem> {
    let id = u64_of(v, "id")?;
    let name = str_of(v, "name")?;
    if name.is_empty() {
        return None;
    }
    Some(AlbumItem {
        id,
        name,
        cover_url: str_of(v, "picUrl")
            .or_else(|| str_of(v, "coverImgUrl"))
            .filter(|s| s.starts_with("http")),
        artist: v
            .get("artist")
            .and_then(|a| str_of(a, "name"))
            .or_else(|| {
                v.get("artists").and_then(|a| {
                    a.as_array()
                        .and_then(|arr| arr.first())
                        .and_then(|x| str_of(x, "name"))
                })
            })
            .unwrap_or_default(),
        track_count: u64_of(v, "size")
            .or_else(|| u64_of(v, "trackCount"))
            .unwrap_or(0),
    })
}

/// 最近播放(专辑/歌单/电台)的响应形状: {code, data:{list:[{data:{...}}]}}
/// 只留下每条记录的 data 对象, 由各类型的解析器处理.
pub fn recent_items(body: &Value) -> Vec<Value> {
    body.get("data")
        .and_then(|d| d.get("list"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|it| it.get("data").cloned().filter(|d| d.is_object()))
                .collect()
        })
        .unwrap_or_default()
}

/// 签到进度: {code, data:{records:[{day,signed}], stats:[{id,currentProgress,description}],
/// today:{todaySignedIn}}}
/// stats 的 id: 6001 累计签到 / 4001 每周签到 / 5001 连续签到(28 天循环).
pub fn parse_signin_progress(body: &Value) -> SigninStatus {
    let data = body.get("data").unwrap_or(body);
    let signed_today = data
        .get("today")
        .and_then(|t| t.get("todaySignedIn"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let stats = data.get("stats").and_then(Value::as_array);
    let progress_of = |id: i64| -> u32 {
        stats
            .and_then(|arr| {
                arr.iter().find(|s| {
                    s.get("id").and_then(Value::as_i64) == Some(id)
                })
            })
            .and_then(|s| s.get("currentProgress").and_then(Value::as_u64))
            .unwrap_or(0) as u32
    };
    let recent = data
        .get("records")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|r| {
                    let day = str_of(r, "day")?;
                    Some(SigninDay {
                        day,
                        signed: r.get("signed").and_then(Value::as_bool).unwrap_or(false),
                    })
                })
                .take(7)
                .collect()
        })
        .unwrap_or_default();
    SigninStatus {
        signed_today,
        total_days: progress_of(6001),
        continuous_days: progress_of(5001),
        week_days: progress_of(4001),
        recent,
        today_point: 0,
    }
}

/// 歌曲百科: {code, data:{blocks:[{code, creatives:[{creativeType, uiElement:{mainTitle, textLinks},
/// resources:[{uiElement:{mainTitle, subTitles}}]}]}]}}
/// 只取 "音乐百科" 那个块(其余是相似歌曲/相关歌单/回忆坐标, 我们已有等价入口).
pub fn parse_song_wiki(body: &Value) -> Vec<WikiFact> {
    let blocks = body
        .get("data")
        .and_then(|d| d.get("blocks"))
        .and_then(Value::as_array);
    let Some(blocks) = blocks else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for block in blocks {
        if str_of(block, "code").as_deref() != Some("SONG_PLAY_ABOUT_SONG_BASIC") {
            continue;
        }
        let Some(creatives) = block.get("creatives").and_then(Value::as_array) else {
            continue;
        };
        for creative in creatives {
            let ui = creative.get("uiElement");
            let label = ui
                .and_then(|u| u.get("mainTitle"))
                .and_then(|t| str_of(t, "title"))
                .unwrap_or_default();
            if label.is_empty() {
                continue;
            }
            let mut values: Vec<String> = Vec::new();
            if let Some(texts) = ui.and_then(|u| u.get("textLinks")).and_then(Value::as_array) {
                for text in texts {
                    if let Some(t) = str_of(text, "text").filter(|s| !s.is_empty()) {
                        values.push(t);
                    }
                }
            }
            if let Some(resources) = creative.get("resources").and_then(Value::as_array) {
                for res in resources {
                    let rui = res.get("uiElement");
                    let title = rui
                        .and_then(|u| u.get("mainTitle"))
                        .and_then(|t| str_of(t, "title"))
                        .unwrap_or_default();
                    let mut parts: Vec<String> = Vec::new();
                    if !title.is_empty() {
                        parts.push(title);
                    }
                    if let Some(subs) = rui.and_then(|u| u.get("subTitles")).and_then(Value::as_array)
                    {
                        for sub in subs {
                            if let Some(t) = str_of(sub, "title").filter(|s| !s.is_empty()) {
                                parts.push(t);
                            }
                        }
                    }
                    if !parts.is_empty() {
                        values.push(parts.join(" "));
                    }
                }
            }
            if values.is_empty() {
                continue;
            }
            out.push(WikiFact { label, value: values.join(" / ") });
        }
    }
    out
}

/// 听歌排行的响应: {code:200, allData:[{playCount,score,song:{...}}], weekData:[...]}.
/// 名次按 score(其次 play_count)倒序, 保证 UI 拿到的顺序稳定.
pub fn parse_play_ranking(body: &Value, period: RankingPeriod) -> Vec<PlayRankEntry> {
    let key = match period {
        RankingPeriod::All => "allData",
        RankingPeriod::Week => "weekData",
    };
    let privileges = parse_privileges(body);
    let mut out: Vec<PlayRankEntry> = body
        .get(key)
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|item| {
                    let song = parse_song_with(item.get("song")?, &privileges)?;
                    Some(PlayRankEntry {
                        song,
                        play_count: u64_of(item, "playCount").unwrap_or(0),
                        score: u64_of(item, "score").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    out.sort_by(|a, b| {
        b.score
            .cmp(&a.score)
            .then_with(|| b.play_count.cmp(&a.play_count))
    });
    out
}

/// 曲风偏好的响应: {code:200, data:{tagPreferenceVos:[...], tags:[...]}}.
/// 登录态下真正有内容的是这两个数组之一, 字段名各版本略有差异, 统一容错.
pub fn parse_style_preference(body: &Value) -> Vec<StyleTag> {
    let data = body.get("data").unwrap_or(body);
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for key in ["tagPreferenceVos", "tags", "preferenceTags"] {
        let Some(arr) = data.get(key).and_then(Value::as_array) else {
            continue;
        };
        for item in arr {
            if let Some(tag) = parse_style_tag(item) {
                if seen.insert(tag.id.clone()) {
                    out.push(tag);
                }
            }
        }
    }
    // 有的版本 data 直接是数组
    if out.is_empty() {
        if let Some(arr) = data.as_array() {
            for item in arr {
                if let Some(tag) = parse_style_tag(item) {
                    if seen.insert(tag.id.clone()) {
                        out.push(tag);
                    }
                }
            }
        }
    }
    out
}

/// 通用曲风表(style_list)的响应: {code:200, data:[{tagId,tagName,picUrl,childrenTags:[...]}]}.
/// 取二级标签(level 2)作为推荐页入口; 二级为空时退回一级标签本身.
/// 这是"我的曲风偏好"为空时的兜底, 也是未登录用户能看到的风格入口.
pub fn parse_style_list(body: &Value, limit: usize) -> Vec<StyleTag> {
    let Some(arr) = body.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for top in arr {
        // 有二级标签就用二级; 一级标签本身只是分组名("语种"/"风格"), 不单列
        let mut expanded = false;
        if let Some(children) = top.get("childrenTags").and_then(Value::as_array) {
            for child in children {
                if let Some(tag) = parse_style_tag(child) {
                    out.push(tag);
                    expanded = true;
                }
                if out.len() >= limit {
                    return out;
                }
            }
        }
        if !expanded {
            if let Some(tag) = parse_style_tag(top) {
                out.push(tag);
            }
        }
        if out.len() >= limit {
            return out;
        }
    }
    out
}

fn parse_style_tag(v: &Value) -> Option<StyleTag> {
    // tagId 有时是数字有时是字符串
    let id = u64_of(v, "tagId")
        .map(|n| n.to_string())
        .or_else(|| str_of(v, "tagId"))
        .or_else(|| u64_of(v, "id").map(|n| n.to_string()))
        .or_else(|| str_of(v, "id"))?;
    let name = str_of(v, "tagName")
        .or_else(|| str_of(v, "name"))
        .unwrap_or_default();
    if id.is_empty() || name.is_empty() {
        return None;
    }
    // style_list 的 picUrl 是相对路径(yyimgs/<hash>), 没有 host, 直接用会报
    // "No host specified in URI"; 只保留绝对地址, 其余交给 UI 用默认图标.
    let cover_url = str_of(v, "picUrl")
        .or_else(|| str_of(v, "coverUrl"))
        .or_else(|| str_of(v, "imageUrl"))
        .filter(|s| s.starts_with("http"));
    Some(StyleTag {
        id,
        name,
        cover_url,
        song_count: u64_of(v, "songCount").or_else(|| u64_of(v, "songNum")),
    })
}

/// 曲风歌曲的响应: {code:200, data:{songs:[{...完整 song 对象...}], page:{...}}}
pub fn parse_style_songs(body: &Value) -> Vec<Song> {
    let data = body.get("data").unwrap_or(body);
    let privileges = parse_privileges(body);
    data.get("songs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| parse_song_with(s, &privileges))
                .collect()
        })
        .unwrap_or_default()
}

/// 曲风歌单的响应: {code:200, data:{playlist:[{id,name,cover,songCount,...}], page:{...}}}
pub fn parse_style_playlists(body: &Value) -> Vec<Playlist> {
    let data = body.get("data").unwrap_or(body);
    data.get("playlist")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_style_playlist).collect())
        .unwrap_or_default()
}

/// 曲风歌单用的字段名与用户歌单不同: cover / songCount(没有 coverImgUrl/trackCount)
fn parse_style_playlist(v: &Value) -> Option<Playlist> {
    let id = u64_of(v, "id")?;
    Some(Playlist {
        id,
        name: str_of(v, "name").unwrap_or_default(),
        cover_url: str_of(v, "cover")
            .or_else(|| str_of(v, "coverImgUrl"))
            .or_else(|| str_of(v, "picUrl"))
            .filter(|s| !s.is_empty()),
        track_count: u64_of(v, "songCount").or_else(|| u64_of(v, "trackCount")).unwrap_or(0),
        special: false,
    })
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

/// 动态配图. 线上 pics 是对象数组(2026-11-06 实测), 用 originUrl 拿最大图,
/// 退化到 pcSquareUrl/pcRectangleUrl/squareUrl/rectangleUrl;
/// 老的字符串数组形态也认.
pub fn parse_event_images(value: &Value) -> Vec<String> {
    let Some(arr) = value.as_array() else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| {
            v.as_str().map(str::to_string).or_else(|| {
                [
                    "originUrl",
                    "pcSquareUrl",
                    "pcRectangleUrl",
                    "squareUrl",
                    "rectangleUrl",
                    "thumbUrl",
                    "url",
                ]
                .iter()
                .find_map(|key| str_of(v, key))
            })
        })
        .filter(|s| !s.is_empty())
        .take(9)
        .collect()
}

/// 从 pics 里捞视频直链(部分动态把视频挂在配图节点上)
fn video_from_pics(value: &Value) -> Option<String> {
    let arr = value.as_array()?;
    arr.iter().find_map(|v| {
        ["videoUrl", "videoOriginalUrl"]
            .iter()
            .find_map(|key| str_of(v, key))
            .filter(|s| !s.is_empty())
    })
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
        // 配图在顶层 pics(线上实测), 少数通道塞在 json.pics/imgs 里
        let pics_value = event
            .get("pics")
            .or_else(|| payload.and_then(|p| p.get("pics").or_else(|| p.get("imgs"))));
        let images = pics_value.map(parse_event_images).unwrap_or_default();
        // 视频动态: 封面照旧用图片, 直链单独给 UI(点击交给系统播放器/浏览器)
        let video = payload
            .and_then(|p| p.get("video").or_else(|| p.get("mv")))
            .or_else(|| event.get("video"));
        let video_url = video
            .and_then(|v| {
                str_of(v, "playUrl")
                    .or_else(|| str_of(v, "playUrlHd"))
                    .or_else(|| str_of(v, "url"))
            })
            .or_else(|| pics_value.and_then(video_from_pics))
            .filter(|s| !s.is_empty());
        // 动态自带标题(艺人长文常用), 空串就当没有
        let title = payload
            .and_then(|p| str_of(p, "title"))
            .unwrap_or_default()
            .trim()
            .to_string();
        let cover_url = song.as_ref().and_then(Song::cover_url).or_else(|| {
            payload.and_then(|p| {
                str_of(p, "coverUrl")
                    .or_else(|| str_of(p, "coverImgUrl"))
                    .or_else(|| p.get("album").and_then(|a| str_of(a, "picUrl")))
                    .or_else(|| p.get("playlist").and_then(|x| str_of(x, "coverImgUrl")))
            })
        }).or_else(|| images.first().cloned()).or_else(|| {
            video.and_then(|v| str_of(v, "coverUrl").or_else(|| str_of(v, "cover")))
                .filter(|s| !s.is_empty())
        });
        let user = event.get("user");
        let user_name = user
            .and_then(|u| str_of(u, "nickname"))
            .or_else(|| payload.and_then(|p| str_of(p, "nickname")))
            .unwrap_or_default();
        let avatar_url = user.and_then(|u| str_of(u, "avatarUrl"));
        let user_id = user.and_then(|u| u64_of(u, "userId")).unwrap_or(0);
        // 评论/点赞都按 threadId 走, 优先 info.threadId, 兜底 info.commentThread.id
        let thread_id = info
            .and_then(|i| str_of(i, "threadId"))
            .or_else(|| {
                info.and_then(|i| i.get("commentThread"))
                    .and_then(|c| str_of(c, "id"))
            })
            .unwrap_or_default();
        let liked = info
            .and_then(|i| i.get("liked"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let liked_count = info.and_then(|i| u64_of(i, "likedCount")).unwrap_or(0);
        let share_count = info.and_then(|i| u64_of(i, "shareCount")).unwrap_or(0);
        let comment_count = info.and_then(|i| u64_of(i, "commentCount")).unwrap_or(0);
        let time_ms = u64_of(event, "eventTime")
            .or_else(|| u64_of(event, "time"))
            .unwrap_or(0);
        out.push(FeedEvent {
            id,
            thread_id,
            user_id,
            kind: event_kind(event_type).to_string(),
            user_name,
            avatar_url,
            text,
            song,
            cover_url,
            images,
            video_url,
            title,
            time_ms,
            liked,
            liked_count,
            share_count,
            comment_count,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use ncm_provider::ProviderErrorKind;
    use serde_json::json;

    /// 最近播放三类共用的外层形状: data.list[].data
    #[test]
    fn recent_bucket_unwraps_item_data() {
        let body = json!({
            "code": 200,
            "data": {
                "list": [
                    {"data": {"id": 1, "name": "野泳", "artists": [{"name": "祝游会"}], "size": 7}},
                    {"playCount": 3},
                    {"data": {"id": 2, "name": "", "size": 1}}
                ]
            }
        });
        let items = recent_items(&body);
        assert_eq!(items.len(), 2, "没有 data 对象的条目要丢掉");
        let album = parse_album_item(&items[0]).unwrap();
        assert_eq!(album.name, "野泳");
        assert_eq!(album.artist, "祝游会");
        assert_eq!(album.track_count, 7);
        assert!(parse_album_item(&items[1]).is_none(), "空名称的专辑要跳过");
    }

    /// 签到进度: today.todaySignedIn + stats[6001/4001/5001] + records
    #[test]
    fn signin_progress_mapping() {
        let body = json!({
            "code": 200,
            "data": {
                "records": [
                    {"day": "2026-11-06", "signed": true},
                    {"day": "2026-11-05", "signed": false}
                ],
                "stats": [
                    {"id": 6001, "currentProgress": 13},
                    {"id": 4001, "currentProgress": 5},
                    {"id": 5001, "currentProgress": 1}
                ],
                "today": {"todaySignedIn": true}
            }
        });
        let s = parse_signin_progress(&body);
        assert!(s.signed_today);
        assert_eq!(s.total_days, 13);
        assert_eq!(s.week_days, 5);
        assert_eq!(s.continuous_days, 1);
        assert_eq!(s.recent.len(), 2);
        assert!(s.recent[0].signed);
        assert_eq!(s.today_point, 0, "进度接口不给本次奖励");
    }

    /// 歌曲百科: 只取 SONG_PLAY_ABOUT_SONG_BASIC 块, 富文本压成 "a / b"
    #[test]
    fn song_wiki_flattens_basic_block() {
        let body = json!({
            "code": 200,
            "data": {"blocks": [
                {"code": "SONG_PLAY_ABOUT_MUSIC_MEMORY", "creatives": []},
                {"code": "SONG_PLAY_ABOUT_SONG_BASIC", "creatives": [
                    {
                        "creativeType": "songTag",
                        "uiElement": {"mainTitle": {"title": "曲风"}},
                        "resources": [
                            {"uiElement": {"mainTitle": {"title": "流行-华语流行"}}},
                            {"uiElement": {"mainTitle": {"title": "原声带-动画片原声"}}}
                        ]
                    },
                    {
                        "creativeType": "language",
                        "uiElement": {
                            "mainTitle": {"title": "语种"},
                            "textLinks": [{"text": "国语"}]
                        },
                        "resources": []
                    },
                    {
                        "creativeType": "songAward",
                        "uiElement": {"mainTitle": {"title": "获奖成就"}},
                        "resources": [
                            {"uiElement": {
                                "mainTitle": {"title": "第30届东方风云榜"},
                                "subTitles": [{"title": "获"}, {"title": "动感101年度金曲"}]
                            }}
                        ]
                    },
                    {"creativeType": "bpm", "uiElement": {"mainTitle": {"title": "BPM"}}, "resources": []}
                ]}
            ]}
        });
        let facts = parse_song_wiki(&body);
        assert_eq!(facts.len(), 3, "空值的 BPM 不出现; 其它三个块不算");
        assert_eq!(facts[0].label, "曲风");
        assert_eq!(facts[0].value, "流行-华语流行 / 原声带-动画片原声");
        assert_eq!(facts[1].value, "国语");
        assert_eq!(facts[2].value, "第30届东方风云榜 获 动感101年度金曲");
    }


    /// 私信里的 msg/lastMsg 是 JSON 字符串, 富消息要退到 generalMsg 的标题/摘要
    #[test]
    fn msg_text_unwraps_json_and_rich_payload() {
        assert_eq!(msg_text("你好"), "你好", "纯文本原样返回");
        assert_eq!(msg_text(r#"{"msg":"在吗"}"#), "在吗");
        assert_eq!(
            msg_text(r#"{"generalMsg":{"title":"本月等级权益已更新"},"pushMsg":"push"}"#),
            "本月等级权益已更新",
            "富消息优先用 generalMsg 标题"
        );
        assert_eq!(msg_text("  "), "");
    }

    #[test]
    fn private_sessions_and_history_mapping() {
        let sessions = json!({
            "code": 200,
            "msgs": [
                {"fromUser": {"userId": 7, "nickname": "VIP", "avatarUrl": "http://a/1.jpg"},
                 "lastMsg": "{\"msg\":\"本月权益已更新\"}", "lastMsgTime": 1700000000000u64, "newMsgCount": 6},
                {"fromUser": {"userId": 8, "nickname": "好友"}, "lastMsg": "hi", "lastMsgTime": 1600000000000u64, "newMsgCount": 0}
            ]
        });
        let list = parse_private_sessions(&sessions);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].user_id, 7);
        assert_eq!(list[0].last_message, "本月权益已更新");
        assert_eq!(list[0].unread, 6);
        assert_eq!(list[1].last_message, "hi");

        let history = json!({
            "code": 200,
            "msgs": [
                {"id": 2, "fromUser": {"userId": 42, "nickname": "我"}, "msg": "{\"msg\":\"在的\"}", "time": 200},
                {"id": 1, "fromUser": {"userId": 7, "nickname": "VIP"}, "msg": "你好", "time": 100}
            ]
        });
        let list = parse_private_history(&history, 42);
        assert_eq!(list.len(), 2);
        assert!(!list[0].from_me, "接口给的是倒序, 解析后老的在前");
        assert_eq!(list[0].content, "你好");
        assert!(list[1].from_me);
        assert_eq!(list[1].content, "在的");
    }

    #[test]
    fn notices_and_comment_messages_mapping() {
        let notices = json!({
            "code": 200,
            "notices": [
                {"id": 11, "time": 1779, "pushMsg": "push 文案",
                 "notice": "{\"generalNotice\":{\"actionDesc\":\"赞了你的主页背景\"},\"user\":{\"nickname\":\"小明\",\"avatarUrl\":\"http://a/2.jpg\"}}"},
                {"id": 12, "time": 1778, "pushMsg": "", "notice": "garbage"}
            ]
        });
        let list = parse_notices(&notices);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].actor, "小明");
        assert_eq!(list[0].text, "赞了你的主页背景");
        assert_eq!(list[0].time_ms, 1779);
        assert_eq!(list[1].text, "系统通知", "解析不出来的通知给兜底文案");

        let comments = json!({
            "code": 200,
            "comments": [
                {"commentId": 21, "content": "来了来了", "beRepliedContent": "我: 「旧评论」",
                 "time": 1777, "user": {"userId": 5, "nickname": "小红"},
                 "resourceJson": "{\"name\":\"我喜欢的音乐\",\"id\":9}"},
                {"commentId": 22, "content": "", "time": 1776}
            ]
        });
        let list = parse_comment_messages(&comments);
        assert_eq!(list.len(), 1, "空评论要丢掉");
        assert_eq!(list[0].actor, "小红");
        assert_eq!(list[0].text, "来了来了");
        assert_eq!(list[0].detail, "我喜欢的音乐", "优先显示被评论的资源名");
    }


    /// @我: 真实空响应(2026-11 实测, 本账号没有 @我 消息) — 顶层 forwards/lasttime/more/newCount
    #[test]
    fn forwards_empty_real_response() {
        let body = json!({"code": 200, "forwards": [], "lasttime": 0, "more": false, "newCount": 0});
        assert!(parse_forwards(&body).is_empty());
        // 缺 forwards 键 / 条目不是对象都不炸
        assert!(parse_forwards(&json!({"code": 301})).is_empty());
        assert!(parse_forwards(&json!({"code": 200, "forwards": [null, 1, "x"]})).is_empty());
    }

    /// @我 非空形状未实测, 用合成条目覆盖防御式解析的各分支
    #[test]
    fn forwards_synthetic_items_defensive() {
        let body = json!({
            "code": 200,
            "forwards": [
                // 形状 A: 顶层 content/user + eventId, content 是 JSON 字符串, 秒级时间
                {"id": 9001, "time": 1700000000i64, "type": 2,
                 "content": "{\"msg\":\"转发一句话\"}",
                 "user": {"userId": 7, "nickname": "小明", "avatarUrl": "http://a/1.jpg"},
                 "eventId": 42},
                // 形状 B: fromUser + event{id,pics} + json 兜底正文
                {"id": 9002, "forwardTime": 1600000000i64,
                 "fromUser": {"userId": 8, "nickname": "小红"},
                 "event": {"id": 43, "pics": [{"picUrl": "http://p/1.jpg"}]},
                 "json": "{\"msg\":\"看看图\"}"},
                // 无法识别 id → 跳过
                {"user": {"userId": 9, "nickname": "路人"}}
            ]
        });
        let list = parse_forwards(&body);
        assert_eq!(list.len(), 2, "解析不出 id 的条目跳过");
        assert_eq!(list[0].id, Some(9001));
        assert_eq!(list[0].event_id, Some(42));
        assert_eq!(list[0].user_id, Some(7));
        assert_eq!(list[0].nickname.as_deref(), Some("小明"));
        assert_eq!(list[0].comment.as_deref(), Some("转发一句话"));
        assert_eq!(list[0].forward_type, Some(2));
        assert_eq!(list[0].time_ms, Some(1_700_000_000_000), "秒级时间戳归一成毫秒");
        assert_eq!(list[1].id, Some(9002));
        assert_eq!(list[1].event_id, Some(43));
        assert_eq!(list[1].user_id, Some(8));
        assert_eq!(list[1].comment.as_deref(), Some("看看图"));
        assert_eq!(list[1].pic_url.as_deref(), Some("http://p/1.jpg"));
        assert!(list[1].avatar_url.is_none());
    }

    /// 最近联系人: 真实形状(2026-11 实测 data.follow)
    #[test]
    fn recent_contacts_follow_mapping() {
        let body = json!({
            "code": 200,
            "data": {"follow": [
                {"userId": 32953014u64, "nickname": "云音乐VIP",
                 "avatarUrl": "https://p4.music.126.net/a.jpg",
                 "mutual": false, "onlined": false, "vipType": 11, "gender": 0,
                 "userType": 10, "remarkName": "", "py": "VIP"},
                {"userId": 2, "nickname": "好友", "mutual": true, "onlined": true,
                 "remarkName": "老王"},
                {"nickname": "幽灵"}
            ]}
        });
        let list = parse_recent_contacts(&body);
        assert_eq!(list.len(), 2, "没有 userId 的条目跳过");
        assert_eq!(list[0].user_id, 32953014);
        assert_eq!(list[0].nickname, "云音乐VIP");
        assert_eq!(list[0].vip_type, 11);
        assert!(!list[0].mutual && !list[0].onlined);
        assert_eq!(list[0].remark_name, None, "空 remarkName 归 None");
        assert_eq!(list[1].remark_name.as_deref(), Some("老王"));
        assert!(list[1].mutual && list[1].onlined);
        // 顶层不是 data.follow 也不炸
        assert!(parse_recent_contacts(&json!({"code": 200})).is_empty());
    }

    /// 新歌速递: data[] 是完整 song 对象(artists/album/duration/privilege)
    #[test]
    fn top_songs_mapping() {
        let body = json!({
            "code": 200,
            "data": [
                {"id": 1, "name": "最重要的听众", "artists": [{"id": 9, "name": "法老"}],
                 "album": {"id": 3, "name": "专辑", "picUrl": "http://p/1.jpg"},
                 "duration": 334000, "fee": 0, "privilege": {"st": 0}},
                {"id": 2, "name": "Masterpiece", "artists": [{"id": 10, "name": "LNGSHOT"}],
                 "duration": 170000, "fee": 1, "privilege": {"st": -200}}
            ]
        });
        let songs = parse_top_songs(&body);
        assert_eq!(songs.len(), 2);
        assert_eq!(songs[0].artist_line(), "法老");
        assert_eq!(songs[0].duration_ms, 334000);
        assert_eq!(songs[0].album.as_ref().unwrap().name, "专辑");
        assert!(songs[0].playable);
        assert!(!songs[1].playable, "privilege.st=-200 要标成不可播");
        assert!(songs[1].is_vip());
    }

    /// 新碟: weekData 与 monthData 合并去重, 再按 limit 截断
    #[test]
    fn new_albums_merge_and_dedupe() {
        let album = |id: u64, name: &str| {
            json!({"id": id, "name": name, "picUrl": "http://p/a.jpg",
                   "artist": {"name": "歌手"}, "size": 3})
        };
        let body = json!({
            "code": 200,
            "weekData": [album(1, "Growth")],
            "monthData": [album(1, "Growth"), album(2, "Iceberg"), album(3, "家后")]
        });
        let list = parse_new_albums(&body, 2);
        assert_eq!(list.len(), 2, "同一张碟只出现一次, 且按 limit 截断");
        assert_eq!(list[0].name, "Growth");
        assert_eq!(list[1].name, "Iceberg");
        assert_eq!(list[0].track_count, 3);
        assert_eq!(list[0].artist, "歌手");
    }

    #[test]
    fn hot_artists_mapping() {
        let body = json!({
            "artists": [
                {"id": 3684, "name": "林俊杰", "picUrl": "http://p/1.jpg", "fansCount": 16908300},
                {"id": 0, "name": "", "fansCount": 1}
            ]
        });
        let list = parse_hot_artists(&body);
        assert_eq!(list.len(), 1, "空名字要跳过");
        assert_eq!(list[0].name, "林俊杰");
        assert_eq!(list[0].fans, 16908300);
        assert_eq!(list[0].avatar_url.as_deref(), Some("http://p/1.jpg"));
    }


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
                 "content": "好", "time": 1700000000000u64, "likedCount": 10, "liked": true,
                 "ipLocation": {"location": ""}},
                {"commentId": 2, "user": {"nickname": "B"}, "content": "赞"}
            ],
            "comments": [
                {"commentId": 2, "user": {"nickname": "B"}, "content": "赞",
                 "ipLocation": {"location": "广东"}},
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
        // 精彩评论带 hot 标记; 去重时保留先出现的 hot 版本, IP 归属地仍是空
        assert!(page.comments[0].hot);
        assert!(page.comments[1].hot);
        assert!(!page.comments[2].hot);
        assert!(page.comments[0].ip_location.is_empty());
        // 热评版没有 IP, 去重时从后面同一评论的普通版本补上
        assert_eq!(page.comments[1].ip_location, "广东");
        // 没有 ipLocation 字段时是空串(UI 不显示)
        assert!(page.comments[2].ip_location.is_empty());
    }

    #[test]
    fn hot_comments_page_shape() {
        // vendor comment_hot 的响应: {code, hasMore, hotComments:[...], total}
        // 注意用的是 hasMore(不是普通评论页的 more), 总数也是"热门评论"的总数
        let body = json!({
            "code": 200,
            "hasMore": true,
            "total": 9405,
            "hotComments": [
                {"commentId": 7, "user": {"nickname": "D"}, "content": "热",
                 "likedCount": 444050, "ipLocation": {"location": ""}},
                {"commentId": 8, "user": {"nickname": "E"}, "content": "也热"}
            ]
        });
        let page = parse_comments(&body).unwrap();
        assert_eq!(page.total, 9405);
        assert!(page.has_more);
        assert_eq!(page.comments.len(), 2);
        assert!(page.comments.iter().all(|c| c.hot));
        assert_eq!(page.comments[0].liked_count, 444050);
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

        // 关键词和推荐理由是两回事: keyword 拿去搜, show 只用来展示
        let def = json!({"code": 200, "data": {
            "showKeyword": "🔥Mili 你的十月榜首", "realkeyword": "Mili"
        }});
        let d = parse_default_search(&def).unwrap();
        assert_eq!(d.keyword, "Mili");
        assert_eq!(d.show_text, "🔥Mili 你的十月榜首");
        // 只有 showKeyword 时退化成"用它当关键词"
        let only_show = json!({"code": 200, "data": {"showKeyword": "周杰伦"}});
        assert_eq!(parse_default_search(&only_show).unwrap().keyword, "周杰伦");
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

    #[test]
    fn feed_event_detail_fields() {
        // 线上(2026-11-06)真实字段: pics 是对象数组, info 里有 threadId/likedCount,
        // user 里有 userId, json 里可能带 title. 这些是详情页/点赞/评论的依据.
        let body = json!({"code": 200, "event": [{
            "id": 38024377972u64,
            "type": 35,
            "eventTime": 1793228407720u64,
            "user": {"nickname": "某艺人", "userId": 1373758224u64,
                     "avatarUrl": "http://p/u.jpg"},
            "json": {"msg": "长文正文", "title": "标题一句"},
            "pics": [
                {"originUrl": "http://p/1.jpg", "pcSquareUrl": "http://p/1s.jpg"},
                {"originUrl": "http://p/2.jpg", "videoUrl": "http://v/2.mp4"}
            ],
            "info": {
                "threadId": "A_EV_2_38024377972_1373758224",
                "liked": true, "likedCount": 30, "shareCount": 4, "commentCount": 3
            }
        }]});
        let e = &parse_feed_events(&body)[0];
        assert_eq!(e.kind, "text");
        assert_eq!(e.user_id, 1373758224);
        assert_eq!(e.thread_id, "A_EV_2_38024377972_1373758224");
        assert_eq!(e.title, "标题一句");
        assert_eq!(e.images, vec!["http://p/1.jpg".to_string(), "http://p/2.jpg".to_string()]);
        assert_eq!(e.video_url.as_deref(), Some("http://v/2.mp4"));
        assert!(e.liked);
        assert_eq!(e.liked_count, 30);
        assert_eq!(e.share_count, 4);
        assert_eq!(e.comment_count, 3);
    }

    #[test]
    fn play_ranking_mapping() {
        let body = json!({
            "code": 200,
            "allData": [
                {"playCount": 100, "score": 90, "song": {"id": 1, "name": "A", "ar": [{"id": 7, "name": "x"}], "dt": 1000}},
                {"playCount": 200, "score": 95, "song": {"id": 2, "name": "B", "ar": [{"name": "y"}], "dt": 2000}}
            ],
            "weekData": [
                {"playCount": 5, "score": 5, "song": {"id": 3, "name": "C", "ar": [], "dt": 3000}}
            ]
        });
        let all = parse_play_ranking(&body, RankingPeriod::All);
        assert_eq!(all.len(), 2);
        // 按 score 倒序: B(95) 在 A(90) 前
        assert_eq!(all[0].song.name, "B");
        assert_eq!(all[0].play_count, 200);
        let week = parse_play_ranking(&body, RankingPeriod::Week);
        assert_eq!(week.len(), 1);
        assert_eq!(week[0].song.name, "C");
    }

    #[test]
    fn style_preference_mapping() {
        // 登录态: data 下的 tagPreferenceVos / tags 两种字段都认
        let body = json!({"code": 200, "data": {
            "tagPreferenceVos": [{"tagId": 1009, "tagName": "粤语流行"}],
            "tags": [
                {"tagId": "1020", "tagName": "华语流行", "picUrl": "http://p/a.jpg"},
                {"tagId": 1021, "tagName": "相对图", "picUrl": "yyimgs/abc==/123"}
            ]
        }});
        let tags = parse_style_preference(&body);
        assert_eq!(tags.len(), 3);
        // 相对路径(无 host)的 picUrl 要丢掉, 否则 UI 报 No host specified in URI
        assert!(tags[2].cover_url.is_none());
        assert_eq!(tags[0].id, "1009");
        assert_eq!(tags[1].name, "华语流行");
        assert_eq!(tags[1].cover_url.as_deref(), Some("http://p/a.jpg"));

        // 空偏好(未登录)返回空, 由调用方退化到通用曲风表
        let empty = json!({"code": 200, "data": {"tagPreferenceVos": [], "tags": []}});
        assert!(parse_style_preference(&empty).is_empty());
    }

    #[test]
    fn style_list_flattens_children() {
        let body = json!({"code": 200, "data": [
            {"tagId": 1, "tagName": "语种", "childrenTags": [
                {"tagId": 1009, "tagName": "粤语流行"},
                {"tagId": 1020, "tagName": "华语流行"}
            ]},
            {"tagId": 2, "tagName": "风格"}
        ]});
        let tags = parse_style_list(&body, 10);
        assert_eq!(tags.len(), 3);
        assert_eq!(tags[0].id, "1009");
        assert_eq!(tags[2].name, "风格");
        // limit 生效
        assert_eq!(parse_style_list(&body, 1).len(), 1);
    }

    #[test]
    fn thread_id_roundtrip_and_split() {
        assert_eq!(thread_id_for("song", 42).as_deref(), Some("R_SO_4_42"));
        assert_eq!(thread_id_for("playlist", 7).as_deref(), Some("A_PL_0_7"));
        assert!(thread_id_for("unknown", 1).is_none());

        assert_eq!(
            split_thread_id("R_SO_4_42"),
            Some(("0", "42".to_string()))
        );
        assert_eq!(
            split_thread_id("A_PL_0_7"),
            Some(("2", "7".to_string()))
        );
        // 动态的 id 段要保留 eventId_userId
        assert_eq!(
            split_thread_id("A_EV_2_38024377972_1373758224"),
            Some(("6", "38024377972_1373758224".to_string()))
        );
        assert!(split_thread_id("R_SO_4_").is_none());
        assert!(split_thread_id("garbage").is_none());
    }

    #[test]
    fn comment_floor_and_users_mapping() {
        let floor = json!({"code": 200, "data": {
            "comments": [
                {"commentId": 1, "content": "回复一", "user": {"userId": 9, "nickname": "A", "avatarUrl": "https://p/a.jpg"},
                 "likedCount": 2, "liked": true, "showFloorComment": {"replyCount": 3}},
                {"commentId": 2, "content": "回复二", "user": {"nickname": "B"}}
            ],
            "hasMore": true, "total": 2
        }});
        let page = parse_comment_floor(&floor).unwrap();
        assert_eq!(page.comments.len(), 2);
        assert_eq!(page.comments[0].user_id, 9);
        assert_eq!(page.comments[0].reply_count, 3);
        assert!(page.comments[0].liked);
        assert!(page.has_more);

        let follows = json!({"code": 200, "follow": [
            {"userId": 11, "nickname": "关注的人", "avatarUrl": "https://p/f.jpg", "signature": "hi"},
            {"userId": 12, "nickname": "另一个"}
        ]});
        let users = parse_user_items(&follows, "follow", true);
        assert_eq!(users.len(), 2);
        assert_eq!(users[0].signature, "hi");
        assert!(users[0].followed);
        assert_eq!(users[1].avatar_url, None);

        let followeds = json!({"code": 200, "followeds": [
            {"userId": 13, "nickname": "粉丝"}
        ]});
        let fans = parse_user_items(&followeds, "followeds", false);
        assert_eq!(fans.len(), 1);
        assert!(!fans[0].followed);
    }

    #[test]
    fn history_dates_mapping() {
        // 字符串数组
        let a = json!({"code": 200, "data": {"dates": ["2024-06-20", "2024-06-19"]}});
        assert_eq!(parse_history_dates(&a), vec!["2024-06-20", "2024-06-19"]);
        // 对象数组
        let b = json!({"code": 200, "data": {"dates": [
            {"date": "2024-06-18"}, {"day": "2024-06-17"}, {"x": 1}
        ]}});
        assert_eq!(parse_history_dates(&b), vec!["2024-06-18", "2024-06-17"]);
        // 非 VIP: 空数组
        let c = json!({"code": 200, "data": {"dates": [], "noHistoryMessage": "黑胶VIP可查看"}});
        assert!(parse_history_dates(&c).is_empty());
    }

    #[test]
    fn new_release_and_similar_mapping() {
        // 新歌: 曲目嵌在 result[].song 里
        let newsong = json!({"code": 200, "result": [
            {"id": 9, "name": "外层名", "song": {"id": 1, "name": "新歌一", "ar": [{"name": "A"}], "dt": 1000}},
            {"id": 10, "name": "没有 song 字段"}
        ]});
        let songs = parse_new_songs(&newsong);
        assert_eq!(songs.len(), 1);
        assert_eq!(songs[0].name, "新歌一");

        // 相似歌曲: 直接是 songs 数组
        let simi = json!({"code": 200, "songs": [
            {"id": 2, "name": "像它", "ar": [{"name": "B"}], "dt": 2000, "fee": 1}
        ]});
        let similar = parse_song_bucket(&simi, "songs");
        assert_eq!(similar.len(), 1);
        assert_eq!(similar[0].name, "像它");

        // 相似歌手
        let artists = json!({"code": 200, "artists": [
            {"id": 3, "name": "歌手C", "picUrl": "https://p/c.jpg"},
            {"id": 4, "name": "歌手D", "picUrl": "yyimgs/rel"}
        ]});
        let list = parse_similar_artists(&artists);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].avatar_url.as_deref(), Some("https://p/c.jpg"));
        assert!(list[1].avatar_url.is_none());
    }

    #[test]
    fn charts_mapping() {
        let body = json!({"code": 200, "list": [
            {"id": 19723756, "name": "飙升榜", "coverImgUrl": "https://p/a.jpg",
             "updateFrequency": "刚刚更新", "trackCount": 100, "playCount": 6522631680u64,
             "tracks": [{"id": 1, "name": "t"}]},
            {"id": 3778678, "name": "热歌榜", "coverImgUrl": "yyimgs/rel", "updateFrequency": "更新17首"},
            {"id": 2, "name": ""}
        ]});
        let charts = parse_charts(&body);
        assert_eq!(charts.len(), 2);
        assert_eq!(charts[0].name, "飙升榜");
        assert_eq!(charts[0].update_frequency, "刚刚更新");
        // 相对图片地址丢掉
        assert!(charts[1].cover_url.is_none());
    }

    #[test]
    fn playlist_categories_mapping() {
        let body = json!({"code": 200,
            "categories": {"0": "语种", "1": "风格", "4": "主题"},
            "sub": [
                {"category": 1, "name": "流行"},
                {"category": 0, "name": "华语"},
                {"category": 4, "name": "综艺"},
                {"category": 0, "name": "欧美"}
            ]});
        let groups = parse_playlist_categories(&body);
        // 按 categories 的数字 key 排序: 语种 → 风格 → 主题, 空组被过滤
        assert_eq!(groups.len(), 3);
        assert_eq!(groups[0].group, "语种");
        assert_eq!(groups[0].subs, vec!["华语".to_string(), "欧美".to_string()]);
        assert_eq!(groups[1].group, "风格");
        assert_eq!(groups[1].subs, vec!["流行".to_string()]);
    }

    #[test]
    fn playlists_and_albums_mapping() {
        let body = json!({"code": 200, "playlists": [
            {"id": 9, "name": "歌单一", "coverImgUrl": "https://p/c.jpg", "trackCount": 30}
        ]});
        let lists = parse_playlist_bucket(&body, "playlists");
        assert_eq!(lists.len(), 1);
        assert_eq!(lists[0].track_count, 30);

        let albums = json!({"code": 200, "data": [
            {"id": 5, "name": "专辑一", "picUrl": "https://p/a.jpg",
             "artist": {"id": 7, "name": "歌手"}, "size": 12},
            {"id": 6, "name": "专辑二", "picUrl": "yyimgs/rel",
             "artists": [{"name": "歌手B"}], "trackCount": 8}
        ]});
        let items = parse_album_items(&albums);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].artist, "歌手");
        assert_eq!(items[0].track_count, 12);
        assert_eq!(items[1].artist, "歌手B");
        assert!(items[1].cover_url.is_none());
    }

    #[test]
    fn style_songs_and_playlists_mapping() {
        let songs_body = json!({"code": 200, "data": {
            "songs": [{"id": 11, "name": "S", "ar": [{"name": "x"}], "dt": 1000, "fee": 1}],
            "page": {"total": 1}
        }});
        let songs = parse_style_songs(&songs_body);
        assert_eq!(songs.len(), 1);
        assert_eq!(songs[0].name, "S");

        let pl_body = json!({"code": 200, "data": {
            "playlist": [{"id": 22, "name": "P", "cover": "http://p/c.jpg", "songCount": 200}],
            "page": {"total": 1}
        }});
        let lists = parse_style_playlists(&pl_body);
        assert_eq!(lists.len(), 1);
        assert_eq!(lists[0].track_count, 200);
        assert_eq!(lists[0].cover_url.as_deref(), Some("http://p/c.jpg"));
    }
}
