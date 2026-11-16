//! 能力声明与音质档位。
//!
//! `Capability` 是路由的唯一依据: 注册表按能力挑 provider, 不按 trait 形状。

use serde::{Deserialize, Serialize};

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
    Album,
    Podcast,
    SearchSuggest,
    Recent,
    SearchHot,
    Feed,
    PlaylistDetail,
    Comment,
    Share,
    PodcastDetail,
    SearchAll,
    Artist,
    ProfileDetail,
    PlaylistEdit,
    /// 听歌排行(总量/当周)
    ListeningRank,
    /// 曲风推荐(我的曲风偏好 / 曲风下的歌曲与歌单)
    StyleRecommend,
    /// 排行榜(榜单列表; 榜单本身就是一个歌单)
    Chart,
    /// 收藏专辑(收藏/取消收藏 + 我收藏的专辑)
    AlbumSub,
    /// 关注关系(关注/粉丝列表、关注/取关)
    Follow,
    /// 新歌/新碟(推荐页"新歌速递/新碟上架")
    NewRelease,
    /// 相似推荐(相似歌曲/歌单/歌手)
    Similar,
    /// 云贝签到(今日状态 / 签到)
    Signin,
    /// 歌曲百科(曲风/语种/BPM/获奖)
    Wiki,
    /// 单曲喜欢状态 + 喜欢总数(需要登录; 官方 App 的 /api/song/like/get)
    SongLike,
    /// 消息中心(私信/通知/评论)
    Message,
    /// 黑胶会员只读(等级/成长值/签到/任务)
    Vip,
    /// 数字专辑只读(详情/已购/销量/已购单曲; 不含下单)
    DigitalAlbum,
    /// 电台发现(只读: 分类/精选/推荐/榜单/订阅者; 不含订阅写操作)
    RadioExplore,
    /// 音乐云盘(列表/删除/下载直链; 不含上传)
    Cloud,
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
            Capability::Album => "album",
            Capability::Podcast => "podcast",
            Capability::SearchSuggest => "searchSuggest",
            Capability::Recent => "recent",
            Capability::SearchHot => "searchHot",
            Capability::Feed => "feed",
            Capability::PlaylistDetail => "playlistDetail",
            Capability::Comment => "comment",
            Capability::Share => "share",
            Capability::PodcastDetail => "podcastDetail",
            Capability::SearchAll => "searchAll",
            Capability::Artist => "artist",
            Capability::ProfileDetail => "profileDetail",
            Capability::PlaylistEdit => "playlistEdit",
            Capability::ListeningRank => "listeningRank",
            Capability::StyleRecommend => "styleRecommend",
            Capability::Chart => "chart",
            Capability::AlbumSub => "albumSub",
            Capability::Follow => "follow",
            Capability::NewRelease => "newRelease",
            Capability::Similar => "similar",
            Capability::Signin => "signin",
            Capability::Wiki => "wiki",
            Capability::SongLike => "songLike",
            Capability::Message => "message",
            Capability::Vip => "vip",
            Capability::DigitalAlbum => "digitalAlbum",
            Capability::RadioExplore => "radioExplore",
            Capability::Cloud => "cloud",
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
