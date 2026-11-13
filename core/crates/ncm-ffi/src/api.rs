//! 暴露给 Dart 的 API. 规则:
//! - 只传可序列化 DTO, 不传引用/闭包
//! - 错误统一成 String(带 kind 前缀), UI 按前缀决定文案
//! - 全局单例 Core, 由 init() 建立

use std::path::Path;
use std::sync::{Mutex, OnceLock};

use flutter_rust_bridge::frb;

pub use ncm_domain::{
    AlbumBrief, AlbumItem, Artist, ChartSummary, Comment, CommentPage, CommentStats, DefaultSearch,
    DigitalAlbumDetail, DigitalAlbumPurchased, DigitalAlbumPurchasedEntry, DigitalAlbumSalesEntry,
    FollowCount, ForwardItem, HotArtist, HotSearchDetailItem, HotSearchTerm, InboxItem,
    PhoneLoginResult, Playlist, PlaylistCategory, PlaylistDetail, PodcastRadio, PrivateMessage,
    PrivateSession, ProfileDetail, PurchasedSongEntry, QrLoginCheck, QrLoginKey, QrLoginState,
    RadioCategory, RadioExploreHome, RadioPick, RadioRankedDj, RadioRankedRadio, RadioSubscriber,
    RadioSubscriberPage, RecentContact, SearchAlbum, SearchArtist, SearchExact, SearchPlaylistItem,
    SearchPodcast, SigninDay, SigninStatus, SmsCodeSent, SongPurchasedPage, StreamUrl, StyleTag,
    SuggestItem, ToplistCatalogGroup, ToplistCatalogItem, UserItem, UserLevel, UserMedal,
    VipGrowth, VipMembership, VipOverview, VipSign, VipSignDay, VipTask, WikiFact,
};
use ncm_provider::{Capability, RankingPeriod, SearchQuery};
use ncm_service::Core;

static CORE: OnceLock<Mutex<Core>> = OnceLock::new();

fn core() -> Result<&'static Mutex<Core>, String> {
    CORE.get().ok_or_else(|| "core not initialized".to_string())
}

/// D5: 纯 provider 转发型 FFI 封装统一 helper。
/// - ffi_forward!(Capability::X, provider.method(args))             返回值直接透传
/// - ffi_forward!(Capability::X, provider.method(args), map conv)     末步转 Dto(conv 为普通 fn/闭包)
/// - ffi_forward!(Capability::X, provider.method(args), map_each conv) Vec 转 Vec<Dto>
///   错误映射统一 |e| e.to_string(), 与手写导出一致; frb 只看函数签名, 宏只生成函数体。
macro_rules! ffi_forward {
    ($cap:expr, $p:ident . $m:ident ( $($arg:expr),* ), map $conv:expr) => {{
        let $p = with_provider($cap)?;
        let v = $p.$m($($arg),*).await.map_err(|e| e.to_string())?;
        Ok(($conv)(v))
    }};
    ($cap:expr, $p:ident . $m:ident ( $($arg:expr),* ), map_each $conv:expr) => {{
        let $p = with_provider($cap)?;
        let list = $p.$m($($arg),*).await.map_err(|e| e.to_string())?;
        Ok(list.into_iter().map($conv).collect())
    }};
    ($cap:expr, $p:ident . $m:ident ( $($arg:expr),* )) => {{
        let $p = with_provider($cap)?;
        let v = $p.$m($($arg),*).await.map_err(|e| e.to_string())?;
        Ok(v)
    }};
}

fn data_dir_default() -> String {
    std::env::var("NCM_DATA_DIR").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
        format!("{home}/.local/share/ncm")
    })
}

/// 初始化: 建立/加载身份, 注册 provider. 幂等.
pub fn init(data_dir: Option<String>) -> Result<InitInfo, String> {
    let dir = data_dir.unwrap_or_else(data_dir_default);
    let _ = DATA_DIR.set(std::path::PathBuf::from(&dir));
    if CORE.get().is_none() {
        let core = Core::open(Path::new(&dir)).map_err(|e| e.to_string())?;
        let _ = CORE.set(Mutex::new(core));
    }
    let guard = core()?.lock().map_err(|e| e.to_string())?;
    Ok(InitInfo {
        data_dir: dir,
        device_id: guard.session.device_id.clone(),
        logged_in: guard.session.is_logged_in(),
        vip: guard
            .session
            .profile
            .as_ref()
            .map(|p| p.vip)
            .unwrap_or(false),
        providers: guard
            .providers
            .all()
            .iter()
            .map(|p| ProviderInfo {
                id: p.id().to_string(),
                name: p.name().to_string(),
                capabilities: p
                    .capabilities()
                    .iter()
                    .map(|c| c.as_str().to_string())
                    .collect(),
            })
            .collect(),
    })
}

pub struct InitInfo {
    pub data_dir: String,
    pub device_id: String,
    pub logged_in: bool,
    /// 当前账号是否会员(黑胶/音乐包)
    pub vip: bool,
    pub providers: Vec<ProviderInfo>,
}

pub struct ProviderInfo {
    pub id: String,
    pub name: String,
    pub capabilities: Vec<String>,
}

pub struct SongDto {
    pub id: u64,
    pub name: String,
    pub artist: String,
    /// 第一歌手的 id(0 = 未知). 用于"歌手信息"
    pub artist_id: u64,
    pub album: String,
    /// 专辑 id(0 = 未知). 用于点封面看专辑详情
    pub album_id: u64,
    /// 专辑封面直链
    pub cover_url: Option<String>,
    pub duration_ms: u64,
    pub fee: i64,
    /// VIP 专属(高音质需会员)
    pub vip: bool,
    /// 需单独购买的数字专辑
    pub paid: bool,
    /// 有版权、可播(false = 官方灰显那种"暂无版权")
    pub playable: bool,
}

fn song_dto(s: ncm_domain::Song) -> SongDto {
    let artist = s.artist_line();
    let vip = s.is_vip();
    let paid = s.is_paid();
    let playable = s.playable;
    let album_id = s.album_id();
    let cover_url = s.cover_url();
    let artist_id = s.artists.first().map(|a| a.id).unwrap_or(0);
    SongDto {
        id: s.id.0,
        name: s.name,
        artist,
        artist_id,
        album: s.album.map(|a| a.name).unwrap_or_default(),
        album_id,
        cover_url,
        duration_ms: s.duration_ms,
        fee: s.fee.unwrap_or(0),
        vip,
        paid,
        playable,
    }
}

/// SongDto -> domain Song(本地播放历史用: 只保留展示必需字段).
fn song_from_dto(d: &SongDto) -> ncm_domain::Song {
    ncm_domain::Song {
        id: ncm_domain::TrackId::new(d.id),
        name: d.name.clone(),
        artists: if d.artist.is_empty() {
            vec![]
        } else {
            vec![ncm_domain::Artist {
                id: d.artist_id,
                name: d.artist.clone(),
                avatar_url: None,
            }]
        },
        album: Some(ncm_domain::Album {
            id: d.album_id,
            name: d.album.clone(),
            pic_url: d.cover_url.clone(),
        }),
        duration_ms: d.duration_ms,
        fee: Some(d.fee),
        playable: d.playable,
    }
}

#[frb(mirror(StreamUrl))]
pub struct _StreamUrl {
    pub url: Option<String>,
    pub quality: String,
    pub br: Option<u64>,
    pub size: Option<u64>,
    pub expire_at: Option<u64>,
}

// ---------------- 综合搜索(分板块) ----------------

#[frb(mirror(SearchArtist))]
pub struct _SearchArtist {
    pub id: u64,
    pub name: String,
    pub avatar_url: Option<String>,
    /// 别名, 已用 " / " 拼好
    pub alias: String,
    pub album_count: u64,
    pub music_count: u64,
}

#[frb(mirror(SearchAlbum))]
pub struct _SearchAlbum {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub artist: String,
    pub track_count: u64,
}

#[frb(mirror(SearchPlaylistItem))]
pub struct _SearchPlaylistItem {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub creator_name: String,
    pub track_count: u64,
    pub play_count: u64,
}

#[frb(mirror(SearchPodcast))]
pub struct _SearchPodcast {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub dj_name: String,
    pub program_count: u64,
    pub play_count: u64,
}

/// 综合搜索结果: 单曲/歌手/专辑/歌单/播客 各一个板块
pub struct SearchBundleDto {
    pub songs: Vec<SongDto>,
    pub song_total: u64,
    pub artists: Vec<SearchArtist>,
    pub albums: Vec<SearchAlbum>,
    pub playlists: Vec<SearchPlaylistItem>,
    pub podcasts: Vec<SearchPodcast>,
    /// 用户(type=1002)
    pub users: Vec<UserItem>,
}

/// 综合搜索: 一次拿回所有板块(UI 分区展示).
pub async fn search_all(keywords: String, limit: u32) -> Result<SearchBundleDto, String> {
    let provider = with_provider(Capability::SearchAll)?;
    let query = SearchQuery {
        keywords,
        limit,
        offset: 0,
    };
    let bundle = provider
        .search_all(&query)
        .await
        .map_err(|e| e.to_string())?;
    Ok(SearchBundleDto {
        songs: bundle.songs.into_iter().map(song_dto).collect(),
        song_total: bundle.song_total,
        artists: bundle.artists,
        albums: bundle.albums,
        playlists: bundle.playlists,
        users: bundle.users,
        podcasts: bundle.podcasts,
    })
}

// ---------------- 歌手详情 ----------------

#[frb(mirror(AlbumBrief))]
pub struct _AlbumBrief {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub track_count: u64,
    pub publish_time: u64,
}

pub struct ArtistDetailDto {
    pub id: u64,
    pub name: String,
    pub avatar_url: Option<String>,
    pub cover_url: Option<String>,
    pub alias: Vec<String>,
    pub brief_desc: String,
    pub album_count: u64,
    pub music_count: u64,
    pub songs: Vec<SongDto>,
    pub albums: Vec<AlbumBrief>,
}

