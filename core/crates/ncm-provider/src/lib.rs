//! 音源插件边界: Provider trait + 能力声明 + 注册表.
//!
//! 首版不实现脚本宿主, 但边界从第一天就固定:
//! - 出入参全是可序列化 DTO (见 ncm-domain)
//! - 错误统一成 ProviderError, UI 只按 kind 决策
//! - 未来加 QuickJS 时, 只需新增一个 ScriptProvider 实现本 trait

use ncm_domain::{Lyric, Playlist, Profile, SearchPage, Song, StreamUrl, TrackId};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Capability {
    Search,
    SongUrl,
    Lyric,
    Login,
    Profile,
    Playlist,
    DailyRecommend,
    PersonalFm,
}

impl Capability {
    pub fn as_str(&self) -> &'static str {
        match self {
            Capability::Search => "search",
            Capability::SongUrl => "songUrl",
            Capability::Lyric => "lyric",
            Capability::Login => "login",
            Capability::Profile => "profile",
            Capability::Playlist => "playlist",
            Capability::DailyRecommend => "dailyRecommend",
            Capability::PersonalFm => "personalFm",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AudioLevel {
    #[default]
    Standard,
    Higher,
    Exhigh,
    Lossless,
    Hires,
}

impl AudioLevel {
    pub fn as_str(&self) -> &'static str {
        match self {
            AudioLevel::Standard => "standard",
            AudioLevel::Higher => "higher",
            AudioLevel::Exhigh => "exhigh",
            AudioLevel::Lossless => "lossless",
            AudioLevel::Hires => "hires",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "standard" | "128k" => Some(AudioLevel::Standard),
            "higher" | "192k" => Some(AudioLevel::Higher),
            "exhigh" | "320k" => Some(AudioLevel::Exhigh),
            "lossless" | "flac" => Some(AudioLevel::Lossless),
            "hires" | "flac24bit" => Some(AudioLevel::Hires),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchQuery {
    pub keywords: String,
    pub limit: u32,
    pub offset: u32,
}

impl SearchQuery {
    pub fn new(keywords: impl Into<String>) -> Self {
        Self { keywords: keywords.into(), limit: 30, offset: 0 }
    }

    pub fn limit(mut self, v: u32) -> Self {
        self.limit = v;
        self
    }

    pub fn offset(mut self, v: u32) -> Self {
        self.offset = v;
        self
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct SongUrlRequest {
    pub track: TrackId,
    pub level: AudioLevel,
}

impl SongUrlRequest {
    pub fn new(track: TrackId) -> Self {
        Self { track, level: AudioLevel::default() }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderErrorKind {
    Network,
    Auth,
    RiskControl,
    NotFound,
    Unsupported,
    Internal,
}

impl ProviderErrorKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            ProviderErrorKind::Network => "network",
            ProviderErrorKind::Auth => "auth",
            ProviderErrorKind::RiskControl => "riskControl",
            ProviderErrorKind::NotFound => "notFound",
            ProviderErrorKind::Unsupported => "unsupported",
            ProviderErrorKind::Internal => "internal",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderError {
    pub kind: ProviderErrorKind,
    pub retryable: bool,
    pub detail: String,
}

impl ProviderError {
    pub fn new(kind: ProviderErrorKind, retryable: bool, detail: impl Into<String>) -> Self {
        Self { kind, retryable, detail: detail.into() }
    }

    pub fn network(detail: impl Into<String>) -> Self {
        Self::new(ProviderErrorKind::Network, true, detail)
    }

    pub fn auth(detail: impl Into<String>) -> Self {
        Self::new(ProviderErrorKind::Auth, false, detail)
    }

    pub fn risk_control(detail: impl Into<String>) -> Self {
        Self::new(ProviderErrorKind::RiskControl, false, detail)
    }

    pub fn not_found(detail: impl Into<String>) -> Self {
        Self::new(ProviderErrorKind::NotFound, false, detail)
    }

    pub fn unsupported(detail: impl Into<String>) -> Self {
        Self::new(ProviderErrorKind::Unsupported, false, detail)
    }

    pub fn internal(detail: impl Into<String>) -> Self {
        Self::new(ProviderErrorKind::Internal, false, detail)
    }
}

impl std::fmt::Display for ProviderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.kind.as_str(), self.detail)
    }
}

impl std::error::Error for ProviderError {}

pub type ProviderResult<T> = Result<T, ProviderError>;

pub trait Provider: Send + Sync {
    fn id(&self) -> &'static str;
    fn name(&self) -> &str;
    fn capabilities(&self) -> &'static [Capability];

    fn supports(&self, cap: Capability) -> bool {
        self.capabilities().contains(&cap)
    }

    fn search<'a>(&'a self, query: &'a SearchQuery) -> BoxFuture<'a, ProviderResult<SearchPage>>;

    fn song_url<'a>(&'a self, req: &'a SongUrlRequest) -> BoxFuture<'a, ProviderResult<StreamUrl>>;

    fn lyric<'a>(&'a self, track: TrackId) -> BoxFuture<'a, ProviderResult<Lyric>>;

    /// 当前登录账号的资料(uid/昵称/VIP). 未登录或不支持时返回 Unsupported.
    fn profile<'a>(&'a self) -> BoxFuture<'a, ProviderResult<Profile>> {
        Box::pin(async { Err(ProviderError::unsupported("no profile")) })
    }

    /// "我喜欢的音乐"里的曲目 id(用于红心状态)
    fn liked_ids<'a>(&'a self) -> BoxFuture<'a, ProviderResult<Vec<TrackId>>> {
        Box::pin(async { Err(ProviderError::unsupported("no liked ids")) })
    }

