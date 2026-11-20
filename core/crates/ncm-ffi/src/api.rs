//! 暴露给 Dart 的 API. 规则:
//! - 只传可序列化 DTO, 不传引用/闭包
//! - 错误统一成 [`FfiError`](kind + retryable + detail), UI 按 kind 决策文案
//! - 全局单例 Core, 由 init() 建立

use std::path::Path;
use std::sync::{Mutex, OnceLock};

use flutter_rust_bridge::frb;

pub use ncm_domain::{
    AlbumBrief, AlbumItem, Artist, ChartSummary, CloudPage, CloudSong, CloudUploadResult, Comment,
    CommentPage, CommentStats, DefaultSearch, DigitalAlbumDetail, DigitalAlbumPurchased,
    DigitalAlbumPurchasedEntry, DigitalAlbumSalesEntry, FollowCount, ForwardItem, HotArtist,
    HotSearchDetailItem, HotSearchTerm, InboxItem, MvItem, PhoneLoginResult, Playlist,
    PlaylistCategory, PlaylistDetail, PodcastRadio, PrivateMessage, PrivateSession, ProfileDetail,
    PurchasedSongEntry, QrLoginCheck, QrLoginKey, QrLoginState, RadioCategory, RadioExploreHome,
    RadioPick, RadioRankedDj, RadioRankedRadio, RadioSubscriber, RadioSubscriberPage,
    RecentContact, SearchAlbum, SearchArtist, SearchExact, SearchPlaylistItem, SearchPodcast,
    SigninDay, SigninStatus, SmsCodeSent, SongLikeState, SongPurchasedPage, StreamUrl, StyleTag,
    SuggestItem, ToplistCatalogGroup, ToplistCatalogItem, UserItem, UserLevel, UserMedal,
    VipGrowth, VipMembership, VipOverview, VipTask, WikiFact,
};
use ncm_provider::{Capability, RankingPeriod, SearchQuery};
use ncm_service::Core;

static CORE: OnceLock<Mutex<Core>> = OnceLock::new();

/// 跨桥错误: 结构化的 provider 错误, 不再让 Dart 靠文本前缀猜.
///
/// 字段语义与 [`ncm_provider::ProviderError`] 一一对应:
/// - `kind`: `network` / `auth` / `riskControl` / `notFound` /
///   `unsupported` / `forbidden` / `internal`
/// - `retryable`: 是否值得重试(网络抖动类为 true; 鉴权/风控/无版权 false)
/// - `detail`: 原始细节, 网络类基本是 os error, forbidden 类是可读中文
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FfiError {
    pub kind: String,
    pub retryable: bool,
    pub detail: String,
}

impl FfiError {
    pub fn new(kind: impl Into<String>, retryable: bool, detail: impl Into<String>) -> Self {
        Self {
            kind: kind.into(),
            retryable,
            detail: detail.into(),
        }
    }

    /// 桥接层自身的问题(未初始化/锁中毒/本地 io): 非 provider 错误, 不可重试
    pub fn internal(detail: impl Into<String>) -> Self {
        Self::new("internal", false, detail)
    }

    pub fn network(detail: impl Into<String>) -> Self {
        Self::new("network", true, detail)
    }

    pub fn auth(detail: impl Into<String>) -> Self {
        Self::new("auth", false, detail)
    }

    pub fn unsupported(detail: impl Into<String>) -> Self {
        Self::new("unsupported", false, detail)
    }
}

impl std::fmt::Display for FfiError {
    /// 与 [`ncm_provider::ProviderError`] 的展示保持一致, 日志仍可读、旧的
    /// "[kind] " 文本匹配路径(Dart 兜底/脚本 grep)继续有效.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.kind, self.detail)
    }
}

impl std::error::Error for FfiError {}

impl From<ncm_provider::ProviderError> for FfiError {
    fn from(e: ncm_provider::ProviderError) -> Self {
        Self {
            kind: e.kind.as_str().to_string(),
            retryable: e.retryable,
            detail: e.detail,
        }
    }
}

// 下面这些不是 provider 错误, 一律归到 internal(不可重试), 但保留原始 detail ——
// 目的是让导出函数里的 `?` 直接可用, 不必再写 map_err 手搓字符串.
impl From<String> for FfiError {
    fn from(e: String) -> Self {
        Self::internal(e)
    }
}

impl From<std::io::Error> for FfiError {
    fn from(e: std::io::Error) -> Self {
        Self::internal(e.to_string())
    }
}

impl<T> From<std::sync::PoisonError<T>> for FfiError {
    fn from(e: std::sync::PoisonError<T>) -> Self {
        Self::internal(e.to_string())
    }
}

impl From<ncm_domain::EqProfileError> for FfiError {
    fn from(e: ncm_domain::EqProfileError) -> Self {
        Self::internal(e.to_string())
    }
}

impl From<tokio::task::JoinError> for FfiError {
    fn from(e: tokio::task::JoinError) -> Self {
        Self::internal(e.to_string())
    }
}

fn core() -> Result<&'static Mutex<Core>, FfiError> {
    CORE.get()
        .ok_or_else(|| FfiError::internal("core not initialized"))
}