/// 歌手详情(头像/简介/热门歌曲/专辑)
pub async fn artist_detail(artist_id: u64) -> Result<ArtistDetailDto, String> {
    let provider = with_provider(Capability::Artist)?;
    let a = provider
        .artist_detail(artist_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(ArtistDetailDto {
        id: a.id,
        name: a.name,
        avatar_url: a.avatar_url,
        cover_url: a.cover_url,
        alias: a.alias,
        brief_desc: a.brief_desc,
        album_count: a.album_count,
        music_count: a.music_count,
        songs: a.songs.into_iter().map(song_dto).collect(),
        albums: a.albums,
    })
}

// ---------------- 歌手全部歌曲 / MV ----------------

pub struct ArtistSongPageDto {
    pub songs: Vec<SongDto>,
    pub has_more: bool,
}

pub struct ArtistMvDto {
    pub id: u64,
    pub name: String,
    pub duration_ms: u64,
    pub play_count: u64,
    pub publish_time: String,
    pub cover_url: Option<String>,
}

pub struct MvDetailDto {
    pub id: u64,
    pub name: String,
    pub artist_name: String,
    pub duration_ms: u64,
    pub play_count: u64,
    pub publish_time: String,
    pub cover_url: Option<String>,
    pub max_br: u32,
    pub brs: Vec<u32>,
    pub desc: Option<String>,
}

pub struct MvUrlDto {
    pub url: Option<String>,
    pub r: u32,
    pub size: u64,
}

pub struct ArtistMvPageDto {
    pub mvs: Vec<ArtistMvDto>,
    pub has_more: bool,
}

/// 歌手全部歌曲一页(artist_songs, offset/limit 分页)
pub async fn artist_songs_page(
    artist_id: u64,
    offset: u32,
    limit: u32,
) -> Result<ArtistSongPageDto, String> {
    let provider = with_provider(Capability::Artist)?;
    let page = provider
        .artist_songs_page(artist_id, offset, limit)
        .await
        .map_err(|e| e.to_string())?;
    Ok(ArtistSongPageDto {
        songs: page.songs.into_iter().map(song_dto).collect(),
        has_more: page.has_more,
    })
}

pub struct ArtistAlbumPageDto {
    pub albums: Vec<AlbumBrief>,
    pub has_more: bool,
}

/// 歌手专辑一页(artist_album, offset/limit 分页). 头部 albumSize 是真实总数,
/// 详情只带前 20 张, 专辑 tab 用这个接口翻完.
pub async fn artist_albums_page(
    artist_id: u64,
    offset: u32,
    limit: u32,
) -> Result<ArtistAlbumPageDto, String> {
    let provider = with_provider(Capability::Artist)?;
    let page = provider
        .artist_albums_page(artist_id, offset, limit)
        .await
        .map_err(|e| e.to_string())?;
    Ok(ArtistAlbumPageDto {
        albums: page.albums,
        has_more: page.has_more,
    })
}

/// 歌手 MV 一页(artist_mv, offset/limit 分页)
pub async fn artist_mvs_page(
    artist_id: u64,
    offset: u32,
    limit: u32,
) -> Result<ArtistMvPageDto, String> {
    let provider = with_provider(Capability::Artist)?;
    let page = provider
        .artist_mvs_page(artist_id, offset, limit)
        .await
        .map_err(|e| e.to_string())?;
    Ok(ArtistMvPageDto {
        mvs: page
            .mvs
            .into_iter()
            .map(|m| ArtistMvDto {
                id: m.id,
                name: m.name,
                duration_ms: m.duration_ms,
                play_count: m.play_count,
                publish_time: m.publish_time,
                cover_url: m.cover_url,
            })
            .collect(),
        has_more: page.has_more,
    })
}

/// MV 详情(mv_detail)
pub async fn mv_detail(mv_id: u64) -> Result<MvDetailDto, String> {
    let provider = with_provider(Capability::Artist)?;
    let d = provider.mv_detail(mv_id).await.map_err(|e| e.to_string())?;
    Ok(MvDetailDto {
        id: d.id,
        name: d.name,
        artist_name: d.artist_name,
        duration_ms: d.duration_ms,
        play_count: d.play_count,
        publish_time: d.publish_time,
        cover_url: d.cover_url,
        max_br: d.max_br,
        brs: d.brs,
        desc: d.desc,
    })
}

/// MV 播放链接(mv_url, r=清晰度档位, 0 表示请求最高)
pub async fn mv_url(mv_id: u64, r: u32) -> Result<MvUrlDto, String> {
    let provider = with_provider(Capability::Artist)?;
    let u = provider.mv_url(mv_id, r).await.map_err(|e| e.to_string())?;
    Ok(MvUrlDto {
        url: u.url,
        r: u.r,
        size: u.size,
    })
}

/// 关注/取消关注歌手(需要登录). 返回 true 表示接口接受.
pub async fn artist_sub_toggle(artist_id: u64, sub: bool) -> Result<bool, String> {
    let provider = with_provider(Capability::Artist)?;
    provider
        .toggle_artist_sub(artist_id, sub)
        .await
        .map_err(|e| e.to_string())
}

// ---------------- 个人主页资料 ----------------

/// 个人主页资料: 直接镜像 domain 类型 `ProfileDetail`.
#[frb(mirror(ProfileDetail))]
pub struct _ProfileDetail {
    pub user_id: u64,
    pub nickname: String,
    pub avatar_url: Option<String>,
    pub background_url: Option<String>,
    pub signature: String,
    pub vip: bool,
    pub follows: u64,
    pub followeds: u64,
    pub level: u64,
}

/// 个人主页资料(背景图/头像/签名/关注数). 需要登录.
pub async fn profile_detail() -> Result<ProfileDetail, String> {
    ffi_forward!(Capability::ProfileDetail, provider.profile_detail())
}

/// 任意用户的公开资料(他人主页; 不需要登录). 与 profile_detail 的区别: 那个只读当前账号.
pub async fn user_profile(user_id: u64) -> Result<ProfileDetail, String> {
    ffi_forward!(Capability::ProfileDetail, provider.user_profile(user_id))
}

/// 任意用户的公开歌单(他人主页; 不需要登录).
/// 口径: 未登录时服务端只回公开歌单, 不含对方的"我喜欢的音乐".
pub async fn user_playlists_of(user_id: u64, limit: u32) -> Result<Vec<Playlist>, String> {
    ffi_forward!(
        Capability::Playlist,
        provider.user_playlists_of(user_id, limit)
    )
}

/// 收藏曲目到指定歌单(需登录)
pub async fn add_to_playlist(playlist_id: u64, track_id: u64) -> Result<bool, String> {
    let provider = with_provider(Capability::PlaylistEdit)?;
    provider
        .add_to_playlist(playlist_id, ncm_domain::TrackId::new(track_id))
        .await
        .map_err(|e| e.to_string())
}

pub async fn song_url(track_id: u64, level: String) -> Result<StreamUrl, String> {
    let provider = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard
            .providers
            .first_with(Capability::SongUrl)
            .ok_or_else(|| "no provider supports songUrl".to_string())?
    };
    let level = ncm_provider::AudioLevel::parse(&level).unwrap_or_default();
    let req = ncm_provider::SongUrlRequest {
        track: ncm_domain::TrackId::new(track_id),
        level,
    };
    let stream = provider.song_url(&req).await.map_err(|e| e.to_string())?;
    Ok(stream)
}

pub async fn lyric(track_id: u64) -> Result<String, String> {
    let provider = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard
            .providers
            .first_with(Capability::Lyric)
            .ok_or_else(|| "no provider supports lyric".to_string())?
    };
    let lyric = provider
        .lyric(ncm_domain::TrackId::new(track_id))
        .await
        .map_err(|e| e.to_string())?;
    Ok(lyric.lrc.unwrap_or_default())
}

/// 退出登录: 只清登录凭据, 设备指纹(deviceId/_ntes_*/WNMCID/NMTID)保留.
/// 账号本身留在账号簿里, 下次可以一键切回(不用重新扫码).
/// 返回 true 表示现在已经不是登录态.
pub fn logout() -> Result<bool, String> {
    let mut guard = core()?.lock().map_err(|e| e.to_string())?;
    guard.logout().map_err(|e| e.to_string())?;
    Ok(!guard.session.is_logged_in())
}

// ---------------- 多账号(账号簿) ----------------

pub struct AccountDto {
    pub user_id: u64,
    pub nickname: String,
    pub avatar_url: Option<String>,
    pub active: bool,
    pub vip: bool,
}

/// 扫码登录: 二维码会话(Dart 侧渲染 QR + 轮询)
#[frb(mirror(QrLoginKey))]
pub struct _QrLoginKey {
    pub key: String,
    /// 二维码内容(App 直接扫)
    pub url: String,
    /// 有效期(秒)
    pub expires_in: u64,
}

/// 扫码登录状态(801 待扫 / 802 已扫 / 803 成功 / 800 过期)
#[frb(mirror(QrLoginState))]
pub enum _QrLoginState {
    Pending,
    Scanned,
    Confirmed,
    Expired,
    Failed,
}

/// 扫码登录: 一次轮询的结果(Confirmed 时凭据已由 Rust 落盘, UI 只看 loggedIn).
///
/// 注意: **凭据不进 Dart** —— cookie 在 ncm-provider 的 QrLoginOutcome 里,
/// 由本模块落盘后丢弃, 只回元数据。
#[frb(mirror(QrLoginCheck))]
pub struct _QrLoginCheck {
    pub state: QrLoginState,
    /// 官方原始 code(801/802/803/800), 排障用
    pub code: i64,
    /// Confirmed 且凭据已落盘
    pub logged_in: bool,
    pub nickname: String,
    pub avatar_url: Option<String>,
}

#[frb(mirror(SmsCodeSent))]
pub struct _SmsCodeSent {
    /// 服务端原始 code(200 已发送 / 8821 风控 / 400 号码不合法 / 503 频率限制)
    pub code: i64,
    pub message: String,
    /// 声明有效期(秒)
    pub expires_in: u32,
}

/// 手机号+验证码登录成功后的结果(凭据已落盘, 不回传 Dart)
#[frb(mirror(PhoneLoginResult))]
pub struct _PhoneLoginResult {
    /// 校验通过且凭据已落盘
    pub logged_in: bool,
    pub nickname: String,
    pub avatar_url: Option<String>,
}

/// 凭据后端状态(设置页展示用). 不含任何凭据内容.
pub struct CredentialStatusDto {
    /// secure / plaintext_consented / plaintext_fallback
    pub kind: String,
    /// dpapi / file / none
    pub backend: String,
    /// 旧明文是否已迁移进后端
    pub migrated: bool,
    /// 面向用户的说明文案
    pub note: String,
}

fn accounts_of(guard: &Core) -> Result<Vec<AccountDto>, String> {
    let book = guard.accounts().map_err(|e| e.to_string())?;
    Ok(book
        .accounts
        .into_iter()
        .map(|a| AccountDto {
            user_id: a.user_id,
            nickname: a.nickname,
            avatar_url: a.avatar_url,
            active: book.active == Some(a.user_id),
            vip: a.vip,
        })
        .collect())
}

/// 扫码登录 ①(桌面端官方网页登录通道): 申请二维码.
///
/// 桌面端没有 WebView, 也就无法读浏览器里 HttpOnly 的 MUSIC_U; 官方扫码通道把凭据
/// 放在轮询响应的 Set-Cookie 里, 因此 Linux/Windows 共用这一条实现, 不需要平台代码.
pub async fn login_qr_create() -> Result<QrLoginKey, String> {
    let provider = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard.netease.clone()
    };
    use ncm_provider::Provider;
    provider.login_qr_create().await.map_err(|e| e.to_string())
}

/// 扫码登录 ②: 轮询一次. Confirmed(803) 时顺带把凭据合并落盘, Dart 侧再同步账号资料.
pub async fn login_qr_check(key: String) -> Result<QrLoginCheck, String> {
    let provider = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard.netease.clone()
    };
    use ncm_provider::Provider;
    let outcome = provider
        .login_qr_check(&key)
        .await
        .map_err(|e| e.to_string())?;
    if let Some(cookie) = outcome.cookie.as_deref() {
        let mut guard = core()?.lock().map_err(|e| e.to_string())?;
        guard
            .apply_login_cookie(cookie)
            .map_err(|e| e.to_string())?;
    }
    // 凭据到此为止: 只把元数据交给 Dart
    Ok(outcome.check)
}

fn credential_status_dto(
    status: ncm_service::credential_store::CredentialStatus,
) -> CredentialStatusDto {
    use ncm_service::credential_store::CredentialStatus as S;
    let kind = match &status {
        S::Secure { .. } => "secure",
        S::PlaintextConsented { .. } => "plaintext_consented",
        S::PlaintextFallback { .. } => "plaintext_fallback",
    };
    CredentialStatusDto {
        kind: kind.to_string(),
        backend: status.backend_name().to_string(),
        migrated: status.migrated(),
        note: status.note(),
    }
}

/// 当前凭据后端状态(设置页/排障用): 是否有安全后端、旧明文是否已迁移.
pub fn credential_status() -> Result<CredentialStatusDto, String> {
    let guard = core()?.lock().map_err(|e| e.to_string())?;
    Ok(credential_status_dto(guard.credential_status()))
}

/// 用户明确同意/撤销"0600 明文回退". 同意后立刻重建后端并补跑迁移.
///
/// 只在没有系统钥匙串的平台(Android/Linux 的 P1/P2 未落地前)才有意义;
/// Windows 走 DPAPI, 不需要这个开关。
pub fn consent_plaintext_storage(consent: bool) -> Result<CredentialStatusDto, String> {
    let mut guard = core()?.lock().map_err(|e| e.to_string())?;
    guard
        .set_plaintext_consent(consent)
        .map_err(|e| e.to_string())?;
    Ok(credential_status_dto(guard.credential_status()))
}

/// Android Keystore 桥(lane p1, 方案 B): Keystore 里的一条凭据.
/// key 为 CredentialKey::id() 形式("session" / "account:uid").
#[derive(Debug, Clone)]
pub struct CredentialEntryDto {
    pub key: String,
    pub value: String,
}

/// 一条待 Dart 落 Keystore 的操作: op = "put"(带 value) | "remove".
#[derive(Debug, Clone)]
pub struct CredentialOpDto {
    pub op: String,
    pub key: String,
    pub value: String,
}

/// Android 启动时、rust.init 之前调用: 用 Keystore 现存条目激活凭据桥.
/// 幂等(重复调用合并); 未激活时 open_backend 的 android 分支走既有同意门.
/// 见 docs/android-keystore-wiring-design.md.
pub fn credential_restore(entries: Vec<CredentialEntryDto>) -> Result<(), String> {
    let converted: Vec<(String, String)> = entries.into_iter().map(|e| (e.key, e.value)).collect();
    ncm_service::credential_channel::activate(converted);
    Ok(())
}

