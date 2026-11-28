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

/// `init()` **一次性发布**的三件套: 实际生效的数据目录 / `Core` / 插件宿主句柄.
///
/// 为什么合成一个结构体: 以前是 `DATA_DIR` / `CORE` / `PLUGIN` 三个独立 `OnceLock`,
/// 分三步 `set` 且都用 `let _ =` 吞掉失败 ——
/// - 并发 `init()`(Dart 侧 `bootstrap()` 与 `refreshInfo()` 都会调)时 TOCTOU:
///   两个线程都能过 `CORE.get().is_none()`, 各自 `Core::open` 一份; 输掉 `CORE.set` 的那个
///   仍会把自己的 `plugin_host_handle()` 塞进 `PLUGIN` ⇒ 插件启停/路由看到的是**孤儿
///   `Core`** 的那套状态, 与其它域用的 `Core` 不是同一份;
/// - `init()` 回给 Dart 的是**入参** dir, 不是实际生效的目录: 重复 init 传了不同目录时,
///   Dart 拿 dir2 写 `settings.json`, 而 Rust 仍在 dir1 里写缓存/历史(两份数据分家)。
///
/// 现在三者是同一个 `Arc` 一起发布(见 [`init`]), 不存在"半套"状态。
struct Inited {
    /// 实际生效的数据目录: 所有 FFI 侧落盘(缓存/历史/响度/TTML/设置)都在它下面。
    dir: std::path::PathBuf,
    core: Mutex<Core>,
    /// 插件宿主的共享句柄(与 `core` 里那份是**同一个** `Arc`).
    ///
    /// 插件 FFI 入口只走这里, **不取 `Core` 锁**: `rescan`/`install_*`/`enable` 会真的装载
    /// QuickJS(单插件装载预算 8s), 持 `Core` 锁做这些会让所有其它域的 FFI 排队(隔离二期切片 A).
    /// 锁序纪律: 允许 `Core -> 插件句柄`, **禁止**反过来.
    plugin: ncm_service::PluginHostHandle,
}

static INITED: OnceLock<std::sync::Arc<Inited>> = OnceLock::new();

/// 已发布的单例(未初始化 ⇒ 与 [`core`] 同一个错误口径).
fn inited() -> Result<&'static std::sync::Arc<Inited>, FfiError> {
    INITED
        .get()
        .ok_or_else(|| FfiError::internal("core not initialized"))
}

/// 首次调用时开 `Core` 并**原子发布** [`Inited`](目录 + Core + 插件句柄); 已发布就复用。
///
/// 双检 + 持锁做"唯一一次 `set`": 并发 `init()` 里只有一个线程真的 `Core::open`,
/// 其余线程等它发布完拿到同一份 `Arc`。所以不存在"两个 `Core` 各绑一个插件句柄"——
/// 以前 `CORE` / `PLUGIN` 分两步 `set` 正是这个漏洞的来源。
fn inited_or_open(dir: &str) -> Result<&'static std::sync::Arc<Inited>, FfiError> {
    if let Some(inited) = INITED.get() {
        return Ok(inited);
    }
    // 锁中毒只可能意味着"持锁期间 panic"; 那时什么都没发布, 继续用这把锁是安全的
    static INIT_LOCK: Mutex<()> = Mutex::new(());
    let _guard = INIT_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(inited) = INITED.get() {
        return Ok(inited);
    }
    let core = Core::open(Path::new(dir)).map_err(FfiError::from)?;
    let plugin = core.plugin_host_handle();
    let published = INITED.set(std::sync::Arc::new(Inited {
        dir: Path::new(dir).to_path_buf(),
        core: Mutex::new(core),
        plugin,
    }));
    if published.is_err() {
        // 持锁期间不可能有别的写者; 真出现了就如实报错, 不静默丢掉
        return Err(FfiError::internal("init: 单例已被并发发布, 请重试"));
    }
    inited()
}

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
    Ok(&inited()?.core)
}

/// 插件宿主的共享句柄(未初始化 ⇒ 与 `core()` 同一个错误口径).
fn plugin_host() -> Result<ncm_service::PluginHostHandle, FfiError> {
    Ok(inited()?.plugin.clone())
}

/// 实际生效的数据目录(未初始化 ⇒ 与 `core()` 同一个错误口径).
fn data_dir() -> Result<&'static Path, FfiError> {
    Ok(&inited()?.dir)
}

