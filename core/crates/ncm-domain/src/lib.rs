//! 领域模型: 纯数据, 无 IO, 无第三方协议依赖.
//!
//! 规则: 所有跨层传递的类型都定义在这里, 必须是可序列化的.
//! UI 只认这些类型, 不直接吃 provider 返回的原始 JSON.

use serde::{Deserialize, Serialize};

mod lrc;
pub use lrc::{parse_lrc, parse_lrc_with_translation, LyricLine};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TrackId(pub u64);

impl TrackId {
    pub fn new(v: u64) -> Self {
        Self(v)
    }
}

impl std::fmt::Display for TrackId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Artist {
    pub id: u64,
    pub name: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Album {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pic_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Song {
    pub id: TrackId,
    pub name: String,
    #[serde(default)]
    pub artists: Vec<Artist>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album: Option<Album>,
    /// 时长(毫秒)
    #[serde(default)]
    pub duration_ms: u64,
    /// 网易云计费标记: 0 免费 / 1 VIP / 4 付费专辑 / 8 低音质免费
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fee: Option<i64>,
}

impl Song {
    pub fn artist_line(&self) -> String {
        self.artists
            .iter()
            .map(|a| a.name.as_str())
            .collect::<Vec<_>>()
            .join(" / ")
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SearchPage {
    pub songs: Vec<Song>,
    pub total: u64,
    pub has_more: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct StreamUrl {
    /// None 表示当前账号/音质拿不到直链(版权或会员限制)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    pub quality: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub br: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
    /// 直链过期时间(unix 秒). 队列必须在到期前换链.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expire_at: Option<u64>,
}

impl StreamUrl {
    pub fn is_playable(&self) -> bool {
        self.url.as_deref().is_some_and(|u| !u.is_empty())
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Lyric {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lrc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub translated: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub romaji: Option<String>,
}

impl Lyric {
    pub fn is_empty(&self) -> bool {
        self.lrc.as_deref().unwrap_or("").is_empty()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Profile {
    pub user_id: u64,
    pub nickname: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
}

/// 一次登录的产物. 不论从哪个入口登录, 最终都落到这个结构.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Session {
    pub cookie: String,
    /// 52 位十六进制, 首次启动生成后永久复用
    pub device_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<Profile>,
}

impl Session {
    pub fn is_logged_in(&self) -> bool {
        self.cookie.contains("MUSIC_U=")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_url_playable() {
        let mut s = StreamUrl::default();
        assert!(!s.is_playable());
        s.url = Some(String::new());
        assert!(!s.is_playable());
        s.url = Some("http://x/y.mp3".into());
        assert!(s.is_playable());
    }

    #[test]
    fn session_detects_login() {
        let mut s = Session::default();
        assert!(!s.is_logged_in());
        s.cookie = "MUSIC_U=abc; os=pc".into();
        assert!(s.is_logged_in());
    }

    #[test]
    fn artist_line_joins() {
        let song = Song {
            id: TrackId::new(1),
            name: "n".into(),
            artists: vec![
                Artist { id: 1, name: "A".into() },
                Artist { id: 2, name: "B".into() },
            ],
            album: None,
            duration_ms: 0,
            fee: None,
        };
        assert_eq!(song.artist_line(), "A / B");
    }
}
