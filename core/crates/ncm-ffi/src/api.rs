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
