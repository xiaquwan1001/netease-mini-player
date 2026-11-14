use std::sync::RwLock;

use ncm_api_rs::{ApiClient, CryptoType, NcmError, Query, RequestOption};
use ncm_domain::{
    Album, AlbumBrief, AlbumDetail, AlbumItem, Artist, ArtistAlbumPage, ArtistDetail, ArtistMv,
    ArtistMvPage, ArtistSongPage, ChartSummary, CloudPage, CloudSong, CloudUploadResult, Comment,
    CommentPage, CommentStats, DefaultSearch, DigitalAlbumDetail, DigitalAlbumPurchased,
    DigitalAlbumPurchasedEntry, DigitalAlbumSalesEntry, FeedEvent, FeedPage, FollowCount,
    ForwardItem, HotArtist, HotSearchDetailItem, HotSearchTerm, InboxItem, Lyric, MedalWall,
    MessageCounts, MvDetail, MvItem, MvUrl, PhoneLoginOutcome, PhoneLoginResult, PlayRankEntry,
    Playlist, PlaylistCategory, PlaylistDetail, PodcastProgram, PodcastRadio, PrivateMessage,
    PrivateSession, ProfileDetail, PurchasedSongEntry, QrLoginCheck, QrLoginKey, QrLoginOutcome,
    QrLoginState, RadioCategory, RadioExploreHome, RadioPick, RadioRankedDj, RadioRankedProgram,
    RadioRankedRadio, RadioSubscriber, RadioSubscriberPage, RadioToplist, RecentContact,
    SearchAlbum, SearchArtist, SearchBundle, SearchExact, SearchPage, SearchPlaylistItem,
    SearchPodcast, Session, SigninDay, SigninStatus, SmsCodeSent, Song, SongLikeState,
    SongPurchasedPage, StreamUrl, StyleTag, SuggestItem, ToplistCatalogGroup, ToplistCatalogItem,
    TrackId, UserItem, UserLevel, UserMedal, VipGrowth, VipMembership, VipOverview, VipSign,
    VipSignDay, VipTask, WikiFact, WordLyric,
};
use ncm_provider::{
    BoxFuture, Capability, Provider, ProviderError, ProviderErrorKind, ProviderResult,
    RankingPeriod, SearchQuery, SongUrlRequest,
};
use serde_json::Value;
pub const CAPABILITIES: &[Capability] = &[
    Capability::Search,
    Capability::SongUrl,
    Capability::SongLike,
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
    Capability::Vip,
    Capability::DigitalAlbum,
    Capability::RadioExplore,
    Capability::Cloud,
];
/// 内置网易云直连 provider.
/// 协议与加解密全部委托给 vendor/ncm-api (api-enhanced 的 Rust 移植).
pub struct NeteaseProvider {
    inner: RwLock<Inner>,
    /// 只读接口的进程内响应缓存(TTL 300s / 200 条 LRU / 同 key 单飞).
    /// 白名单与纪律见 crate::read_cache: 只放与账号无关的只读接口.
    cache: crate::read_cache::ReadCache,
    /// 关注艺人 id 的进程内缓存(见 search::search_suggest).
    ///
    /// 输入联想要用「我关注的人」排序, 但联想是每按键一次请求, 不能每次都打
    /// artist_sublist(那也是风控敏感接口). 这里按 TTL 缓存一次列表, 登录/切号
    /// 时会随 update_session 一起清空.
    followed_artists: RwLock<Option<(std::time::Instant, Vec<u64>)>>,
    /// 联想单曲封面缓存(歌曲 id → 封面 URL).
    ///
    /// 建议接口的歌曲只回 album.picId(纯数字), 不回 picUrl, 所以 UI 上联想列表的
    /// 单曲只能显示占位图标(用户反馈「图片没有真正加载」). 这里按 id 缓存一次
    /// song_detail 里查到的专辑封面, 只补真正缺图的那几条.
    suggest_covers: RwLock<std::collections::HashMap<u64, String>>,
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
        Self {
            client,
            session,
            domain,
            ua,
        }
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
        Self {
            inner: RwLock::new(Inner::new(session, domain, ua)),
            cache: crate::read_cache::ReadCache::default(),
            followed_artists: RwLock::new(None),
            suggest_covers: RwLock::new(std::collections::HashMap::new()),
        }
    }

    /// 覆盖域名/UA (风控实验用): 例如切 interface3 + 网页 UA
    pub fn with_channel(session: Session, domain: Option<String>, ua: Option<String>) -> Self {
        Self {
            inner: RwLock::new(Inner::new(session, domain, ua)),
            cache: crate::read_cache::ReadCache::default(),
            followed_artists: RwLock::new(None),
            suggest_covers: RwLock::new(std::collections::HashMap::new()),
        }
    }

    pub fn update_session(&self, session: Session) {
        let mut guard = self.inner.write().unwrap_or_else(|e| e.into_inner());
        let domain = guard.domain.clone();
        let ua = guard.ua.clone();
        *guard = Inner::new(session, domain, ua);
        drop(guard);
        // 会话变了(登录/登出/切账号)就整体清空只读缓存: 白名单里的接口虽然匿名可用,
        // 但 body 里仍可能带账号侧字段(歌单的 subscribed、搜索结果的 privileges),
        // key 里没有 uid, 不清就可能把上一个账号的数据端给新账号.
        self.cache.clear();
        // 关注列表是账号私有的, 必须一起清; 封面缓存与账号无关, 保留.
        *self
            .followed_artists
            .write()
            .unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// 只读接口的响应缓存(各能力模块统一走这里).
    pub(super) fn read_cache(&self) -> &crate::read_cache::ReadCache {
        &self.cache
    }

    /// 传 0 表示"用当前账号"
    pub(super) async fn resolve_uid(&self, uid: u64) -> ProviderResult<u64> {
        if uid > 0 {
            return Ok(uid);
        }
        self.uid().await
    }

    /// 当前账号 uid(登录后由 profile 落盘); 没有就先拉一次资料
    pub(super) async fn uid(&self) -> ProviderResult<u64> {
        let cached = {
            let guard = self.inner.read().unwrap_or_else(|e| e.into_inner());
            guard.session.profile.as_ref().map(|p| p.user_id)
        };
        if let Some(uid) = cached {
            return Ok(uid);
        }
        Ok(Provider::profile(self).await?.user_id)
    }

    /// 同步拿已缓存的当前账号 uid(不触发网络请求)
    pub(super) fn uid_cached(&self) -> Option<u64> {
        let guard = self.inner.read().unwrap_or_else(|e| e.into_inner());
        guard.session.profile.as_ref().map(|p| p.user_id)
    }

    /// await 之前先把要用的东西克隆出来: 避免 std RwLock guard 跨 await (破坏 Send)
    pub(super) fn snapshot(&self) -> (ApiClient, Option<String>, Option<String>, String) {
        let guard = self.inner.read().unwrap_or_else(|e| e.into_inner());
        let mut q = guard.query();
        q.cookie = None;
        (
            guard.client.clone(),
            guard.domain.clone(),
            guard.ua.clone(),
            guard.session.cookie.clone(),
        )
    }
}
pub(super) fn make_query(cookie: &str, domain: &Option<String>, ua: &Option<String>) -> Query {
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
pub(super) fn proxy_hint() -> String {
    for key in [
        "HTTPS_PROXY",
        "https_proxy",
        "ALL_PROXY",
        "all_proxy",
        "HTTP_PROXY",
        "http_proxy",
    ] {
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
pub(super) fn error_chain(err: &(dyn std::error::Error + 'static)) -> String {
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

pub(super) fn map_error(e: NcmError) -> ProviderError {
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

pub(super) fn map_code(code: i64, msg: String) -> ProviderError {
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
pub(super) fn check_body(body: &Value) -> ProviderResult<()> {
    check_body_with(body, map_code)
}

/// 同上, 但业务码到错误的映射可换(见 [`map_login_code`]).
pub(super) fn check_body_with(
    body: &Value,
    map: fn(i64, String) -> ProviderError,
) -> ProviderResult<()> {
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
            Err(map(code, msg))
        }
    }
}

/// 手机号登录两条接口的业务码补充.
///
/// 全局 `map_code` 把 400/503 都归成 Internal, 但登录场景这两个码是**用户能当场处理**的:
/// 400(号码/区号/验证码不合法)算输入错误(Auth), 503(发码太频繁)标成可重试.
/// 只作用于 sms/captcha/sent 与 login/cellphone, 不动全局语义.
pub(super) fn map_login_code(code: i64, msg: String) -> ProviderError {
    let detail = if msg.is_empty() {
        format!("code={code}")
    } else {
        format!("code={code}: {msg}")
    };
    match code {
        400 => ProviderError::new(ProviderErrorKind::Auth, false, detail),
        503 => ProviderError::new(ProviderErrorKind::Internal, true, detail),
        _ => map_code(code, msg),
    }
}

/// 并行子请求的失败容忍: 把错误收进 errs, 只返回成功的 body.
pub(super) fn take_body(
    result: Result<ncm_api_rs::ApiResponse, NcmError>,
    errs: &mut Vec<ProviderError>,
) -> Option<Value> {
    match result {
        Ok(resp) => match check_body(&resp.body) {
            Ok(()) => Some(resp.body),
            Err(e) => {
                errs.push(e);
                None
            }
        },
        Err(e) => {
            errs.push(map_error(e));
            None
        }
    }
}

pub use self::account::*;
pub use self::album::*;
pub use self::artist::*;
pub use self::cloud::*;
pub use self::comment::*;
pub use self::community::*;
pub use self::lyric::*;
pub use self::parse::*;
pub use self::playlist::*;
pub use self::radio::*;
pub use self::search::*;
pub use self::song::*;
pub use self::vip::*;

mod account;
mod album;
mod artist;
mod cloud;
mod comment;
mod community;
mod lyric;
mod parse;
mod playlist;
mod provider;
mod radio;
mod search;
mod song;
mod vip;

#[cfg(test)]
mod tests;
