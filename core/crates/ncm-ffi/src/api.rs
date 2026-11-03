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
        songs: page
            .songs
            .into_iter()
            .map(|s| {
                let artist = s.artist_line();
                SongDto {
                    id: s.id.0,
                    name: s.name,
                    artist,
                    album: s.album.map(|a| a.name).unwrap_or_default(),
                    duration_ms: s.duration_ms,
                    fee: s.fee.unwrap_or(0),
                }
            })
            .collect(),
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
