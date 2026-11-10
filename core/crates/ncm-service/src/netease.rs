use std::sync::RwLock;

use ncm_api_rs::{ApiClient, CryptoType, NcmError, Query, RequestOption};
use ncm_domain::{
    Album, AlbumBrief, AlbumDetail, AlbumItem, Artist, ArtistDetail, ArtistMv, ArtistMvPage, ArtistSongPage, ChartSummary, Comment, CommentPage,
    MvDetail, MvUrl,
    CommentStats,
    DefaultSearch, FeedEvent, FollowCount, ForwardItem, HotArtist, HotSearchTerm, InboxItem, Lyric, MessageCounts,
    PlayRankEntry,
    HotSearchDetailItem, Playlist, PlaylistCategory, PlaylistDetail, PodcastProgram, PodcastRadio, PrivateMessage,
    SearchExact, ToplistCatalogGroup, ToplistCatalogItem,
    PrivateSession, ProfileDetail, RecentContact, SearchAlbum, SearchArtist, SearchBundle, SearchPage, SearchPlaylistItem,
    SearchPodcast, Session, SigninDay, SigninStatus, Song, StreamUrl, StyleTag, SuggestItem, TrackId,
    WordLyric,
    MedalWall, QrLoginCheck, QrLoginKey, QrLoginState, UserItem, UserLevel, UserMedal, VipGrowth, VipMembership, VipOverview, VipSign, VipSignDay,
    VipTask, WikiFact,
    DigitalAlbumDetail, DigitalAlbumPurchased, DigitalAlbumPurchasedEntry, DigitalAlbumSalesEntry,
    PurchasedSongEntry, SongPurchasedPage,
    RadioCategory, RadioExploreHome, RadioPick, RadioRankedDj, RadioRankedProgram, RadioRankedRadio,
    RadioSubscriber, RadioSubscriberPage, RadioToplist,
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
    Capability::Vip,
    Capability::DigitalAlbum,
    Capability::RadioExplore,
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

    /// 取当前登录账号 uid: 先问等级接口(data.userId, 服务端权威), 失败/缺失再回退本地缓存.
    /// 勋章接口的 uid 是**必填**(空串时服务端回 code=499).
    async fn remote_uid(
        &self,
        client: &ApiClient,
        domain: &Option<String>,
        ua: &Option<String>,
        cookie: &str,
    ) -> Option<u64> {
        let resp = client.user_level(&make_query(cookie, domain, ua)).await.ok()?;
        if check_body(&resp.body).is_err() {
            return self.uid_cached();
        }
        resp.body
            .get("data")
            .and_then(|d| u64_of(d, "userId"))
            .filter(|u| *u > 0)
            .or_else(|| self.uid_cached())
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

/// 并行子请求的失败容忍: 把错误收进 errs, 只返回成功的 body.
fn take_body(
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

/// vip_info_v2: data.associator + redVipLevel.
/// is_vip 判定用 associator.expireTime > now(服务端 data.now, 缺省本机时间);
/// **不要**按 vipCode/vipLevel 判断 —— 过期账号这两个字段仍是旧值.
pub fn parse_vip_membership(body: &Value) -> Option<VipMembership> {
    let data = body.get("data")?;
    let associator = data.get("associator").unwrap_or(&Value::Null);
    let expire_time_ms = u64_of(associator, "expireTime").unwrap_or(0);
    let now = u64_of(data, "now").unwrap_or_else(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    });
    Some(VipMembership {
        level: u64_of(associator, "vipLevel").unwrap_or(0) as u32,
        red_vip_level: data
            .get("redVipLevel")
            .and_then(Value::as_i64)
            .unwrap_or(0)
            .max(0) as u32,
        expire_time_ms,
        is_vip: expire_time_ms > 0 && expire_time_ms > now,
        // 负数(= 未知/非年费)保留原值, 由 UI 决定怎么显示
        annual_count: data
            .get("redVipAnnualCount")
            .and_then(Value::as_i64)
            .unwrap_or(-1) as i32,
    })
}

/// vip_growthpoint: data.userLevel(成长值/今日成长值) + data.levelCard(等级名/图).
/// 今日成长值藏在 userLevel.extJson 这个"JSON 字符串"里(不是对象).
pub fn parse_vip_growth(body: &Value) -> Option<VipGrowth> {
    let data = body.get("data")?;
    let user = data.get("userLevel").unwrap_or(&Value::Null);
    let card = data.get("levelCard").unwrap_or(&Value::Null);
    let mut level_name = str_of(card, "levelName").unwrap_or_default();
    if level_name.trim().is_empty() {
        level_name = str_of(user, "levelName").unwrap_or_default();
    }
    let today_score = str_of(user, "extJson")
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v.get("todayScore").and_then(Value::as_i64))
        .unwrap_or(0);
    Some(VipGrowth {
        level: u64_of(user, "level")
            .or_else(|| u64_of(card, "level"))
            .unwrap_or(0) as u32,
        level_name,
        growth_point: user.get("growthPoint").and_then(Value::as_i64).unwrap_or(0),
        today_score,
        max_level: user.get("maxLevel").and_then(Value::as_bool).unwrap_or(false),
    })
}

/// vip_sign_info: data 是**数组, 只回最近 7 天**(不是月份/累计).
/// score > 0 才算已签 —— 未签的那天 recordId/time 也是 0, 拿它们判断会全判成"已签".
pub fn parse_vip_sign(body: &Value) -> VipSign {
    let days: Vec<VipSignDay> = body
        .get("data")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|v| {
                    let date = str_of(v, "timeStr")?;
                    let score = u64_of(v, "score").unwrap_or(0) as u32;
                    Some(VipSignDay {
                        date,
                        signed: score > 0,
                        today: v.get("today").and_then(Value::as_bool).unwrap_or(false),
                        score,
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let signed_today = days.iter().any(|d| d.today && d.signed);
    let week_signed = days.iter().filter(|d| d.signed).count() as u32;
    VipSign {
        days,
        signed_today,
        week_signed,
    }
}

/// vip_tasks: data.taskList[].taskItems[] 平铺.
/// 实测 name 常为空串(action 才是可读标题); targets 为 null = 没有可量化目标(不显示进度条).
/// 非 null 的 targets 形状未实测, 这里兼容 数字 / 数组 两种.
pub fn parse_vip_tasks(body: &Value) -> (Vec<VipTask>, i64) {
    let data = body.get("data").unwrap_or(&Value::Null);
    let task_score = data.get("taskScore").and_then(Value::as_i64).unwrap_or(0);
    let mut out: Vec<VipTask> = Vec::new();
    if let Some(groups) = data.get("taskList").and_then(Value::as_array) {
        for g in groups {
            let Some(items) = g.get("taskItems").and_then(Value::as_array) else {
                continue;
            };
            for it in items {
                let name = str_of(it, "name").unwrap_or_default();
                let action = str_of(it, "action").unwrap_or_default();
                let title = if name.trim().is_empty() { action } else { name };
                if title.trim().is_empty() {
                    continue;
                }
                let target = match it.get("targets") {
                    Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
                    Some(Value::Array(a)) => a.len() as i64,
                    _ => 0,
                };
                let progress = it.get("currentProgress").and_then(Value::as_i64).unwrap_or(0);
                let status = it.get("status").and_then(Value::as_i64).unwrap_or(0);
                out.push(VipTask {
                    title,
                    reward: str_of(it, "description").unwrap_or_default(),
                    growth_point: it.get("growthPoint").and_then(Value::as_i64).unwrap_or(0) as i32,
                    progress,
                    target,
                    done: status == 2 || (target > 0 && progress >= target),
                    show_progress: it
                        .get("showProgress")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    url: str_of(it, "url").filter(|u| !u.trim().is_empty()),
                });
            }
        }
    }
    (out, task_score)
}

/// user_level: data = {level, nowPlayCount, nextPlayCount, nowLoginCount, nextLoginCount,
/// progress, info, userId}. 实测(2026-11-08): level=9, 2301/12000, progress=0.19175(= 听歌数比).
/// data 缺失时返回 None(由调用方按"接口成功但没有数据"处理).
pub fn parse_user_level(body: &Value) -> Option<UserLevel> {
    let data = body.get("data")?;
    if !data.is_object() {
        return None;
    }
    Some(UserLevel {
        level: u64_of(data, "level").unwrap_or(0) as u32,
        now_play_count: u64_of(data, "nowPlayCount").unwrap_or(0),
        next_play_count: u64_of(data, "nextPlayCount").unwrap_or(0),
        now_login_count: u64_of(data, "nowLoginCount").unwrap_or(0),
        next_login_count: u64_of(data, "nextLoginCount").unwrap_or(0),
        // progress 实测是 f64(0.19175), 但防御性兼容字符串形态
        progress: data
            .get("progress")
            .and_then(|v| v.as_f64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))
            .unwrap_or(0.0),
        privileges: str_of(data, "info").unwrap_or_default(),
    })
}

/// user_medal: data.categoryMedalBlockVos[].medalVOS[] 平铺.
///
/// 实测(2026-11-08, uid=1822714196): 5 个分类共 200 枚, status 分布
/// OBTAIN 157 / NOT_OBTAIN_PROCESS 16 / NOT_OBTAIN_NO_PROCESS 14 / WILL_OBTAIN 13;
/// data.medalNum = 157 = OBTAIN 枚数。data.obtainMedals 是同一批对象里已获得的那部分,
/// **只解析 categoryMedalBlockVos**, 否则会重复计数。
///
/// medalCode 是字符串(乐迷徽章形如 "20170503_1081839"), 缺 code 的条目直接跳过。
pub fn parse_user_medals(body: &Value) -> MedalWall {
    let data = body.get("data").unwrap_or(&Value::Null);
    let mut medals: Vec<UserMedal> = Vec::new();
    if let Some(groups) = data.get("categoryMedalBlockVos").and_then(Value::as_array) {
        for g in groups {
            let Some(items) = g.get("medalVOS").and_then(Value::as_array) else {
                continue;
            };
            for m in items {
                let Some(code) = str_of(m, "medalCode").filter(|c| !c.trim().is_empty()) else {
                    continue;
                };
                let status = str_of(m, "status").unwrap_or_default();
                medals.push(UserMedal {
                    code,
                    name: str_of(m, "medalName").unwrap_or_default(),
                    pic_url: str_of(m, "medalPicUrl").filter(|u| !u.trim().is_empty()),
                    wear_pic_url: str_of(m, "wearPic").filter(|u| !u.trim().is_empty()),
                    condition: str_of(m, "acceptCondition").unwrap_or_default(),
                    obtained: status == "OBTAIN",
                    obtain_time_ms: u64_of(m, "obtainTime").filter(|t| *t > 0),
                    level_title: str_of(m, "levelTitle").filter(|s| !s.trim().is_empty()),
                    progress_text: str_of(m, "progress").filter(|s| !s.trim().is_empty()),
                    rank_text: str_of(m, "rankText").filter(|s| !s.trim().is_empty()),
                    status,
                });
            }
        }
    }
    let medal_num = u64_of(data, "medalNum")
        .map(|n| n as u32)
        // 兜底: 接口没给 medalNum 时按 obtainTime 数(实测与 OBTAIN 枚数等价)
        .unwrap_or_else(|| medals.iter().filter(|m| m.obtained).count() as u32);
    MedalWall { medal_num, medals }
}

/// 新建歌单响应 → (id, name). id 在顶层, 老形态回退 playlist.id(2026-11-10 实测,
/// 样例见 docs/b7-playlist-write-notes.md). 拿不到 id 视为解析失败.
pub fn parse_created_playlist(body: &Value) -> Option<ncm_domain::CreatedPlaylist> {
    let playlist = body.get("playlist");
    let id = body
        .get("id")
        .and_then(Value::as_u64)
        .or_else(|| playlist.and_then(|p| p.get("id")).and_then(Value::as_u64))
        .unwrap_or(0);
    if id == 0 {
        return None;
    }
    let name = playlist
        .and_then(|p| p.get("name"))
        .and_then(Value::as_str)
        .or_else(|| body.get("name").and_then(Value::as_str))
        .unwrap_or_default()
        .to_string();
    Some(ncm_domain::CreatedPlaylist { id, name })
}

/// 歌单写操作(tracks add / delete)通用结果. 成功判定 = code==200;
/// add 成功时 count=接受数, 无 message; 失败给 msg/message.
pub fn parse_playlist_edit_result(body: &Value) -> ncm_domain::PlaylistEditResult {
    let code = body.get("code").and_then(Value::as_i64).unwrap_or(0);
    let message = ["message", "msg"]
        .iter()
        .find_map(|k| body.get(*k).and_then(Value::as_str))
        .map(str::to_string);
    let count = body.get("count").and_then(Value::as_u64);
    ncm_domain::PlaylistEditResult {
        code,
        message,
        count,
        ok: code == 200,
    }
}

fn u64_of(v: &Value, key: &str) -> Option<u64> {
    v.get(key).and_then(|x| x.as_u64().or_else(|| x.as_str().and_then(|s| s.parse().ok())))
}

fn str_of(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).map(str::to_string)
}

fn u32_of(v: &Value, key: &str) -> Option<u32> {
    u64_of(v, key).and_then(|n| u32::try_from(n).ok())
}

/// lastRank 是 i32(服务器用 -1 表示新上榜), 与其它计数不同
fn i32_of(v: &Value, key: &str) -> Option<i32> {
    v.get(key)
        .and_then(|x| x.as_i64().or_else(|| x.as_str().and_then(|s| s.parse().ok())))
        .and_then(|n| i32::try_from(n).ok())
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

/// 从 lyric_new 响应解析逐字歌词; 无 yrc 时返回空 WordLyric(不报错, 由调用方退化).
pub fn parse_word_lyric_body(body: &Value) -> ProviderResult<WordLyric> {
    let yrc = body
        .get("yrc")
        .and_then(|x| x.get("lyric"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let Some(yrc) = yrc else {
        return Ok(WordLyric::default());
    };
    // ytlrc 实测恒空; 翻译兜底用 tlyric(行级 LRC, 按行首对齐)
    let translated = body
        .get("ytlrc")
        .and_then(|x| x.get("lyric"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .or_else(|| {
            body.get("tlyric")
                .and_then(|x| x.get("lyric"))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
        });
    Ok(ncm_domain::parse_word_lyric_with_translation(&yrc, translated))
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

    fn word_lyric<'a>(&'a self, track: TrackId) -> BoxFuture<'a, ProviderResult<WordLyric>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("id", &track.to_string());
            let resp = client.lyric_new(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_word_lyric_body(&resp.body)
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

    /// 榜单 v2 目录(toplist_detail_v2): 按 categoryCode 分组的榜单卡.
    /// 实测没有 v1 的 trackUpdateTime 数字字段; "更新 N 首"混在 updateFrequency 字符串里,
    /// 增强点是按 categoryCode 分组 + canPlay(个别卡 id=0 且不可播).
    fn toplist_catalog(&self) -> BoxFuture<'_, ProviderResult<Vec<ToplistCatalogGroup>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.toplist_detail_v2(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_toplist_catalog(&resp.body))
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

    /// 新建歌单: 响应 {code, id, playlist:{id,...}}(id 在顶层, 实测样例见 docs/b7-playlist-write-notes.md)
    fn create_playlist<'a>(&'a self, name: &'a str, privacy: u8) -> BoxFuture<'a, ProviderResult<u64>> {
        Box::pin(async move {
            let name = name.trim();
            if name.is_empty() {
                return Err(ProviderError::internal("歌单名不能为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("新建歌单需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("name", name)
                .param("privacy", &privacy.to_string());
            let resp = client.playlist_create(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_created_playlist(&resp.body)
                .map(|created| created.id)
                .ok_or_else(|| ProviderError::internal("新建歌单: 响应里没有 id"))
        })
    }

    /// 批量把曲目加入歌单(op=add). vendor 把逗号分隔 id 序列化成字符串数组进 trackIds;
    /// 响应 {"code":200,"count":N,...}, count 可小于提交数(重复曲目服务端跳过).
    fn playlist_tracks_add<'a>(
        &'a self,
        playlist_id: u64,
        song_ids: &'a [u64],
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            if playlist_id == 0 {
                return Err(ProviderError::not_found("playlist id 为空"));
            }
            if song_ids.is_empty() {
                return Err(ProviderError::internal("没有可加入的曲目"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("收藏到歌单需要登录"));
            }
            let tracks = song_ids
                .iter()
                .map(|id| id.to_string())
                .collect::<Vec<_>>()
                .join(",");
            let q = make_query(&cookie, &domain, &ua)
                .param("op", "add")
                .param("pid", &playlist_id.to_string())
                .param("tracks", &tracks)
                .param("imme", "true");
            let resp = client.playlist_tracks(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_playlist_edit_result(&resp.body).ok)
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

    /// 最新专辑(album_newest): 与 album_new 不同源, 实测固定 12 张, 无 total, 不翻页.
    fn newest_albums(&self, limit: u32) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.album_newest(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut out = parse_album_items(&resp.body);
            out.truncate(limit as usize);
            Ok(out)
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

    /// 歌手全部歌曲(artist_songs): offset/limit 分页, more=还有下一页
    fn artist_songs_page<'a>(
        &'a self,
        artist_id: u64,
        offset: u32,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<ArtistSongPage>> {
        Box::pin(async move {
            if artist_id == 0 {
                return Err(ProviderError::not_found("artist id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &artist_id.to_string())
                .param("offset", &offset.to_string())
                .param("limit", &limit.to_string());
            let resp = client.artist_songs(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_artist_songs(&resp.body))
        })
    }

    /// 关注/取消关注歌手(artist_sub: t=1 sub / t=0 unsub), 需要登录.
    fn toggle_artist_sub<'a>(&'a self, artist_id: u64, sub: bool) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            if artist_id == 0 {
                return Err(ProviderError::not_found("artist id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("关注歌手需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &artist_id.to_string())
                .param("t", if sub { "1" } else { "0" });
            let resp = client.artist_sub(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 歌手 MV(artist_mv): offset/limit 分页, hasMore=还有下一页
    fn artist_mvs_page<'a>(
        &'a self,
        artist_id: u64,
        offset: u32,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<ArtistMvPage>> {
        Box::pin(async move {
            if artist_id == 0 {
                return Err(ProviderError::not_found("artist id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &artist_id.to_string())
                .param("offset", &offset.to_string())
                .param("limit", &limit.to_string());
            let resp = client.artist_mv(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_artist_mvs(&resp.body))
        })
    }

    /// MV 详情(mv_detail)
    fn mv_detail<'a>(&'a self, mv_id: u64) -> BoxFuture<'a, ProviderResult<MvDetail>> {
        Box::pin(async move {
            if mv_id == 0 {
                return Err(ProviderError::not_found("mv id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("mvid", &mv_id.to_string());
            let resp = client.mv_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let detail = parse_mv_detail(&resp.body);
            if detail.id == 0 || detail.name.is_empty() {
                return Err(ProviderError::not_found("MV 不存在"));
            }
            Ok(detail)
        })
    }

    /// MV 播放链接(mv_url, r=清晰度档位如 1080)
    fn mv_url<'a>(&'a self, mv_id: u64, r: u32) -> BoxFuture<'a, ProviderResult<MvUrl>> {
        Box::pin(async move {
            if mv_id == 0 {
                return Err(ProviderError::not_found("mv id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let r_str = if r == 0 { "1080".to_string() } else { r.to_string() };
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &mv_id.to_string())
                .param("r", &r_str);
            let resp = client.mv_url(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let u = parse_mv_url(&resp.body);
            if u.url.is_none() {
                return Err(ProviderError::unsupported(
                    "该 MV 无可播放链接(可能需要 VIP 或已下架)",
                ));
            }
            Ok(u)
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

    /// 联想下拉的纯关键词候选(type=mobile 分支, /api/search/suggest/keyword).
    fn search_suggest_keywords<'a>(
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
    fn search_exact<'a>(&'a self, keywords: &'a str) -> BoxFuture<'a, ProviderResult<SearchExact>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("keywords", keywords);
            let resp = client.search_multimatch(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_search_exact(&resp.body))
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

    /// 黑胶会员总览(需要登录). 四个子接口并行, 单个失败只丢对应字段.
    fn vip_overview(&self) -> BoxFuture<'_, ProviderResult<VipOverview>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                // 未登录不报鉴权错误: 回 logged_in=false, UI 走"登录后可见"空态.
                return Ok(VipOverview::default());
            }
            let mk = || make_query(&cookie, &domain, &ua);
            let (a, b, c, d) = futures::future::join4(
                client.vip_info_v2(&mk()),
                client.vip_growthpoint(&mk()),
                client.vip_sign_info(&mk()),
                client.vip_tasks(&mk()),
            )
            .await;
            let mut errs: Vec<ProviderError> = Vec::new();
            let membership = take_body(a, &mut errs)
                .as_ref()
                .and_then(parse_vip_membership);
            let growth = take_body(b, &mut errs).as_ref().and_then(parse_vip_growth);
            let sign = take_body(c, &mut errs).as_ref().map(parse_vip_sign);
            let (tasks, task_score) = take_body(d, &mut errs)
                .as_ref()
                .map(parse_vip_tasks)
                .unwrap_or_default();
            if membership.is_none() && growth.is_none() && sign.is_none() && tasks.is_empty() {
                if let Some(e) = errs.into_iter().next() {
                    return Err(e);
                }
            }
            Ok(VipOverview {
                logged_in: true,
                membership,
                growth,
                sign,
                tasks,
                task_score,
            })
        })
    }

    /// 账号听歌等级(/api/user/level, weapi, body {}).
    fn user_level(&self) -> BoxFuture<'_, ProviderResult<UserLevel>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("查看等级需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.user_level(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_user_level(&resp.body)
                .ok_or_else(|| ProviderError::internal("user_level 响应缺少 data"))
        })
    }

    /// 账号勋章墙(/api/medal/user/page, eapi, body **必须带 uid**).
    ///
    /// uid 优先取等级接口里服务端回的 data.userId(不依赖本地缓存的 profile),
    /// 拿不到再回退 session.profile.user_id。实测空 uid 时服务端回 code=499.
    fn user_medals(&self) -> BoxFuture<'_, ProviderResult<MedalWall>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("查看勋章需要登录"));
            }
            let uid = self
                .remote_uid(&client, &domain, &ua, &cookie)
                .await
                .ok_or_else(|| ProviderError::auth("拿不到账号 uid, 无法查勋章"))?;
            let q = make_query(&cookie, &domain, &ua).param("uid", &uid.to_string());
            // 该 eapi 端点限流很严(实测 2026-11-08: 不间断连打 5 次只通 2 次;
            // 每次隔 ≥10s 则 5/5 全通; "先打一次 user_level 再打勋章" 也照样被 reset
            // -> 触发条件在服务端, 与客户端连发次数无关). 这里做有界重试, 退避 1.5s/3s,
            // 收紧后实测 8/10(单次 5/10). 业务错误(301/499)不重试.
            let mut last: Option<ProviderError> = None;
            for delay_ms in [0u64, 1500, 3000] {
                if delay_ms > 0 {
                    tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
                }
                match client.user_medal(&q).await {
                    Ok(resp) => match check_body(&resp.body) {
                        Ok(()) => return Ok(parse_user_medals(&resp.body)),
                        // 业务错误不重试(301/499 之类重试也没用)
                        Err(e) => return Err(e),
                    },
                    Err(e) => {
                        let pe = map_error(e);
                        // 只有网络类错误值得重试
                        if pe.kind != ncm_provider::ProviderErrorKind::Network {
                            return Err(pe);
                        }
                        last = Some(pe);
                    }
                }
            }
            Err(last.unwrap_or_else(|| ProviderError::network("user_medal 重试耗尽")))
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
                // MV(R_MV_5_) / 视频(R_VI_62_)评论区: 形状与歌曲评论一致, 复用 parse_comments
                "mv" => client.comment_mv(&q).await,
                "video" => client.comment_video(&q).await,
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

    /// 评论统计(实测: vendor comment_info_list = /api/resource/commentInfo/list, weapi).
    /// 入参是 type(资源类型数字) + ids(逗号分隔), **不是 threadId** —— 传 threadId 只会拿到空数组;
    /// 这里用 split_thread_id 把 threadId 反解成 (type, id). 动态(A_EV_2_)的 id 段是
    /// `eventId_userId`, 该接口不认, 直接 unsupported.
    fn comment_stats<'a>(
        &'a self,
        thread_id: &'a str,
    ) -> BoxFuture<'a, ProviderResult<CommentStats>> {
        Box::pin(async move {
            let (ty, rid) = split_thread_id(thread_id).ok_or_else(|| {
                ProviderError::unsupported(format!("comment_stats: 无法识别的 threadId {thread_id}"))
            })?;
            if ty == "6" {
                return Err(ProviderError::unsupported("comment_stats: 动态暂不支持评论统计"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("type", ty)
                .param("ids", &rid);
            let resp = client.comment_info_list(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_comment_stats(&resp.body, thread_id)
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

    /// 已购数字专辑(digitalAlbum/purchased, weapi). 实测顶层是 paidAlbums + total.
    fn digital_album_purchased<'a>(
        &'a self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<DigitalAlbumPurchased>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("已购数字专辑需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string())
                .param("total", "true");
            let resp = client.digital_album_purchased(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_digital_album_purchased(&resp.body)
        })
    }

    /// 已购单曲(song/purchased = /api/single/mybought/song/list, weapi).
    fn song_purchased<'a>(
        &'a self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<SongPurchasedPage>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("已购单曲需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.song_purchased(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_song_purchased(&resp.body)
        })
    }

    /// 数字专辑详情(vipmall/albumproduct/detail, weapi, 入参 id).
    fn digital_album_detail(&self, album_id: u64) -> BoxFuture<'_, ProviderResult<DigitalAlbumDetail>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("id", &album_id.to_string());
            let resp = client.digital_album_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_digital_album_detail(&resp.body)
        })
    }

    /// 数字专辑销量(vipmall/albumproduct/album/query/sales, weapi, 入参键 albumIds).
    fn digital_album_sales<'a>(
        &'a self,
        album_ids: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<DigitalAlbumSalesEntry>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("ids", album_ids);
            let resp = client.digital_album_sales(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_digital_album_sales(&resp.body))
        })
    }

    // ---- 电台发现(只读; 全部匿名可用) ----

    /// 电台发现首页: dj_catelist(分类) + dj_category_recommend(各分类精选), 并发拉取.
    fn radio_explore_home(&self) -> BoxFuture<'_, ProviderResult<RadioExploreHome>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let (cats, picks) = futures::future::join(
                client.dj_catelist(&q),
                client.dj_category_recommend(&q),
            )
            .await;
            let categories = parse_radio_categories(&cats.map_err(map_error)?.body);
            let picks_body = picks.map_err(map_error)?;
            check_body(&picks_body.body)?;
            Ok(RadioExploreHome { categories, picks: parse_radio_picks(&picks_body.body) })
        })
    }

    /// 某分类推荐电台(dj_recommend_type). cate_id=0 服务端返回空 djRadios, 原样透传空列表.
    fn radio_recommend<'a>(&'a self, cate_id: u64) -> BoxFuture<'a, ProviderResult<Vec<PodcastRadio>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("type", &cate_id.to_string());
            let resp = client.dj_recommend_type(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(resp
                .body
                .get("djRadios")
                .and_then(Value::as_array)
                .map(|arr| arr.iter().filter_map(parse_radio).collect())
                .unwrap_or_default())
        })
    }

    /// 电台榜单(kind: hot/new/pay/hours/newcomer/popular/program).
    fn radio_toplist<'a>(&'a self, kind: &'a str) -> BoxFuture<'a, ProviderResult<RadioToplist>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            match kind {
                "hot" | "new" => {
                    // vendor 把 type "hot"→1 其余→0
                    let q = q.param("type", if kind == "hot" { "1" } else { "0" });
                    let resp = client.dj_toplist(&q).await.map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(parse_radio_toplist_radios(&resp.body))
                }
                "pay" => {
                    let resp = client.dj_toplist_pay(&q).await.map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(parse_radio_toplist_radios(&resp.body))
                }
                "hours" | "newcomer" | "popular" => {
                    let resp = match kind {
                        "hours" => client.dj_toplist_hours(&q).await,
                        "newcomer" => client.dj_toplist_newcomer(&q).await,
                        _ => client.dj_toplist_popular(&q).await,
                    }
                    .map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(parse_radio_toplist_djs(&resp.body))
                }
                "program" => {
                    let resp = client.dj_program_toplist(&q).await.map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(parse_radio_toplist_programs(&resp.body))
                }
                other => Err(ProviderError::not_found(format!("未知电台榜单: {other}"))),
            }
        })
    }

    /// 电台订阅者列表(dj_subscriber; 游标 time=-1 表示最新一页).
    fn radio_subscribers<'a>(
        &'a self,
        radio_id: u64,
        limit: u32,
        time_ms: Option<u64>,
    ) -> BoxFuture<'a, ProviderResult<RadioSubscriberPage>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if radio_id == 0 {
                return Err(ProviderError::not_found("radio id 为空"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &radio_id.to_string())
                .param("limit", &limit.to_string())
                // 游标是"上一页最后一条的 subscribeTime"(ms), 首页传 -1
                .param("time", &time_ms.map(|t| t.to_string()).unwrap_or_else(|| "-1".to_string()))
                .param("total", "true");
            let resp = client.dj_subscriber(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_radio_subscribers(&resp.body)
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

    /// 热搜榜详情(/api/hotsearchlist/get, weapi, 无参数): 带 score + 榜位.
    fn hot_search_detail(&self) -> BoxFuture<'_, ProviderResult<Vec<HotSearchDetailItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.search_hot_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_hot_search_detail(&resp.body))
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

    /// 扫码登录 ①: 申请二维码 key(官方网页登录页同一通道, weapi)
    fn login_qr_create<'a>(&'a self) -> BoxFuture<'a, ProviderResult<QrLoginKey>> {
        Box::pin(async move {
            let (client, domain, _ua, _cookie) = self.snapshot();
            let resp = client
                .request(
                    "/api/login/qrcode/unikey",
                    serde_json::json!({ "type": 1 }),
                    qr_option(domain),
                )
                .await
                .map_err(map_error)?;
            check_body(&resp.body)?;
            let key = resp
                .body
                .get("unikey")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            if key.is_empty() {
                return Err(ProviderError::internal("qr login: 响应里没有 unikey"));
            }
            Ok(QrLoginKey {
                url: format!("https://music.163.com/login?codekey={key}"),
                key,
                // 官方 key 有效期约 3 分钟; 过期由服务端回 800 决定, 这里只给 UI 提示用
                expires_in: 180,
            })
        })
    }

    /// 扫码登录 ②: 轮询. 803 时的登录凭据在 Set-Cookie 里(不在 body).
    fn login_qr_check<'a>(&'a self, key: &'a str) -> BoxFuture<'a, ProviderResult<QrLoginCheck>> {
        Box::pin(async move {
            let (client, domain, _ua, _cookie) = self.snapshot();
            let resp = client
                .request(
                    "/api/login/qrcode/client/login",
                    serde_json::json!({ "key": key, "type": 1 }),
                    qr_option(domain),
                )
                .await
                .map_err(map_error)?;
            parse_qr_check(&resp.body, &resp.cookie)
        })
    }
}

/// 轮询响应的解析(抽出来便于单测).
///
/// 官方 code: 800 过期 / 801 待扫 / 802 已扫待确认 / 803 成功.
/// **803 的登录凭据不在 body 里, 而在响应的 Set-Cookie 中** —— 这是整个桌面端登录
/// 能绕开 WebView 的关键(见 docs 与 .pi/memory/HINDSIGHT.md).
fn parse_qr_check(body: &Value, set_cookies: &[String]) -> ProviderResult<QrLoginCheck> {
    let code = body.get("code").and_then(Value::as_i64).unwrap_or(-1);
    let state = match code {
        803 => QrLoginState::Confirmed,
        802 => QrLoginState::Scanned,
        801 => QrLoginState::Pending,
        800 => QrLoginState::Expired,
        _ => QrLoginState::Failed,
    };
    let cookie = if state == QrLoginState::Confirmed {
        // 只留登录凭据键: 设备指纹(deviceId/_ntes_nuid/WNMCID...)由本地会话提供
        let raw = set_cookies
            .iter()
            .map(|c| c.split(';').next().unwrap_or("").trim())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("; ");
        let login_only = crate::identity::extract_login_cookie(&raw);
        if !login_only.contains("MUSIC_U=") {
            return Err(ProviderError::internal(
                "qr login: 已确认但没有拿到 MUSIC_U(检查 Set-Cookie)",
            ));
        }
        Some(login_only)
    } else {
        None
    };
    let nickname = body
        .get("nickname")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let avatar_url = body
        .get("avatarUrl")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    Ok(QrLoginCheck { state, code, cookie, nickname, avatar_url })
}

/// 扫码登录走 weapi(官方网页登录页的通道).
///
/// UA 故意不传业务侧的 NeteaseMusicDesktop: weapi 由 vendor 选 PC 浏览器 UA,
/// 与"网页登录"这个动作自洽; 混用客户端 UA 反而是风控特征.
fn qr_option(domain: Option<String>) -> RequestOption {
    RequestOption {
        crypto: CryptoType::Weapi,
        domain,
        ..Default::default()
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

/// 评论统计(comment_info_list = /api/resource/commentInfo/list)的响应形如
///   {code:200, data:[{commentCount, commentCountDesc, commentUpgraded, comments, latestLikedUsers,
///                     liked, likedCount, musicianSaidCount, resourceId, resourceType, shareCount, threadId}]}
/// 实测要点:
/// - `data` 是**数组**(一个请求 id 对应一项), 这里只发一个 id, 取第一项;
/// - **没有 subscribedCount / hotCount**, 别按文档补齐字段;
/// - `data` 缺失、空数组、空对象都当"全 0"返回(用请求的 threadId 兜底), 不报错也不 panic ——
///   评论数缺失不该让整个详情页失败;
/// - 服务端回显的 threadId 优先(与请求一致), 缺失时用入参兜底.
pub fn parse_comment_stats(body: &Value, thread_id: &str) -> ProviderResult<CommentStats> {
    let first = body
        .get("data")
        .and_then(|d| match d {
            Value::Array(arr) => arr.first(),
            Value::Object(_) => Some(d),
            _ => None,
        })
        .filter(|v| v.is_object());
    let Some(v) = first else {
        return Ok(CommentStats { thread_id: thread_id.to_string(), ..Default::default() });
    };
    Ok(CommentStats {
        thread_id: str_of(v, "threadId")
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| thread_id.to_string()),
        resource_id: u64_of(v, "resourceId").unwrap_or(0),
        comment_count: u64_of(v, "commentCount").unwrap_or(0),
        comment_count_desc: str_of(v, "commentCountDesc").unwrap_or_default(),
        share_count: u64_of(v, "shareCount").unwrap_or(0),
        liked_count: u64_of(v, "likedCount").unwrap_or(0),
        liked: v.get("liked").and_then(Value::as_bool).unwrap_or(false),
        musician_said_count: u64_of(v, "musicianSaidCount").unwrap_or(0),
        comment_upgraded: v.get("commentUpgraded").and_then(Value::as_bool).unwrap_or(false),
    })
}

/// 已购数字专辑(digitalAlbum/purchased)的响应形如
///   {code:200, total:2, paidAlbums:[{albumId, albumName, artist:{id,name}, cover, paidTime,
///                                     boughtCount, sub, channel, valid, …}]}
/// 实测要点(2026-11-09):
/// - **顶层是 paidAlbums + total, 没有 data 包装**; 分页字段只有 total, 没有 hasMore/more;
/// - `paidTime` 是毫秒时间戳, `boughtCount` 是购买数量, 封面字段就叫 `cover`;
/// - paidAlbums 缺失/为 null 时当空列表(总数仍取 total), 不报错.
pub fn parse_digital_album_purchased(body: &Value) -> ProviderResult<DigitalAlbumPurchased> {
    let albums = body
        .get("paidAlbums")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|a| {
                    Some(DigitalAlbumPurchasedEntry {
                        album_id: u64_of(a, "albumId")?,
                        album_name: str_of(a, "albumName").unwrap_or_default(),
                        artist_id: a.get("artist").and_then(|x| u64_of(x, "id")).unwrap_or(0),
                        artist_name: a
                            .get("artist")
                            .and_then(|x| str_of(x, "name"))
                            .unwrap_or_default(),
                        cover_url: str_of(a, "cover").unwrap_or_default(),
                        paid_time_ms: u64_of(a, "paidTime").unwrap_or(0),
                        bought_count: u64_of(a, "boughtCount").unwrap_or(0),
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    Ok(DigitalAlbumPurchased { total: u64_of(body, "total").unwrap_or(0), albums })
}

/// 已购单曲(song/purchased)的响应形如
///   {code:200, data:{count:0, hasMore:false, list:[]}}
/// 本账号无已购单曲, list 元素形状未实测到, 字段宽松取常见命名(id/name/paidTime 等).
pub fn parse_song_purchased(body: &Value) -> ProviderResult<SongPurchasedPage> {
    let data = body.get("data");
    let songs = data
        .and_then(|d| d.get("list"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| {
                    Some(PurchasedSongEntry {
                        song_id: u64_of(s, "id").or_else(|| u64_of(s, "songId"))?,
                        name: str_of(s, "name").or_else(|| str_of(s, "songName")).unwrap_or_default(),
                        artist_name: s
                            .get("artist")
                            .and_then(|x| str_of(x, "name"))
                            .or_else(|| str_of(s, "artistName"))
                            .unwrap_or_default(),
                        cover_url: str_of(s, "cover")
                            .or_else(|| str_of(s, "picUrl"))
                            .unwrap_or_default(),
                        paid_time_ms: u64_of(s, "paidTime")
                            .or_else(|| u64_of(s, "purchaseTime"))
                            .unwrap_or(0),
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    Ok(SongPurchasedPage {
        count: data.and_then(|d| u64_of(d, "count")).unwrap_or(0),
        has_more: data.and_then(|d| d.get("hasMore")).and_then(Value::as_bool).unwrap_or(false),
        songs,
    })
}

/// 电台分类(dj_catelist). **顶层直接是 categories, 没有 code 字段**, 判断空数组即可.
pub fn parse_radio_categories(body: &Value) -> Vec<RadioCategory> {
    body.get("categories")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|c| {
                    Some(RadioCategory {
                        id: u64_of(c, "id")?,
                        name: str_of(c, "name").unwrap_or_default(),
                        cover_url: str_of(c, "pic56x56Url").unwrap_or_default(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 各分类精选(dj_category_recommend 的 data[] 元素 = {categoryId, categoryName, radios}).
pub fn parse_radio_picks(body: &Value) -> Vec<RadioPick> {
    body.get("data")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .map(|g| RadioPick {
                    category_id: u64_of(g, "categoryId").unwrap_or(0),
                    category_name: str_of(g, "categoryName").unwrap_or_default(),
                    radios: g
                        .get("radios")
                        .and_then(Value::as_array)
                        .map(|rs| rs.iter().filter_map(parse_radio).collect())
                        .unwrap_or_default(),
                })
                .collect()
        })
        .unwrap_or_default()
}

/// dj_toplist(顶层 toplist, 元素是 DjRadio 超集 + rank/score/lastRank).
/// 注意推荐语字段是 rcmdtext(全小写).
fn ranked_radio(v: &Value) -> Option<RadioRankedRadio> {
    Some(RadioRankedRadio {
        rank: u32_of(v, "rank")?,
        last_rank: i32_of(v, "lastRank").unwrap_or(-1),
        radio_id: u64_of(v, "id")?,
        name: str_of(v, "name").unwrap_or_default(),
        cover_url: str_of(v, "picUrl").unwrap_or_default(),
        dj_name: v
            .get("dj")
            .and_then(|d| str_of(d, "nickname"))
            .or_else(|| str_of(v, "creatorName"))
            .unwrap_or_default(),
        category: str_of(v, "category").unwrap_or_default(),
        play_count: u64_of(v, "playCount").unwrap_or(0),
        program_count: u64_of(v, "programCount").unwrap_or(0),
        sub_count: u64_of(v, "subCount").unwrap_or(0),
        score: u64_of(v, "score").unwrap_or(0),
        rcmd_text: str_of(v, "rcmdtext").unwrap_or_default(),
    })
}

pub fn parse_radio_toplist_radios(body: &Value) -> RadioToplist {
    let radios = body
        .get("toplist")
        .or_else(|| body.get("data").and_then(|d| d.get("list")))
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(ranked_radio).collect())
        .unwrap_or_default();
    RadioToplist { radios, ..RadioToplist::default() }
}

/// 主播榜(hours/newcomer/popular): data.list, 元素是用户(nickName 驼峰).
pub fn parse_radio_toplist_djs(body: &Value) -> RadioToplist {
    let djs = body
        .get("data")
        .and_then(|d| d.get("list"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|d| {
                    Some(RadioRankedDj {
                        rank: u32_of(d, "rank")?,
                        last_rank: i32_of(d, "lastRank").unwrap_or(-1),
                        user_id: u64_of(d, "id")?,
                        nickname: str_of(d, "nickName").unwrap_or_default(),
                        avatar_url: str_of(d, "avatarUrl").unwrap_or_default(),
                        score: u64_of(d, "score").unwrap_or(0),
                        followed_count: u64_of(d, "userFollowedCount").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    RadioToplist { djs, ..RadioToplist::default() }
}

/// 节目榜(dj_program_toplist): 顶层 toplist, 元素 = {rank,lastRank,program}.
pub fn parse_radio_toplist_programs(body: &Value) -> RadioToplist {
    let programs = body
        .get("toplist")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|e| {
                    Some(RadioRankedProgram {
                        rank: u32_of(e, "rank")?,
                        last_rank: i32_of(e, "lastRank").unwrap_or(-1),
                        program: e.get("program").and_then(parse_program)?,
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    RadioToplist { programs, ..RadioToplist::default() }
}

/// 电台订阅者(dj_subscriber): 顶层 hasMore + subscribers(完整 user 对象).
pub fn parse_radio_subscribers(body: &Value) -> ProviderResult<RadioSubscriberPage> {
    let subs = body
        .get("subscribers")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| {
                    Some(RadioSubscriber {
                        user_id: u64_of(s, "userId")?,
                        nickname: str_of(s, "nickname").unwrap_or_default(),
                        avatar_url: str_of(s, "avatarUrl").unwrap_or_default(),
                        signature: str_of(s, "signature").unwrap_or_default(),
                        subscribe_time_ms: u64_of(s, "subscribeTime").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(RadioSubscriberPage {
        has_more: body.get("hasMore").and_then(Value::as_bool).unwrap_or(false),
        subscribers: subs,
    })
}

/// 数字专辑详情(vipmall/albumproduct/detail)的响应形如
///   {code:200, hasAlbum:true, boughtCnt:1,
///    album:{albumId, albumName, artistName, artistId, coverUrl, …},
///    product:{price:22.0, pubTime, saleNum, tags:[…], descr:[{resource,type}], …}}
/// 实测要点: 专辑字段在 album, 价格/上架/标签在 product; descr 的 `</br>` 是分隔占位要过滤.
pub fn parse_digital_album_detail(body: &Value) -> ProviderResult<DigitalAlbumDetail> {
    let album = body.get("album").ok_or_else(|| ProviderError::not_found("digital_album_detail: missing album"))?;
    let product = body.get("product");
    let tags = product
        .and_then(|p| p.get("tags"))
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).map(String::from).collect())
        .unwrap_or_default();
    let description = product
        .and_then(|p| p.get("descr"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|d| d.get("resource").and_then(Value::as_str))
                .filter(|s| *s != "</br>")
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default();
    Ok(DigitalAlbumDetail {
        album_id: u64_of(album, "albumId").unwrap_or(0),
        name: str_of(album, "albumName").unwrap_or_default(),
        artist_id: u64_of(album, "artistId").unwrap_or(0),
        artist_name: str_of(album, "artistName").unwrap_or_default(),
        cover_url: str_of(album, "coverUrl").unwrap_or_default(),
        has_album: body.get("hasAlbum").and_then(Value::as_bool).unwrap_or(false),
        price: product.and_then(|p| p.get("price")).and_then(Value::as_f64).unwrap_or(0.0),
        pub_time_ms: product.and_then(|p| u64_of(p, "pubTime")).unwrap_or(0),
        sale_num: product.and_then(|p| u64_of(p, "saleNum")).unwrap_or(0),
        tags,
        description,
    })
}

/// 数字专辑销量(vipmall/albumproduct/album/query/sales)的响应形如
///   {code:200, data:{"120605500":1300052}}
/// `data` 是 {专辑id字符串: 销量} 的 map, 不是数组(实测, 与工单里 bizType/limit 的说法不符).
pub fn parse_digital_album_sales(body: &Value) -> Vec<DigitalAlbumSalesEntry> {
    body.get("data")
        .and_then(Value::as_object)
        .map(|m| {
            m.iter()
                .filter_map(|(k, v)| Some(DigitalAlbumSalesEntry { album_id: k.clone(), sales: v.as_u64()? }))
                .collect()
        })
        .unwrap_or_default()
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
        let Some(kw) = str_of(v, "keyword") else { continue };
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
            })
        })
        .collect();
    let podcasts = arr_of("voice").iter().filter_map(parse_voice_radio).collect();
    SearchExact { orders, artists, playlists, podcasts }
}

/// multimatch 的 `voice` 是"播客节目"对象, 结构与 dj_detail 完全不同:
///   {resourceId, resourceName, resourceType:"voice", internalType:null,
///    baseInfo:{id, name, coverUrl, trackCount, listenerCount, dj:{nickname}, radio:{name, programCount}}}
/// 映射成 [`PodcastRadio`]: id/name 取 baseInfo.id/name(播客**单集**),
/// dj_name 取 baseInfo.dj.nickname, program_count 取 baseInfo.radio.programCount,
/// play_count 取 baseInfo.listenerCount.
fn parse_voice_radio(v: &Value) -> Option<PodcastRadio> {
    let base = v.get("baseInfo").unwrap_or(v);
    let id = u64_of(base, "id").or_else(|| u64_of(v, "resourceId"))?;
    if id == 0 {
        return None;
    }
    let name = str_of(base, "name")
        .or_else(|| str_of(v, "resourceName"))
        .unwrap_or_default();
    let radio = base.get("radio");
    Some(PodcastRadio {
        id,
        name,
        cover_url: str_of(base, "coverUrl")
            .or_else(|| base.get("radio").and_then(|r| str_of(r, "picUrl")))
            .filter(|s| !s.is_empty()),
        description: String::new(),
        dj_name: base
            .get("dj")
            .and_then(|d| str_of(d, "nickname"))
            .unwrap_or_default(),
        program_count: radio.and_then(|r| u64_of(r, "programCount")).unwrap_or(0),
        play_count: u64_of(base, "listenerCount").unwrap_or(0),
    })
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

/// 歌手全部歌曲: {code, more, songs:[...]}(artist_songs, 每首歌自带 privilege)
pub fn parse_artist_songs(body: &Value) -> ArtistSongPage {
    ArtistSongPage {
        songs: parse_song_list(body),
        has_more: body.get("more").and_then(Value::as_bool).unwrap_or(false),
    }
}

/// 歌手 MV: {code, hasMore, mvs:[{id,name,duration,playCount,publishTime,imgurl16v9}]}
pub fn parse_artist_mvs(body: &Value) -> ArtistMvPage {
    let mvs = body
        .get("mvs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|v| {
                    let id = u64_of(v, "id")?;
                    let name = str_of(v, "name").unwrap_or_default();
                    if name.is_empty() {
                        return None;
                    }
                    Some(ArtistMv {
                        id,
                        name,
                        duration_ms: u64_of(v, "duration").unwrap_or(0),
                        play_count: u64_of(v, "playCount").unwrap_or(0),
                        publish_time: str_of(v, "publishTime").unwrap_or_default(),
                        cover_url: str_of(v, "imgurl16v9")
                            .or_else(|| str_of(v, "imgurl"))
                            .filter(|s| s.starts_with("http")),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    ArtistMvPage {
        mvs,
        has_more: body.get("hasMore").and_then(Value::as_bool).unwrap_or(false),
    }
}

/// MV 详情: {code, data:{id,name,artistName,duration,playCount,publishTime,cover,brs:[{br,size}],desc}}
pub fn parse_mv_detail(body: &Value) -> MvDetail {
    let d = body.get("data").cloned().unwrap_or(Value::Null);
    let mut brs: Vec<u32> = d
        .get("brs")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(|v| v.get("br").and_then(Value::as_u64).map(|b| b as u32)).collect())
        .unwrap_or_default();
    brs.sort_unstable();
    brs.dedup();
    let name = str_of(&d, "name").unwrap_or_default();
    let id = u64_of(&d, "id").unwrap_or(0);
    MvDetail {
        id,
        name,
        artist_name: str_of(&d, "artistName").unwrap_or_default(),
        duration_ms: u64_of(&d, "duration").unwrap_or(0),
        play_count: u64_of(&d, "playCount").unwrap_or(0),
        publish_time: str_of(&d, "publishTime").unwrap_or_default(),
        cover_url: str_of(&d, "cover").filter(|s| s.starts_with("http")),
        max_br: brs.last().copied().unwrap_or(0),
        brs,
        desc: str_of(&d, "desc").or_else(|| str_of(&d, "briefDesc")).filter(|s| !s.is_empty()),
    }
}

/// MV 播放链接: {code, data:{url,r,size,expi,...}} (data 是对象, video 版才是数组)
pub fn parse_mv_url(body: &Value) -> MvUrl {
    let d = body.get("data").cloned().unwrap_or(Value::Null);
    let url = str_of(&d, "url").filter(|s| s.starts_with("http"));
    MvUrl {
        url,
        r: u64_of(&d, "r").unwrap_or(0) as u32,
        size: u64_of(&d, "size").unwrap_or(0),
    }
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

/// 榜单 v2 目录: {code, data:[{categoryCode, list:[{id,name,coverUrl,updateFrequency,
///                targetType,canPlay}]}]}. data 缺失/为空都返回空目录.
pub fn parse_toplist_catalog(body: &Value) -> Vec<ToplistCatalogGroup> {
    body.get("data")
        .and_then(Value::as_array)
        .map(|groups| {
            groups
                .iter()
                .map(|g| ToplistCatalogGroup {
                    code: str_of(g, "categoryCode").unwrap_or_default(),
                    items: g
                        .get("list")
                        .and_then(Value::as_array)
                        .map(|arr| {
                            arr.iter()
                                .filter_map(|v| {
                                    let id = u64_of(v, "id")?;
                                    let name = str_of(v, "name")?;
                                    if name.is_empty() {
                                        return None;
                                    }
                                    Some(ToplistCatalogItem {
                                        id,
                                        name,
                                        cover_url: str_of(v, "coverUrl")
                                            .filter(|s| s.starts_with("http")),
                                        update_frequency: str_of(v, "updateFrequency")
                                            .unwrap_or_default(),
                                        target_type: str_of(v, "targetType").unwrap_or_default(),
                                        can_play: v.get("canPlay").and_then(Value::as_bool).unwrap_or(false),
                                    })
                                })
                                .collect()
                        })
                        .unwrap_or_default(),
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

    /// 扫码登录轮询: 实测 code 语义 + 803 时凭据只在 Set-Cookie 里.
    #[test]
    fn qr_login_check_states_and_cookie() {
        // 801: 待扫
        let r = parse_qr_check(&json!({"code":801}), &[]).unwrap();
        assert_eq!(r.state, QrLoginState::Pending);
        assert!(r.cookie.is_none());
        // 802: 已扫待确认
        let r = parse_qr_check(&json!({"code":802}), &[]).unwrap();
        assert_eq!(r.state, QrLoginState::Scanned);
        // 800: 过期
        let r = parse_qr_check(&json!({"code":800}), &[]).unwrap();
        assert_eq!(r.state, QrLoginState::Expired);
        // 其它(如 400/风控): Failed, 不 panic
        let r = parse_qr_check(&json!({"code":400,"message":"x"}), &[]).unwrap();
        assert_eq!(r.state, QrLoginState::Failed);

        // 803: body 里带昵称/头像, 凭据在 Set-Cookie(只保留登录键, 设备指纹键丢掉)
        let cookies = vec![
            "MUSIC_U=abc123; Path=/; Domain=.music.163.com; HttpOnly".to_string(),
            "JSESSIONID-WYYY=xyz; Path=/".to_string(),
            "__csrf=csrf456; Path=/".to_string(),
            "NMTID=devfingerprint; Path=/".to_string(),
        ];
        let r = parse_qr_check(
            &json!({"code":803,"nickname":"下去玩","avatarUrl":"https://x/y.jpg"}),
            &cookies,
        )
        .unwrap();
        assert_eq!(r.state, QrLoginState::Confirmed);
        assert_eq!(r.code, 803);
        assert_eq!(r.nickname, "下去玩");
        assert_eq!(r.avatar_url.as_deref(), Some("https://x/y.jpg"));
        let cookie = r.cookie.unwrap();
        assert!(cookie.contains("MUSIC_U=abc123"));
        assert!(cookie.contains("__csrf=csrf456"));
        // JSESSIONID-WYYY 是 weapi 会话的一部分, 保留; 设备指纹键不进账号簿
        assert!(cookie.contains("JSESSIONID-WYYY=xyz"));
        assert!(!cookie.contains("NMTID"));

        // 803 但没有 MUSIC_U: 必须报错, 不能当成登录成功
        let err = parse_qr_check(&json!({"code":803}), &[]).unwrap_err();
        assert_eq!(err.kind, ProviderErrorKind::Internal);
    }

    /// album_newest: 2026-11-09 实测形状(顶层 albums, 固定 12 张, 专辑对象同 album_new).
    #[test]
    fn album_newest_parses_real_shape() {
        let body = json!({
            "code": 200,
            "albums": [{
                "id": 404764114u64,
                "name": "Love Me Later 巡回演唱会LIVE TRACKS",
                "picUrl": "https://p4.music.126.net/RT7TwtwTJ8Gw-9qaltqjkw==/109951174134867745.jpg",
                "size": 10,
                "publishTime": 1792598400000u64,
                "artist": {"id": 12236125u64, "name": "王以太", "picUrl": "https://p4.music.126.net/x.jpg"},
                "songs": null
            }]
        });
        let albums = parse_album_items(&body);
        assert_eq!(albums.len(), 1);
        assert_eq!(albums[0].id, 404764114);
        assert_eq!(albums[0].artist, "王以太");
        assert_eq!(albums[0].track_count, 10);
        assert!(albums[0].cover_url.as_deref().unwrap_or("").starts_with("https://"));
    }

    /// album_newest: albums 缺失(code!=200 / 接口变更)时给空列表, 不 panic.
    #[test]
    fn album_newest_missing_albums_is_empty() {
        assert!(parse_album_items(&json!({"code": 301})).is_empty());
        assert!(parse_album_items(&json!({"code": 200, "albums": null})).is_empty());
    }

    /// ---- 歌单写接口 parse(2026-11-10 实测样例, 见 docs/b7-playlist-write-notes.md) ----

    #[test]
    fn created_playlist_from_top_level_id() {
        let body = json!({"code":200,"id":18580697682u64,"playlist":{"adType":0,"anonimous":false,
            "id":18580697682u64,"name":"B7抓包临时歌单 20261110-023344","privacy":0,
            "trackCount":0,"userId":1822714196u64,"subscribedCount":0,"tags":[]}});
        let p = parse_created_playlist(&body).expect("应能解析");
        assert_eq!(p.id, 18580697682);
        assert_eq!(p.name, "B7抓包临时歌单 20261110-023344");
    }

    #[test]
    fn created_playlist_falls_back_to_playlist_id() {
        // 防御老形态: 顶层缺 id 时回退 playlist.id
        let p = parse_created_playlist(&json!({"code":200,"playlist":{"id":12345678901u64,"name":"X"}}))
            .expect("应能解析");
        assert_eq!(p.id, 12345678901);
        assert_eq!(p.name, "X");
    }

    #[test]
    fn created_playlist_none_when_no_id() {
        assert!(parse_created_playlist(&json!({"code":500,"msg":"请求异常"})).is_none());
        assert!(parse_created_playlist(&json!({"code":200,"id":0})).is_none());
    }

    #[test]
    fn playlist_edit_add_ok_track_ids_is_string_not_array() {
        // 实测原文: trackIds 是数组 JSON 文本(字符串), count=2; 成功无 message
        let body = json!({"cloudCount":0,"code":200,"count":2,
            "coverImgId":"109951167894836691",
            "coverImgUrl":"http://p3.music.126.net/Pz4sEpA7nsiyIdIrswTx9A==/109951167894836691.jpg",
            "trackIds":"[186016,26305527]"});
        let r = parse_playlist_edit_result(&body);
        assert!(r.ok);
        assert_eq!(r.code, 200);
        assert_eq!(r.count, Some(2));
        assert_eq!(r.message, None);
    }

    #[test]
    fn playlist_edit_delete_ok_without_message() {
        let r = parse_playlist_edit_result(&json!({"code":200,"data":null,"message":null,"msg":null}));
        assert!(r.ok);
        assert_eq!(r.code, 200);
        assert_eq!(r.count, None);
        assert_eq!(r.message, None);
    }

    #[test]
    fn playlist_edit_failure_extracts_msg() {
        // 实测: UA/身份形态不配套时服务端回 500「请求异常」
        let r = parse_playlist_edit_result(&json!({"code":500,"msg":"请求异常，请稍后重试"}));
        assert!(!r.ok);
        assert_eq!(r.code, 500);
        assert_eq!(r.message.as_deref(), Some("请求异常，请稍后重试"));
    }

    /// artist_songs: 2026-11-22 实测形状(顶层 more + songs[], 歌曲为 NCM 歌曲 DTO).
    #[test]
    fn artist_songs_parses_real_shape() {
        let body = json!({
            "code": 200,
            "more": true,
            "songs": [
                {"id": 298317u64, "name": "屋顶", "dt": 319039u64, "fee": 0,
                 "ar": [{"id": 9612u64, "name": "温岚"}, {"id": 6452u64, "name": "周杰伦"}],
                 "al": {"id": 29597u64, "name": "有点野",
                        "picUrl": "https://p4.music.126.net/t1KaAJmIphZKdPq8JfItbA==/109951170514287417.jpg"},
                 "privilege": {"st": -53918, "dl": 999000}},
                {"id": 210049u64, "name": "安静", "dt": 274573u64, "fee": 8,
                 "ar": [{"id": 6452u64, "name": "周杰伦"}],
                 "al": {"id": 18919u64, "name": "范特西", "picUrl": "https://p3.music.126.net/x.jpg"},
                 "privilege": {"st": 0, "dl": 320000}}
            ]
        });
        let page = parse_artist_songs(&body);
        assert!(page.has_more);
        assert_eq!(page.songs.len(), 2);
        assert_eq!(page.songs[0].name, "屋顶");
        assert_eq!(page.songs[0].artists.len(), 2);
        assert_eq!(page.songs[0].artists[0].name, "温岚");
        assert_eq!(page.songs[0].album.as_ref().unwrap().name, "有点野");
        assert_eq!(page.songs[0].duration_ms, 319039);
        assert_eq!(page.songs[0].fee, Some(0));
    }

    /// mv_detail: 2026-11-22 实测形状(id=5436712 广岛之恋, brs 数组).
    #[test]
    fn mv_detail_parses_real_shape() {
        let body = json!({
            "code": 200,
            "data": {
                "id": 5436712u64, "name": "广岛之恋", "artistName": "莫文蔚",
                "duration": 378040u64, "playCount": 852564u64,
                "publishTime": "1997-10-01",
                "cover": "http://p4.music.126.net/abc.jpg",
                "brs": [{"br": 480, "point": 0, "size": 31157772.0}, {"br": 240, "point": 0, "size": 17639436.0}],
                "desc": null, "commentCount": 689u64
            },
            "subed": false
        });
        let d = parse_mv_detail(&body);
        assert_eq!(d.id, 5436712);
        assert_eq!(d.name, "广岛之恋");
        assert_eq!(d.artist_name, "莫文蔚");
        assert_eq!(d.duration_ms, 378040);
        assert_eq!(d.publish_time, "1997-10-01");
        assert_eq!(d.cover_url.as_deref(), Some("http://p4.music.126.net/abc.jpg"));
        assert_eq!(d.brs, vec![240, 480]);
        assert_eq!(d.max_br, 480);
        assert!(d.desc.is_none());
    }

    /// mv_detail: desc 非空时保留.
    #[test]
    fn mv_detail_keeps_desc() {
        let body = json!({"code": 200, "data": {"id": 1u64, "name": "mv", "desc": "简介文本"}});
        assert_eq!(parse_mv_detail(&body).desc.as_deref(), Some("简介文本"));
    }

    /// mv_detail: data 缺失时空默认值(id=0).
    #[test]
    fn mv_detail_missing_data_is_default() {
        let d = parse_mv_detail(&json!({"code": 301}));
        assert_eq!(d.id, 0);
        assert!(d.name.is_empty());
        assert!(d.brs.is_empty());
        assert_eq!(d.max_br, 0);
    }

    /// mv_url: 2026-11-22 实测形状(data 单对象, 签名直链 + 实际档位).
    #[test]
    fn mv_url_parses_real_shape() {
        let body = json!({
            "code": 200,
            "data": {
                "code": 200, "expi": 3600u64, "fee": 0, "id": 5436712u64, "md5": "",
                "r": 480, "size": 31157772u64,
                "url": "http://vodkgeyttp8.vod.126.net/cloudmusic/a.mp4?wsSecret=x&wsTime=1"
            }
        });
        let u = parse_mv_url(&body);
        assert!(u.url.as_deref().unwrap().starts_with("http://vodkgeyttp8"));
        assert_eq!(u.r, 480);
        assert_eq!(u.size, 31157772);
    }

    /// mv_url: url 为 null(需要 VIP / 下架)时 url=None.
    #[test]
    fn mv_url_null_url_is_none() {
        let body = json!({"code": 200, "data": {"code": 200, "url": null, "r": 1080}});
        assert!(parse_mv_url(&body).url.is_none());
    }

    /// mv_url: data 缺失时全默认.
    #[test]
    fn mv_url_missing_data_is_default() {
        let u = parse_mv_url(&json!({"code": 404}));
        assert!(u.url.is_none());
        assert_eq!(u.r, 0);
        assert_eq!(u.size, 0);
    }

    /// mv_detail: brs 乱序/重复时升序去重, max_br 取最大.
    #[test]
    fn mv_detail_brs_sorted_deduped() {
        let body = json!({"code": 200, "data": {"id": 2u64, "name": "m",
            "brs": [{"br": 1080}, {"br": 480}, {"br": 1080}, {"br": 720}]}});
        let d = parse_mv_detail(&body);
        assert_eq!(d.brs, vec![480, 720, 1080]);
        assert_eq!(d.max_br, 1080);
    }

    /// artist_songs: more=false 表示没有下一页(最后一页).
    #[test]
    fn artist_songs_more_flag_ends_paging() {
        let body = json!({"code": 200, "more": false, "songs": [{"id": 1u64, "name": "a"}]});
        let page = parse_artist_songs(&body);
        assert!(!page.has_more);
        assert_eq!(page.songs.len(), 1);
    }

    /// artist_songs: songs 缺失(code!=200)时空列表 + more 缺失按 false.
    #[test]
    fn artist_songs_missing_fields_is_empty_page() {
        let page = parse_artist_songs(&json!({"code": 301}));
        assert!(page.songs.is_empty());
        assert!(!page.has_more);
    }

    /// artist_songs: privilege.st<0(无版权)时歌曲标记为不可播.
    #[test]
    fn artist_songs_privilege_marks_playable() {
        let body = json!({
            "code": 200, "more": true,
            "songs": [
                {"id": 1u64, "name": "无版权", "dt": 1000u64, "fee": 0,
                 "ar": [], "al": null, "privilege": {"st": -200}},
                {"id": 2u64, "name": "可播", "dt": 1000u64, "fee": 0,
                 "ar": [], "al": null, "privilege": {"st": 0}}
            ]
        });
        let page = parse_artist_songs(&body);
        assert!(!page.songs[0].playable);
        assert!(page.songs[1].playable);
    }

    /// artist_mv: 2026-11-22 实测形状(顶层 hasMore + mvs[], imgurl16v9 是 16:9 封面).
    #[test]
    fn artist_mvs_parses_real_shape() {
        let body = json!({
            "code": 200,
            "hasMore": true,
            "mvs": [
                {"id": 22695250u64, "name": "任性 (5525 Live版)", "artistName": "周杰伦",
                 "duration": 266000u64, "playCount": 106722u64, "publishTime": "2025-02-23",
                 "imgurl": "http://p3.music.126.net/a.jpg",
                 "imgurl16v9": "http://p4.music.126.net/b.jpg", "status": 0, "subed": false}
            ]
        });
        let page = parse_artist_mvs(&body);
        assert!(page.has_more);
        assert_eq!(page.mvs.len(), 1);
        let mv = &page.mvs[0];
        assert_eq!(mv.id, 22695250);
        assert_eq!(mv.name, "任性 (5525 Live版)");
        assert_eq!(mv.duration_ms, 266000);
        assert_eq!(mv.play_count, 106722);
        assert_eq!(mv.publish_time, "2025-02-23");
        assert_eq!(mv.cover_url.as_deref(), Some("http://p4.music.126.net/b.jpg"));
    }

    /// artist_mv: imgurl16v9 缺失时回退 imgurl.
    #[test]
    fn artist_mvs_cover_fallback_imgurl() {
        let body = json!({
            "code": 200, "hasMore": false,
            "mvs": [{"id": 1u64, "name": "mv", "duration": 1000u64,
                     "imgurl": "http://p3.music.126.net/fallback.jpg"}]
        });
        let page = parse_artist_mvs(&body);
        assert_eq!(page.mvs[0].cover_url.as_deref(), Some("http://p3.music.126.net/fallback.jpg"));
        assert!(!page.has_more);
    }

    /// artist_mv: mvs 缺失(接口失败/变更)时空列表, 不 panic.
    #[test]
    fn artist_mvs_missing_mvs_is_empty_page() {
        let page = parse_artist_mvs(&json!({"code": 301}));
        assert!(page.mvs.is_empty());
        assert!(!page.has_more);
    }

    /// artist_mv: name 缺失/为空的条目丢弃(脏数据防御).
    #[test]
    fn artist_mvs_drops_unnamed_entries() {
        let body = json!({
            "code": 200, "hasMore": true,
            "mvs": [
                {"id": 1u64, "name": "", "duration": 1u64},
                {"id": 2u64, "duration": 2u64},
                {"id": 3u64, "name": "正常", "duration": 3u64}
            ]
        });
        let page = parse_artist_mvs(&body);
        assert_eq!(page.mvs.len(), 1);
        assert_eq!(page.mvs[0].id, 3);
    }

    /// artist_songs: 翻页语义 —— 解析器按 offset/limit 由调用方控制, 响应只带 more.
    /// 这里验证两次响应合并不重叠由 id 区分(模拟 page1/page2 实测).
    #[test]
    fn artist_songs_page_ids_distinguishable() {
        let p1 = parse_artist_songs(&json!({
            "code": 200, "more": true,
            "songs": [{"id": 298317u64, "name": "屋顶"}, {"id": 210049u64, "name": "安静"}]
        }));
        let p2 = parse_artist_songs(&json!({
            "code": 200, "more": false,
            "songs": [{"id": 1888354230u64, "name": "other"}]
        }));
        let mut ids: Vec<u64> = p1.songs.iter().chain(p2.songs.iter()).map(|s| s.id.0).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), 3);
        assert!(!p2.has_more);
    }


    /// toplist_detail_v2: 2026-11-09 实测形状(data[].categoryCode 分组 + list[] 榜单卡;
    /// 无 trackUpdateTime / "更新 N 首", 元素带 canPlay/targetType).
    #[test]
    fn toplist_catalog_parses_real_shape() {
        let body = json!({
            "code": 200,
            "data": [
                {"categoryCode": "TOPPING", "displayType": "ONLY_COVER", "list": [
                    {"id": 5059633707u64, "name": "网易云摇滚榜", "category": "MUSIC_STYLE",
                     "coverUrl": "https://p3.music.126.net/abc.jpg", "updateFrequency": "每周五更新",
                     "targetType": "PLAYLIST", "canPlay": true, "tracks": null, "trackRankList": null}
                ]},
                {"categoryCode": "GLOBAL", "list": [
                    {"id": 60131u64, "name": "日本Oricon榜", "coverUrl": "https://p3.music.126.net/def.jpg",
                     "updateFrequency": "每天更新", "targetType": "PLAYLIST", "canPlay": true}
                ]}
            ]
        });
        let groups = parse_toplist_catalog(&body);
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0].code, "TOPPING");
        assert_eq!(groups[0].items.len(), 1);
        let it = &groups[0].items[0];
        assert_eq!(it.id, 5059633707);
        assert_eq!(it.name, "网易云摇滚榜");
        assert_eq!(it.update_frequency, "每周五更新");
        assert_eq!(it.target_type, "PLAYLIST");
        assert!(it.can_play);
        assert_eq!(groups[1].items[0].name, "日本Oricon榜");
    }

    /// toplist_detail_v2: data 缺失/空数组/空分组都返回空目录.
    #[test]
    fn toplist_catalog_missing_data_is_empty() {
        assert!(parse_toplist_catalog(&json!({"code": 200})).is_empty());
        assert!(parse_toplist_catalog(&json!({"code": 200, "data": []})).is_empty());
        let groups = parse_toplist_catalog(&json!({"code": 200, "data": [{"categoryCode": "X"}]}));
        assert_eq!(groups.len(), 1);
        assert!(groups[0].items.is_empty());
    }

    /// MV/视频评论: /api/v1/resource/comments/R_MV_5_|R_VI_62_ 与歌曲评论同形,
    /// parse_comments 直接复用(hotComments + comments + total + more).
    #[test]
    fn mv_video_comments_share_comment_page_shape() {
        let body = json!({
            "code": 200,
            "total": 1234u64,
            "more": true,
            "hotComments": [{"commentId": 1u64, "content": "神作", "likedCount": 99u64}],
            "comments": [{"commentId": 2u64, "content": "前排", "likedCount": 1u64}]
        });
        let page = parse_comments(&body).expect("parse ok");
        assert_eq!(page.total, 1234);
        assert!(page.has_more);
        assert_eq!(page.comments.len(), 2);
        assert!(page.comments[0].hot);
        assert!(!page.comments[1].hot);
        // kind → threadId 前缀映射早已存在
        assert_eq!(thread_id_for("mv", 5436712).as_deref(), Some("R_MV_5_5436712"));
        assert_eq!(thread_id_for("video", 144634).as_deref(), Some("R_VI_62_144634"));
    }

    /// digitalAlbum/purchased: 2026-11-09 实测形状(顶层 paidAlbums + total, 封面叫 cover)
    #[test]
    fn digital_album_purchased_parses_real_shape() {
        let body = json!({
            "code": 200,
            "total": 2,
            "paidAlbums": [{
                "albumId": 120605500u64,
                "albumName": "冀西南林路行",
                "artist": {"id": 13223, "name": "万能青年旅店"},
                "cover": "https://p4.music.126.net/aEehIWg8Qk5DXLGf0XZHqw==/109951166554891221.jpg",
                "paidTime": 1638063971559u64,
                "boughtCount": 1,
                "sub": false,
                "channel": 0,
                "valid": 99
            }, {
                "albumId": 162008967u64,
                "albumName": "伍六七之暗影宿命 原声大碟",
                "artist": {"id": 56085302, "name": "伍六七"},
                "cover": "https://p3.music.126.net/MJOV25-FS6XdLEjqDddt-g==/109951168553533864.jpg",
                "paidTime": 1687007720179u64,
                "boughtCount": 1
            }]
        });
        let p = parse_digital_album_purchased(&body).expect("purchased");
        assert_eq!(p.total, 2);
        assert_eq!(p.albums.len(), 2);
        let first = &p.albums[0];
        assert_eq!(first.album_id, 120605500);
        assert_eq!(first.album_name, "冀西南林路行");
        assert_eq!(first.artist_id, 13223);
        assert_eq!(first.artist_name, "万能青年旅店");
        assert!(first.cover_url.starts_with("https://"));
        assert_eq!(first.paid_time_ms, 1638063971559);
        assert_eq!(first.bought_count, 1);
    }

    /// paidAlbums 缺失 / null / 空数组都当空列表, total 仍取服务端值
    #[test]
    fn digital_album_purchased_tolerates_missing_albums() {
        for body in [
            json!({"code": 200, "total": 2}),
            json!({"code": 200, "total": 2, "paidAlbums": null}),
            json!({"code": 200, "total": 0, "paidAlbums": []}),
        ] {
            let p = parse_digital_album_purchased(&body).expect("purchased");
            assert!(p.albums.is_empty(), "body={body}");
            assert_eq!(p.total, if p.total == 0 { 0 } else { 2 });
        }
        // 元素缺 albumId 的坏条目直接跳过, 不 panic
        let bad = json!({"code": 200, "total": 1, "paidAlbums": [{"albumName": "x"}]});
        let p = parse_digital_album_purchased(&bad).expect("purchased");
        assert!(p.albums.is_empty());
    }

    /// song_purchased: 实测(无已购单曲)为 data.{count,hasMore,list:[]}; list 元素宽松兼容两种命名
    #[test]
    fn song_purchased_parses_pagination_and_empty() {
        let empty = json!({"code": 200, "data": {"count": 0, "hasMore": false, "list": []}, "message": ""});
        let p = parse_song_purchased(&empty).expect("purchased");
        assert_eq!(p.count, 0);
        assert!(!p.has_more);
        assert!(p.songs.is_empty());

        let listed = json!({"code": 200, "data": {"count": 1, "hasMore": true, "list": [
            {"id": 186016u64, "name": "晴天", "artist": {"name": "周杰伦"}, "cover": "https://c", "paidTime": 1700000000000u64},
            {"songId": 999, "songName": "别名兼容", "artistName": "A/B"}
        ]}});
        let p = parse_song_purchased(&listed).expect("purchased");
        assert_eq!(p.count, 1);
        assert!(p.has_more);
        assert_eq!(p.songs.len(), 2);
        assert_eq!(p.songs[0].song_id, 186016);
        assert_eq!(p.songs[0].artist_name, "周杰伦");
        assert_eq!(p.songs[1].song_id, 999);
        assert_eq!(p.songs[1].name, "别名兼容");
    }

    /// digital_album_detail: 专辑字段在 album, 价格/上架/标签在 product, descr 过滤 </br>
    #[test]
    fn digital_album_detail_parses_real_shape() {
        // 2026-11-09 实测: ncm raw digital_album_detail id=120605500
        let body = json!({
            "code": 200,
            "hasAlbum": true,
            "boughtCnt": 1,
            "album": {
                "albumId": 120605500u64,
                "albumName": "冀西南林路行",
                "artistName": "万能青年旅店",
                "artistId": 13223,
                "coverUrl": "https://p4.music.126.net/aEehIWg8Qk5DXLGf0XZHqw==/109951166554891221.jpg"
            },
            "product": {
                "price": 22.0,
                "pubTime": 1608566401510u64,
                "saleNum": 0,
                "tags": ["独家", "无损品质收听＆下载"],
                "descr": [{"resource": "发端似乎在2013年", "type": 1}, {"resource": "</br>", "type": 1}, {"resource": "西郊有密林", "type": 1}]
            }
        });
        let d = parse_digital_album_detail(&body).expect("detail");
        assert_eq!(d.album_id, 120605500);
        assert_eq!(d.name, "冀西南林路行");
        assert_eq!(d.artist_name, "万能青年旅店");
        assert!(d.has_album);
        assert!((d.price - 22.0).abs() < f64::EPSILON);
        assert_eq!(d.pub_time_ms, 1608566401510);
        assert_eq!(d.sale_num, 0);
        assert_eq!(d.tags, vec!["独家", "无损品质收听＆下载"]);
        assert_eq!(d.description, "发端似乎在2013年\n西郊有密林");
        // 缺 product 只退化字段, album 缺失才是 not_found
        let no_product = json!({"code": 200, "album": {"albumId": 1, "albumName": "x"}});
        let d = parse_digital_album_detail(&no_product).expect("detail");
        assert_eq!(d.price, 0.0);
        assert!(d.tags.is_empty());
        assert!(parse_digital_album_detail(&json!({"code": 200})).is_err());
    }

    /// digital_album_sales: data 是 {专辑id串: 销量} map, 不是数组
    #[test]
    fn digital_album_sales_parses_map() {
        let body = json!({"code": 200, "data": {"120605500": 1300052u64, "162008967": 7u64}});
        let s = parse_digital_album_sales(&body);
        assert_eq!(s.len(), 2);
        assert!(s.contains(&DigitalAlbumSalesEntry { album_id: "120605500".into(), sales: 1300052 }));
        // data 缺失/非对象 → 空列表, 不报错
        assert!(parse_digital_album_sales(&json!({"code": 200})).is_empty());
        assert!(parse_digital_album_sales(&json!({"code": 200, "data": []})).is_empty());
    }

    // ---- B10 电台补充(只读) ----

    /// dj_catelist: 顶层直接是 categories, 没有 code; 缺字段要兜底
    #[test]
    fn radio_categories_parses_real_shape() {
        let body = json!({"categories": [
            {"id": 3, "name": "情感", "pic56x56Url": "https://p4.music.126.net/x.jpg",
             "picWebUrl": "https://p3.music.126.net/y.jpg"},
            {"id": 2, "name": "音乐播客"}
        ]});
        let cats = parse_radio_categories(&body);
        assert_eq!(cats.len(), 2);
        assert_eq!(cats[0].id, 3);
        assert_eq!(cats[0].name, "情感");
        assert!(cats[0].cover_url.starts_with("https://"));
        assert!(cats[1].cover_url.is_empty());
        // 空/缺 categories → 空列表不报错
        assert!(parse_radio_categories(&json!({})).is_empty());
    }

    /// dj_category_recommend: data 是数组, radios 元素与 DjRadio 同形状(icon 可 null)
    #[test]
    fn radio_picks_parses_real_shape() {
        let body = json!({"code": 200, "data": [
            {"categoryId": 3, "categoryName": "情感", "radios": [
                {"id": 526564706, "name": "伴听FM", "picUrl": "https://x.jpg",
                 "playCount": 6555956u64, "programCount": 18, "subCount": 0,
                 "lastProgramName": "想和你把生活过成一首诗", "radioFeeType": 0, "icon": null,
                 "dj": {"nickname": "小北"}}
            ]}
        ]});
        let picks = parse_radio_picks(&body);
        assert_eq!(picks.len(), 1);
        assert_eq!(picks[0].category_id, 3);
        assert_eq!(picks[0].radios.len(), 1);
        assert_eq!(picks[0].radios[0].name, "伴听FM");
        assert_eq!(picks[0].radios[0].dj_name, "小北");
        // data 缺失 → 空
        assert!(parse_radio_picks(&json!({"code": 200})).is_empty());
    }

    /// dj_toplist: 顶层 toplist, 元素带 rank/score/lastRank, rcmdtext 全小写
    #[test]
    fn radio_toplist_radios_parses_real_shape() {
        let body = json!({"code": 200, "toplist": [
            {"rank": 1, "lastRank": 3, "score": 116563u64, "category": "创作翻唱", "categoryId": 2001,
             "id": 792868378u64, "name": "一条小团团OvO的翻唱合集", "picUrl": "http://p2.music.126.net/x.jpg",
             "playCount": 131838544u64, "programCount": 56, "subCount": 456521u64,
             "creatorName": "一条小团团OvO", "dj": {"nickname": "一条小团团OvO"},
             "rcmdtext": "可神经可温柔的宝藏女声"}
        ]});
        let t = parse_radio_toplist_radios(&body);
        assert_eq!(t.radios.len(), 1);
        let r = &t.radios[0];
        assert_eq!(r.rank, 1);
        assert_eq!(r.last_rank, 3);
        assert_eq!(r.radio_id, 792868378);
        assert_eq!(r.dj_name, "一条小团团OvO");
        assert_eq!(r.rcmd_text, "可神经可温柔的宝藏女声");
        assert_eq!(r.play_count, 131838544);
        // pay 榜形状(在 data.list 下) + 缺 dj 用 creatorName 兜底 + lastRank=-1
        let pay = json!({"code": 200, "data": {"list": [
            {"rank": 1, "lastRank": -1, "id": 988499285u64, "name": "猫小九历险记",
             "picUrl": "https://p3.music.126.net/y.jpg", "creatorName": "奇喵君故事", "score": 11104632u64}
        ]}});
        let t = parse_radio_toplist_radios(&pay);
        assert_eq!(t.radios.len(), 1);
        assert_eq!(t.radios[0].dj_name, "奇喵君故事");
        assert_eq!(t.radios[0].last_rank, -1);
        assert_eq!(t.radios[0].program_count, 0);
        // 缺 toplist → 空
        assert!(parse_radio_toplist_radios(&json!({"code": 200})).radios.is_empty());
    }

    /// 主播榜(hours/newcomer/popular): data.list 是用户, 字段 nickName(驼峰)
    #[test]
    fn radio_toplist_djs_parses_real_shape() {
        let body = json!({"code": 200, "data": {"list": [
            {"rank": 1, "lastRank": 2, "id": 287921940u64, "nickName": "开心锤锤",
             "avatarUrl": "http://p1.music.126.net/z.jpg", "score": 3581801u64,
             "userFollowedCount": 79757u64, "userType": 4, "avatarDetail": null}
        ]}});
        let t = parse_radio_toplist_djs(&body);
        assert_eq!(t.djs.len(), 1);
        let d = &t.djs[0];
        assert_eq!(d.rank, 1);
        assert_eq!(d.user_id, 287921940);
        assert_eq!(d.nickname, "开心锤锤");
        assert_eq!(d.followed_count, 79757);
        // data.list 缺失 → 空
        assert!(parse_radio_toplist_djs(&json!({"code": 200})).djs.is_empty());
        assert!(parse_radio_toplist_djs(&json!({"code": 200, "data": {}})).djs.is_empty());
    }

    /// 节目榜: toplist 元素 = {rank,lastRank,program}; program 与 dj_program 同形状
    #[test]
    fn radio_toplist_programs_parses_real_shape() {
        let body = json!({"code": 200, "toplist": [
            {"rank": 1, "lastRank": 3, "program": {
                "id": 3731681674u64, "name": "罗言新歌", "coverUrl": "https://p3.music.126.net/a.jpg",
                "duration": 92400, "description": "比冬天先来的是罗言的新歌",
                "dj": {"nickname": "_XXXTENTACION-_"}, "mainSong": {"id": 1, "name": "s"}}}
        ]});
        let t = parse_radio_toplist_programs(&body);
        assert_eq!(t.programs.len(), 1);
        assert_eq!(t.programs[0].rank, 1);
        assert_eq!(t.programs[0].program.name, "罗言新歌");
        assert_eq!(t.programs[0].program.duration_ms, 92400);
        // 缺 program 的条目跳过
        let partial = json!({"code": 200, "toplist": [
            {"rank": 2, "lastRank": 1},
            {"rank": 3, "lastRank": 2, "program": {"id": 9u64, "name": "p"}}
        ]});
        let t = parse_radio_toplist_programs(&partial);
        assert_eq!(t.programs.len(), 1);
        assert_eq!(t.programs[0].program.id, 9);
    }

    /// dj_subscriber: 顶层 hasMore + subscribers(完整 user 对象)
    #[test]
    fn radio_subscribers_parses_real_shape() {
        let body = json!({"code": 200, "hasMore": true, "subscribers": [
            {"userId": 1594251132u64, "nickname": "饱饭三餐何来忧", "avatarUrl": "http://x.jpg",
             "signature": "一个喜欢音乐的过客！", "subscribeTime": 1793611157940u64, "userType": 0}
        ]});
        let p = parse_radio_subscribers(&body).expect("subs");
        assert!(p.has_more);
        assert_eq!(p.subscribers.len(), 1);
        assert_eq!(p.subscribers[0].user_id, 1594251132);
        assert_eq!(p.subscribers[0].subscribe_time_ms, 1793611157940);
        // subscribers 缺失/为空 → 空页不报错
        let empty = parse_radio_subscribers(&json!({"code": 200, "hasMore": false})).expect("empty");
        assert!(!empty.has_more);
        assert!(empty.subscribers.is_empty());
    }

    /// comment_info_list: 实测字段(歌曲 186016), 只取 data[0], 服务端 threadId 优先
    #[test]
    fn comment_stats_parses_real_shape() {
        // 2026-11-09 实测: ncm raw comment_info_list type=0 ids=186016
        let body = json!({
            "code": 200,
            "data": [{
                "commentCount": 1_969_911u64,
                "commentCountDesc": "100w+",
                "commentUpgraded": false,
                "comments": null,
                "latestLikedUsers": null,
                "liked": false,
                "likedCount": 352,
                "musicianSaidCount": 0,
                "resourceId": 186016,
                "resourceType": 4,
                "shareCount": 109_723u64,
                "threadId": "R_SO_4_186016"
            }]
        });
        let s = parse_comment_stats(&body, "R_SO_4_186016").expect("stats");
        assert_eq!(s.thread_id, "R_SO_4_186016");
        assert_eq!(s.resource_id, 186016);
        assert_eq!(s.comment_count, 1_969_911);
        assert_eq!(s.comment_count_desc, "100w+");
        assert_eq!(s.share_count, 109_723);
        assert_eq!(s.liked_count, 352);
        assert!(!s.liked);
        assert_eq!(s.musician_said_count, 0);
        assert!(!s.comment_upgraded);
    }

    /// data 缺失 / 空数组 / 空对象 / null 都退化成全 0(threadId 用入参), 不能 panic 也不能报错
    #[test]
    fn comment_stats_tolerates_missing_data() {
        for body in [
            json!({"code": 200}),
            json!({"code": 200, "data": []}),
            json!({"code": 200, "data": {}}),
            json!({"code": 200, "data": null}),
        ] {
            let s = parse_comment_stats(&body, "A_PL_0_24381616").expect("stats");
            assert_eq!(s.thread_id, "A_PL_0_24381616", "body={body}");
            assert_eq!(s.comment_count, 0);
            assert_eq!(s.share_count, 0);
            assert_eq!(s.liked_count, 0);
            assert!(s.comment_count_desc.is_empty());
        }
    }

    /// 歌单/专辑/播客/视频共用同一形状, 只是数值不同(实测均为空 desc + 0 评论)
    #[test]
    fn comment_stats_shape_is_same_across_resource_types() {
        let cases = [
            ("A_PL_0_24381616", 24381616u64, 6u64),
            ("R_AL_3_32311", 32311, 10_519),
            ("A_DJ_1_32507038", 32507038, 0),
            ("R_VI_62_12147019", 12147019, 0),
        ];
        for (tid, rid, share) in cases {
            let body = json!({"code": 200, "data": [{
                "commentCount": 0, "commentCountDesc": "", "commentUpgraded": false,
                "comments": null, "latestLikedUsers": null, "liked": false, "likedCount": 0,
                "musicianSaidCount": 0, "resourceId": rid, "resourceType": 0,
                "shareCount": share, "threadId": tid
            }]});
            let s = parse_comment_stats(&body, tid).expect("stats");
            assert_eq!(s.thread_id, tid);
            assert_eq!(s.resource_id, rid);
            assert_eq!(s.share_count, share);
        }
    }

    /// vip_info_v2: is_vip 只看 expireTime > now(vipCode/vipLevel 过期后仍是旧值)
    #[test]
    fn vip_membership_is_vip_by_expire_time() {
        let body = json!({
            "code": 200,
            "data": {
                "now": 1_794_021_180_859u64,
                "redVipLevel": 3,
                "redVipAnnualCount": -1,
                "associator": {"vipCode": 100, "vipLevel": 3, "expireTime": 1_794_326_399_000u64}
            }
        });
        let m = parse_vip_membership(&body).expect("membership");
        assert_eq!(m.level, 3);
        assert_eq!(m.red_vip_level, 3);
        assert!(m.is_vip, "expireTime 晚于 now 应算会员");
        assert_eq!(m.annual_count, -1);

        // 同一个账号, 把 now 挪到过期之后 -> 不再是会员(但 vipLevel 仍是 3)
        let expired = json!({
            "code": 200,
            "data": {
                "now": 1_800_000_000_000u64,
                "associator": {"vipLevel": 3, "expireTime": 1_794_326_399_000u64}
            }
        });
        let m = parse_vip_membership(&expired).expect("membership");
        assert!(!m.is_vip);
        assert_eq!(m.level, 3);
        assert_eq!(m.red_vip_level, 0);
    }

    /// vip_growthpoint: 今日成长值藏在 userLevel.extJson(JSON 字符串) 里
    #[test]
    fn vip_growth_reads_today_score_from_ext_json() {
        let body = json!({
            "code": 200,
            "data": {
                "levelCard": {"level": 3, "levelName": "黑胶·叁"},
                "userLevel": {
                    "level": 3,
                    "levelName": "黑胶·叁",
                    "growthPoint": 2195,
                    "maxLevel": false,
                    "extJson": "{\"yearMonth\":\"202610\",\"todayScore\":6,\"totalScore\":0}"
                }
            }
        });
        let g = parse_vip_growth(&body).expect("growth");
        assert_eq!(g.level, 3);
        assert_eq!(g.level_name, "黑胶·叁");
        assert_eq!(g.growth_point, 2195);
        assert_eq!(g.today_score, 6);
        assert!(!g.max_level);

        // extJson 坏掉时不能 panic, 今日成长值退 0
        let broken = json!({"data": {"userLevel": {"growthPoint": 1, "extJson": "not-json"}}});
        let g = parse_vip_growth(&broken).expect("growth");
        assert_eq!(g.today_score, 0);
    }

    /// vip_sign_info: 只回最近 7 天, score > 0 才算已签(recordId/time 未签时也是 0)
    #[test]
    fn vip_sign_uses_score_not_record_id() {
        let body = json!({
            "code": 200,
            "data": [
                {"timeStr": "2026-11-05", "today": false, "score": 0, "recordId": 0, "time": 0},
                {"timeStr": "2026-11-06", "today": false, "score": 3, "recordId": 0, "time": 0},
                {"timeStr": "2026-11-07", "today": true, "score": 3, "recordId": 0, "time": 0}
            ]
        });
        let s = parse_vip_sign(&body);
        assert_eq!(s.days.len(), 3);
        assert_eq!(s.week_signed, 2);
        assert!(s.days[0].signed == false);
        assert!(s.days[1].signed);
        assert!(s.signed_today);
        assert!(s.days[2].today);

        let empty = json!({"code": 200, "data": []});
        let s = parse_vip_sign(&empty);
        assert!(s.days.is_empty());
        assert!(!s.signed_today);
        assert_eq!(s.week_signed, 0);
    }

    /// vip_tasks: name 空回退 action; targets=null 时 target=0(不显示进度条); status=2 算完成
    #[test]
    fn vip_tasks_flatten_and_fallback_title() {
        let body = json!({
            "code": 200,
            "data": {
                "taskScore": 7,
                "taskList": [
                    {"seqName": "个性化任务", "taskItems": [
                        {"action": "浏览黑胶时光机", "name": "", "description": "成长值+3",
                         "growthPoint": 3, "currentProgress": 0, "targets": null,
                         "showProgress": true, "status": 0,
                         "url": "https://music.163.com/prime/m/viptimemachine"},
                        {"action": "听歌 60 分钟", "name": "每日听歌", "description": "成长值+2",
                         "growthPoint": 2, "currentProgress": 60, "targets": 60,
                         "showProgress": true, "status": 0},
                        {"action": "已完成的任务", "name": "", "description": "云贝+10",
                         "growthPoint": 0, "currentProgress": 0, "targets": null,
                         "showProgress": false, "status": 2}
                    ]}
                ]
            }
        });
        let (tasks, score) = parse_vip_tasks(&body);
        assert_eq!(score, 7);
        assert_eq!(tasks.len(), 3);
        assert_eq!(tasks[0].title, "浏览黑胶时光机");
        assert_eq!(tasks[0].reward, "成长值+3");
        assert_eq!(tasks[0].target, 0);
        assert!(!tasks[0].done);
        assert!(tasks[0].url.is_some());
        assert_eq!(tasks[1].title, "每日听歌");
        assert_eq!(tasks[1].target, 60);
        assert!(tasks[1].done);
        assert!(tasks[2].done);
        assert!(!tasks[2].show_progress);
    }

    /// 未登录时 vip_overview 不该报鉴权错误, 而是 logged_in=false 的空态
    #[tokio::test]
    async fn vip_overview_anonymous_is_empty_state() {
        let provider = NeteaseProvider::new(Session::default());
        let o = provider.vip_overview().await.expect("anonymous ok");
        assert!(!o.logged_in);
        assert!(o.membership.is_none());
        assert!(o.tasks.is_empty());
    }

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
    fn word_lyric_real_shape() {
        // 实测 id=5264842 的 yrc 片段(署名 JSON 行 + 逐字行混排)
        let yrc = concat!(
            "{\"t\":0,\"c\":[{\"tx\":\"作词: \"},{\"tx\":\"席慕容\"}]}",
            "\n[21960,7590](21960,470,0)让(22430,2610,0)我(25400,280,0)与(25680,640,0)你(26320,1940,0)握(28290,750,0)别",
        );
        let body = json!({"code": 200, "yrc": {"version": 7, "lyric": yrc}});
        let wl = parse_word_lyric_body(&body).unwrap();
        assert_eq!(wl.lines.len(), 2);
        assert!(wl.has_word_timing);
        assert_eq!(wl.lines[1].words.len(), 6);
        assert_eq!(wl.lines[0].words[0].text, "作词: 席慕容");
    }

    #[test]
    fn word_lyric_missing_yrc_is_empty() {
        // 老歌(晴天)实测: 只有 lrc/tlyric, 无 yrc
        let body = json!({"code": 200, "lrc": {"version": 70, "lyric": "[00:01.00]hi"}, "tlyric": {"lyric": ""}});
        let wl = parse_word_lyric_body(&body).unwrap();
        assert!(wl.is_empty());
    }

    #[test]
    fn word_lyric_translation_falls_back_to_tlyric() {
        let body = json!({
            "code": 200,
            "yrc": {"version": 1, "lyric": "[1000,500](1000,500,0)hello\n[2000,500](2000,500,0)world"},
            "ytlrc": {"version": 0, "lyric": ""},
            "tlyric": {"version": 24, "lyric": "[00:01.00]你好"}
        });
        let wl = parse_word_lyric_body(&body).unwrap();
        assert_eq!(wl.translation_lines[0].as_deref(), Some("你好"));
        assert_eq!(wl.translation_lines[1], None);
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

    #[test]
    fn suggest_keywords_dedup_and_order() {
        let body = json!({"code": 200, "result": {"allMatch": [
            {"keyword": "晴天周杰伦", "type": 1, "alg": "x"},
            {"keyword": " 晴天 ", "type": 1, "alg": "y"},
            {"keyword": "晴天周杰伦", "type": 1},
            {"keyword": "", "type": 1},
            {"keyword": "   ", "type": 1},
            {"keyword": "晴天弦乐版", "type": 1},
            {"keyword": "晴天有点孤单玩具丢在旁边", "type": 1},
            {"keyword": "第7条应被截断", "type": 1}
        ]}});
        let kws = parse_suggest_keywords(&body);
        // 去重保序 + 去空白 + 丢弃空串 + 最多 6 条
        assert_eq!(
            kws,
            vec![
                "晴天周杰伦",
                "晴天",
                "晴天弦乐版",
                "晴天有点孤单玩具丢在旁边",
                "第7条应被截断"
            ]
        );
    }

    #[test]
    fn suggest_keywords_empty_and_missing_keyword() {
        // web 分支的空命中形态: result 是空对象
        assert!(parse_suggest_keywords(&json!({"code": 200, "result": {}})).is_empty());
        // 无 result / allMatch 不是数组 / 缺 keyword 或 keyword 非字符串
        assert!(parse_suggest_keywords(&json!({"code": 200})).is_empty());
        assert!(parse_suggest_keywords(&json!({"code": 200, "result": {"allMatch": "x"}})).is_empty());
        let body = json!({"code": 200, "result": {"allMatch": [
            {"type": 1, "alg": "no-keyword"},
            {"keyword": null},
            {"keyword": 123},
            {"keyword": "唯一有效"}
        ]}});
        assert_eq!(parse_suggest_keywords(&body), vec!["唯一有效".to_string()]);
        // 超过 6 条时截断
        let many: Vec<Value> = (0..9).map(|i| json!({"keyword": format!("k{i}")})).collect();
        let body = json!({"code": 200, "result": {"allMatch": many}});
        assert_eq!(parse_suggest_keywords(&body).len(), 6);
    }

    #[test]
    fn search_exact_with_orders() {
        let body = json!({"code": 200, "result": {
            "orders": ["artist", "playlist", "voice"],
            "artist": [{"id": 6452, "name": "周杰伦", "picUrl": "http://p4/head.jpg",
                        "alias": ["Jay Chou"], "alg": "埋点"}],
            "playlist": [{"id": 8181670003u64, "name": "听薛之谦热门精选",
                          "coverImgUrl": "http://p1/cover.jpg", "trackCount": 40,
                          "playCount": 17158528, "specialType": 0}],
            "voice": [{"resourceId": 2543533915u64, "resourceName": "声音",
                       "resourceType": "voice", "internalType": null,
                       "baseInfo": {"id": 2543533915u64, "name": "霉霉横扫Billboard",
                                    "coverUrl": "http://p4/voice.jpg",
                                    "listenerCount": 1109996,
                                    "dj": {"nickname": "伦敦酒吐座"},
                                    "radio": {"name": "Billboard风云录", "programCount": 15}}}]
        }});
        let ex = parse_search_exact(&body);
        assert_eq!(ex.orders, vec!["artist", "playlist", "voice"]);
        assert!(!ex.is_empty());
        assert_eq!(ex.artists.len(), 1);
        assert_eq!(ex.artists[0].id, 6452);
        assert_eq!(ex.artists[0].name, "周杰伦");
        assert_eq!(ex.artists[0].avatar_url.as_deref(), Some("http://p4/head.jpg"));
        assert_eq!(ex.playlists.len(), 1);
        assert_eq!(ex.playlists[0].id, 8181670003);
        assert_eq!(ex.playlists[0].track_count, 40);
        assert_eq!(ex.playlists[0].cover_url.as_deref(), Some("http://p1/cover.jpg"));
        assert!(!ex.playlists[0].special);
        assert_eq!(ex.podcasts.len(), 1);
        assert_eq!(ex.podcasts[0].id, 2543533915);
        assert_eq!(ex.podcasts[0].name, "霉霉横扫Billboard");
        assert_eq!(ex.podcasts[0].dj_name, "伦敦酒吐座");
        assert_eq!(ex.podcasts[0].program_count, 15);
        assert_eq!(ex.podcasts[0].play_count, 1109996);
    }

    #[test]
    fn search_exact_empty_orders_is_fake_success() {
        // 实测的"空命中伪装成功": code=200 但 result 只有空 orders, 各类型 key 不存在
        let body = json!({"code": 200, "result": {"orders": []}});
        let ex = parse_search_exact(&body);
        assert!(ex.is_empty());
        assert!(
            ex.orders.is_empty()
                && ex.artists.is_empty()
                && ex.playlists.is_empty()
                && ex.podcasts.is_empty()
        );
        // 没有 result(400 之类)也当无命中, 不 panic
        assert!(parse_search_exact(&json!({"code": 400})).is_empty());
        assert!(parse_search_exact(&json!({})).is_empty());
        // orders 有值但对应数组缺失: 保留 orders, 实体为空
        let ex = parse_search_exact(&json!({"code": 200, "result": {"orders": ["song"]}}));
        assert_eq!(ex.orders, vec!["song"]);
        assert!(ex.artists.is_empty());
    }

    #[test]
    fn hot_search_detail_rank_and_fields() {
        let body = json!({"code": 200, "message": null, "trp": null, "data": [
            {"searchWord": "天龙八部之宿敌", "score": 91197, "iconType": 4,
             "iconUrl": "http://p1/icon.png", "content": "", "source": 0, "url": ""},
            {"searchWord": "无 意", "score": 65196, "iconType": 2, "alg": "埋点"},
            {"searchWord": "  ", "score": 1, "iconType": 0},
            {"searchWord": "季候风"}
        ]});
        let items = parse_hot_search_detail(&body);
        assert_eq!(items.len(), 3); // 空白词被丢弃
        assert_eq!(items[0].rank, 1);
        assert_eq!(items[0].keyword, "天龙八部之宿敌");
        assert_eq!(items[0].score, 91197);
        assert_eq!(items[0].icon_type, 4);
        assert_eq!(items[1].keyword, "无 意"); // 中间空格原样保留
        assert_eq!(items[1].rank, 2);
        assert_eq!(items[2].keyword, "季候风");
        assert_eq!(items[2].rank, 3);
        assert_eq!(items[2].score, 0); // 缺字段默认 0
        assert_eq!(items[2].icon_type, 0);
        // 无 data / 空数组
        assert!(parse_hot_search_detail(&json!({"code": 200})).is_empty());
        assert!(parse_hot_search_detail(&json!({"code": 200, "data": []})).is_empty());
    }

    #[test]
    fn user_level_mapping() {
        // 实测响应原样(2026-11-08, 已登录: 9 级, 2301/12000 首, 350/350 天)
        let body = json!({"code": 200, "full": false, "data": {
            "info": "60G音乐网盘免费容量$黑名单上限120$云音乐商城满100减12元优惠券",
            "level": 9,
            "nextLoginCount": 350,
            "nextPlayCount": 12000,
            "nowLoginCount": 350,
            "nowPlayCount": 2301,
            "progress": 0.19175,
            "userId": 1822714196u64
        }});
        let lv = parse_user_level(&body).expect("data 存在应解析成功");
        assert_eq!(lv.level, 9);
        assert_eq!(lv.now_play_count, 2301);
        assert_eq!(lv.next_play_count, 12000);
        assert_eq!(lv.now_login_count, 350);
        assert_eq!(lv.next_login_count, 350);
        // progress 实测 = nowPlayCount / nextPlayCount = 0.19175
        assert!((lv.progress - 0.19175).abs() < 1e-9);
        assert!(lv.privileges.starts_with("60G音乐网盘免费容量$"));
        assert_eq!(lv.privileges.split('$').count(), 3);
    }

    #[test]
    fn user_level_missing_data() {
        // data 缺失 / 不是对象 / 字段缺失: 前者返回 None, 后者全 0 不 panic
        assert!(parse_user_level(&json!({"code": 200})).is_none());
        assert!(parse_user_level(&json!({"code": 200, "data": null})).is_none());
        assert!(parse_user_level(&json!({"code": 200, "data": []})).is_none());
        assert!(parse_user_level(&json!({})).is_none());
        let empty = parse_user_level(&json!({"code": 200, "data": {}})).expect("空对象也要有默认值");
        assert_eq!(empty.level, 0);
        assert_eq!(empty.now_play_count, 0);
        assert_eq!(empty.progress, 0.0);
        assert!(empty.privileges.is_empty());
        // progress 若被服务端换成字符串, 也要能吃
        let lv = parse_user_level(&json!({"code": 200, "data": {"progress": "0.5"}})).unwrap();
        assert!((lv.progress - 0.5).abs() < 1e-9);
    }

    #[test]
    fn user_medals_empty() {
        // 空账号/空分类: 不 panic, medal_num 落 0
        assert_eq!(parse_user_medals(&json!({"code": 200})), MedalWall::default());
        let wall = parse_user_medals(&json!({"code": 200, "data": {
            "medalNum": 0, "categoryMedalBlockVos": []
        }}));
        assert_eq!(wall.medal_num, 0);
        assert!(wall.medals.is_empty());
        // 分类存在但没有 medalVOS / medalVOS 不是数组
        let wall = parse_user_medals(&json!({"code": 200, "data": {
            "medalNum": 3,
            "categoryMedalBlockVos": [{"categoryTitle": "A"}, {"categoryTitle": "B", "medalVOS": "x"}]
        }}));
        assert_eq!(wall.medal_num, 3);
        assert!(wall.medals.is_empty());
    }

    #[test]
    fn user_medals_mapping() {
        // 三项覆盖三种实测形态: 已获得(普通) / 未获得有进度(进程文字) / 乐迷徽章(等级+艺术家)
        let body = json!({"code": 200, "data": {
            "medalNum": 2,
            "obtainMedals": [{"medalCode": "忽略我", "status": "OBTAIN"}],
            "categoryMedalBlockVos": [
                {"categoryCode": "will_obtain", "categoryTitle": "即将获得", "medalVOS": [
                    {"medalCode": "23811503", "medalName": "喵！优秀达人", "status": "WILL_OBTAIN",
                     "acceptCondition": "参与「笔记达人限时挑战」活动",
                     "medalPicUrl": "http://p5.music.126.net/obj/a.png",
                     "wearPic": "http://p5.music.126.net/obj/a_wear.png",
                     "obtainTime": null, "progress": null, "rankText": null,
                     "levelTitle": null, "userObtainProportion": null}
                ]},
                {"categoryCode": "genre_language", "categoryTitle": "成就徽章", "medalVOS": [
                    {"medalCode": "21298503", "medalName": "听歌成就·奏鸣", "status": "NOT_OBTAIN_PROCESS",
                     "acceptCondition": "统计歌曲需满足完整播放", "medalPicUrl": "http://p5/b.png",
                     "wearPic": "", "obtainTime": null, "progress": "当前进度1897/5000",
                     "rankText": null, "levelTitle": null},
                    {"medalCode": "22086503", "medalName": "汪牌认证", "status": "OBTAIN",
                     "acceptCondition": "为歌曲下你喜欢的乐评点个赞吧",
                     "medalPicUrl": "http://p5/c.png", "wearPic": "http://p5/c_wear.png",
                     "obtainTime": 1787144904304u64, "progress": null,
                     "rankText": "前0.033%获得该徽章", "levelTitle": null}
                ]},
                {"categoryTitle": "乐迷徽章", "medalVOS": [
                    {"medalCode": "20170503_1081839", "medalName": "Chinese Football",
                     "status": "OBTAIN", "specialMedalType": "new_fans_level",
                     "acceptCondition": "关注99天", "artistName": "Chinese Football",
                     "medalPicUrl": "https://p5/d.png", "wearPic": "http://p5/d_wear.png",
                     "levelTitle": "Lv.4 乐迷", "levelTitleShort": "Lv.4",
                     "medalLevel": 4, "medalLevelAll": 9,
                     "obtainTime": 1721337006822u64, "rankText": "前2.839%获得该徽章"}
                ]}
            ]
        }});
        let wall = parse_user_medals(&body);
        // 只解析 categoryMedalBlockVos, obtainMedals 不重复计入
        assert_eq!(wall.medals.len(), 4);
        assert_eq!(wall.medal_num, 2); // 接口给的 medalNum

        let will = &wall.medals[0];
        assert_eq!(will.code, "23811503");
        assert_eq!(will.name, "喵！优秀达人");
        assert_eq!(will.status, "WILL_OBTAIN");
        assert!(!will.obtained);
        assert_eq!(will.obtain_time_ms, None);
        assert_eq!(will.pic_url.as_deref(), Some("http://p5.music.126.net/obj/a.png"));
        assert_eq!(will.wear_pic_url.as_deref(), Some("http://p5.music.126.net/obj/a_wear.png"));
        assert!(will.progress_text.is_none() && will.rank_text.is_none() && will.level_title.is_none());

        let busy = &wall.medals[1];
        assert_eq!(busy.code, "21298503");
        assert!(!busy.obtained);
        // progress 是字符串文案, 原样保留不拆数字
        assert_eq!(busy.progress_text.as_deref(), Some("当前进度1897/5000"));
        // 空串 wearPic 归 None
        assert!(busy.wear_pic_url.is_none());

        let got = &wall.medals[2];
        assert!(got.obtained);
        assert_eq!(got.obtain_time_ms, Some(1787144904304));
        assert_eq!(got.rank_text.as_deref(), Some("前0.033%获得该徽章"));

        let fans = &wall.medals[3];
        assert_eq!(fans.code, "20170503_1081839");
        assert_eq!(fans.name, "Chinese Football");
        assert_eq!(fans.level_title.as_deref(), Some("Lv.4 乐迷"));
        assert_eq!(fans.obtain_time_ms, Some(1721337006822));
    }

    #[test]
    fn user_medals_num_fallback_and_skip_bad() {
        // 缺 medalNum 时按 status=OBTAIN 数; 缺 medalCode 的条目跳过
        let body = json!({"code": 200, "data": {"categoryMedalBlockVos": [
            {"medalVOS": [
                {"medalName": "无 code", "status": "OBTAIN"},
                {"medalCode": "", "medalName": "空 code", "status": "OBTAIN"},
                {"medalCode": "A1", "medalName": "x", "status": "OBTAIN", "obtainTime": 1},
                {"medalCode": "A2", "medalName": "y", "status": "NOT_OBTAIN_NO_PROCESS", "obtainTime": 0}
            ]}
        ]}});
        let wall = parse_user_medals(&body);
        assert_eq!(wall.medals.len(), 2);
        assert_eq!(wall.medal_num, 1);
        assert_eq!(wall.medals[0].code, "A1");
        assert_eq!(wall.medals[0].name, "x"); // 缺 acceptCondition → 空串
        assert_eq!(wall.medals[0].condition, "");
        // obtainTime = 0 视为未获得(null), 不能当 1970 年
        assert_eq!(wall.medals[1].obtain_time_ms, None);
    }
}
