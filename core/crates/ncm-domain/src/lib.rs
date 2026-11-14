//! 领域模型: 纯数据, 无 IO, 无第三方协议依赖.
//!
//! 规则: 所有跨层传递的类型都定义在这里, 必须是可序列化的.
//! UI 只认这些类型, 不直接吃 provider 返回的原始 JSON.

use serde::{Deserialize, Serialize};

mod eq_profile;
mod lrc;
mod playlist_edit;
mod ttml;
mod word_lyric;
/// 一次响度测量的结果(R2b/R7 的 ReplayGain 输入).
///
/// 只对首播后台测一次并缓存在 `loudness.json`(key = trackId), 未测曲目按 0 dB 播放。
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct TrackLoudness {
    /// integrated loudness(LUFS, BS.1770-4)
    #[serde(default)]
    pub lufs: f32,
    /// 样本峰值(线性 0..1; 未做过采样, 与真峰值差 <1 dB)
    #[serde(default)]
    pub sample_peak: f32,
    /// 测量时间(unix 毫秒)
    #[serde(default)]
    pub measured_at_ms: u64,
}

pub use eq_profile::{
    EqFilter, EqFilterKind, EqProfile, EqProfileError, MAX_FILTERS, MAX_FREQ_HZ, MAX_GAIN_DB,
};
pub use lrc::{parse_lrc, parse_lrc_with_translation, LyricLine};
pub use playlist_edit::{CreatedPlaylist, PlaylistEditResult};
pub use ttml::{parse_ttml, parse_ttml_time, TtmlLine, TtmlWord};
pub use word_lyric::{
    parse_word_lyric, parse_word_lyric_with_translation, WordItem, WordLyric, WordLyricLine,
};

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

/// 搜索命中的 MV(cloudsearch type=1004 的 result.mvs)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MvItem {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub artist_name: String,
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
    /// 用户(type=1002 的 userprofiles)
    #[serde(default)]
    pub users: Vec<UserItem>,
    /// MV(type=1004 的 mvs)
    #[serde(default)]
    pub mvs: Vec<MvItem>,
}

impl SearchBundle {
    pub fn is_empty(&self) -> bool {
        self.songs.is_empty()
            && self.artists.is_empty()
            && self.albums.is_empty()
            && self.playlists.is_empty()
            && self.podcasts.is_empty()
            && self.mvs.is_empty()
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

/// 歌手全部歌曲一页(artist_songs: offset/limit 分页, more=还有下一页)
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ArtistSongPage {
    #[serde(default)]
    pub songs: Vec<Song>,
    #[serde(default)]
    pub has_more: bool,
}

/// 歌手专辑一页(artist_album: offset/limit 分页, more=还有下一页)
///
/// 之前「全部 N 张」只有 artist_detail 带的固定 20 张(limit=20 且无分页),
/// 与头部 albumSize 对不上; 现在专辑 tab 走这个分页接口。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtistAlbumPage {
    #[serde(default)]
    pub albums: Vec<AlbumBrief>,
    #[serde(default)]
    pub has_more: bool,
}

/// 歌手 MV 条目(artist_mv 的 mvs[] 子集)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtistMv {
    pub id: u64,
    pub name: String,
    /// 时长(毫秒)
    #[serde(default)]
    pub duration_ms: u64,
    #[serde(default)]
    pub play_count: u64,
    /// 发布日期字符串, 原样展示(如 "2025-02-23")
    #[serde(default)]
    pub publish_time: String,
    /// 16:9 封面(imgurl16v9), 列表用
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
}

/// 歌手 MV 一页(artist_mv: offset/limit 分页, hasMore=还有下一页)
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ArtistMvPage {
    #[serde(default)]
    pub mvs: Vec<ArtistMv>,
    #[serde(default)]
    pub has_more: bool,
}

/// MV 详情(mv_detail 的 data 子集)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MvDetail {
    pub id: u64,
    pub name: String,
    #[serde(default)]
    pub artist_name: String,
    /// 时长(毫秒)
    #[serde(default)]
    pub duration_ms: u64,
    #[serde(default)]
    pub play_count: u64,
    /// 发布日期字符串, 原样展示(如 "1997-10-01")
    #[serde(default)]
    pub publish_time: String,
    /// 封面(data.cover)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    /// 可用最高清晰度(brs[] 里最大的 br, 如 240/480/720/1080)
    #[serde(default)]
    pub max_br: u32,
    /// 可用清晰度列表(brs[].br 升序)
    #[serde(default)]
    pub brs: Vec<u32>,
    /// 简介(可空)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub desc: Option<String>,
}

