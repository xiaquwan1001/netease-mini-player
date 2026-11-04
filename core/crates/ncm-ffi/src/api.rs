//! 暴露给 Dart 的 API. 规则:
//! - 只传可序列化 DTO, 不传引用/闭包
//! - 错误统一成 String(带 kind 前缀), UI 按前缀决定文案
//! - 全局单例 Core, 由 init() 建立

use std::path::Path;
use std::sync::{Mutex, OnceLock};

use ncm_provider::{Capability, SearchQuery};
use ncm_service::Core;

static CORE: OnceLock<Mutex<Core>> = OnceLock::new();

fn core() -> Result<&'static Mutex<Core>, String> {
    CORE.get().ok_or_else(|| "core not initialized".to_string())
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
        vip: guard.session.profile.as_ref().map(|p| p.vip).unwrap_or(false),
        providers: guard
            .providers
            .all()
            .iter()
            .map(|p| ProviderInfo {
                id: p.id().to_string(),
                name: p.name().to_string(),
                capabilities: p.capabilities().iter().map(|c| c.as_str().to_string()).collect(),
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
    pub album: String,
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
    SongDto {
        id: s.id.0,
        name: s.name,
        artist,
        album: s.album.map(|a| a.name).unwrap_or_default(),
        duration_ms: s.duration_ms,
        fee: s.fee.unwrap_or(0),
        vip,
        paid,
        playable,
    }
}

pub struct SearchResultDto {
    pub total: u64,
    pub has_more: bool,
    pub songs: Vec<SongDto>,
}

pub struct StreamDto {
    pub url: Option<String>,
    pub quality: String,
    pub br: Option<u64>,
    pub expire_at: Option<u64>,
}

pub async fn search(keywords: String, limit: u32) -> Result<SearchResultDto, String> {
    let provider = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard
            .providers
            .first_with(Capability::Search)
            .ok_or_else(|| "no provider supports search".to_string())?
    };
    let query = SearchQuery { keywords, limit, offset: 0 };
    let page = provider.search(&query).await.map_err(|e| e.to_string())?;
    Ok(SearchResultDto {
        total: page.total,
        has_more: page.has_more,
        songs: page.songs.into_iter().map(song_dto).collect(),
    })
}

pub async fn song_url(track_id: u64, level: String) -> Result<StreamDto, String> {
    let provider = {
        let guard = core()?.lock().map_err(|e| e.to_string())?;
        guard
            .providers
            .first_with(Capability::SongUrl)
            .ok_or_else(|| "no provider supports songUrl".to_string())?
    };
    let level = ncm_provider::AudioLevel::parse(&level).unwrap_or_default();
    let req = ncm_provider::SongUrlRequest { track: ncm_domain::TrackId::new(track_id), level };
    let stream = provider.song_url(&req).await.map_err(|e| e.to_string())?;
    Ok(StreamDto {
        url: stream.url,
        quality: stream.quality,
        br: stream.br,
        expire_at: stream.expire_at,
    })
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
    guard.remember_account(&profile).map_err(|e| e.to_string())?;
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

pub struct PlaylistDto {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub track_count: u64,
    /// 是否"我喜欢的音乐"
    pub special: bool,
}

fn with_provider(
    cap: Capability,
) -> Result<std::sync::Arc<dyn ncm_provider::Provider>, String> {
    let guard = core()?.lock().map_err(|e| e.to_string())?;
    guard
        .providers
        .first_with(cap)
        .ok_or_else(|| format!("no provider supports {}", cap.as_str()))
        .map(|p| p.clone())
}

/// "我喜欢的音乐"里的曲目 id(红心状态的唯一真相)
pub async fn liked_ids() -> Result<Vec<u64>, String> {
    let provider = with_provider(Capability::Playlist)?;
    let ids = provider.liked_ids().await.map_err(|e| e.to_string())?;
    Ok(ids.into_iter().map(|t| t.0).collect())
}

/// 红心/取消红心(需登录)
pub async fn set_liked(track_id: u64, liked: bool) -> Result<bool, String> {
    let provider = with_provider(Capability::Playlist)?;
    provider
        .set_like(ncm_domain::TrackId::new(track_id), liked)
        .await
        .map_err(|e| e.to_string())
}

/// 我的歌单(含"我喜欢的音乐")
pub async fn my_playlists() -> Result<Vec<PlaylistDto>, String> {
    let provider = with_provider(Capability::Playlist)?;
    let list = provider.user_playlists().await.map_err(|e| e.to_string())?;
    Ok(list
        .into_iter()
        .map(|p| PlaylistDto {
            id: p.id,
            name: p.name,
            cover_url: p.cover_url,
            track_count: p.track_count,
            special: p.special,
        })
        .collect())
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

/// "我喜欢的音乐"曲目详情(按红心时间倒序 = likelist 的顺序)
pub async fn liked_songs() -> Result<Vec<SongDto>, String> {
    let provider = with_provider(Capability::Playlist)?;
    let ids = provider.liked_ids().await.map_err(|e| e.to_string())?;
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    // 先把 id 拼成一次详情请求(vendor 的 song_detail 只认逗号分隔), 分块避免 URL 过长
    // 详情接口不保证按请求顺序返回(还可能缺曲), 用 id→Song 映射按 likelist 顺序还原
    let mut by_id: std::collections::HashMap<u64, ncm_domain::Song> =
        std::collections::HashMap::new();
    for chunk in ids.chunks(500) {
        let joined = chunk.iter().map(|t| t.0.to_string()).collect::<Vec<_>>().join(",");
        let detail = provider
            .songs_detail(&joined)
            .await
            .map_err(|e| e.to_string())?;
        for s in detail {
            by_id.insert(s.id.0, s);
        }
    }
    Ok(ids.iter().filter_map(|t| by_id.remove(&t.0)).map(song_dto).collect())
}

/// 一行歌词(已按时间排序, 翻译按时间戳对齐)
pub struct LyricLineDto {
    pub time_ms: u64,
    pub text: String,
    pub sub: Option<String>,
}

/// 解析好的歌词时间轴. UI 只需要按 position 找当前行, 不再自己啃 LRC.
pub async fn lyric_lines(track_id: u64) -> Result<Vec<LyricLineDto>, String> {
    let raw = lyric(track_id).await?;
    Ok(ncm_domain::parse_lrc_with_translation(&raw, None)
        .into_iter()
        .map(|l| LyricLineDto { time_ms: l.time_ms, text: l.text, sub: l.sub })
        .collect())
}

/// 带翻译的歌词时间轴(网易云 tlyric). 无翻译时等价于 lyric_lines.
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
    .map(|l| LyricLineDto { time_ms: l.time_ms, text: l.text, sub: l.sub })
    .collect())
}

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
