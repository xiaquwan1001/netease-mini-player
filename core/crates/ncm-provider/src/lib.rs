//! 音源插件边界: Provider trait + 能力声明 + 注册表.
//!
//! 首版不实现脚本宿主, 但边界从第一天就固定:
//! - 出入参全是可序列化 DTO (见 ncm-domain)
//! - 错误统一成 ProviderError, UI 只按 kind 决策
//! - 未来加 QuickJS 时, 只需新增一个 ScriptProvider 实现本 trait

use ncm_domain::{
    AlbumDetail, AlbumItem, Artist, ArtistDetail, ChartSummary, CommentPage, DefaultSearch, FeedEvent,
    HotSearchDetailItem, SearchExact,
    FollowCount, HotSearchTerm, Lyric, PlayRankEntry, Playlist, PlaylistCategory, PlaylistDetail,
    ForwardItem, HotArtist, InboxItem, MessageCounts, PodcastProgram, PodcastRadio, PrivateMessage, PrivateSession,
    Profile, RecentContact,
    ProfileDetail, SearchBundle, SearchPage, SigninStatus, Song, StreamUrl, StyleTag, SuggestItem, TrackId,
    MedalWall, UserItem, UserLevel, VipOverview, WikiFact,
};
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
    /// 消息中心(私信/通知/评论)
    Message,
    /// 黑胶会员只读(等级/成长值/签到/任务)
    Vip,
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
            Capability::Message => "message",
            Capability::Vip => "vip",
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

    /// 综合搜索: 单曲/歌手/专辑/歌单/播客分板块.
    /// 默认退化成只搜单曲(兼容只实现 search 的 provider).
    fn search_all<'a>(
        &'a self,
        query: &'a SearchQuery,
    ) -> BoxFuture<'a, ProviderResult<SearchBundle>> {
        Box::pin(async move {
            let page = self.search(query).await?;
            Ok(SearchBundle {
                songs: page.songs,
                song_total: page.total,
                ..SearchBundle::default()
            })
        })
    }

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

    /// 每日推荐歌曲(原版"每日推荐")
    fn daily_recommend_songs(&self) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no daily recommend")) })
    }

    /// 每日推荐歌单(原版"推荐歌单")
    fn daily_recommend_playlists(&self) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no daily playlists")) })
    }

    /// 心动模式(基于当前曲目的智能连续播放)
    fn intelligence_songs(
        &self,
        _song_id: u64,
        _playlist_id: u64,
        _count: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no intelligence mode")) })
    }

    /// 搜索建议(输入联想)
    fn search_suggest<'a>(
        &'a self,
        _keywords: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<SuggestItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no search suggest")) })
    }

    /// 联想下拉的**纯关键词候选**(最多 6 条, 已去重保序).
    ///
    /// 与 `search_suggest` 的区别: 后者回的是「实体卡片」( songs/artists/albums/playlists 分段),
    /// 这里只是可点的候选词串, 适合输入框下方的简版下拉.
    /// 能力声明复用 [`Capability::SearchSuggest`].
    fn search_suggest_keywords<'a>(
        &'a self,
        _keywords: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<String>>> {
        Box::pin(async { Err(ProviderError::unsupported("no suggest keywords")) })
    }

    /// 精确实体改写: 关键词命中歌手/歌单/电台时的"最精确那一条".
    ///
    /// 注意**空命中伪装成功**: provider 侧必须把 orders 为空的结果翻成 [`SearchExact::default()`],
    /// 不要当错误抛. 能力声明复用 [`Capability::SearchSuggest`].
    fn search_exact<'a>(&'a self, _keywords: &'a str) -> BoxFuture<'a, ProviderResult<SearchExact>> {
        Box::pin(async { Err(ProviderError::unsupported("no search exact")) })
    }

    /// 最近播放(需要登录; 服务端记录)
    fn recent_songs(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no recent songs")) })
    }

    /// 专辑详情(封面预览 + 曲目)
    fn album_detail(&self, _album_id: u64) -> BoxFuture<'_, ProviderResult<AlbumDetail>> {
        Box::pin(async { Err(ProviderError::unsupported("no album detail")) })
    }

    /// 热门播客/电台
    fn podcast_hot(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<PodcastRadio>>> {
        Box::pin(async { Err(ProviderError::unsupported("no podcast")) })
    }

    /// 某个播客的节目列表
    fn podcast_programs(
        &self,
        _radio_id: u64,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<PodcastProgram>>> {
        Box::pin(async { Err(ProviderError::unsupported("no podcast programs")) })
    }

    /// 单个节目详情
    fn podcast_program(&self, _program_id: u64) -> BoxFuture<'_, ProviderResult<PodcastProgram>> {
        Box::pin(async { Err(ProviderError::unsupported("no podcast program")) })
    }

    /// 搜索热词榜(已按热度排序, rank 从 1 开始)
    fn hot_search(&self) -> BoxFuture<'_, ProviderResult<Vec<HotSearchTerm>>> {
        Box::pin(async { Err(ProviderError::unsupported("no hot search")) })
    }

    /// 热搜榜详情(带热度分与榜位, 比 [`Self::hot_search`] 的瘦热词多 score/rank).
    /// 能力声明复用 [`Capability::SearchHot`].
    fn hot_search_detail(&self) -> BoxFuture<'_, ProviderResult<Vec<HotSearchDetailItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no hot search detail")) })
    }

    /// 默认/推荐搜索词("猜你想搜"): keyword 是要搜的词, show 是推荐理由文案
    fn default_search(&self) -> BoxFuture<'_, ProviderResult<Option<DefaultSearch>>> {
        Box::pin(async { Err(ProviderError::unsupported("no default search")) })
    }

    /// 私人 FM(需要登录)
    fn personal_fm(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no personal fm")) })
    }

    /// 已订阅的播客/电台(需要登录)
    fn subscribed_podcasts(
        &self,
        _limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<PodcastRadio>>> {
        Box::pin(async { Err(ProviderError::unsupported("no subscribed podcasts")) })
    }

    /// 关注的艺人(需要登录)
    fn subscribed_artists(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Artist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no subscribed artists")) })
    }

    /// 关注动态(关注的人/艺人发布的内容, 需要登录)
    fn feed_events(
        &self,
        _limit: u32,
        _last_time: i64,
    ) -> BoxFuture<'_, ProviderResult<Vec<FeedEvent>>> {
        Box::pin(async { Err(ProviderError::unsupported("no feed")) })
    }

    /// 动态的评论列表(threadId 来自 FeedEvent.thread_id)
    fn event_comments<'a>(
        &'a self,
        _thread_id: &'a str,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        Box::pin(async { Err(ProviderError::unsupported("no event comments")) })
    }

    /// 点赞/取消点赞一条动态(threadId 来自 FeedEvent.thread_id)
    fn like_event<'a>(
        &'a self,
        _thread_id: &'a str,
        _liked: bool,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no event like")) })
    }

    /// 转发一条动态(附转发语)
    fn forward_event<'a>(
        &'a self,
        _event_id: u64,
        _user_id: u64,
        _msg: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no event forward")) })
    }

    /// 歌单详情(歌单页头部信息)
    fn playlist_detail(&self, _playlist_id: u64) -> BoxFuture<'_, ProviderResult<PlaylistDetail>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist detail")) })
    }

    /// 收藏/取消收藏歌单(需要登录). 返回 true 表示操作被接受.
    fn set_playlist_subscribed(
        &self,
        _playlist_id: u64,
        _subscribed: bool,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist subscribe")) })
    }

    /// 评论列表. kind = song | playlist | album | podcast
    fn comments<'a>(
        &'a self,
        _kind: &'a str,
        _id: u64,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        Box::pin(async { Err(ProviderError::unsupported("no comments")) })
    }

    /// 精彩评论(单独接口, 可单独翻页). threadId 来自 CommentPage.thread_id
    fn hot_comments<'a>(
        &'a self,
        _thread_id: &'a str,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        Box::pin(async { Err(ProviderError::unsupported("no hot comments")) })
    }

    /// 分享资源到动态(需要登录). 返回 true 表示操作被接受.
    fn share_resource<'a>(
        &'a self,
        _kind: &'a str,
        _id: u64,
        _msg: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no share")) })
    }

    /// 播客/电台详情
    fn podcast_radio(&self, _radio_id: u64) -> BoxFuture<'_, ProviderResult<PodcastRadio>> {
        Box::pin(async { Err(ProviderError::unsupported("no podcast radio")) })
    }

    /// 歌手详情(头像/简介/热门歌曲/专辑)
    fn artist_detail(&self, _artist_id: u64) -> BoxFuture<'_, ProviderResult<ArtistDetail>> {
        Box::pin(async { Err(ProviderError::unsupported("no artist detail")) })
    }

    /// 当前账号资料详情(个人主页背景图/头像/签名/关注数)
    fn profile_detail(&self) -> BoxFuture<'_, ProviderResult<ProfileDetail>> {
        Box::pin(async { Err(ProviderError::unsupported("no profile detail")) })
    }

    /// 收藏曲目到指定歌单(需要登录). 返回 true 表示接口接受.
    fn add_to_playlist(
        &self,
        _playlist_id: u64,
        _track: TrackId,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist edit")) })
    }

    /// "我喜欢的音乐"曲目, 按收藏时间从新到旧(服务端 addTime 排序).
    fn liked_songs_ordered(&self) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no liked songs")) })
    }

    /// 听歌排行(需要登录): 全部时间 / 最近一周. 顺序即名次.
    fn play_ranking(
        &self,
        _period: RankingPeriod,
    ) -> BoxFuture<'_, ProviderResult<Vec<PlayRankEntry>>> {
        Box::pin(async { Err(ProviderError::unsupported("no play ranking")) })
    }

    /// 我的曲风偏好(系统按听歌口味算出来的风格, 需要登录; 未登录可退化成通用曲风表).
    fn style_preference(&self) -> BoxFuture<'_, ProviderResult<Vec<StyleTag>>> {
        Box::pin(async { Err(ProviderError::unsupported("no style preference")) })
    }

    /// 某个曲风下的歌曲
    fn style_songs<'a>(
        &'a self,
        _tag_id: &'a str,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no style songs")) })
    }

    /// 某个曲风下的歌单
    fn style_playlists<'a>(
        &'a self,
        _tag_id: &'a str,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no style playlists")) })
    }

    /// 排行榜列表(飙升/新歌/热歌/原创 + 各语种/曲风榜)
    fn charts(&self) -> BoxFuture<'_, ProviderResult<Vec<ChartSummary>>> {
        Box::pin(async { Err(ProviderError::unsupported("no charts")) })
    }

    /// 歌单分类(语种/风格/场景/情感/主题)
    fn playlist_categories(&self) -> BoxFuture<'_, ProviderResult<Vec<PlaylistCategory>>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist categories")) })
    }

    /// 某个分类下的歌单(按热度/最新排序, 支持 offset 翻页)
    fn playlists_by_category<'a>(
        &'a self,
        _cat: &'a str,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no category playlists")) })
    }

    /// 精品歌单(编辑精选)
    fn high_quality_playlists<'a>(
        &'a self,
        _cat: &'a str,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no high quality playlists")) })
    }

    /// 我收藏的专辑(需要登录)
    fn subscribed_albums(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no subscribed albums")) })
    }

    /// 收藏/取消收藏专辑(需要登录)
    fn set_album_subscribed(
        &self,
        _album_id: u64,
        _subscribed: bool,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no album subscribe")) })
    }

    /// 新建歌单(需要登录), 返回新歌单 id
    fn create_playlist<'a>(&'a self, _name: &'a str) -> BoxFuture<'a, ProviderResult<u64>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist create")) })
    }

    /// 删除歌单(需要登录)
    fn delete_playlist(&self, _playlist_id: u64) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist delete")) })
    }

    /// 改歌单名
    fn rename_playlist<'a>(
        &'a self,
        _playlist_id: u64,
        _name: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist rename")) })
    }

    /// 改歌单简介
    fn update_playlist_desc<'a>(
        &'a self,
        _playlist_id: u64,
        _desc: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist desc")) })
    }

    /// 把一首歌移出歌单(需要登录)
    fn remove_track(
        &self,
        _playlist_id: u64,
        _track: TrackId,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist track delete")) })
    }

    /// 评论点赞/取消点赞(需要登录). threadId 来自 CommentPage.thread_id
    fn like_comment<'a>(
        &'a self,
        _thread_id: &'a str,
        _comment_id: u64,
        _liked: bool,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no comment like")) })
    }

    /// 某条评论下的回复(楼层)
    fn comment_replies<'a>(
        &'a self,
        _thread_id: &'a str,
        _parent_comment_id: u64,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        Box::pin(async { Err(ProviderError::unsupported("no comment replies")) })
    }

    /// 回复某条评论(需要登录)
    fn reply_comment<'a>(
        &'a self,
        _thread_id: &'a str,
        _comment_id: u64,
        _content: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no comment reply")) })
    }

    /// 某人关注的人(不传 uid 用当前账号)
    fn user_follows(
        &self,
        _uid: u64,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<UserItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no user follows")) })
    }

    /// 某人的粉丝
    fn user_followeds(
        &self,
        _uid: u64,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<UserItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no user followeds")) })
    }

    /// 关注/取关某人(需要登录)
    fn set_follow(&self, _uid: u64, _follow: bool) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no follow")) })
    }

    /// 我的关注/粉丝数
    fn follow_counts(&self) -> BoxFuture<'_, ProviderResult<FollowCount>> {
        Box::pin(async { Err(ProviderError::unsupported("no follow counts")) })
    }

    /// 推荐新音乐("新歌速递")
    fn new_songs(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no new songs")) })
    }

    /// 新碟上架(region = ALL|ZH|EA|KR|JP)
    fn new_albums(
        &self,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no new albums")) })
    }

    /// 相似歌曲
    fn similar_songs(
        &self,
        _song_id: u64,
        _limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no similar songs")) })
    }

    /// 相似歌单
    fn similar_playlists(
        &self,
        _song_id: u64,
        _limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no similar playlists")) })
    }

    /// 相似歌手(需要登录)
    fn similar_artists(&self, _artist_id: u64) -> BoxFuture<'_, ProviderResult<Vec<Artist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no similar artists")) })
    }

    /// 每日推荐"不感兴趣"(需要登录): 把这首歌从以后的日推里排掉
    fn dislike_recommend_song(&self, _song_id: u64) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no recommend dislike")) })
    }

    /// 私人 FM"不再播放"(需要登录)
    fn trash_fm_song(&self, _song_id: u64) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no fm trash")) })
    }

    /// 历史日推可用日期(黑胶 VIP; 形如 "2024-06-20", 新的在前)
    fn history_recommend_dates(&self) -> BoxFuture<'_, ProviderResult<Vec<String>>> {
        Box::pin(async { Err(ProviderError::unsupported("no history recommend dates")) })
    }

    /// 某个日期的历史日推曲目
    fn history_recommend_songs<'a>(
        &'a self,
        _date: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no history recommend songs")) })
    }

    /// 最近播放的专辑(服务端记录, 需要登录)
    fn recent_albums(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no recent albums")) })
    }

    /// 最近播放的歌单(服务端记录, 需要登录)
    fn recent_playlists(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no recent playlists")) })
    }

    /// 最近播放的播客/电台(服务端记录, 需要登录)
    fn recent_podcasts(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<PodcastRadio>>> {
        Box::pin(async { Err(ProviderError::unsupported("no recent podcasts")) })
    }

    /// 云贝签到状态(需要登录)
    fn signin_status(&self) -> BoxFuture<'_, ProviderResult<SigninStatus>> {
        Box::pin(async { Err(ProviderError::unsupported("no signin status")) })
    }

    /// 签到(需要登录). 返回签到后的状态; 今日已签到时 Unsupported("已签到")
    fn sign_in(&self) -> BoxFuture<'_, ProviderResult<SigninStatus>> {
        Box::pin(async { Err(ProviderError::unsupported("no signin")) })
    }

    /// 黑胶会员总览(会员等级 / 成长值 / 本周签到 / 任务; 需要登录).
    ///
    /// 四个子接口互相独立: 单个失败只让对应字段为 None, 全部失败才返回错误.
    fn vip_overview(&self) -> BoxFuture<'_, ProviderResult<VipOverview>> {
        Box::pin(async { Err(ProviderError::unsupported("no vip overview")) })
    }

    /// 账号听歌等级(听歌数/登录天数/进度; 需要登录).
    /// 能力复用 [`Capability::ProfileDetail`](crate::Capability::ProfileDetail).
    fn user_level(&self) -> BoxFuture<'_, ProviderResult<UserLevel>> {
        Box::pin(async { Err(ProviderError::unsupported("no user level")) })
    }

    /// 账号勋章墙(已获得 + 未获得, 按服务端分类顺序平铺; 需要登录).
    /// 能力复用 [`Capability::ProfileDetail`](crate::Capability::ProfileDetail).
    fn user_medals(&self) -> BoxFuture<'_, ProviderResult<MedalWall>> {
        Box::pin(async { Err(ProviderError::unsupported("no user medals")) })
    }

    /// 删除自己的评论(需要登录)
    fn delete_comment<'a>(
        &'a self,
        _thread_id: &'a str,
        _comment_id: u64,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no comment delete")) })
    }

    /// 歌曲百科(曲风/语种/BPM/获奖成就...). 没有百科时返回空列表.
    fn song_wiki(&self, _song_id: u64) -> BoxFuture<'_, ProviderResult<Vec<WikiFact>>> {
        Box::pin(async { Err(ProviderError::unsupported("no song wiki")) })
    }

    /// 未读消息计数(需登录)
    fn message_counts(&self) -> BoxFuture<'_, ProviderResult<MessageCounts>> {
        Box::pin(async { Err(ProviderError::unsupported("no message counts")) })
    }

    /// 私信会话列表(需登录, 按最后一条消息倒序)
    fn private_sessions(
        &self,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<PrivateSession>>> {
        Box::pin(async { Err(ProviderError::unsupported("no private sessions")) })
    }

    /// 与某人的私信历史(需登录; before_ms = 0 表示最新一页)
    fn private_history(
        &self,
        _user_id: u64,
        _limit: u32,
        _before_ms: u64,
    ) -> BoxFuture<'_, ProviderResult<Vec<PrivateMessage>>> {
        Box::pin(async { Err(ProviderError::unsupported("no private history")) })
    }

    /// 新歌速递(按地区; area = all|zh|ea|jp|kr)
    fn new_songs_by_area<'a>(
        &'a self,
        _area: &'a str,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no new songs by area")) })
    }

    /// 新碟上架(按地区; area 同上)
    fn new_albums_by_area<'a>(
        &'a self,
        _area: &'a str,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no new albums by area")) })
    }

    /// 热门歌手榜(按粉丝/热度倒序)
    fn hot_artists(
        &self,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<HotArtist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no hot artists")) })
    }

    /// 通知(点赞/关注/系统), 新的在前
    fn message_notices(
        &self,
        _limit: u32,
        _last_time_ms: u64,
    ) -> BoxFuture<'_, ProviderResult<Vec<InboxItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no notices")) })
    }

    /// 评论/回复消息(需登录), 新的在前
    fn comment_messages(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<InboxItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no comment messages")) })
    }

    /// 消息中心"@我"(需登录, 新的在前).
    /// 网易该接口实际用 offset/limit 分页, last_time_ms 只是保留游标形状, 实现可忽略.
    fn forward_messages(
        &self,
        _limit: u32,
        _last_time_ms: u64,
    ) -> BoxFuture<'_, ProviderResult<Vec<ForwardItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no forward messages")) })
    }

    /// 最近联系人(需登录; "可发起私信的联系人/关注列表", 服务端顺序)
    fn recent_contacts(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<RecentContact>>> {
        Box::pin(async { Err(ProviderError::unsupported("no recent contacts")) })
    }
}

/// 听歌排行的统计区间.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RankingPeriod {
    /// 全部时间(总量排行)
    #[default]
    All,
    /// 最近一周
    Week,
}

impl RankingPeriod {
    /// 接口的 type 参数: 0 = 全部时间, 1 = 最近一周
    pub fn type_param(&self) -> &'static str {
        match self {
            RankingPeriod::All => "0",
            RankingPeriod::Week => "1",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "all" | "0" | "" => Some(RankingPeriod::All),
            "week" | "1" => Some(RankingPeriod::Week),
            _ => None,
        }
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