/// MV 播放链接(mv_url 的 data 子集)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MvUrl {
    /// 签名直链(http/https mp4, expi=3600 秒)
    pub url: Option<String>,
    /// 实际返回的清晰度档位
    #[serde(default)]
    pub r: u32,
    /// 文件字节数
    #[serde(default)]
    pub size: u64,
}

/// 账号资料详情(个人主页: 背景图 + 头像 + 签名 + 关注数)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProfileDetail {
    pub user_id: u64,
    /// 音乐人身份对应的**艺人 id**(user_detail 的 profile.artistId);
    /// 普通用户没有这个字段 ⇒ None。user id 与 artist id 是两个 id 空间,
    /// 头像点击要靠它决定进用户主页还是艺人主页(见 ui/lib/src/user_nav.dart)。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist_id: Option<u64>,
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
    /// 是否是"我收藏的"(true)/ "我创建的"(false). 接口字段 subscribed;
    /// 缺失(部分端点不给)按 false 处理, 即归到"创建"侧.
    #[serde(default)]
    pub subscribed: bool,
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

/// 精确实体改写(对应 vendor 的 `search_multimatch`, 端点 /api/search/suggest/multimatch w/ eapi).
///
/// 语义: 输入一个关键词, 服务端只在「歌手/歌单/电台节目」里挑**最精确的实体**回 1 条,
/// 不是模糊多类型搜索。实测(2026-11-07):
/// - `orders` 是命中类型的展示顺序, 同时是「有哪些字段」的清单;
///   出现过的值: `artist` / `playlist` / `voice`(另按 vendor 约定可能有 song/album/djRadio, 不可依赖)。
/// - **空命中伪装成功**: 完全无命中时回 `{"code":200,"result":{"orders":[]}}`,
///   各类型 key 直接不存在。所以消费方必须按 `orders.is_empty()` 判空, 不能看 key 存在与否。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchExact {
    /// 命中类型顺序, 原样保留服务端字符串(artist/playlist/voice/...)
    #[serde(default)]
    pub orders: Vec<String>,
    #[serde(default)]
    pub artists: Vec<Artist>,
    #[serde(default)]
    pub playlists: Vec<Playlist>,
    #[serde(default)]
    pub podcasts: Vec<PodcastRadio>,
}

impl SearchExact {
    /// 无命中(空命中伪装成 200 时用它)
    pub fn is_empty(&self) -> bool {
        self.orders.is_empty()
            && self.artists.is_empty()
            && self.playlists.is_empty()
            && self.podcasts.is_empty()
    }
}

/// 热搜榜详情行(对应 vendor 的 `search_hot_detail`, 端点 /api/hotsearchlist/get w/ eapi).
///
/// 实测(2026-11-07, debug 构建已登录设备): `POST /api/hotsearchlist/get`, body `{}`, 返回
/// `{code:200, data:[{searchWord, score, iconType, iconUrl, content, source, url, alg?, trp?}]}`,
/// 固定 20 条; **服务端不给 rank 字段**, 排名就是数组下标(解析时按顺序写 1..=n)。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HotSearchDetailItem {
    /// 要展示/可搜索的词(接口字段 searchWord, 可能带空格如 `"无 意"`, 原样保留)
    pub keyword: String,
    /// 榜位, 从 1 开始(数组下标推导)
    pub rank: u32,
    /// 热度分(接口字段 score, 实测 5 位数)
    #[serde(default)]
    pub score: u64,
    /// 图标种类(接口字段 iconType: 0 = 无图标, 2/4/5 = 火焰/推荐等; 未知值原样保留)
    #[serde(default)]
    pub icon_type: u32,
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

/// 关注动态的一页: 事件列表 + 真实翻页游标.
///
/// 上游 /api/v1/event/get 的响应里带 `lasttime` 与 `more`: 把本页的 lasttime 原样
/// 回传就能拿下一页(时间倒序), more=false 表示到底了. 之前忽略这两个字段,
/// 每次都只能看到最新一页.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FeedPage {
    #[serde(default)]
    pub events: Vec<FeedEvent>,
    /// 下一页游标(原样回传给 provider; 0 = 上游没给, 不能翻页)
    #[serde(default)]
    pub last_time: i64,
    /// 是否还有下一页
    #[serde(default)]
    pub more: bool,
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
    /// IP 归属地(接口给的 `ipLocation.location`, 如 "广东"); 精彩评论通常为空
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub ip_location: String,
    /// 是否来自精彩评论(`hotComments`). 接口把精彩评论和最新评论混在一页返回, 靠它区分
    #[serde(default)]
    pub hot: bool,
    /// 这条评论回复的是谁(被回复者昵称). 楼层/回复里 `beReplied[0].user.nickname`;
    /// None = 直接评论资源本身(顶层评论). UI 靠它区分"回复 @某人"与独立评论.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replied_to: Option<String>,
    /// 所属主评论 id(0 = 自己没有父级). 楼层接口给的 `parentCommentId`;
    /// 回复自己的评论时父级就是这条评论自己.
    #[serde(default)]
    pub parent_id: u64,
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