/// Dart drain: 拉走(并清空)待落 Keystore 的操作. 同 key 只剩最终态.
/// 拉取失败 = 丢该条凭据(下次启动重登), 不影响本会话内存态.
pub fn credential_pending_writes() -> Result<Vec<CredentialOpDto>, String> {
    use ncm_service::credential_channel::CredOp;
    Ok(ncm_service::credential_channel::take_pending()
        .into_iter()
        .map(|op| match op {
            CredOp::Put { key, value } => CredentialOpDto {
                op: "put".into(),
                key,
                value,
            },
            CredOp::Remove { key } => CredentialOpDto {
                op: "remove".into(),
                key,
                value: String::new(),
            },
        })
        .collect())
}

/// 手机号+验证码登录 ①(网页登录通道 weapi): 发短信验证码.
///
/// 与扫码同一族(网页登录), 不走 App 原生登录族; 命中交互式风控时错误带
/// `[riskControl]` 前缀(官方 code 8821), UI 应引导改用扫码.
pub async fn login_sms_send(phone: String, country_code: String) -> Result<SmsCodeSent, String> {
    let provider = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard.netease.clone()
    };
    use ncm_provider::Provider;
    provider
        .login_sms_send(&phone, &country_code)
        .await
        .map_err(|e| e.to_string())
}

/// 手机号+验证码登录 ②: 校验验证码. 成功时顺带把凭据合并落盘, Dart 侧再同步账号资料.
pub async fn login_sms_verify(
    phone: String,
    code: String,
    country_code: String,
) -> Result<PhoneLoginResult, String> {
    let provider = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard.netease.clone()
    };
    use ncm_provider::Provider;
    let outcome = provider
        .login_sms_verify(&phone, &code, &country_code)
        .await
        .map_err(|e| e.to_string())?;
    let mut guard = core()?.lock().map_err(|e| e.to_string())?;
    guard
        .apply_login_cookie(&outcome.cookie)
        .map_err(|e| e.to_string())?;
    Ok(outcome.result)
}

/// 已记住的账号列表(只含凭据, 指纹共享)
pub fn accounts() -> Result<Vec<AccountDto>, String> {
    let guard = core()?.lock().map_err(|e| e.to_string())?;
    accounts_of(&guard)
}

/// 登录后/启动时调用: 拉一次账号资料并记进账号簿.
/// 失败(离线/风控)不影响已登录状态, UI 只当作"没有昵称"。
pub async fn account_sync_active() -> Result<AccountDto, String> {
    let (logged_in, provider) = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        if !guard.session.is_logged_in() {
            return Err("未登录".to_string());
        }
        let provider = guard
            .providers
            .first_with(Capability::Profile)
            .ok_or_else(|| "no provider supports profile".to_string())?;
        (true, provider)
    };
    debug_assert!(logged_in);
    let profile = provider.profile().await.map_err(|e| e.to_string())?;
    let mut guard = core()?.lock().map_err(|e| e.to_string())?;
    guard
        .remember_account(&profile)
        .map_err(|e| e.to_string())?;
    Ok(AccountDto {
        user_id: profile.user_id,
        nickname: profile.nickname,
        avatar_url: profile.avatar_url,
        active: true,
        vip: profile.vip,
    })
}

/// 切换到账号簿里的某个账号(不重新登录)
pub async fn account_switch(user_id: u64) -> Result<bool, String> {
    {
        let mut guard = core()?.lock().map_err(|e| e.to_string())?;
        if !guard.switch_account(user_id).map_err(|e| e.to_string())? {
            return Ok(false);
        }
    }
    // 切完顺手同步一次昵称/头像(失败不影响切换)
    let _ = account_sync_active().await;
    Ok(true)
}

/// 从账号簿移除某个账号(不影响当前登录态, 只是忘掉它的凭据)
pub fn account_remove(user_id: u64) -> Result<bool, String> {
    let mut guard = core()?.lock().map_err(|e| e.to_string())?;
    let before = guard.accounts().map_err(|e| e.to_string())?.accounts.len();
    let book = guard.forget_account(user_id).map_err(|e| e.to_string())?;
    Ok(book.accounts.len() < before)
}

// ---------------- 收藏(红心)与歌单 ----------------

/// 歌单(列表项): 直接镜像 domain 类型 `Playlist`.
#[frb(mirror(Playlist))]
pub struct _Playlist {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub track_count: u64,
    /// 是否"我喜欢的音乐"
    pub special: bool,
    /// 是否"我收藏的"(true = 收藏, false = 创建)
    pub subscribed: bool,
}

fn with_provider(cap: Capability) -> Result<std::sync::Arc<dyn ncm_provider::Provider>, String> {
    let guard = core()?.lock().map_err(|e| e.to_string())?;
    guard
        .providers
        .first_with(cap)
        .ok_or_else(|| format!("no provider supports {}", cap.as_str()))
}

/// "我喜欢的音乐"里的曲目 id(红心状态的唯一真相)
pub async fn liked_ids() -> Result<Vec<u64>, String> {
    let provider = with_provider(Capability::Playlist)?;
    let ids = provider.liked_ids().await.map_err(|e| e.to_string())?;
    Ok(ids.into_iter().map(|t| t.0).collect())
}

/// 红心/取消红心(需登录)
pub async fn set_liked(track_id: u64, liked: bool) -> Result<bool, String> {
    ffi_forward!(
        Capability::Playlist,
        provider.set_like(ncm_domain::TrackId::new(track_id), liked)
    )
}

/// 我的歌单(含"我喜欢的音乐")
pub async fn my_playlists() -> Result<Vec<Playlist>, String> {
    ffi_forward!(Capability::Playlist, provider.user_playlists())
}

/// 某个歌单的曲目
pub async fn playlist_songs(playlist_id: u64) -> Result<Vec<SongDto>, String> {
    let provider = with_provider(Capability::Playlist)?;
    let songs = provider
        .playlist_songs(playlist_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(songs.into_iter().map(song_dto).collect())
}

/// "我喜欢的音乐"曲目详情(按收藏时间从新到旧)
pub async fn liked_songs() -> Result<Vec<SongDto>, String> {
    let provider = with_provider(Capability::Playlist)?;
    // 优先用歌单详情的 addTime(真实收藏时间)排序; 老 provider 回落到 likelist 顺序
    match provider.liked_songs_ordered().await {
        Ok(songs) if !songs.is_empty() => return Ok(songs.into_iter().map(song_dto).collect()),
        Ok(_) => {}
        Err(_) => {}
    }
    let ids = provider.liked_ids().await.map_err(|e| e.to_string())?;
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    // 先把 id 拼成一次详情请求(vendor 的 song_detail 只认逗号分隔), 分块避免 URL 过长
    // 详情接口不保证按请求顺序返回(还可能缺曲), 用 id→Song 映射按 likelist 顺序还原
    let mut by_id: std::collections::HashMap<u64, ncm_domain::Song> =
        std::collections::HashMap::new();
    for chunk in ids.chunks(500) {
        let joined = chunk
            .iter()
            .map(|t| t.0.to_string())
            .collect::<Vec<_>>()
            .join(",");
        let detail = provider
            .songs_detail(&joined)
            .await
            .map_err(|e| e.to_string())?;
        for s in detail {
            by_id.insert(s.id.0, s);
        }
    }
    Ok(ids
        .iter()
        .filter_map(|t| by_id.remove(&t.0))
        .map(song_dto)
        .collect())
}

/// 一行歌词(已按时间排序, 翻译按时间戳对齐)
pub struct LyricLineDto {
    pub time_ms: u64,
    pub text: String,
    pub sub: Option<String>,
}

/// 带翻译的歌词时间轴(网易云 tlyric). UI 只需要按 position 找当前行, 不再自己啃 LRC.
pub async fn lyric_lines_i18n(track_id: u64) -> Result<Vec<LyricLineDto>, String> {
    let provider = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard
            .providers
            .first_with(Capability::Lyric)
            .ok_or_else(|| "no provider supports lyric".to_string())?
    };
    let lyric = provider
        .lyric(ncm_domain::TrackId::new(track_id))
        .await
        .map_err(|e| e.to_string())?;
    Ok(ncm_domain::parse_lrc_with_translation(
        lyric.lrc.as_deref().unwrap_or_default(),
        lyric.translated.as_deref(),
    )
    .into_iter()
    .map(|l| LyricLineDto {
        time_ms: l.time_ms,
        text: l.text,
        sub: l.sub,
    })
    .collect())
}

/// 一个词(字)的逐字时间与文本
pub struct WordItemDto {
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
}

/// 一行逐字歌词; words 为空或单词 = 无词级时间(退化行)
pub struct WordLyricLineDto {
    pub start_ms: i64,
    pub end_ms: i64,
    pub words: Vec<WordItemDto>,
}

/// 逐字歌词(YRC). 无逐字数据时 lines 为空, UI 应回落 lyric_lines_i18n.
pub async fn word_lyric_lines(track_id: u64) -> Result<WordLyricDto, String> {
    let provider = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard
            .providers
            .first_with(Capability::Lyric)
            .ok_or_else(|| "no provider supports lyric".to_string())?
    };
    let wl = provider
        .word_lyric(ncm_domain::TrackId::new(track_id))
        .await
        .map_err(|e| e.to_string())?;
    Ok(WordLyricDto {
        lines: wl
            .lines
            .iter()
            .zip(wl.translation_lines.iter())
            .map(|(l, _t)| WordLyricLineDto {
                start_ms: l.start_ms,
                end_ms: l.end_ms,
                words: l
                    .words
                    .iter()
                    .map(|w| WordItemDto {
                        start_ms: w.start_ms,
                        end_ms: w.end_ms,
                        text: w.text.clone(),
                    })
                    .collect(),
            })
            .collect(),
        translation_lines: wl.translation_lines,
        has_word_timing: wl.has_word_timing,
    })
}

/// 逐字歌词整体 DTO(frb 不直接吃 domain 类型)
pub struct WordLyricDto {
    pub lines: Vec<WordLyricLineDto>,
    pub translation_lines: Vec<Option<String>>,
    pub has_word_timing: bool,
}

/// WordLyric -> DTO(聚合导出与 TTML 单独导出共用).
fn word_lyric_dto(wl: ncm_domain::WordLyric) -> WordLyricDto {
    WordLyricDto {
        lines: wl
            .lines
            .iter()
            .zip(wl.translation_lines.iter())
            .map(|(l, _t)| WordLyricLineDto {
                start_ms: l.start_ms,
                end_ms: l.end_ms,
                words: l
                    .words
                    .iter()
                    .map(|w| WordItemDto {
                        start_ms: w.start_ms,
                        end_ms: w.end_ms,
                        text: w.text.clone(),
                    })
                    .collect(),
            })
            .collect(),
        translation_lines: wl.translation_lines,
        has_word_timing: wl.has_word_timing,
    }
}

/// B13: 只取 TTML 第二来源(带磁盘缓存: `dataDir/ttml/<id>.ttml` / `<id>.none`).
/// 无数据/解析失败返回 Ok(None), 网络错误返回 Err —— 调用方(或 Dart 侧)静默回退.
pub async fn ttml_lyric_lines(track_id: u64) -> Result<Option<WordLyricDto>, String> {
    let dir = DATA_DIR
        .get()
        .ok_or_else(|| "core not initialized".to_string())?
        .clone();
    match ncm_service::ttml_source::fetch_ttml(&dir, track_id).await {
        Ok(Some(doc)) => Ok(Some(word_lyric_dto(
            ncm_service::ttml_source::ttml_to_word_lyric(&doc),
        ))),
        Ok(None) => Ok(None),
        Err(e) => Err(e),
    }
}

// 说明(2026-11 去重): 这里原本还有一个 `word_lyric_with_fallback` 导出, 与
// Dart 侧 main.dart 的 `resolveLyricSource` 是同一套"yrc → TTML → 行级"择优
// 策略的两份实现 —— 而 UI 实际走的是 Dart 那份(可注入 loader, 有单测覆盖),
// 这个导出从来没有人调用。已删除, 只保留原子能力:
//   word_lyric_lines / ttml_lyric_lines / lyric_lines_i18n(UI 自己组合)。
// Rust 侧 ncm_service::ttml_source::word_lyric_with_fallback 保留并由其单测覆盖,
// 供 CLI / 未来宿主使用; 若要恢复 UI 走它, 只需把 Dart 的 loaders 换成一次调用。

