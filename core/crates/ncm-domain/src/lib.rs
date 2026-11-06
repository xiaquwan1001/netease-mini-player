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
    /// 头像(关注艺人列表/歌手搜索结果才有)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
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
    /// VIP 专属: 只有 fee=1 是会员曲。
    /// fee=8 是"低音质(128k)免费"——非会员也能完整播放, 不能标 VIP
    /// (2026-11-06 修复: 之前把 8 也算进来, 导致大部分免费歌被误标 VIP)。
    pub fn is_vip(&self) -> bool {
        matches!(self.fee, Some(1))
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

/// 搜索命中的歌手(带头像, 搜索结果分区用)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchArtist {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    #[serde(default)]
    pub alias: String,
    #[serde(default)]
    pub album_count: u64,
    #[serde(default)]
    pub music_count: u64,
}

/// 搜索命中的专辑(带封面)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchAlbum {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub track_count: u64,
}

/// 搜索命中的歌单(带封面)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchPlaylistItem {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub creator_name: String,
    #[serde(default)]
    pub track_count: u64,
    #[serde(default)]
    pub play_count: u64,
}

/// 搜索命中的播客/电台(带封面)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchPodcast {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub dj_name: String,
    #[serde(default)]
    pub program_count: u64,
    #[serde(default)]
    pub play_count: u64,
}

/// 一次"综合搜索"的结果: 每个类型一个板块.
/// 网易云 cloudsearch 的 type: 1 单曲 / 10 专辑 / 100 歌手 / 1000 歌单 / 1009 播客.
/// (type=2000 声音/节目实测返回空, 本接口不支持节目搜索.)
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SearchBundle {
    #[serde(default)]
    pub songs: Vec<Song>,
    #[serde(default)]
    pub song_total: u64,
    #[serde(default)]
    pub artists: Vec<SearchArtist>,
    #[serde(default)]
    pub albums: Vec<SearchAlbum>,
    #[serde(default)]
    pub playlists: Vec<SearchPlaylistItem>,
    #[serde(default)]
    pub podcasts: Vec<SearchPodcast>,
}

impl SearchBundle {
    pub fn is_empty(&self) -> bool {
        self.songs.is_empty()
            && self.artists.is_empty()
            && self.albums.is_empty()
            && self.playlists.is_empty()
            && self.podcasts.is_empty()
    }
}

/// 专辑简介(歌手页/搜索结果用, 只有展示必需字段)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlbumBrief {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub track_count: u64,
    #[serde(default)]
    pub publish_time: u64,
}

/// 歌手详情(歌手页头部 + 热门歌曲 + 专辑)
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ArtistDetail {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    /// 歌手页大图(横幅)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub alias: Vec<String>,
    #[serde(default)]
    pub brief_desc: String,
    #[serde(default)]
    pub album_count: u64,
    #[serde(default)]
    pub music_count: u64,
    #[serde(default)]
    pub songs: Vec<Song>,
    #[serde(default)]
    pub albums: Vec<AlbumBrief>,
}

/// 账号资料详情(个人主页: 背景图 + 头像 + 签名 + 关注数)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProfileDetail {
    pub user_id: u64,
    pub nickname: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background_url: Option<String>,
    #[serde(default)]
    pub signature: String,
    #[serde(default)]
    pub vip: bool,
    #[serde(default)]
    pub follows: u64,
    #[serde(default)]
    pub followeds: u64,
    #[serde(default)]
    pub level: u64,
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
    /// 创建者 uid(0 = 未知). 与当前账号 uid 相同即可编辑歌单
    #[serde(default)]
    pub creator_id: u64,
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
    /// 评论/点赞用的 threadId(形如 A_EV_2_<eventId>_<userId>)
    #[serde(default)]
    pub thread_id: String,
    /// 发布者的用户 id(艺人/好友都按用户维度区分)
    #[serde(default)]
    pub user_id: u64,
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
    /// 配图(最多 9 张, 由 provider 截断)
    #[serde(default)]
    pub images: Vec<String>,
    /// 动态里的视频直链(视频动态才有)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_url: Option<String>,
    /// 动态自带的标题(艺人发的长文常用; 为空就是没有)
    #[serde(default)]
    pub title: String,
    /// 发布时间(unix 毫秒)
    #[serde(default)]
    pub time_ms: u64,
    /// 当前账号是否已赞
    #[serde(default)]
    pub liked: bool,
    #[serde(default)]
    pub liked_count: u64,
    /// 转发/分享数
    #[serde(default)]
    pub share_count: u64,
    /// 评论数
    #[serde(default)]
    pub comment_count: u64,
}