/// 评论统计(评论页/详情页标题上的「N 评论 · N 分享 · N 点赞」).
///
/// 来源: `/api/resource/commentInfo/list`(vendor `comment_info_list`, weapi)。**实测形状**
/// (2026-11-09, 匿名/登录态一致):
/// 入参是 `type`(资源类型 **数字**, 对应 `RESOURCE_TYPE_MAP`: 0=歌曲 1=MV 2=歌单 3=专辑
/// 4=播客 5=视频 6=动态 7=节目)+ `ids`(逗号分隔的若干 id), **不是 threadId**; 传 threadId 只会
/// 得到 200 + 空数组。响应 `data` 是**数组**, 每个请求 id 一项:
/// `{commentCount, commentCountDesc, commentUpgraded, comments, latestLikedUsers, liked,
///   likedCount, musicianSaidCount, resourceId, resourceType, shareCount, threadId}`。
///
/// 与工单草案的差异(按实测裁剪, 不按文档猜):
/// - **没有 `subscribedCount`**(收藏数不在这个接口; 歌单的收藏数仍走 `PlaylistDetail`);
/// - **没有 `hotCount`**(热门评论数不存在, 精彩评论靠 `comment_hot` 单独拉);
/// - `likedCount` 实测是**这条评论线程本身被点赞数**(歌曲 186016 = 352, 歌单/播客/视频为 0),
///   与"分享数 `shareCount`"并列存在, 保留;
/// - `resourceType` 是**服务端归一后的子类型**(歌曲=4, 专辑=3, 歌单=0, 播客=1, 视频=62),
///   与请求的 `type` 数值不同, 不要拿来当入参; `threadId` 才是权威 threadId(与请求保持一致)。
/// - `commentCountDesc` 是官方展示文案("100w+"/"999+"/空串), 数字过大时用它更接近官方观感。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommentStats {
    /// 评论线程 id(R_SO_4_/A_PL_0_/R_AL_3_/A_DJ_1_/R_VI_62_…), 与请求一致
    #[serde(default)]
    pub thread_id: String,
    /// 资源 id(原样回显请求的 id)
    #[serde(default)]
    pub resource_id: u64,
    /// 评论总数
    #[serde(default)]
    pub comment_count: u64,
    /// 评论数的官方展示文案, 如 "100w+"/"999+"(少评论时为空串)
    #[serde(default)]
    pub comment_count_desc: String,
    /// 分享数
    #[serde(default)]
    pub share_count: u64,
    /// 该 thread 被点赞数
    #[serde(default)]
    pub liked_count: u64,
    /// 当前账号是否点过赞(匿名恒 false)
    #[serde(default)]
    pub liked: bool,
    /// 作者(= 歌手/创作者)参与评论数
    #[serde(default)]
    pub musician_said_count: u64,
    /// 评论区是否已升级到新版(服务端灰度开关, 实测恒 false)
    #[serde(default)]
    pub comment_upgraded: bool,
}

/// 单曲"喜欢"状态 + 喜欢总数(官方 App 的 `/api/song/like/get`).
///
/// 响应形如 `{code:200, liked:false, likedCount:352}`; **需要登录**, 匿名回 301。
/// 注意与 [`CommentStats::liked_count`] 区分: 那个是**评论线程**被点赞数,
/// 这里是**歌曲**被多少人喜欢(播放页 ♥ 旁边的那个数字)。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SongLikeState {
    /// 当前账号是否喜欢了这首歌
    #[serde(default)]
    pub liked: bool,
    /// 喜欢这首歌的人数
    #[serde(default)]
    pub liked_count: u64,
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

/// 榜单 v2 目录里的一张榜单卡(toplist_detail_v2 的 data[].list[]).
/// 实测(2026-11-09): v2 **没有** v1 的 trackUpdateTime/trackNumberUpdateTime 数字字段,
/// "更新 N 首"只以字符串形式混在 updateFrequency(如 "更新18首"/"刚刚更新");
/// 增强点是「按 categoryCode 分组 + canPlay + targetType(个别卡 id=0 且不可播)」.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToplistCatalogItem {
    /// 榜单 id(榜单本身还是歌单, 可喂 playlist_detail)
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    /// "每周五更新"
    #[serde(default)]
    pub update_frequency: String,
    /// 实测恒 "PLAYLIST"
    #[serde(default)]
    pub target_type: String,
    #[serde(default)]
    pub can_play: bool,
}