/// 导入登录 cookie(手机端/浏览器导出), 与设备指纹合并后持久化.
pub fn login_with_cookie(cookie: String) -> Result<bool, String> {
    let mut guard = core()?.lock().map_err(|e| e.to_string())?;
    let merged = ncm_service::identity::merge_device_cookie(
        &guard.session.cookie,
        &cookie,
        &guard.session.device_id,
    );
    let mut next = guard.session.clone();
    next.cookie = merged;
    guard.apply_session(next).map_err(|e| e.to_string())?;
    Ok(guard.session.is_logged_in())
}

pub fn ping(name: String) -> String {
    format!("pong from rust: {name}")
}

// ---------------- 播放 ----------------

static PLAYER: OnceLock<ncm_playback::Player> = OnceLock::new();
static DATA_DIR: OnceLock<std::path::PathBuf> = OnceLock::new();

fn player() -> &'static ncm_playback::Player {
    PLAYER.get_or_init(ncm_playback::Player::new)
}

pub struct PlayerStateDto {
    pub track_id: Option<u64>,
    pub playing: bool,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub volume: f32,
}

fn state_dto() -> PlayerStateDto {
    let s = player().state();
    PlayerStateDto {
        track_id: s.track_id,
        playing: s.playing,
        position_ms: s.position_ms,
        duration_ms: s.duration_ms,
        volume: s.volume,
    }
}

/// 下载(带缓存)后交给平台播放后端. 直链有时效, 所以先落盘再播.
pub async fn play_track(track_id: u64, url: String) -> Result<PlayerStateDto, String> {
    let dir = DATA_DIR
        .get()
        .ok_or_else(|| "core not initialized".to_string())?
        .join("audio");
    let cache = ncm_service::cache::AudioCache::open(&dir).map_err(|e| e.to_string())?;
    let path = cache.fetch(track_id, &url).await?;
    player().play_file(track_id, path.to_string_lossy().to_string());
    Ok(state_dto())
}

pub fn player_state() -> PlayerStateDto {
    state_dto()
}

pub fn player_pause() -> PlayerStateDto {
    player().pause();
    state_dto()
}

pub fn player_resume() -> PlayerStateDto {
    player().resume();
    state_dto()
}

pub fn player_stop() -> PlayerStateDto {
    player().stop();
    state_dto()
}

pub fn player_seek(position_ms: u64) -> PlayerStateDto {
    player().seek(position_ms);
    state_dto()
}

pub fn player_set_volume(volume: f32) -> PlayerStateDto {
    player().set_volume(volume);
    state_dto()
}

// ---------------- 播放参数: 精细音量 / 淡入 / 自定义曲线 (R2/R5/R7) ----------------

/// 当前生效的播放参数(回显给 UI, 便于确认设置真的落地了)
pub struct PlaybackTuningDto {
    /// 精细音量增益(dB, -40..=0)
    pub gain_db: f64,
    /// 淡入时长(ms)
    pub fade_ms: u32,
    /// 生效的滤波器数量(0 = 曲线旁路)
    pub eq_filters: u32,
    /// 曲线前级增益(dB)
    pub eq_preamp_db: f64,
}

fn tuning_dto(t: &ncm_playback::PlaybackTuning) -> PlaybackTuningDto {
    let (filters, preamp) = match &t.eq {
        Some(profile) => (
            profile.active_filters().count() as u32,
            profile.preamp_db as f64,
        ),
        None => (0, 0.0),
    };
    PlaybackTuningDto {
        gain_db: t.gain_db as f64,
        fade_ms: t.fade_ms,
        eq_filters: filters,
        eq_preamp_db: preamp,
    }
}

/// 曲线校验结果(导入时给 UI 显示"生效了 N 个滤波器 / 前级 -6 dB / 峰值抬升 +2.5 dB")
pub struct EqValidationDto {
    /// 曲线里一共有多少个 filter(含 OFF)
    pub filters: u32,
    /// 实际参与求值的 filter(ON 且增益非 0)
    pub active_filters: u32,
    pub preamp_db: f64,
    /// 保守估计的总抬升(前级 + 各 filter 正增益之和), > 0 时可能削波
    pub max_boost_db: f64,
}

/// 校验 AutoEQ ParametricEQ.txt 文本。错误消息已是 "第 N 行: 原因" 形式, UI 直接显示。
pub fn eq_profile_validate(text: String) -> Result<EqValidationDto, String> {
    let profile = ncm_domain::EqProfile::parse(&text).map_err(|e| e.to_string())?;
    Ok(EqValidationDto {
        filters: profile.filters.len() as u32,
        active_filters: profile
            .active_filters()
            .filter(|f| f.gain_db.abs() > f32::EPSILON)
            .count() as u32,
        preamp_db: profile.preamp_db as f64,
        max_boost_db: profile.max_boost_db() as f64,
    })
}

/// 归一化曲线文本(统一成 Rust 侧的规范格式, 便于落盘与跨端一致)
pub fn eq_profile_normalize(text: String) -> Result<String, String> {
    let profile = ncm_domain::EqProfile::parse(&text).map_err(|e| e.to_string())?;
    Ok(profile.to_text())
}

/// 应用播放参数: 精细音量立即生效; 淡入与曲线在下一首开始时套用。
///
/// `eq_text` 为 None/空串 ⇒ 曲线旁路(清除曲线)。
pub fn player_configure(
    gain_db: f64,
    fade_ms: u32,
    eq_text: Option<String>,
) -> Result<PlaybackTuningDto, String> {
    let eq = match eq_text {
        Some(text) if !text.trim().is_empty() => {
            Some(ncm_domain::EqProfile::parse(&text).map_err(|e| e.to_string())?)
        }
        _ => None,
    };
    let tuning = ncm_playback::PlaybackTuning {
        gain_db: gain_db as f32,
        fade_ms,
        eq,
    };
    player().configure(tuning);
    Ok(tuning_dto(&player().tuning()))
}

/// 读取当前生效的播放参数
pub fn player_tuning() -> PlaybackTuningDto {
    tuning_dto(&player().tuning())
}

// ---------------- 音频缓存占用上限 (R5) ----------------

fn audio_cache() -> Result<ncm_service::cache::AudioCache, String> {
    let dir = DATA_DIR
        .get()
        .ok_or_else(|| "core not initialized".to_string())?
        .join("audio");
    ncm_service::cache::AudioCache::open(&dir).map_err(|e| e.to_string())
}

/// 缓存占用(limit_mb = 0 表示不限制)
pub struct CacheStatsDto {
    pub total_bytes: u64,
    pub limit_bytes: u64,
    pub files: u32,
}

/// 只读统计, 不删任何文件
pub fn cache_stats(limit_mb: u32) -> Result<CacheStatsDto, String> {
    let cache = audio_cache()?;
    Ok(CacheStatsDto {
        total_bytes: cache.total_bytes(),
        limit_bytes: limit_mb as u64 * 1024 * 1024,
        files: cache.file_count() as u32,
    })
}

/// 按上限收敛缓存(最久未修改优先), 返回删了多少
pub struct CacheEvictionDto {
    pub removed: u32,
    pub freed_bytes: u64,
    pub total_bytes: u64,
    pub limit_bytes: u64,
}

pub fn cache_enforce_limit(
    limit_mb: u32,
    keep_track_id: Option<u64>,
) -> Result<CacheEvictionDto, String> {
    let cache = audio_cache()?;
    let limit = limit_mb as u64 * 1024 * 1024;
    let r = cache.enforce_limit(limit, keep_track_id)?;
    Ok(CacheEvictionDto {
        removed: r.removed as u32,
        freed_bytes: r.freed_bytes,
        total_bytes: r.total_bytes,
        limit_bytes: limit,
    })
}

// ---------------- 响度测量 (R2b/R7) ----------------

/// 一次响度测量的对外形态(track_id + 测量值 + 相对目标电平的静态增益)
pub struct LoudnessDto {
    pub track_id: u64,
    pub lufs: f64,
    pub sample_peak: f64,
    /// ReplayGain 2.0 语义: target - measured(已钳到 ±24 dB)
    pub gain_db: f64,
    pub measured_at_ms: u64,
}

fn loudness_dto(track_id: u64, l: ncm_domain::TrackLoudness, target_lufs: f64) -> LoudnessDto {
    LoudnessDto {
        track_id,
        lufs: l.lufs as f64,
        sample_peak: l.sample_peak as f64,
        gain_db: ncm_playback::loudness::replay_gain_db(target_lufs as f32, l.lufs) as f64,
        measured_at_ms: l.measured_at_ms,
    }
}

fn loudness_store() -> Result<ncm_service::LoudnessStore, String> {
    let dir = DATA_DIR
        .get()
        .ok_or_else(|| "core not initialized".to_string())?;
    Ok(ncm_service::LoudnessStore::open(dir))
}

/// 读缓存的响度(没测过就是 None, 播放时按 0 dB 处理)
pub fn loudness_cached(track_id: u64, target_lufs: f64) -> Result<Option<LoudnessDto>, String> {
    let store = loudness_store()?;
    Ok(store
        .get(track_id)
        .map(|l| loudness_dto(track_id, *l, target_lufs)))
}

/// 测量已缓存音频文件的响度并写入 `loudness.json`。未缓存该曲目时返回 None(不下载)。
pub async fn loudness_measure_cached(
    track_id: u64,
    target_lufs: f64,
) -> Result<Option<LoudnessDto>, String> {
    if let Ok(store) = loudness_store() {
        if let Some(existing) = store.get(track_id) {
            return Ok(Some(loudness_dto(track_id, *existing, target_lufs)));
        }
    }
    let dir = DATA_DIR
        .get()
        .ok_or_else(|| "core not initialized".to_string())?
        .join("audio");
    let cache = ncm_service::cache::AudioCache::open(&dir).map_err(|e| e.to_string())?;
    let Some(path) = cache.cached_path(track_id) else {
        return Ok(None);
    };
    let path_for_task = path.clone();
    let measured =
        tokio::task::spawn_blocking(move || ncm_playback::loudness::measure_file(&path_for_task))
            .await
            .map_err(|e| e.to_string())??;
    let Some(m) = measured else {
        return Ok(None);
    };
    let entry = ncm_domain::TrackLoudness {
        lufs: m.lufs,
        sample_peak: m.sample_peak,
        measured_at_ms: now_ms(),
    };
    let mut store = loudness_store()?;
    store.put(track_id, entry)?;
    Ok(Some(loudness_dto(track_id, entry, target_lufs)))
}