/// D5: 纯 provider 转发型 FFI 封装统一 helper。
/// - ffi_forward!(Capability::X, provider.method(args))             返回值直接透传
/// - ffi_forward!(Capability::X, provider.method(args), map conv)     末步转 Dto(conv 为普通 fn/闭包)
/// - ffi_forward!(Capability::X, provider.method(args), map_each conv) Vec 转 Vec<Dto>
///   错误统一靠 `?` 走 `From<_> for FfiError`(ProviderError 保留 kind/retryable);
///   frb 只看函数签名, 宏只生成函数体。
///
/// 调用走 [`routed_call`](routed_call): 判定(插件/内置)由 `ncm_service::plugins::route` 独家
/// 负责, 插件侧失败自动回落内置 provider —— 本层不重复判定, 也不自己写回落分支。
macro_rules! ffi_forward {
    ($cap:expr, $p:ident . $m:ident ( $($arg:expr),* ), map $conv:expr) => {{
        let v = routed_call($cap, |$p| Box::pin(async move { $p.$m($($arg),*).await })).await?;
        Ok(($conv)(v))
    }};
    ($cap:expr, $p:ident . $m:ident ( $($arg:expr),* ), map_each $conv:expr) => {{
        let list = routed_call($cap, |$p| Box::pin(async move { $p.$m($($arg),*).await })).await?;
        Ok(list.into_iter().map($conv).collect())
    }};
    ($cap:expr, $p:ident . $m:ident ( $($arg:expr),* )) => {{
        let v = routed_call($cap, |$p| Box::pin(async move { $p.$m($($arg),*).await })).await?;
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
///
/// 这个函数也**直接暴露给 UI**(`rust.dataDirDefault()`): 启动时要在 `runApp` 之前读
/// `settings.json`(否则首帧用默认主题、设置加载完再翻一次 —— 缓存审计 P2 的「首帧主题闪」),
/// 而那一步只需要目录**路径**, 不需要 `init()` 打开 `Core`(keystore 恢复/D-Bus 探测都在
/// `init` 里, 挪到首帧前会拖慢启动)。两个调用点拿到的是同一个路径, 迁移也只发生一次。
pub fn data_dir_default() -> String {
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
///
/// 首次调用时开 `Core` 并**原子发布** [`Inited`](目录 + Core + 插件句柄); 已发布就直接复用。
/// 为什么用一把初始化锁 + 双检, 而不用 `OnceLock::get_or_try_init`: 后者截至 Rust 1.99
/// 仍是 unstable(issue #109737)。两者给的保证一样 —— 并发 `init()` 里只有一个线程真的
/// `Core::open`, 其余线程等它发布完拿到同一份 `Arc`, 于是不可能出现第二个 `Core`
/// 把自己的插件句柄写进单例。`Core::open` 失败 ⇒ 什么都不发布(下次调用重试)。
pub fn init(data_dir: Option<String>) -> Result<InitInfo, FfiError> {
    let requested = data_dir.unwrap_or_else(data_dir_default);
    let inited = inited_or_open(&requested)?;
    if inited.dir.as_path() != Path::new(&requested) {
        // 已经初始化过且这次传了别的目录: 以**生效中**的目录为准(见 `Inited` 的注释),
        // 但要把不一致说出来 —— 静默沿用会让"Dart 用 dir2、Rust 用 dir1"再次变成隐形缺陷。
        eprintln!(
            "[ncm-ffi] init(dataDir={requested}) 与已生效的 {} 不一致: 沿用已生效的目录",
            inited.dir.display()
        );
    }
    let guard = inited.core.lock().map_err(FfiError::from)?;
    Ok(InitInfo {
        data_dir: inited.dir.to_string_lossy().into_owned(),
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

/// 本次调用该用哪个 provider 的**目标选择**: 判定归 `ncm_service::plugins::route`
/// (`Core::route_decision`), 这里只把判定结果翻成 `Arc`, 不自己挑人。
///
/// 只选目标、不负责回落 —— 需要"插件失败回落内置"的调用点用 [`routed_call`]
/// (单个 provider 方法调用的标准形态), 多步拼装(如 `search_all` 的 DTO 转换)也用
/// [`routed_call`] 包住那一次调用即可。这里保留下来的直连形态只用于"取到 provider
/// 之后还要做别的事"的少数调用点, 它们因此拿到的是路由判定后的目标(插件命中即插件)。
fn with_provider(cap: Capability) -> Result<std::sync::Arc<dyn ncm_provider::Provider>, FfiError> {
    let guard = core()?.lock().map_err(FfiError::from)?;
    let decision = guard.route_decision(cap);
    decision
        .plugin
        .or(decision.builtin)
        .ok_or_else(|| FfiError::unsupported(format!("no provider supports {}", cap.as_str())))
}

/// 一次**路由调用**: 判定 + 「插件先试、失败回落内置」都由
/// `ncm_service::plugins::route::call_routed` 独家实现(回落只在插件侧失败时发生,
/// 内置自身的错误直接上抛)。本函数只做两件事: 拿 `Core` 锁取判定、把错误摊成 [`FfiError`]。
///
/// 闭包拿到的是 provider 的 `Arc`(按值), 调用点写
/// `|p| Box::pin(async move { p.method(&args).await })` —— future 自己持有 provider,
/// 只有调用点借来的参数受限, 不会被迫 `'static`。
async fn routed_call<'p, T, F>(cap: Capability, call: F) -> Result<T, FfiError>
where
    F: Fn(
        std::sync::Arc<dyn ncm_provider::Provider>,
    ) -> ncm_provider::BoxFuture<'p, ncm_provider::ProviderResult<T>>,
{
    let decision = {
        let guard = core()?.lock().map_err(FfiError::from)?;
        guard.route_decision(cap)
    };
    let routed = ncm_service::plugins::call_routed(decision, call)
        .await
        .map_err(FfiError::from)?;
    Ok(routed.value)
}

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
#[cfg(test)]
#[path = "api/data_dir_regression_tests.rs"]
mod data_dir_regression_tests;
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