/// 榜单 v2 目录的一个分组(实测顺序: TOPPING/OFFICIAL/FEATURE/MUSIC_STYLE/GLOBAL/LANGUAGE/MORE)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToplistCatalogGroup {
    /// 服务端的分组代码(大写英文), 接口不给中文名
    pub code: String,
    #[serde(default)]
    pub items: Vec<ToplistCatalogItem>,
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

/// 一行云盘歌曲(音乐云盘: 用户自己上传的文件).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CloudSong {
    /// 云盘条目 id(user_cloud 的 data[].id) —— 删除用的就是它, 不是 song_id
    pub id: u64,
    /// 歌曲 id(播放/详情用; 老数据可能只有 simpleSong.id)
    #[serde(default)]
    pub song_id: u64,
    #[serde(default)]
    pub name: String,
    /// 歌手名(多歌手用 " / " 拼接, 展示用)
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub album: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    /// 文件字节数
    #[serde(default)]
    pub size: u64,
    /// 码率(bps)
    #[serde(default)]
    pub bitrate: u64,
    /// 上传时间(unix 毫秒)
    #[serde(default)]
    pub add_time: u64,
}

/// 云盘列表页: 分页游标就是 offset, 由调用方自己加.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CloudPage {
    #[serde(default)]
    pub songs: Vec<CloudSong>,
    /// 云盘总曲目数(上游 count)
    #[serde(default)]
    pub count: u64,
    /// 云盘已用字节(上游 size)
    #[serde(default)]
    pub size: u64,
    /// 云盘容量上限字节(上游 maxSize; 0 = 未知)
    #[serde(default)]
    pub max_size: u64,
    /// 同 CloudSong: 本页是否还有下一页(上游 more)
    #[serde(default)]
    pub more: bool,
}

/// 云盘上传结果(cloud_upload): 新歌在云盘的 songId 与文件名, 供 UI 提示/定位.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CloudUploadResult {
    /// 新歌曲 id(后续进云盘列表/播放都用它)
    pub song_id: u64,
    /// 歌名(云端按文件名给, 之后可在列表里改)
    #[serde(default)]
    pub name: String,
    /// 是否命中秒传(云端已有同 md5 文件, 没有真正上传字节)
    #[serde(default)]
    pub instant: bool,
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

/// 热门歌手榜里的一行(比 Artist 多粉丝数, 榜单要展示热度)
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HotArtist {
    pub id: u64,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    #[serde(default)]
    pub fans: u64,
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
    /// 触发人 uid(取不到就是 None; UI 用它决定头像能否点进个人主页)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_id: Option<u64>,
    /// 评论线程 id(评论消息由 resourceJson 的 type+id 推得, 形如 R_SO_4_186016)。
    /// 有它就能从消息直接跳到评论区并回复; 通知类一般是 None。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread_id: Option<String>,
    /// 评论 id(评论消息的 commentId), 用于定位/直接回复该条
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment_id: Option<u64>,
}

/// 消息中心"@我"页签里的一行(转发/提到我的动态).
/// 空账号拿不到非空条目的真实形状, 字段全部可缺(Option/serde(default));
/// 解析函数对拿不到任何 id 的条目直接跳过, 所以这里不保证 id 非空.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ForwardItem {
    /// 通知自身 id(部分条目形状可能缺失)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    /// 被转发/提到的动态 id
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub event_id: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_id: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nickname: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    /// 转发/评论正文(富载荷抽文本后)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub time_ms: Option<u64>,
    /// 服务端 type 字段(语义未实测, 原样透传)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub forward_type: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pic_url: Option<String>,
}

/// 私信页顶部的"最近联系人"一行.
/// 注意: /msg/recentcontact 返回的是 data.follow —— "可发起私信的联系人/关注列表",
/// 不是"最近聊天"; 顺序是服务端顺序, 前端不要重排.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecentContact {
    pub user_id: u64,
    pub nickname: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    /// 双向关注
    #[serde(default)]
    pub mutual: bool,
    /// 在线状态
    #[serde(default)]
    pub onlined: bool,
    /// 0 = 非会员, >0 会员类型(原样透传)
    #[serde(default)]
    pub vip_type: u32,
    /// 好友备注名(空串归 None)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remark_name: Option<String>,
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