    /// 红心/取消红心. 返回 true 表示操作被接受.
    fn set_like<'a>(&'a self, _track: TrackId, _liked: bool) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no like")) })
    }

    /// 当前账号的歌单列表(含"我喜欢的音乐")
    fn user_playlists<'a>(&'a self) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlists")) })
    }

    /// 某个歌单的曲目
    fn playlist_songs<'a>(&'a self, _playlist_id: u64) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist songs")) })
    }

    /// 批量取曲目详情(逗号分隔的 id)
    fn songs_detail<'a>(&'a self, _ids: &'a str) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no song detail")) })
    }
}

#[derive(Default, Clone)]
pub struct ProviderRegistry {
    providers: Vec<Arc<dyn Provider>>,
    by_id: HashMap<&'static str, usize>,
}

impl ProviderRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, provider: Arc<dyn Provider>) -> &mut Self {
        let id = provider.id();
        if self.by_id.contains_key(id) {
            return self;
        }
        self.by_id.insert(id, self.providers.len());
        self.providers.push(provider);
        self
    }

    pub fn get(&self, id: &str) -> Option<Arc<dyn Provider>> {
        self.by_id.get(id).and_then(|i| self.providers.get(*i)).cloned()
    }

    pub fn all(&self) -> &[Arc<dyn Provider>] {
        &self.providers
    }

    /// 按注册顺序找第一个支持该能力的 provider
    pub fn first_with(&self, cap: Capability) -> Option<Arc<dyn Provider>> {
        self.providers.iter().find(|p| p.supports(cap)).cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ncm_domain::{SearchPage, StreamUrl};

    struct Dummy;

    impl Provider for Dummy {
        fn id(&self) -> &'static str {
            "dummy"
        }
        fn name(&self) -> &str {
            "Dummy"
        }
        fn capabilities(&self) -> &'static [Capability] {
            &[Capability::Search]
        }
        fn search<'a>(&'a self, _q: &'a SearchQuery) -> BoxFuture<'a, ProviderResult<SearchPage>> {
            Box::pin(async { Ok(SearchPage::default()) })
        }
        fn song_url<'a>(&'a self, _r: &'a SongUrlRequest) -> BoxFuture<'a, ProviderResult<StreamUrl>> {
            Box::pin(async { Err(ProviderError::unsupported("no songUrl")) })
        }
        fn lyric<'a>(&'a self, _t: TrackId) -> BoxFuture<'a, ProviderResult<Lyric>> {
            Box::pin(async { Err(ProviderError::unsupported("no lyric")) })
        }
    }

    #[test]
    fn registry_and_capabilities() {
        let mut reg = ProviderRegistry::new();
        reg.register(Arc::new(Dummy));
        assert!(reg.get("dummy").is_some());
        assert!(reg.first_with(Capability::Search).is_some());
        assert!(reg.first_with(Capability::Lyric).is_none());
        assert_eq!(AudioLevel::parse("hires"), Some(AudioLevel::Hires));
    }
}