/// "猜你想搜": keyword 才是真正要搜的词, show 是官方给的推荐理由/文案
/// (形如 "🔥The Weeknd 最近很火哦"), UI 必须把两者分开显示.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DefaultSearch {
    pub keyword: String,
    /// 官方展示文案(含推荐理由). 不能叫 show: Dart 里 show 是关键字, 桥接会变成 show_
    #[serde(default, rename = "show")]
    pub show_text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_url: Option<String>,
}

/// 一条评论(歌曲/歌单/专辑/播客共用)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Comment {
    pub id: u64,
    /// 评论者 uid(0 = 未知), 用于跳用户主页/判断是不是自己发的
    #[serde(default)]
    pub user_id: u64,
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
    /// 该评论下有多少条回复(>0 才显示"回复 N")
    #[serde(default)]
    pub reply_count: u64,
}

/// 评论列表页. comments 里精彩评论在前(hotComments), 其后是最新评论, 按 commentId 去重.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommentPage {
    /// 这条评论线程的 threadId(A_EV_2_.../R_SO_4_...), 点赞/回复都要用它
    #[serde(default)]
    pub thread_id: String,
    /// 精彩评论在前(hotComments), 其后是最新评论, 按 commentId 去重
    #[serde(default)]
    pub comments: Vec<Comment>,
    #[serde(default)]
    pub total: u64,
    #[serde(default)]
    pub has_more: bool,
}

/// 听歌排行的一项. 总量榜与周榜共用同一结构, 顺序即名次(接口已排好序).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlayRankEntry {
    pub song: Song,
    /// 播放次数(周榜是本周播放次数)
    #[serde(default)]
    pub play_count: u64,
    /// 网易云给的推荐分值(越大越靠前), 与 play_count 不完全一致
    #[serde(default)]
    pub score: u64,
}

/// 曲风/风格标签: 推荐页的"风格入口"与风格详情页共用.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct StyleTag {
    /// 网易云的 tagId(接口按字符串传, 数字在 JSON 里可能带/不带引号)
    pub id: String,
    pub name: String,
    /// 曲风配图(体系标签才有)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    /// 该曲风下曲目总数(部分接口不给)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub song_count: Option<u64>,
}

/// 排行榜(榜单)摘要: 热歌榜/飙升榜/新歌榜…
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChartSummary {
    /// 榜单是歌单, 这个 id 可以直接喂给 playlist_detail / playlist_songs
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    /// "每周四更新" / "刚刚更新" / "更新17首"
    #[serde(default)]
    pub update_frequency: String,
    #[serde(default)]
    pub track_count: u64,
    #[serde(default)]
    pub play_count: u64,
}

/// 歌单分类: 一级分类(语种/风格/场景/情感/主题) + 其下子分类名
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlaylistCategory {
    pub group: String,
    #[serde(default)]
    pub subs: Vec<String>,
}

/// 用户条目(关注/粉丝列表): 头像/昵称/签名
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UserItem {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    #[serde(default)]
    pub signature: String,
    /// 当前账号是否已关注 ta(粉丝列表里接口不给, 按 false 处理)
    #[serde(default)]
    pub followed: bool,
}

/// 关注/粉丝数
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct FollowCount {
    #[serde(default)]
    pub follows: u64,
    #[serde(default)]
    pub fans: u64,
}