/// 桌面端官方网页扫码登录的二维码会话.
///
/// 桌面端没有 Android 那套 WebView(CookieManager 能读 HttpOnly 的 MUSIC_U),
/// 也不该让用户在命令行里粘贴 cookie —— 改用官方网页登录同一套扫码通道:
/// 我们只申请一个 key, 用户用手机网易云 App 扫, 凭据由服务端在轮询响应里下发.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct QrLoginKey {
    /// 轮询用的 key(服务端 unikey)
    pub key: String,
    /// 二维码内容, 手机 App 直接扫这个 URL
    pub url: String,
    /// 有效期(秒), 过期后必须重新申请
    pub expires_in: u64,
}

/// 扫码轮询状态. 对齐官方 code: 801 待扫 / 802 已扫待确认 / 803 成功 / 800 过期.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum QrLoginState {
    #[default]
    Pending,
    Scanned,
    Confirmed,
    Expired,
    Failed,
}

/// 一次轮询的结果(交给 UI 的那半边: 只有元数据, 凭据不进 UI 层).
///
/// 登录凭据见 [QrLoginOutcome] —— 它只在 Rust 侧(provider → service → ffi)流动。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct QrLoginCheck {
    pub state: QrLoginState,
    /// 官方原始 code(801/802/803/800), 排障用
    pub code: i64,
    /// Confirmed 且登录凭据已落盘(Rust 侧完成, UI 只需据此推进)
    #[serde(default)]
    pub logged_in: bool,
    #[serde(default)]
    pub nickname: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
}

/// 手机号 + 短信验证码登录: 发送验证码的结果.
///
/// 走的是**网页登录**那套通道(weapi `/api/sms/captcha/sent`), 不是 App 原生登录族 ——
/// 后者在交互式风控下会回 8821 安全环境风险.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SmsCodeSent {
    /// 服务端原始 code(200 已发送; 8821 风控; 400 号码/区号不合法; 503 频率限制)
    pub code: i64,
    /// 服务端提示文案(可能为空)
    pub message: String,
    /// 服务端声明的剩余有效秒数(缺省按 300 显示)
    pub expires_in: u32,
}

/// 手机号 + 短信验证码登录成功后的结果(交给 UI 的那半边: 只有元数据).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PhoneLoginResult {
    /// 校验通过且登录凭据已落盘
    #[serde(default)]
    pub logged_in: bool,
    #[serde(default)]
    pub nickname: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
}

/// 内部通道结果: 扫码轮询的元数据 + 登录凭据.
///
/// **凭据只在 Rust 侧传递**(ncm-provider → ncm-service → ncm-ffi 落盘),
/// 不 derive Serialize, 也不 mirror 到 Dart —— 凭据不得回传 UI 层。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct QrLoginOutcome {
    /// 给 UI 的元数据(logged_in 由凭据是否拿到决定)
    pub check: QrLoginCheck,
    /// 只含登录凭据键(MUSIC_U/__csrf); 设备指纹由本地会话提供
    pub cookie: Option<String>,
}

/// 内部通道结果: 手机号登录的元数据 + 登录凭据(同 [QrLoginOutcome], 不回传 UI)。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PhoneLoginOutcome {
    pub result: PhoneLoginResult,
    /// 只含登录凭据键(MUSIC_U/__csrf)
    pub cookie: String,
}

/// 黑胶会员等级(vip_info_v2 的 data: associator + redVipLevel).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct VipMembership {
    /// associator.vipLevel(黑胶主套餐等级, 0 表示没有黑胶)
    pub level: u32,
    /// redVipLevel(红黑胶展示等级, 未开通时为 0)
    pub red_vip_level: u32,
    /// associator.expireTime(毫秒; 0 表示从未开通)
    pub expire_time_ms: u64,
    /// expireTime > now(服务端 now, 缺省用本机时间)
    pub is_vip: bool,
    /// redVipAnnualCount(年费剩余月数; -1 表示未知)
    pub annual_count: i32,
}

/// 黑胶成长值 / 等级卡(vip_growthpoint 的 data.levelCard + data.userLevel).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct VipGrowth {
    /// userLevel.level
    pub level: u32,
    /// levelCard.levelName(空则退回 userLevel.levelName), 形如 "黑胶·叁"
    pub level_name: String,
    /// userLevel.growthPoint
    pub growth_point: i64,
    /// userLevel.extJson.todayScore(解析失败为 0)
    pub today_score: i64,
    /// userLevel.maxLevel
    pub max_level: bool,
}

/// 某一天的签到状态(vip_sign_info; 接口只回最近 7 天).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct VipSignDay {
    /// yyyy-MM-dd(接口的 timeStr)
    pub date: String,
    /// score > 0 才算已签(recordId/time 在未签时也是 0, 不能用来判断)
    pub signed: bool,
    /// 接口的 today 标记
    pub today: bool,
    /// 当天签到得到的成长值
    pub score: u32,
}

