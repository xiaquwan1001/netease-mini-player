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
    /// 是否可播(版权). 网易云 privilege.st < 0(-200 = 无版权) 时官方灰显并弹提示,
    /// 老数据/接口不给 privilege 时按可播处理.
    #[serde(default = "default_true")]
    pub playable: bool,
}

fn default_true() -> bool {
    true
}

impl Song {
    /// VIP 专属(高音质需会员): 网易云 fee=1 是会员曲, fee=8 是"标准音质免费"。
    pub fn is_vip(&self) -> bool {
        matches!(self.fee, Some(1) | Some(8))
    }

    /// 需要单独购买的数字专辑
    pub fn is_paid(&self) -> bool {
        matches!(self.fee, Some(4))
    }

    pub fn artist_line(&self) -> String {
        self.artists
            .iter()
            .map(|a| a.name.as_str())
            .collect::<Vec<_>>()
            .join(" / ")
    }

    /// 专辑封面(列表/播放条/预览统一从这里取)
    pub fn cover_url(&self) -> Option<String> {
        self.album.as_ref().and_then(|a| a.pic_url.clone())
    }

    /// 专辑 id(0 = 未知)
    pub fn album_id(&self) -> u64 {
        self.album.as_ref().map(|a| a.id).unwrap_or(0)
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
    /// 黑胶/音乐包会员(vipType > 0). 老数据没有这个字段, 默认为 false.
    #[serde(default)]
    pub vip: bool,
}

/// 账号下的歌单(我喜欢的音乐也在里面, 名称固定/specialType=5)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Playlist {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub track_count: u64,
    /// 是否是"我喜欢的音乐"(网易云用 specialType=5 标记)
    #[serde(default)]
    pub special: bool,
}

/// 歌单详情(歌单页头部信息)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlaylistDetail {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub creator_name: String,
    #[serde(default)]
    pub track_count: u64,
    #[serde(default)]
    pub play_count: u64,
    /// 当前账号是否已收藏(匿名恒为 false)
    #[serde(default)]
    pub subscribed: bool,
    #[serde(default)]
    pub subscribed_count: u64,
    #[serde(default)]
    pub share_count: u64,
    #[serde(default)]
    pub comment_count: u64,
    #[serde(default)]
    pub tags: Vec<String>,
}

/// 专辑详情(封面预览用: 大图 + 曲目列表)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlbumDetail {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub songs: Vec<Song>,
}

/// 播客/电台(网易云叫"电台/播客", 接口是 djradio)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PodcastRadio {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub dj_name: String,
    #[serde(default)]
    pub program_count: u64,
    #[serde(default)]
    pub play_count: u64,
}

/// 播客单集(节目). 音频本体是 mainSong, 播放时用 song.id 取直链.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PodcastProgram {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub duration_ms: u64,
    #[serde(default)]
    pub dj_name: String,
    #[serde(default)]
    pub radio_id: u64,
    #[serde(default)]
    pub radio_name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub song: Option<Song>,
}

/// 搜索建议条目(kind = song / artist / album / playlist)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SuggestItem {
    pub kind: String,
    pub id: u64,
    pub title: String,
    #[serde(default)]
    pub subtitle: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
}

/// 搜索热词(rank 从 1 开始, 按接口返回顺序排列)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HotSearchTerm {
    pub rank: u32,
    pub keyword: String,
}

/// 关注动态(艺人/好友发布的内容). kind 是网易云 eventType 的语义化标签:
/// song / album / playlist / program / text / other
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedEvent {
    pub id: u64,
    pub kind: String,
    /// 发布者昵称(关注的艺人名就是这里)
    pub user_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    /// 动态正文/配文(可能为空)
    #[serde(default)]
    pub text: String,
    /// 附带曲目(分享单曲时)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub song: Option<Song>,
    /// 封面(专辑/歌单/单曲封面或动态配图第一张)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    /// 配图(最多 3 张, 由 provider 截断)
    #[serde(default)]
    pub images: Vec<String>,
    /// 发布时间(unix 毫秒)
    #[serde(default)]
    pub time_ms: u64,
}

/// 一条评论(歌曲/歌单/专辑/播客共用)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Comment {
    pub id: u64,
    pub user_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    pub content: String,
    /// 发布时间(unix 毫秒)
    #[serde(default)]
    pub time_ms: u64,
    #[serde(default)]
    pub liked_count: u64,
    #[serde(default)]
    pub liked: bool,
}

/// 评论列表页. comments 里精彩评论在前(hotComments), 其后是最新评论, 按 commentId 去重.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommentPage {
    /// 精彩评论在前(hotComments), 其后是最新评论, 按 commentId 去重
    #[serde(default)]
    pub comments: Vec<Comment>,
    #[serde(default)]
    pub total: u64,
    #[serde(default)]
    pub has_more: bool,
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
            playable: true,
        };
        assert_eq!(song.artist_line(), "A / B");
    }
}