/// 专辑条目: 收藏专辑列表/搜索结果共用(比 AlbumBrief 多歌手名)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlbumItem {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub track_count: u64,
}

/// 未读消息计数(私信/通知/评论/@我). 未登录或接口失败时为全 0.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageCounts {
    /// 私信会话未读数
    pub private: u32,
    /// 通知(点赞/关注/系统通知)
    pub notices: u32,
    /// 评论/回复
    pub comments: u32,
    /// @我
    pub forwards: u32,
}

impl MessageCounts {
    pub fn total(&self) -> u32 {
        self.private + self.notices + self.comments + self.forwards
    }
}

/// 私信会话列表的一行
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrivateSession {
    /// 对方 uid
    pub user_id: u64,
    pub nickname: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    /// 最后一条消息的纯文本(富消息取标题/摘要)
    #[serde(default)]
    pub last_message: String,
    #[serde(default)]
    pub last_time_ms: u64,
    #[serde(default)]
    pub unread: u32,
}

/// 一段私信会话里的一条消息
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrivateMessage {
    pub id: u64,
    /// 我发的(true)还是对方发的(false)
    pub from_me: bool,
    pub nickname: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    pub content: String,
    #[serde(default)]
    pub time_ms: u64,
}

/// 通知/评论这类"通知流"里的一行(结构统一, 便于一个列表渲染)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct InboxItem {
    pub id: u64,
    /// notice | comment
    pub kind: String,
    /// 触发人昵称(系统通知可能为空)
    #[serde(default)]
    pub actor: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    /// 主体文案(通知=动作描述, 评论=评论内容)
    #[serde(default)]
    pub text: String,
    /// 附注(评论=被评论的资源名或我的原评论; 通知=内容摘要)
    #[serde(default)]
    pub detail: String,
    #[serde(default)]
    pub time_ms: u64,
}

/// 签到日历里的一天
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SigninDay {
    /// yyyy-mm-dd
    pub day: String,
    pub signed: bool,
}

/// 签到状态(云贝签到). 进度接口给的是"累计/每周/连续"三套计数, 这里挑常用字段.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SigninStatus {
    /// 今天是否已签到
    pub signed_today: bool,
    /// 累计签到天数(不循环)
    pub total_days: u32,
    /// 连续签到天数(28 天循环内的当前进度)
    pub continuous_days: u32,
    /// 本周签到天数(周一到周日)
    pub week_days: u32,
    /// 最近若干天的签到情况(新的在前)
    #[serde(default)]
    pub recent: Vec<SigninDay>,
    /// 本次签到得到的云贝(只有刚签完才有值)
    #[serde(default)]
    pub today_point: u32,
}

/// 歌曲百科的一条信息(曲风/语种/BPM/获奖成就...).
/// 接口是"装修块 + 富文本"结构, 这里压成 label/value 对, UI 直接两列渲染.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WikiFact {
    /// 分组名(曲风/语种/BPM/...)
    pub label: String,
    /// 值(多个用 " / " 拼好)
    pub value: String,
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
    fn fee8_is_not_vip() {
        let mut s = Song {
            id: TrackId::new(1),
            name: "n".into(),
            artists: vec![],
            album: None,
            duration_ms: 0,
            fee: Some(8),
            playable: true,
        };
        assert!(!s.is_vip());
        s.fee = Some(1);
        assert!(s.is_vip());
        s.fee = Some(4);
        assert!(!s.is_vip());
        assert!(s.is_paid());
    }

    #[test]
    fn artist_line_joins() {
        let song = Song {
            id: TrackId::new(1),
            name: "n".into(),
            artists: vec![
                Artist { id: 1, name: "A".into(), avatar_url: None },
                Artist { id: 2, name: "B".into(), avatar_url: None },
            ],
            album: None,
            duration_ms: 0,
            fee: None,
            playable: true,
        };
        assert_eq!(song.artist_line(), "A / B");
    }
}