/// 黑胶签到概览. 接口不提供"本月/累计"天数, 只能按返回的最近 7 天统计.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct VipSign {
    /// 按日期升序(接口原序即升序)
    #[serde(default)]
    pub days: Vec<VipSignDay>,
    pub signed_today: bool,
    /// days 里已签的天数
    pub week_signed: u32,
}

/// 黑胶任务(vip_tasks 的 data.taskList[].taskItems[], 已平铺).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct VipTask {
    /// name 非空取 name, 否则取 action(实测 name 常为空串)
    pub title: String,
    /// description, 形如 "成长值+3"
    pub reward: String,
    pub growth_point: i32,
    pub progress: i64,
    /// targets: 数字取数值, 数组取长度, null/缺失为 0(= 不显示进度条)
    pub target: i64,
    /// status == 2 或 target > 0 且 progress >= target
    pub done: bool,
    pub show_progress: bool,
    /// 跳转链接(需要用户去官方页完成的任务)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

/// 黑胶会员总览(会员等级 + 成长值 + 本周签到 + 任务).
///
/// 四个子接口互相独立: 任何一个失败只让对应字段为 None, 不影响其它字段;
/// 全部失败时 provider 返回第一个错误.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct VipOverview {
    pub logged_in: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub membership: Option<VipMembership>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub growth: Option<VipGrowth>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sign: Option<VipSign>,
    #[serde(default)]
    pub tasks: Vec<VipTask>,
    /// vip_tasks 的 data.taskScore
    pub task_score: i64,
}

/// 账号听歌/登录等级(对应 vendor 的 `user_level`, 端点 /api/user/level, weapi, body {}).
///
/// 实测(2026-11-08, 已登录设备):
/// ```json
/// {"code":200,"data":{"info":"60G音乐网盘免费容量$黑名单上限120$...","level":9,
///  "nextLoginCount":350,"nextPlayCount":12000,"nowLoginCount":350,"nowPlayCount":2301,
///  "progress":0.19175,"userId":1822714196},"full":false}
/// ```
/// `progress` 实测 = now_play_count / next_play_count(2301/12000 = 0.19175), **按听歌数算**;
/// 该账号 now_login_count 已顶满(350/350), 100% 封顶时以哪个维度为准**未实测**。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct UserLevel {
    /// 当前等级数字(接口的 level, 实测 9)
    #[serde(default)]
    pub level: u32,
    /// 本等级已累计听歌数(接口的 nowPlayCount)
    #[serde(default)]
    pub now_play_count: u64,
    /// 升到下一级所需累计听歌数(接口的 nextPlayCount)
    #[serde(default)]
    pub next_play_count: u64,
    /// 本等级已累计登录天数(接口的 nowLoginCount)
    #[serde(default)]
    pub now_login_count: u64,
    /// 升到下一级所需登录天数(接口的 nextLoginCount)
    #[serde(default)]
    pub next_login_count: u64,
    /// 0..=1 的进度(接口的 progress, 按听歌数算)
    #[serde(default)]
    pub progress: f64,
    /// 该等级权益文案, 接口的 info, 用 `$` 分隔多条; UI 自己 split
    #[serde(default)]
    pub privileges: String,
}

/// 一枚勋章(对应 vendor 的 `user_medal`, 端点 /api/medal/user/page, eapi, body 必带 uid).
///
/// 实测(2026-11-08): 服务端按分类回 `data.categoryMedalBlockVos[].medalVOS[]`, 共 5 类 200 枚;
/// 同一个对象也出现在 `data.obtainMedals[]`(只含已获得的), 解析时只用前者避免重复。
/// `status` 取值实测 4 种: `OBTAIN` / `NOT_OBTAIN_PROCESS`(进行中) /
/// `NOT_OBTAIN_NO_PROCESS`(未开始) / `WILL_OBTAIN`(即将获得)。
/// `medalNum` = status=OBTAIN 的枚数 = obtainTime 非空的枚数(实测 157 对 157)。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UserMedal {
    /// 唯一 id(接口的 medalCode, **字符串**: "22086503" / 乐迷徽章 "20170503_1081839")
    #[serde(default)]
    pub code: String,
    /// 名称(乐迷徽章就是艺术家名)
    #[serde(default)]
    pub name: String,
    /// 徽章图(接口的 medalPicUrl; http:// 与 https:// 两种都出现过, 原样透传)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pic_url: Option<String>,
    /// 佩戴/横排版图(接口的 wearPic); 徽章墙用方形 pic_url, 佩戴位用这张
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wear_pic_url: Option<String>,
    /// 达成条件文案(接口的 acceptCondition, 200/200 非空)
    #[serde(default)]
    pub condition: String,
    /// 已获得 = 接口 status == "OBTAIN"(与 obtain_time_ms.is_some() 实测等价, 以 status 为准)
    #[serde(default)]
    pub obtained: bool,
    /// 获得时间, **毫秒**(接口的 obtainTime, 未获得为 null)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub obtain_time_ms: Option<u64>,
    /// 等级文本, 如 "Lv.4 乐迷"; 仅乐迷徽章有(132/200), 其余为 None
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub level_title: Option<String>,
    /// 进度文案, 接口的 progress **本身就是字符串**如 "当前进度1897/5000";
    /// 实测只有 28/200 有值(未获得且有可量化目标), 不自己拆数字
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress_text: Option<String>,
    /// 获得比例文案, 如 "前0.033%获得该徽章"(接口的 rankText, 122/200)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rank_text: Option<String>,
    /// 接口 status 原值(OBTAIN / NOT_OBTAIN_PROCESS / NOT_OBTAIN_NO_PROCESS / WILL_OBTAIN),
    /// UI 要区分"进行中"与"未开始"时用; 未知新值原样保留
    #[serde(default)]
    pub status: String,
}