/// 测量任意音频文件路径的响度并写入 `loudness.json`(Android 侧 Media3 的 SimpleCache 文件用)。
pub async fn loudness_measure_path(
    track_id: u64,
    path: String,
    target_lufs: f64,
    format_hint: Option<String>,
) -> Result<Option<LoudnessDto>, String> {
    let path_buf = std::path::PathBuf::from(&path);
    let measured = tokio::task::spawn_blocking(move || {
        ncm_playback::loudness::measure_file_with_hint(&path_buf, format_hint.as_deref())
    })
    .await
    .map_err(|e| e.to_string())??;
    let Some(m) = measured else {
        return Ok(None);
    };
    let entry = ncm_domain::TrackLoudness {
        lufs: m.lufs,
        sample_peak: m.sample_peak,
        measured_at_ms: now_ms(),
    };
    let mut store = loudness_store()?;
    store.put(track_id, entry)?;
    Ok(Some(loudness_dto(track_id, entry, target_lufs)))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// ---------------- 每日推荐 / 心动模式 ----------------

/// 每日推荐歌曲(原版每日推荐)
pub async fn daily_recommend_songs() -> Result<Vec<SongDto>, String> {
    let provider = with_provider(Capability::DailyRecommend)?;
    let songs = provider
        .daily_recommend_songs()
        .await
        .map_err(|e| e.to_string())?;
    Ok(songs.into_iter().map(song_dto).collect())
}

/// 每日推荐歌单(原版推荐歌单, 需要登录)
pub async fn daily_recommend_playlists() -> Result<Vec<Playlist>, String> {
    ffi_forward!(
        Capability::DailyRecommend,
        provider.daily_recommend_playlists()
    )
}

/// 心动模式: 以当前曲目为种子, 在 playlist_id(0 = 不限定)里续播 count 首
pub async fn heart_mode_songs(
    song_id: u64,
    playlist_id: u64,
    count: u32,
) -> Result<Vec<SongDto>, String> {
    let provider = with_provider(Capability::DailyRecommend)?;
    let songs = provider
        .intelligence_songs(song_id, playlist_id, count)
        .await
        .map_err(|e| e.to_string())?;
    Ok(songs.into_iter().map(song_dto).collect())
}

// ---------------- 搜索建议 / 历史 ----------------

/// 搜索联想项: 直接镜像 domain 类型 `SuggestItem`.
#[frb(mirror(SuggestItem))]
pub struct _SuggestItem {
    /// song | artist | album | playlist
    pub kind: String,
    pub id: u64,
    pub title: String,
    pub subtitle: String,
    pub cover_url: Option<String>,
}

/// 搜索建议(输入联想)
pub async fn search_suggest(keywords: String) -> Result<Vec<SuggestItem>, String> {
    if keywords.trim().is_empty() {
        return Ok(Vec::new());
    }
    ffi_forward!(
        Capability::SearchSuggest,
        provider.search_suggest(keywords.trim())
    )
}

fn history_store() -> Result<ncm_service::HistoryStore, String> {
    let dir = DATA_DIR
        .get()
        .ok_or_else(|| "core not initialized".to_string())?;
    ncm_service::HistoryStore::open(dir).map_err(|e| e.to_string())
}

/// 搜索历史(最近在前)
pub fn search_history() -> Result<Vec<String>, String> {
    Ok(history_store()?.search_history())
}

/// 记一条搜索(去重, 最近在前), 返回新的历史列表
pub fn record_search(keyword: String) -> Result<Vec<String>, String> {
    history_store()?
        .record_search(&keyword)
        .map_err(|e| e.to_string())
}

pub fn clear_search_history() -> Result<bool, String> {
    history_store()?.clear_search().map_err(|e| e.to_string())?;
    Ok(true)
}

/// 记一次播放到本地历史(未登录/离线时的"最近听过"来源)
pub fn remember_play(song: SongDto) -> Result<bool, String> {
    let domain = song_from_dto(&song);
    history_store()?
        .record_play(&domain)
        .map_err(|e| e.to_string())?;
    Ok(true)
}

/// 本地播放历史
pub fn local_recent_songs(limit: u32) -> Result<Vec<SongDto>, String> {
    let n = limit.max(1) as usize;
    Ok(history_store()?
        .played()
        .into_iter()
        .take(n)
        .map(song_dto)
        .collect())
}

/// 最近听过: 登录时优先服务端记录, 失败/未登录回落到本地历史
pub async fn recent_songs(limit: u32) -> Result<Vec<SongDto>, String> {
    let logged_in = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard.session.is_logged_in()
    };
    if logged_in {
        if let Ok(provider) = with_provider(Capability::Recent) {
            if let Ok(list) = provider.recent_songs(limit).await {
                if !list.is_empty() {
                    return Ok(list.into_iter().map(song_dto).collect());
                }
            }
        }
    }
    local_recent_songs(limit)
}

// ---------------- 专辑封面预览 ----------------

pub struct AlbumDetailDto {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub artist: String,
    pub description: String,
    pub songs: Vec<SongDto>,
}

pub async fn album_detail(album_id: u64) -> Result<AlbumDetailDto, String> {
    let provider = with_provider(Capability::Album)?;
    let album = provider
        .album_detail(album_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(AlbumDetailDto {
        id: album.id,
        name: album.name,
        cover_url: album.cover_url,
        artist: album.artist,
        description: album.description,
        songs: album.songs.into_iter().map(song_dto).collect(),
    })
}

// ---------------- 歌单详情 / 评论 / 分享 ----------------

/// 歌单详情: 直接镜像 domain 类型 `PlaylistDetail`.
#[frb(mirror(PlaylistDetail))]
pub struct _PlaylistDetail {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub description: String,
    /// 创建者昵称
    pub creator_name: String,
    /// 创建者 uid(0 = 未知); 与 my_uid() 相同即可编辑这个歌单
    pub creator_id: u64,
    pub track_count: u64,
    pub play_count: u64,
    /// 当前账号是否已收藏
    pub subscribed: bool,
    pub subscribed_count: u64,
    pub share_count: u64,
    pub comment_count: u64,
    pub tags: Vec<String>,
}

/// 歌单详情(歌单页头部信息)
pub async fn playlist_detail(playlist_id: u64) -> Result<PlaylistDetail, String> {
    ffi_forward!(
        Capability::PlaylistDetail,
        provider.playlist_detail(playlist_id)
    )
}

/// 收藏/取消收藏歌单(需登录)
pub async fn set_playlist_subscribed(playlist_id: u64, subscribed: bool) -> Result<bool, String> {
    let provider = with_provider(Capability::PlaylistDetail)?;
    provider
        .set_playlist_subscribed(playlist_id, subscribed)
        .await
        .map_err(|e| e.to_string())
}

#[frb(mirror(Comment))]
pub struct _Comment {
    pub id: u64,
    /// 评论者 uid(0 = 未知)
    pub user_id: u64,
    pub user_name: String,
    pub avatar_url: Option<String>,
    pub content: String,
    /// 发布时间(unix 毫秒)
    pub time_ms: u64,
    pub liked_count: u64,
    /// 当前账号是否已赞
    pub liked: bool,
    /// 该评论下的回复数(>0 才显示"回复 N")
    pub reply_count: u64,
    /// IP 归属地(如 "广东"); 精彩评论通常为空
    pub ip_location: String,
    /// 是否精彩评论
    pub hot: bool,
    /// 这条评论回复的是谁(被回复者昵称); None = 顶层评论. UI 据此显示"回复 @某人"
    pub replied_to: Option<String>,
    /// 所属主评论 id(0 = 没有父级)
    pub parent_id: u64,
}

#[frb(mirror(CommentPage))]
pub struct _CommentPage {
    /// 这条线程的 threadId(点赞/回复要用)
    pub thread_id: String,
    /// 精彩评论在前(hotComments), 其后是最新评论, 按 commentId 去重
    pub comments: Vec<Comment>,
    pub total: u64,
    pub has_more: bool,
}

/// 评论统计(评论数/分享数/点赞数). 实测形状见 ncm_domain::CommentStats 的文档注释:
/// 没有 subscribedCount(收藏数) 与 hotCount(热门评论数) —— 别在 UI 里显示这两个.
#[frb(mirror(CommentStats))]
pub struct _CommentStats {
    /// 评论线程 id(R_SO_4_/A_PL_0_/R_AL_3_/A_DJ_1_/R_VI_62_…)
    pub thread_id: String,
    /// 资源 id
    pub resource_id: u64,
    /// 评论总数
    pub comment_count: u64,
    /// 评论数的官方展示文案("100w+"/"999+"/空串)
    pub comment_count_desc: String,
    /// 分享数
    pub share_count: u64,
    /// 该 thread 被点赞数
    pub liked_count: u64,
    /// 当前账号是否点过赞(匿名恒 false)
    pub liked: bool,
    /// 作者参与评论数
    pub musician_said_count: u64,
    /// 评论区是否已升级到新版(服务端灰度, 实测恒 false)
    pub comment_upgraded: bool,
}

/// 已购数字专辑的一项(实测形状见 ncm_domain::DigitalAlbumPurchasedEntry 注释)
#[frb(mirror(DigitalAlbumPurchasedEntry))]
pub struct _DigitalAlbumPurchasedEntry {
    pub album_id: u64,
    pub album_name: String,
    pub artist_id: u64,
    pub artist_name: String,
    pub cover_url: String,
    /// 购买时间(毫秒时间戳)
    pub paid_time_ms: u64,
    /// 购买数量
    pub bought_count: u64,
}

#[frb(mirror(DigitalAlbumPurchased))]
pub struct _DigitalAlbumPurchased {
    /// 服务端给的已购总数(分页用)
    pub total: u64,
    pub albums: Vec<DigitalAlbumPurchasedEntry>,
}

/// 已购单曲的一项(元素形状未实测到, 字段宽松)
#[frb(mirror(PurchasedSongEntry))]
pub struct _PurchasedSongEntry {
    pub song_id: u64,
    pub name: String,
    pub artist_name: String,
    pub cover_url: String,
    pub paid_time_ms: u64,
}

#[frb(mirror(SongPurchasedPage))]
pub struct _SongPurchasedPage {
    pub count: u64,
    pub has_more: bool,
    pub songs: Vec<PurchasedSongEntry>,
}

/// 数字专辑详情(album + product 平铺, 实测形状见 ncm_domain::DigitalAlbumDetail)
#[frb(mirror(DigitalAlbumDetail))]
pub struct _DigitalAlbumDetail {
    pub album_id: u64,
    pub name: String,
    pub artist_id: u64,
    pub artist_name: String,
    pub cover_url: String,
    /// 当前账号是否已购
    pub has_album: bool,
    /// 售价(元)
    pub price: f64,
    /// 上架时间(毫秒时间戳)
    pub pub_time_ms: u64,
    /// product.saleNum(实测恒 0, 真实销量用 digital_album_sales)
    pub sale_num: u64,
    pub tags: Vec<String>,
    /// 简介(descr 拼接, 已过滤 </br>)
    pub description: String,
}

#[frb(mirror(DigitalAlbumSalesEntry))]
pub struct _DigitalAlbumSalesEntry {
    pub album_id: String,
    pub sales: u64,
}

/// 已购数字专辑(需登录; limit/offset 分页)
pub async fn digital_album_purchased(
    limit: u32,
    offset: u32,
) -> Result<DigitalAlbumPurchased, String> {
    ffi_forward!(
        Capability::DigitalAlbum,
        provider.digital_album_purchased(limit, offset)
    )
}

/// 已购单曲(需登录; limit/offset 分页)
pub async fn song_purchased(limit: u32, offset: u32) -> Result<SongPurchasedPage, String> {
    ffi_forward!(
        Capability::DigitalAlbum,
        provider.song_purchased(limit, offset)
    )
}

/// 数字专辑详情(只读; 不提供下单)
pub async fn digital_album_detail(album_id: u64) -> Result<DigitalAlbumDetail, String> {
    ffi_forward!(
        Capability::DigitalAlbum,
        provider.digital_album_detail(album_id)
    )
}

/// 数字专辑销量(album_ids 逗号分隔)
pub async fn digital_album_sales(album_ids: String) -> Result<Vec<DigitalAlbumSalesEntry>, String> {
    ffi_forward!(
        Capability::DigitalAlbum,
        provider.digital_album_sales(&album_ids)
    )
}

/// 评论列表: kind = song | playlist | album | podcast
pub async fn comments(
    kind: String,
    resource_id: u64,
    limit: u32,
    offset: u32,
) -> Result<CommentPage, String> {
    ffi_forward!(
        Capability::Comment,
        provider.comments(&kind, resource_id, limit, offset)
    )
}

/// 评论统计: threadId 形如 R_SO_4_186016 / A_PL_0_24381616(也可用 thread_id_for 现拼).
/// 缺数据时返回全 0, 不抛错; 只有 threadId 非法/动态才报 unsupported.
pub async fn comment_stats(thread_id: String) -> Result<CommentStats, String> {
    ffi_forward!(Capability::Comment, provider.comment_stats(&thread_id))
}

/// 精彩评论(可单独翻页): threadId 来自 comments() 的返回
pub async fn hot_comments(
    thread_id: String,
    limit: u32,
    offset: u32,
) -> Result<CommentPage, String> {
    ffi_forward!(
        Capability::Comment,
        provider.hot_comments(&thread_id, limit, offset)
    )
}

/// 分享资源到动态(需登录). kind = song | playlist | album | podcast
pub async fn share_resource(kind: String, resource_id: u64, msg: String) -> Result<bool, String> {
    let provider = with_provider(Capability::Share)?;
    provider
        .share_resource(&kind, resource_id, &msg)
        .await
        .map_err(|e| e.to_string())
}

// ---------------- 播客 ----------------

#[frb(mirror(PodcastRadio))]
pub struct _PodcastRadio {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub description: String,
    pub dj_name: String,
    pub program_count: u64,
    pub play_count: u64,
}

pub struct PodcastProgramDto {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub duration_ms: u64,
    pub dj_name: String,
    pub radio_id: u64,
    pub radio_name: String,
    pub description: String,
    /// 节目音频本体(播放用 song.id 取直链)
    pub song: Option<SongDto>,
}

fn program_dto(p: ncm_domain::PodcastProgram) -> PodcastProgramDto {
    PodcastProgramDto {
        id: p.id,
        name: p.name,
        cover_url: p.cover_url,
        duration_ms: p.duration_ms,
        dj_name: p.dj_name,
        radio_id: p.radio_id,
        radio_name: p.radio_name,
        description: p.description,
        song: p.song.map(song_dto),
    }
}

/// 热门播客/电台
pub async fn podcast_hot(limit: u32) -> Result<Vec<PodcastRadio>, String> {
    ffi_forward!(Capability::Podcast, provider.podcast_hot(limit))
}

/// 某个播客的节目列表
pub async fn podcast_programs(
    radio_id: u64,
    limit: u32,
    offset: u32,
) -> Result<Vec<PodcastProgramDto>, String> {
    let provider = with_provider(Capability::Podcast)?;
    let list = provider
        .podcast_programs(radio_id, limit, offset)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list.into_iter().map(program_dto).collect())
}