/// D5: 纯 provider 转发型 FFI 封装统一 helper。
/// - ffi_forward!(Capability::X, provider.method(args))             返回值直接透传
/// - ffi_forward!(Capability::X, provider.method(args), map conv)     末步转 Dto(conv 为普通 fn/闭包)
/// - ffi_forward!(Capability::X, provider.method(args), map_each conv) Vec 转 Vec<Dto>
///   错误统一靠 `?` 走 `From<_> for FfiError`(ProviderError 保留 kind/retryable);
///   frb 只看函数签名, 宏只生成函数体。
macro_rules! ffi_forward {
    ($cap:expr, $p:ident . $m:ident ( $($arg:expr),* ), map $conv:expr) => {{
        let $p = with_provider($cap)?;
        let v = $p.$m($($arg),*).await?;
        Ok(($conv)(v))
    }};
    ($cap:expr, $p:ident . $m:ident ( $($arg:expr),* ), map_each $conv:expr) => {{
        let $p = with_provider($cap)?;
        let list = $p.$m($($arg),*).await?;
        Ok(list.into_iter().map($conv).collect())
    }};
    ($cap:expr, $p:ident . $m:ident ( $($arg:expr),* )) => {{
        let $p = with_provider($cap)?;
        let v = $p.$m($($arg),*).await?;
        Ok(v)
    }};
}

/// 桌面端默认数据目录(P-18 后半): `~/.local/share/io.github.xiaquwan1001.MiniNCM`.
///
/// - `$NCM_DATA_DIR` 是显式指定 ⇒ 原样使用, **不参与迁移**(测试/多实例靠它隔离)。
/// - 其余情况(默认路径)在返回前做一次**一次性迁移**: 新目录缺失且旧目录
///   (`~/.local/share/ncm`) 存在 ⇒ 搬过去, 失败则回退为继续用旧目录。
///   迁移发生在这里(init 里、`Core::open` 之前), 保证没有任何缓存/凭据/播放状态文件
///   在迁移完成前被打开。规则细节见 `ncm_service::fsutil` 模块注释。
/// - Android 走平台通道传私有目录(`data_dir = Some`), 不经过本函数。
fn data_dir_default() -> String {
    if let Ok(explicit) = std::env::var("NCM_DATA_DIR") {
        return explicit;
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    let home = std::path::Path::new(&home);
    let current = ncm_service::fsutil::default_desktop_data_dir(home);
    let legacy = ncm_service::fsutil::legacy_desktop_data_dir(home);
    // 失败时返回的是旧目录(可用的), 所以这里只关心"用哪个", 日志在 fsutil 里打。
    let (dir, _) = ncm_service::fsutil::resolve_desktop_data_dir(&current, &legacy);
    dir.to_string_lossy().into_owned()
}

/// 初始化: 建立/加载身份, 注册 provider. 幂等.
pub fn init(data_dir: Option<String>) -> Result<InitInfo, FfiError> {
    let dir = data_dir.unwrap_or_else(data_dir_default);
    let _ = DATA_DIR.set(std::path::PathBuf::from(&dir));
    if CORE.get().is_none() {
        let core = Core::open(Path::new(&dir)).map_err(FfiError::from)?;
        let _ = CORE.set(Mutex::new(core));
    }
    let guard = core()?.lock().map_err(FfiError::from)?;
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
    /// 请求的档位(取链时传入). 服务端实际档位见 `actual_level`.
    pub quality: String,
    pub br: Option<u64>,
    pub size: Option<u64>,
    pub expire_at: Option<u64>,
    /// 服务端实际给的档位(上游响应 level). 与 quality 不同 = 被静默降级.
    pub actual_level: Option<String>,
    /// 容器/编码: mp3 / flac / m4a
    pub format: Option<String>,
    /// 整文件 md5(完整性校验用)
    pub md5: Option<String>,
    /// 上游响应 time(毫秒)
    pub duration_ms: Option<u64>,
    /// 试听片段起点(毫秒, 相对整曲)
    pub trial_start_ms: Option<u64>,
    /// 试听片段终点(毫秒, 相对整曲)
    pub trial_end_ms: Option<u64>,
    /// 是不是试听片段(freeTrialInfo 非空)
    pub is_trial: bool,
}

pub fn ping(name: String) -> String {
    format!("pong from rust: {name}")
}

// ---------------- 共享 helper(各域模块共用) ----------------

fn with_provider(cap: Capability) -> Result<std::sync::Arc<dyn ncm_provider::Provider>, FfiError> {
    let guard = core()?.lock().map_err(FfiError::from)?;
    guard
        .providers
        .first_with(cap)
        .ok_or_else(|| FfiError::unsupported(format!("no provider supports {}", cap.as_str())))
}

static DATA_DIR: OnceLock<std::path::PathBuf> = OnceLock::new();

/// PodcastProgram -> DTO(podcast 与 radio 两个域共用).
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

// 域子模块: 每个文件只放一个域的函数与 DTO(mirror), 拆自原 3334 行 api.rs。
// 子模块靠 use super::*; 拿到上面的共享 helper(FfiError/core/with_provider/
// song_dto/ffi_forward! 等); pub use 必须保留 —— frb 生成的 wire 代码按
// crate::api::<fn> 取函数, 少了这行就编译不过。
//
// 子模块必须是 `pub mod`: frb 生成物对在子模块里声明的 DTO 直接写
// `crate::api::<域>::TypeName`(实测 frb_generated.rs 对 WordLyricScoreDto 就是这样),
// 私有模块会让生成物报 E0603(module is private)。
pub mod account;
pub mod artist;
pub mod cloud;
pub mod detail;
pub mod discover;
pub mod library;
pub mod lyric;
pub mod me;
pub mod playback;
pub mod plugin;
pub mod podcast;
pub mod radio;
pub mod recommend;
pub mod search;
pub mod social;

pub use account::*;
pub use artist::*;
pub use cloud::*;
pub use detail::*;
pub use discover::*;
pub use library::*;
pub use lyric::*;
pub use me::*;
pub use playback::*;
pub use plugin::*;
pub use podcast::*;
pub use radio::*;
pub use recommend::*;
pub use search::*;
pub use social::*;