/// 勋章墙(data.medalNum / categoryMedalBlockVos 的扁平化结果).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MedalWall {
    /// 已获得枚数(接口的 medalNum, 实测 = status=OBTAIN 的枚数)
    #[serde(default)]
    pub medal_num: u32,
    /// 全部勋章(按服务端分类顺序平铺, 不重排)
    #[serde(default)]
    pub medals: Vec<UserMedal>,
}

/// 已购数字专辑的一项(digitalAlbum/purchased 顶层 paidAlbums[] 元素, 按实测裁剪).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DigitalAlbumPurchasedEntry {
    #[serde(default)]
    pub album_id: u64,
    #[serde(default)]
    pub album_name: String,
    #[serde(default)]
    pub artist_id: u64,
    #[serde(default)]
    pub artist_name: String,
    /// 封面字段就叫 `cover`(不是 picUrl)
    #[serde(default)]
    pub cover_url: String,
    /// 购买时间(毫秒时间戳)
    #[serde(default)]
    pub paid_time_ms: u64,
    /// 购买数量
    #[serde(default)]
    pub bought_count: u64,
}

/// 我的已购数字专辑(digitalAlbum/purchased). 顶层是 paidAlbums + total, 没有 data 包装.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DigitalAlbumPurchased {
    /// 已购总数(服务端给的 total, 与 paidAlbums.len() 在未翻页时可能不同)
    #[serde(default)]
    pub total: u64,
    #[serde(default)]
    pub albums: Vec<DigitalAlbumPurchasedEntry>,
}

/// 已购单曲的一项(song/purchased = /api/single/mybought/song/list 的 data.list 元素).
/// 该账号无已购单曲, 元素形状未实测到, 字段宽松取常见命名, 全部带默认值.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PurchasedSongEntry {
    #[serde(default)]
    pub song_id: u64,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub artist_name: String,
    #[serde(default)]
    pub cover_url: String,
    /// 购买时间(毫秒时间戳, 缺失为 0)
    #[serde(default)]
    pub paid_time_ms: u64,
}

/// 已购单曲分页(data.{count, hasMore, list}).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SongPurchasedPage {
    #[serde(default)]
    pub count: u64,
    #[serde(default)]
    pub has_more: bool,
    #[serde(default)]
    pub songs: Vec<PurchasedSongEntry>,
}

/// 数字专辑详情(vipmall/albumproduct/detail 的 album + product 平铺, 按实测裁剪).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct DigitalAlbumDetail {
    #[serde(default)]
    pub album_id: u64,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub artist_id: u64,
    #[serde(default)]
    pub artist_name: String,
    #[serde(default)]
    pub cover_url: String,
    /// 当前账号是否已购(顶层 hasAlbum)
    #[serde(default)]
    pub has_album: bool,
    /// 售价(元)
    #[serde(default)]
    pub price: f64,
    /// 上架时间(毫秒时间戳, product.pubTime)
    #[serde(default)]
    pub pub_time_ms: u64,
    /// 销量(product.saleNum, 实测恒 0; 真实销量走 digital_album_sales)
    #[serde(default)]
    pub sale_num: u64,
    /// 标签(product.tags, 如「独家」「无损品质收听＆下载」)
    #[serde(default)]
    pub tags: Vec<String>,
    /// 简介(product.descr[].resource, 已过滤 `</br>` 占位)
    #[serde(default)]
    pub description: String,
}