/// 单个节目详情
pub async fn podcast_program(program_id: u64) -> Result<PodcastProgramDto, String> {
    let provider = with_provider(Capability::Podcast)?;
    let p = provider
        .podcast_program(program_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(program_dto(p))
}

/// 播客/电台详情
pub async fn podcast_radio(radio_id: u64) -> Result<PodcastRadio, String> {
    ffi_forward!(Capability::PodcastDetail, provider.podcast_radio(radio_id))
}

// ---------------- 电台发现(只读) ----------------

#[frb(mirror(RadioCategory))]
pub struct _RadioCategory {
    pub id: u64,
    pub name: String,
    pub cover_url: String,
}

#[frb(mirror(RadioPick))]
pub struct _RadioPick {
    pub category_id: u64,
    pub category_name: String,
    pub radios: Vec<PodcastRadio>,
}

#[frb(mirror(RadioExploreHome))]
pub struct _RadioExploreHome {
    pub categories: Vec<RadioCategory>,
    pub picks: Vec<RadioPick>,
}

#[frb(mirror(RadioRankedRadio))]
pub struct _RadioRankedRadio {
    pub rank: u32,
    /// 上期名次(-1 表示新上榜)
    pub last_rank: i32,
    pub radio_id: u64,
    pub name: String,
    pub cover_url: String,
    pub dj_name: String,
    pub category: String,
    pub play_count: u64,
    pub program_count: u64,
    pub sub_count: u64,
    pub score: u64,
    pub rcmd_text: String,
}

#[frb(mirror(RadioRankedDj))]
pub struct _RadioRankedDj {
    pub rank: u32,
    pub last_rank: i32,
    pub user_id: u64,
    pub nickname: String,
    pub avatar_url: String,
    pub score: u64,
    pub followed_count: u64,
}

pub struct RadioRankedProgramDto {
    pub rank: u32,
    pub last_rank: i32,
    pub program: PodcastProgramDto,
}

pub struct RadioToplistDto {
    pub kind: String,
    pub radios: Vec<RadioRankedRadio>,
    pub djs: Vec<RadioRankedDj>,
    pub programs: Vec<RadioRankedProgramDto>,
}

#[frb(mirror(RadioSubscriber))]
pub struct _RadioSubscriber {
    pub user_id: u64,
    pub nickname: String,
    pub avatar_url: String,
    pub signature: String,
    pub subscribe_time_ms: u64,
}

#[frb(mirror(RadioSubscriberPage))]
pub struct _RadioSubscriberPage {
    pub has_more: bool,
    pub subscribers: Vec<RadioSubscriber>,
}

/// 电台发现首页: 分类(dj_catelist) + 各分类精选(dj_category_recommend), 匿名可用.
pub async fn radio_explore_home() -> Result<RadioExploreHome, String> {
    ffi_forward!(Capability::RadioExplore, provider.radio_explore_home())
}

/// 某分类推荐电台(dj_recommend_type; cate_id 必须是真实分类 id).
pub async fn radio_recommend(cate_id: u64) -> Result<Vec<PodcastRadio>, String> {
    ffi_forward!(Capability::RadioExplore, provider.radio_recommend(cate_id))
}

/// 电台榜单(kind: hot/new/pay/hours/newcomer/popular/program).
pub async fn radio_toplist(kind: String) -> Result<RadioToplistDto, String> {
    let provider = with_provider(Capability::RadioExplore)?;
    let r = provider
        .radio_toplist(&kind)
        .await
        .map_err(|e| e.to_string())?;
    Ok(RadioToplistDto {
        kind,
        radios: r.radios,
        djs: r.djs,
        programs: r
            .programs
            .into_iter()
            .map(|x| RadioRankedProgramDto {
                rank: x.rank,
                last_rank: x.last_rank,
                program: program_dto(x.program),
            })
            .collect(),
    })
}

/// 电台订阅者列表(只读).
pub async fn radio_subscribers(
    radio_id: u64,
    limit: u32,
    time_ms: Option<u64>,
) -> Result<RadioSubscriberPage, String> {
    ffi_forward!(
        Capability::RadioExplore,
        provider.radio_subscribers(radio_id, limit, time_ms)
    )
}

// ---------------- 搜索页(热词/推荐词) ----------------

#[frb(mirror(HotSearchTerm))]
pub struct _HotSearchTerm {
    /// 1 开始的名次
    pub rank: u32,
    pub keyword: String,
}

/// 热门搜索榜(按热度排序)
pub async fn hot_search() -> Result<Vec<HotSearchTerm>, String> {
    ffi_forward!(Capability::SearchHot, provider.hot_search())
}

// ---------------- 搜索增强(B4): 纯词联想 / 精确实体改写 / 热搜详情 ----------------

/// 精确实体改写的结果: 直接镜像 domain SearchExact.
/// 注意: orders 为空即"无命中"(接口把空命中伪装成 code=200), 此时三个数组也都为空.
#[frb(mirror(SearchExact))]
pub struct _SearchExact {
    /// 命中类型顺序, 原样保留 (artist / playlist / voice / ...)
    pub orders: Vec<String>,
    pub artists: Vec<Artist>,
    pub playlists: Vec<Playlist>,
    pub podcasts: Vec<PodcastRadio>,
}

/// 联想下拉的纯关键词候选(最多 6 条, 已去重保序). 空/异常返回空 Vec, 不报错.
pub async fn search_suggest_keywords(keywords: String) -> Result<Vec<String>, String> {
    ffi_forward!(
        Capability::SearchSuggest,
        provider.search_suggest_keywords(&keywords)
    )
}

/// 精确实体改写(歌手/歌单/电台各最多 1 条). 无命中时返回 orders 为空的 DTO, 不是错误.
pub async fn search_exact(keywords: String) -> Result<SearchExact, String> {
    ffi_forward!(Capability::SearchSuggest, provider.search_exact(&keywords))
}

/// 热搜榜详情行: 带热度分与榜位(比 HotSearchTerm 多 score/icon_type)
#[frb(mirror(HotSearchDetailItem))]
pub struct _HotSearchDetailItem {
    pub keyword: String,
    /// 1 开始的榜位
    pub rank: u32,
    pub score: u64,
    /// 角标种类: 0 无图标, 2/4/5 等(未知值原样透传)
    pub icon_type: u32,
}

/// 热搜榜详情(20 条, 带 score/rank; 需要登录态更稳)
pub async fn hot_search_detail() -> Result<Vec<HotSearchDetailItem>, String> {
    ffi_forward!(Capability::SearchHot, provider.hot_search_detail())
}

#[frb(mirror(DefaultSearch))]
pub struct _DefaultSearch {
    /// 真正要搜索的关键词(不含推荐理由)
    pub keyword: String,
    /// 官方展示文案, 形如 "🔥Mili 你的十月榜首"
    pub show_text: String,
    pub image_url: Option<String>,
}

/// 默认/推荐搜索词("猜你想搜"); 接口没有时返回 null
pub async fn default_search() -> Result<Option<DefaultSearch>, String> {
    ffi_forward!(Capability::SearchHot, provider.default_search())
}

// ---------------- 推荐页(私人 FM) / 我的(收藏播客/关注艺人/动态) ----------------

/// 私人 FM(需登录)
pub async fn personal_fm(limit: u32) -> Result<Vec<SongDto>, String> {
    let provider = with_provider(Capability::PersonalFm)?;
    let songs = provider
        .personal_fm(limit)
        .await
        .map_err(|e| e.to_string())?;
    Ok(songs.into_iter().map(song_dto).collect())
}

/// 已收藏/订阅的播客(需登录)
pub async fn subscribed_podcasts(limit: u32) -> Result<Vec<PodcastRadio>, String> {
    ffi_forward!(Capability::Podcast, provider.subscribed_podcasts(limit))
}

/// 歌手(简化版): 直接镜像 domain 类型 `Artist`.
#[frb(mirror(Artist))]
pub struct _Artist {
    pub id: u64,
    pub name: String,
    pub avatar_url: Option<String>,
}

/// 关注的艺人(需登录)
pub async fn subscribed_artists(limit: u32) -> Result<Vec<Artist>, String> {
    ffi_forward!(Capability::Feed, provider.subscribed_artists(limit))
}

pub struct FeedEventDto {
    pub id: u64,
    /// 评论/点赞用的 threadId
    pub thread_id: String,
    /// 发布者用户 id
    pub user_id: u64,
    /// song | playlist | album | program | text | other
    pub kind: String,
    pub user_name: String,
    pub avatar_url: Option<String>,
    pub text: String,
    pub song: Option<SongDto>,
    pub cover_url: Option<String>,
    pub images: Vec<String>,
    /// 视频动态的直链
    pub video_url: Option<String>,
    /// 动态自带标题(艺人长文)
    pub title: String,
    /// unix 毫秒
    pub time_ms: u64,
    pub liked: bool,
    pub liked_count: u64,
    pub share_count: u64,
    pub comment_count: u64,
}

/// 关注动态(需登录): 关注的人/艺人发布的单曲、歌单、专辑、节目或文字动态
pub async fn feed_events(limit: u32, last_time: i64) -> Result<Vec<FeedEventDto>, String> {
    let provider = with_provider(Capability::Feed)?;
    let list = provider
        .feed_events(limit, last_time)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list.into_iter().map(feed_event_dto).collect())
}

fn feed_event_dto(e: ncm_domain::FeedEvent) -> FeedEventDto {
    FeedEventDto {
        id: e.id,
        thread_id: e.thread_id,
        user_id: e.user_id,
        kind: e.kind,
        user_name: e.user_name,
        avatar_url: e.avatar_url,
        text: e.text,
        song: e.song.map(song_dto),
        cover_url: e.cover_url,
        images: e.images,
        video_url: e.video_url,
        title: e.title,
        time_ms: e.time_ms,
        liked: e.liked,
        liked_count: e.liked_count,
        share_count: e.share_count,
        comment_count: e.comment_count,
    }
}

/// 指定用户的动态(用户主页): uid = 目标用户, limit = 条数, last_time = 翻页游标(-1 = 第一页).
/// 对方没公开/没有动态时返回**空列表**(不是错误).
pub async fn user_events(
    uid: u64,
    limit: u32,
    last_time: i64,
) -> Result<Vec<FeedEventDto>, String> {
    let provider = with_provider(Capability::Feed)?;
    let list = provider
        .user_events(uid, limit, last_time)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list.into_iter().map(feed_event_dto).collect())
}

/// 动态评论区(threadId 来自 FeedEvent.thread_id)
pub async fn event_comments(
    thread_id: String,
    limit: u32,
    offset: u32,
) -> Result<CommentPage, String> {
    ffi_forward!(
        Capability::Feed,
        provider.event_comments(&thread_id, limit, offset)
    )
}

/// 点赞/取消点赞一条动态
pub async fn like_event(thread_id: String, liked: bool) -> Result<bool, String> {
    ffi_forward!(Capability::Feed, provider.like_event(&thread_id, liked))
}

/// 转发一条动态(附转发语)
pub async fn forward_event(event_id: u64, user_id: u64, msg: String) -> Result<bool, String> {
    ffi_forward!(
        Capability::Feed,
        provider.forward_event(event_id, user_id, &msg)
    )
}

pub struct PlayRankEntryDto {
    pub song: SongDto,
    /// 播放次数(周榜是本周的)
    pub play_count: u64,
    /// 网易云给的推荐分值
    pub score: u64,
}

/// 听歌排行(需登录): period = "all"(总量排行) | "week"(当周排行).
/// 返回顺序即名次(1 开始由 UI 用下标表达).
pub async fn play_ranking(period: String) -> Result<Vec<PlayRankEntryDto>, String> {
    let provider = with_provider(Capability::ListeningRank)?;
    let period = RankingPeriod::parse(&period).unwrap_or_default();
    let list = provider
        .play_ranking(period)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list
        .into_iter()
        .map(|e| PlayRankEntryDto {
            song: song_dto(e.song),
            play_count: e.play_count,
            score: e.score,
        })
        .collect())
}

/// 他人常听排行(用户主页): uid = 目标用户, period = "all" | "week".
/// 对方没公开/没有记录时返回**空列表**(不是错误).
pub async fn user_play_ranking(uid: u64, period: String) -> Result<Vec<PlayRankEntryDto>, String> {
    let provider = with_provider(Capability::ListeningRank)?;
    let period = RankingPeriod::parse(&period).unwrap_or_default();
    let list = provider
        .play_ranking_of(uid, period)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list
        .into_iter()
        .map(|e| PlayRankEntryDto {
            song: song_dto(e.song),
            play_count: e.play_count,
            score: e.score,
        })
        .collect())
}

/// 曲风标签: 直接镜像 domain 类型(D7 spike), Dart 侧靠 dart_code 的 typedef 保持旧名.
#[frb(mirror(StyleTag))]
pub struct _StyleTag {
    /// 曲风 tagId(字符串, 直接回传给 style_songs/style_playlists)
    pub id: String,
    pub name: String,
    pub cover_url: Option<String>,
    pub song_count: Option<u64>,
}

/// 系统推荐的曲风(我的曲风偏好; 未登录时退化成通用曲风表)
pub async fn style_preference() -> Result<Vec<StyleTag>, String> {
    ffi_forward!(Capability::StyleRecommend, provider.style_preference())
}

/// 某个曲风下的歌曲
pub async fn style_songs(tag_id: String, limit: u32) -> Result<Vec<SongDto>, String> {
    let provider = with_provider(Capability::StyleRecommend)?;
    let list = provider
        .style_songs(&tag_id, limit)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list.into_iter().map(song_dto).collect())
}

/// 某个曲风下的歌单
pub async fn style_playlists(tag_id: String, limit: u32) -> Result<Vec<Playlist>, String> {
    ffi_forward!(
        Capability::StyleRecommend,
        provider.style_playlists(&tag_id, limit)
    )
}

#[frb(mirror(ChartSummary))]
pub struct _ChartSummary {
    /// 榜单就是歌单, 直接喂给 playlist_songs / playlist_detail
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    /// "每周四更新" / "刚刚更新"
    pub update_frequency: String,
    pub track_count: u64,
    pub play_count: u64,
}

/// 排行榜列表(飙升/新歌/热歌/原创 + 语种/曲风榜)
pub async fn chart_list() -> Result<Vec<ChartSummary>, String> {
    ffi_forward!(Capability::Chart, provider.charts())
}

/// 榜单 v2 目录里的一张榜单卡
#[frb(mirror(ToplistCatalogItem))]
pub struct _ToplistCatalogItem {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    /// "每周五更新"
    pub update_frequency: String,
    /// 实测恒 "PLAYLIST"
    pub target_type: String,
    pub can_play: bool,
}

/// 榜单 v2 目录的一个分组(categoryCode)
#[frb(mirror(ToplistCatalogGroup))]
pub struct _ToplistCatalogGroup {
    pub code: String,
    pub items: Vec<ToplistCatalogItem>,
}

/// 最新专辑(album_newest, 固定 12 张); 复用 AlbumItem
pub async fn newest_albums(limit: u32) -> Result<Vec<AlbumItem>, String> {
    ffi_forward!(Capability::NewRelease, provider.newest_albums(limit))
}

/// 榜单 v2 目录(toplist_detail_v2, 按 categoryCode 分组)
pub async fn toplist_catalog() -> Result<Vec<ToplistCatalogGroup>, String> {
    ffi_forward!(Capability::Chart, provider.toplist_catalog())
}

#[frb(mirror(PlaylistCategory))]
pub struct _PlaylistCategory {
    /// 一级分类(语种/风格/场景/情感/主题)
    pub group: String,
    /// 该分类下的子分类名(华语/欧美/流行…), 直接作为 playlists_by_category 的 cat
    pub subs: Vec<String>,
}

/// 歌单分类(歌单广场的筛选条)
pub async fn playlist_categories() -> Result<Vec<PlaylistCategory>, String> {
    ffi_forward!(Capability::Playlist, provider.playlist_categories())
}

/// 某个分类下的歌单(按热度, offset 翻页)
pub async fn playlists_by_category(
    cat: String,
    limit: u32,
    offset: u32,
) -> Result<Vec<Playlist>, String> {
    let provider = with_provider(Capability::Playlist)?;
    let list = provider
        .playlists_by_category(&cat, limit, offset)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list)
}

/// 精品歌单(编辑精选)
pub async fn high_quality_playlists(cat: String, limit: u32) -> Result<Vec<Playlist>, String> {
    let provider = with_provider(Capability::Playlist)?;
    let list = provider
        .high_quality_playlists(&cat, limit)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list)
}

/// 专辑列表项: 直接镜像 domain 类型 `AlbumItem`.
#[frb(mirror(AlbumItem))]
pub struct _AlbumItem {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub artist: String,
    pub track_count: u64,
}

/// 我收藏的专辑(需登录)
pub async fn subscribed_albums(limit: u32) -> Result<Vec<AlbumItem>, String> {
    ffi_forward!(Capability::AlbumSub, provider.subscribed_albums(limit))
}

/// 收藏/取消收藏专辑(需登录)
pub async fn set_album_subscribed(album_id: u64, subscribed: bool) -> Result<bool, String> {
    ffi_forward!(
        Capability::AlbumSub,
        provider.set_album_subscribed(album_id, subscribed)
    )
}

/// 新建歌单(需登录), 返回新歌单 id. privacy: 0=公开 10=私密
pub async fn create_playlist(name: String, privacy: u32) -> Result<u64, String> {
    ffi_forward!(
        Capability::PlaylistEdit,
        provider.create_playlist(&name, privacy as u8)
    )
}

/// 批量把歌加入歌单(需登录). songIds 应已去重; 重复曲目服务端会跳过.
pub async fn playlist_tracks_add(playlist_id: u64, song_ids: Vec<u64>) -> Result<bool, String> {
    ffi_forward!(
        Capability::PlaylistEdit,
        provider.playlist_tracks_add(playlist_id, &song_ids)
    )
}

/// 删除歌单(需登录, 且只能删自己的)
pub async fn delete_playlist(playlist_id: u64) -> Result<bool, String> {
    ffi_forward!(
        Capability::PlaylistEdit,
        provider.delete_playlist(playlist_id)
    )
}

/// 改歌单名
pub async fn rename_playlist(playlist_id: u64, name: String) -> Result<bool, String> {
    ffi_forward!(
        Capability::PlaylistEdit,
        provider.rename_playlist(playlist_id, &name)
    )
}

/// 改歌单简介
pub async fn update_playlist_desc(playlist_id: u64, desc: String) -> Result<bool, String> {
    ffi_forward!(
        Capability::PlaylistEdit,
        provider.update_playlist_desc(playlist_id, &desc)
    )
}

/// 把一首歌移出歌单(需登录)
pub async fn remove_from_playlist(playlist_id: u64, track_id: u64) -> Result<bool, String> {
    ffi_forward!(
        Capability::PlaylistEdit,
        provider.remove_track(playlist_id, ncm_domain::TrackId::new(track_id))
    )
}

/// 每日推荐"不感兴趣"(需登录)
pub async fn dislike_recommend_song(song_id: u64) -> Result<bool, String> {
    ffi_forward!(
        Capability::DailyRecommend,
        provider.dislike_recommend_song(song_id)
    )
}

/// 私人 FM"不再播放"(需登录)
pub async fn trash_fm_song(song_id: u64) -> Result<bool, String> {
    ffi_forward!(Capability::PersonalFm, provider.trash_fm_song(song_id))
}

/// 历史日推可用日期(黑胶 VIP; 新的在前)
pub async fn history_recommend_dates() -> Result<Vec<String>, String> {
    ffi_forward!(
        Capability::DailyRecommend,
        provider.history_recommend_dates()
    )
}

/// 某个日期的历史日推曲目
pub async fn history_recommend_songs(date: String) -> Result<Vec<SongDto>, String> {
    ffi_forward!(Capability::DailyRecommend, provider.history_recommend_songs(&date), map_each song_dto)
}

/// 推荐新音乐("新歌速递")
pub async fn new_songs(limit: u32) -> Result<Vec<SongDto>, String> {
    ffi_forward!(Capability::NewRelease, provider.new_songs(limit), map_each song_dto)
}

/// 新碟上架(limit<=30, offset 翻页); 复用 subscribed_albums 的 AlbumItem
pub async fn new_albums(limit: u32, offset: u32) -> Result<Vec<AlbumItem>, String> {
    ffi_forward!(Capability::NewRelease, provider.new_albums(limit, offset))
}

/// 相似歌曲
pub async fn similar_songs(song_id: u64, limit: u32) -> Result<Vec<SongDto>, String> {
    let provider = with_provider(Capability::Similar)?;
    let list = provider
        .similar_songs(song_id, limit)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list.into_iter().map(song_dto).collect())
}

/// 相似歌单
pub async fn similar_playlists(song_id: u64, limit: u32) -> Result<Vec<Playlist>, String> {
    let provider = with_provider(Capability::Similar)?;
    let list = provider
        .similar_playlists(song_id, limit)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list)
}

/// 相似歌手(需登录)
pub async fn similar_artists(artist_id: u64) -> Result<Vec<Artist>, String> {
    ffi_forward!(Capability::Similar, provider.similar_artists(artist_id))
}

/// 评论点赞/取消点赞(threadId 来自 CommentPage.thread_id)
pub async fn like_comment(thread_id: String, comment_id: u64, liked: bool) -> Result<bool, String> {
    let provider = with_provider(Capability::Comment)?;
    provider
        .like_comment(&thread_id, comment_id, liked)
        .await
        .map_err(|e| e.to_string())
}

/// 某条评论下的回复(楼层)
pub async fn comment_replies(
    thread_id: String,
    parent_comment_id: u64,
    limit: u32,
) -> Result<CommentPage, String> {
    ffi_forward!(
        Capability::Comment,
        provider.comment_replies(&thread_id, parent_comment_id, limit)
    )
}

/// 回复某条评论(需登录)
pub async fn reply_comment(
    thread_id: String,
    comment_id: u64,
    content: String,
) -> Result<bool, String> {
    let provider = with_provider(Capability::Comment)?;
    provider
        .reply_comment(&thread_id, comment_id, &content)
        .await
        .map_err(|e| e.to_string())
}

/// 用户列表项: 直接镜像 domain 类型 `UserItem`.
#[frb(mirror(UserItem))]
pub struct _UserItem {
    pub id: u64,
    pub name: String,
    pub avatar_url: Option<String>,
    pub signature: String,
    /// 是否已关注(关注列表恒 true; 粉丝列表按未关注处理)
    pub followed: bool,
}

/// 某人关注的人(uid = 0 用当前账号)
pub async fn user_follows(uid: u64, limit: u32, offset: u32) -> Result<Vec<UserItem>, String> {
    ffi_forward!(
        Capability::Follow,
        provider.user_follows(uid, limit, offset)
    )
}

/// 某人的粉丝(uid = 0 用当前账号)
pub async fn user_followeds(uid: u64, limit: u32, offset: u32) -> Result<Vec<UserItem>, String> {
    ffi_forward!(
        Capability::Follow,
        provider.user_followeds(uid, limit, offset)
    )
}

/// 关注/取关某人(需登录)
pub async fn set_follow(uid: u64, follow: bool) -> Result<bool, String> {
    let provider = with_provider(Capability::Follow)?;
    provider
        .set_follow(uid, follow)
        .await
        .map_err(|e| e.to_string())
}

/// 关注/粉丝数: 直接镜像 domain 类型 `FollowCount`.
#[frb(mirror(FollowCount))]
pub struct _FollowCount {
    pub follows: u64,
    pub fans: u64,
}

/// 我的关注/粉丝数(需登录)
pub async fn follow_counts() -> Result<FollowCount, String> {
    ffi_forward!(Capability::Follow, provider.follow_counts())
}

/// 最近播放的专辑(需登录)
pub async fn recent_albums(limit: u32) -> Result<Vec<AlbumItem>, String> {
    ffi_forward!(Capability::Recent, provider.recent_albums(limit))
}

/// 最近播放的歌单(需登录)
pub async fn recent_playlists(limit: u32) -> Result<Vec<Playlist>, String> {
    let provider = with_provider(Capability::Recent)?;
    let list = provider
        .recent_playlists(limit)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list)
}