/// 数字专辑销量的一项(vipmall/albumproduct/album/query/sales 返回 data 为 {专辑id串: 销量}).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DigitalAlbumSalesEntry {
    /// 专辑 id(JSON map 的 key 是字符串)
    pub album_id: String,
    pub sales: u64,
}

/// 电台分类(dj_catelist 的 categories[] 元素, 按实测裁剪; 顶层无 code).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RadioCategory {
    #[serde(default)]
    pub id: u64,
    #[serde(default)]
    pub name: String,
    /// pic56x56Url(有 https)
    #[serde(default)]
    pub cover_url: String,
}

/// dj_category_recommend 的一组精选: 每个分类下 3 个推荐电台(radios 元素与 DjRadio 同形状).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct RadioPick {
    #[serde(default)]
    pub category_id: u64,
    #[serde(default)]
    pub category_name: String,
    #[serde(default)]
    pub radios: Vec<PodcastRadio>,
}

/// 电台发现首页(dj_catelist + dj_category_recommend 聚合).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct RadioExploreHome {
    #[serde(default)]
    pub categories: Vec<RadioCategory>,
    #[serde(default)]
    pub picks: Vec<RadioPick>,
}

/// 电台榜里的一个电台(dj_toplist / dj_toplist_pay 元素, 榜单特有 rank/score).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RadioRankedRadio {
    #[serde(default)]
    pub rank: u32,
    /// 上期名次(服务器给 -1 表示新上榜; 这里用 i32 原样保留)
    #[serde(default)]
    pub last_rank: i32,
    #[serde(default)]
    pub radio_id: u64,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub cover_url: String,
    #[serde(default)]
    pub dj_name: String,
    #[serde(default)]
    pub category: String,
    #[serde(default)]
    pub play_count: u64,
    #[serde(default)]
    pub program_count: u64,
    #[serde(default)]
    pub sub_count: u64,
    #[serde(default)]
    pub score: u64,
    #[serde(default)]
    pub rcmd_text: String,
}

/// 主播榜(dj_toplist_hours/newcomer/popular 的 data.list 元素; 是用户不是电台).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RadioRankedDj {
    #[serde(default)]
    pub rank: u32,
    #[serde(default)]
    pub last_rank: i32,
    #[serde(default)]
    pub user_id: u64,
    /// 注意接口字段是 nickName(驼峰), 与 dj.nickname 不同
    #[serde(default)]
    pub nickname: String,
    #[serde(default)]
    pub avatar_url: String,
    #[serde(default)]
    pub score: u64,
    #[serde(default)]
    pub followed_count: u64,
}

/// 节目榜(dj_program_toplist 的 toplist[] 元素 = {rank,lastRank,program}).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct RadioRankedProgram {
    #[serde(default)]
    pub rank: u32,
    #[serde(default)]
    pub last_rank: i32,
    #[serde(default)]
    pub program: PodcastProgram,
}

/// 电台榜单聚合(按 kind 只填其中一组; 空组当"没有这类数据").
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct RadioToplist {
    /// hot/new 榜(dj_toplist)与付费精品榜(dj_toplist_pay)的电台
    #[serde(default)]
    pub radios: Vec<RadioRankedRadio>,
    /// 主播榜(hours/newcomer/popular)
    #[serde(default)]
    pub djs: Vec<RadioRankedDj>,
    /// 节目榜(dj_program_toplist)
    #[serde(default)]
    pub programs: Vec<RadioRankedProgram>,
    #[serde(default)]
    pub has_more: bool,
}

/// 电台订阅者(dj_subscriber 的 subscribers[] 元素, 完整 user 对象按实测裁剪).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RadioSubscriber {
    #[serde(default)]
    pub user_id: u64,
    #[serde(default)]
    pub nickname: String,
    #[serde(default)]
    pub avatar_url: String,
    #[serde(default)]
    pub signature: String,
    /// 订阅时间(毫秒时间戳)
    #[serde(default)]
    pub subscribe_time_ms: u64,
}

/// 电台订阅者分页(顶层 hasMore + subscribers; 游标是 time=上一页最后 subscribeTime).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RadioSubscriberPage {
    #[serde(default)]
    pub has_more: bool,
    #[serde(default)]
    pub subscribers: Vec<RadioSubscriber>,
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
                Artist {
                    id: 1,
                    name: "A".into(),
                    avatar_url: None,
                },
                Artist {
                    id: 2,
                    name: "B".into(),
                    avatar_url: None,
                },
            ],
            album: None,
            duration_ms: 0,
            fee: None,
            playable: true,
        };
        assert_eq!(song.artist_line(), "A / B");
    }
}