/// 最近播放的播客/电台(需登录)
pub async fn recent_podcasts(limit: u32) -> Result<Vec<PodcastRadio>, String> {
    ffi_forward!(Capability::Recent, provider.recent_podcasts(limit))
}

#[frb(mirror(SigninDay))]
pub struct _SigninDay {
    /// yyyy-mm-dd
    pub day: String,
    pub signed: bool,
}

#[frb(mirror(SigninStatus))]
pub struct _SigninStatus {
    pub signed_today: bool,
    /// 累计签到天数
    pub total_days: u32,
    /// 连续签到天数
    pub continuous_days: u32,
    /// 本周签到天数
    pub week_days: u32,
    /// 最近 7 天(新的在前)
    pub recent: Vec<SigninDay>,
    /// 本次签到得到云贝(只有刚签完非 0)
    pub today_point: u32,
}

/// 云贝签到状态(需登录)
pub async fn signin_status() -> Result<SigninStatus, String> {
    ffi_forward!(Capability::Signin, provider.signin_status())
}

/// 签到(需登录). 已签到时返回当前状态(today_point = 0, 不报错)
pub async fn sign_in() -> Result<SigninStatus, String> {
    ffi_forward!(Capability::Signin, provider.sign_in())
}

/// 删除自己的评论(需登录)
pub async fn delete_comment(thread_id: String, comment_id: u64) -> Result<bool, String> {
    ffi_forward!(
        Capability::Comment,
        provider.delete_comment(&thread_id, comment_id)
    )
}

#[frb(mirror(WikiFact))]
pub struct _WikiFact {
    /// 分组(曲风/语种/BPM/获奖成就...)
    pub label: String,
    /// 值(多个已用 " / " 拼好)
    pub value: String,
}

/// 歌曲百科(曲风/语种/BPM/获奖成就). 没有百科时返回空列表
pub async fn song_wiki(song_id: u64) -> Result<Vec<WikiFact>, String> {
    ffi_forward!(Capability::Wiki, provider.song_wiki(song_id))
}

/// 新歌速递(按地区; area = all|zh|ea|jp|kr)
pub async fn new_songs_by_area(area: String, limit: u32) -> Result<Vec<SongDto>, String> {
    let provider = with_provider(Capability::NewRelease)?;
    let list = provider
        .new_songs_by_area(&area, limit)
        .await
        .map_err(|e| e.to_string())?;
    Ok(list.into_iter().map(song_dto).collect())
}

/// 新碟上架(按地区)
pub async fn new_albums_by_area(area: String, limit: u32) -> Result<Vec<AlbumItem>, String> {
    ffi_forward!(
        Capability::NewRelease,
        provider.new_albums_by_area(&area, limit)
    )
}

/// 热门歌手: 直接镜像 domain 类型 `HotArtist`.
#[frb(mirror(HotArtist))]
pub struct _HotArtist {
    pub id: u64,
    pub name: String,
    pub avatar_url: Option<String>,
    /// 粉丝数(列表页显示热度)
    pub fans: u64,
}

/// 热门歌手榜
pub async fn hot_artists(limit: u32, offset: u32) -> Result<Vec<HotArtist>, String> {
    ffi_forward!(Capability::NewRelease, provider.hot_artists(limit, offset))
}

pub struct MessageCountsDto {
    pub private: u32,
    pub notices: u32,
    pub comments: u32,
    pub forwards: u32,
    /// 四项之和(角标用)
    pub total: u32,
}

/// 未读消息计数(需登录)
pub async fn message_counts() -> Result<MessageCountsDto, String> {
    let provider = with_provider(Capability::Message)?;
    let c = provider.message_counts().await.map_err(|e| e.to_string())?;
    Ok(MessageCountsDto {
        private: c.private,
        notices: c.notices,
        comments: c.comments,
        forwards: c.forwards,
        total: c.total(),
    })
}

#[frb(mirror(PrivateSession))]
pub struct _PrivateSession {
    pub user_id: u64,
    pub nickname: String,
    pub avatar_url: Option<String>,
    pub last_message: String,
    pub last_time_ms: u64,
    pub unread: u32,
}

/// 私信会话列表(需登录)
pub async fn private_sessions(limit: u32, offset: u32) -> Result<Vec<PrivateSession>, String> {
    ffi_forward!(
        Capability::Message,
        provider.private_sessions(limit, offset)
    )
}

#[frb(mirror(PrivateMessage))]
pub struct _PrivateMessage {
    pub id: u64,
    pub from_me: bool,
    pub nickname: String,
    pub avatar_url: Option<String>,
    pub content: String,
    pub time_ms: u64,
}

/// 与某人的私信历史(需登录, 老的在前; before_ms = 0 取最新一页)
pub async fn private_history(
    user_id: u64,
    limit: u32,
    before_ms: u64,
) -> Result<Vec<PrivateMessage>, String> {
    ffi_forward!(
        Capability::Message,
        provider.private_history(user_id, limit, before_ms)
    )
}

/// 发送私信(需登录). 纯文本, 成功后应重拉 [private_history] 刷新会话.
pub async fn private_send(user_id: u64, content: String) -> Result<bool, String> {
    ffi_forward!(
        Capability::Message,
        provider.private_send(user_id, content)
    )
}

#[frb(mirror(InboxItem))]
pub struct _InboxItem {
    pub id: u64,
    /// notice | comment
    pub kind: String,
    pub actor: String,
    pub avatar_url: Option<String>,
    pub text: String,
    pub detail: String,
    pub time_ms: u64,
    /// 触发人 uid(未知为 None)
    pub user_id: Option<u64>,
    /// 评论线程 id(R_SO_4_x 一类; 通知类一般为 None)
    pub thread_id: Option<String>,
    /// 评论 id(用于定位/回复)
    pub comment_id: Option<u64>,
}

/// 通知(需登录, 新的在前; last_time_ms = 0 取最新一页)
pub async fn message_notices(limit: u32, last_time_ms: u64) -> Result<Vec<InboxItem>, String> {
    ffi_forward!(
        Capability::Message,
        provider.message_notices(limit, last_time_ms)
    )
}

/// 评论/回复消息(需登录, 新的在前)
pub async fn comment_messages(limit: u32) -> Result<Vec<InboxItem>, String> {
    ffi_forward!(Capability::Message, provider.comment_messages(limit))
}

#[frb(mirror(ForwardItem))]
pub struct _ForwardItem {
    pub id: Option<u64>,
    pub event_id: Option<u64>,
    pub user_id: Option<u64>,
    pub nickname: Option<String>,
    pub avatar_url: Option<String>,
    pub comment: Option<String>,
    pub time_ms: Option<u64>,
    pub forward_type: Option<u32>,
    pub pic_url: Option<String>,
}

/// 消息中心"@我"(需登录; last_time_ms 预留游标形状, 接口实际用 offset/limit, 恒取最新一页)
pub async fn forward_messages(limit: u32, last_time_ms: u64) -> Result<Vec<ForwardItem>, String> {
    ffi_forward!(
        Capability::Message,
        provider.forward_messages(limit, last_time_ms)
    )
}

#[frb(mirror(RecentContact))]
pub struct _RecentContact {
    pub user_id: u64,
    pub nickname: String,
    pub avatar_url: Option<String>,
    pub mutual: bool,
    pub onlined: bool,
    pub vip_type: u32,
    pub remark_name: Option<String>,
}

/// 最近联系人(需登录; "可发起私信的联系人/关注列表", 服务端顺序)
pub async fn recent_contacts(limit: u32) -> Result<Vec<RecentContact>, String> {
    ffi_forward!(Capability::Message, provider.recent_contacts(limit))
}

/// 当前登录账号 uid(0 = 未登录/未同步). 用于判断歌单是不是自己的(能不能编辑)
pub fn my_uid() -> Result<u64, String> {
    let guard = core()?.lock().map_err(|e| e.to_string())?;
    Ok(guard
        .session
        .profile
        .as_ref()
        .map(|p| p.user_id)
        .unwrap_or(0))
}

/// 黑胶会员等级
#[frb(mirror(VipMembership))]
pub struct _VipMembership {
    pub level: u32,
    pub red_vip_level: u32,
    pub expire_time_ms: u64,
    /// 到期时间晚于服务端 now 才算会员(过期后 vipLevel 仍是旧值, 别拿它判断)
    pub is_vip: bool,
    /// 年费剩余月数, 负数 = 未知
    pub annual_count: i32,
}

/// 黑胶成长值 / 等级卡
#[frb(mirror(VipGrowth))]
pub struct _VipGrowth {
    pub level: u32,
    pub level_name: String,
    pub growth_point: i64,
    pub today_score: i64,
    pub max_level: bool,
}

/// 某一天的签到状态(接口只回最近 7 天)
#[frb(mirror(VipSignDay))]
pub struct _VipSignDay {
    /// yyyy-MM-dd
    pub date: String,
    /// score > 0 才算已签
    pub signed: bool,
    pub today: bool,
    pub score: u32,
}

/// 黑胶签到概览(本周维度)
#[frb(mirror(VipSign))]
pub struct _VipSign {
    pub days: Vec<VipSignDay>,
    pub signed_today: bool,
    pub week_signed: u32,
}

/// 黑胶任务
#[frb(mirror(VipTask))]
pub struct _VipTask {
    pub title: String,
    pub reward: String,
    pub growth_point: i32,
    pub progress: i64,
    /// 0 = 没有可量化目标(不显示进度条)
    pub target: i64,
    pub done: bool,
    pub show_progress: bool,
    pub url: Option<String>,
}

/// 黑胶会员总览(只读)
#[frb(mirror(VipOverview))]
pub struct _VipOverview {
    pub logged_in: bool,
    pub membership: Option<VipMembership>,
    pub growth: Option<VipGrowth>,
    pub sign: Option<VipSign>,
    pub tasks: Vec<VipTask>,
    pub task_score: i64,
}

/// 黑胶会员总览: 会员等级/成长值/本周签到/任务.
/// 未登录返回 logged_in=false 的空态; 四个子接口互相独立, 单个失败只让对应字段为 None.
pub async fn vip_overview() -> Result<VipOverview, String> {
    let provider = with_provider(Capability::Vip)?;
    let o = provider.vip_overview().await.map_err(|e| e.to_string())?;
    Ok(o)
}

/// 账号听歌等级(用户等级)
#[frb(mirror(UserLevel))]
pub struct _UserLevel {
    /// 当前等级数字
    pub level: u32,
    /// 本等级已累计听歌数
    pub now_play_count: u64,
    /// 升到下一级所需累计听歌数
    pub next_play_count: u64,
    /// 本等级已累计登录天数
    pub now_login_count: u64,
    /// 升到下一级所需登录天数
    pub next_login_count: u64,
    /// 0..=1 的进度(按听歌数算)
    pub progress: f64,
    /// 该等级权益文案, 用 `$` 分隔多条
    pub privileges: String,
}

/// 一枚勋章
#[frb(mirror(UserMedal))]
pub struct _UserMedal {
    /// 唯一 id(字符串, 乐迷徽章形如 "20170503_1081839")
    pub code: String,
    pub name: String,
    pub pic_url: Option<String>,
    /// 佩戴/横排版图
    pub wear_pic_url: Option<String>,
    /// 达成条件文案
    pub condition: String,
    /// 是否已获得(以服务端 status == "OBTAIN" 为准)
    pub obtained: bool,
    /// 获得时间(毫秒), 未获得为 None
    pub obtain_time_ms: Option<u64>,
    /// 等级文本, 如 "Lv.4 乐迷"(仅乐迷徽章)
    pub level_title: Option<String>,
    /// 进度文案, 如 "当前进度1897/5000"
    pub progress_text: Option<String>,
    /// 获得比例文案, 如 "前0.033%获得该徽章"
    pub rank_text: Option<String>,
    /// 服务端状态原值(OBTAIN / NOT_OBTAIN_PROCESS / NOT_OBTAIN_NO_PROCESS / WILL_OBTAIN)
    pub status: String,
}

/// 账号听歌等级(需要登录)
pub async fn user_level() -> Result<UserLevel, String> {
    ffi_forward!(Capability::ProfileDetail, provider.user_level())
}

/// 账号勋章墙(需要登录). 全部勋章按服务端分类顺序平铺.
pub async fn user_medals() -> Result<Vec<UserMedal>, String> {
    let provider = with_provider(Capability::ProfileDetail)?;
    let wall = provider.user_medals().await.map_err(|e| e.to_string())?;
    Ok(wall.medals)
}
