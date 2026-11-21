//! 我的页: 播放排行 / 风格偏好 / 签到 / 歌曲百科 / 地区新歌 / 会员与等级勋章.
//!
//! 拆分自原 api.rs (2026-11-20 架构审计 7.2: 单文件按域拆开),
//! 函数签名与行为与原文件逐字一致, 只是搬家。
//! 本文件里的 #[frb(mirror(..))] 就是 Dart 侧的类定义 -- 改这里 = 改 Dart API。

pub(crate) use super::*;

pub struct PlayRankEntryDto {
    pub song: SongDto,
    /// 播放次数(周榜是本周的)
    pub play_count: u64,
    /// 网易云给的推荐分值
    pub score: u64,
}

/// 听歌排行(需登录): period = "all"(总量排行) | "week"(当周排行).
/// 返回顺序即名次(1 开始由 UI 用下标表达).
pub async fn play_ranking(period: String) -> Result<Vec<PlayRankEntryDto>, FfiError> {
    let provider = with_provider(Capability::ListeningRank)?;
    let period = RankingPeriod::parse(&period).unwrap_or_default();
    let list = provider
        .play_ranking(period)
        .await
        .map_err(FfiError::from)?;
    Ok(list
        .into_iter()
        .map(|e| PlayRankEntryDto {
            song: song_dto(e.song),
            play_count: e.play_count,
            score: e.score,
        })
        .collect())
}

/// 他人常听排行(用户主页): uid = 目标用户, period = "all" | "week".
/// 对方没公开/没有记录时返回**空列表**(不是错误).
///
/// **登录态是硬前提**(2026-11-21 用户实测): 官方 PC 网页登录后能看到别人的
/// 累积/一周排行(对一个累积 6114 首的账号有真实数据), 而匿名请求同一个端点
/// (vendor 的 user_record → `/api/v1/play/record`)只回 `{"code":200,"allData":[]}`
/// —— 200 + 空数组, 连错误都不给, 所以上游本身分不出「未登录」和「真没记录」。
/// 因此「未登录」这一态必须由 UI 按登录态自己判(见 account.rs 的 `logged_in`),
/// 不能指望本方法返回错误。
pub async fn user_play_ranking(
    uid: u64,
    period: String,
) -> Result<Vec<PlayRankEntryDto>, FfiError> {
    let provider = with_provider(Capability::ListeningRank)?;
    let period = RankingPeriod::parse(&period).unwrap_or_default();
    let list = provider
        .play_ranking_of(uid, period)
        .await
        .map_err(FfiError::from)?;
    Ok(list
        .into_iter()
        .map(|e| PlayRankEntryDto {
            song: song_dto(e.song),
            play_count: e.play_count,
            score: e.score,
        })
        .collect())
}

/// 曲风标签: 直接镜像 domain 类型(D7 spike), Dart 侧靠 dart_code 的 typedef 保持旧名.
#[frb(mirror(StyleTag))]
pub struct _StyleTag {
    /// 曲风 tagId(字符串, 直接回传给 style_songs/style_playlists)
    pub id: String,
    pub name: String,
    pub cover_url: Option<String>,
    pub song_count: Option<u64>,
}

/// 系统推荐的曲风(我的曲风偏好; 未登录时退化成通用曲风表)
pub async fn style_preference() -> Result<Vec<StyleTag>, FfiError> {
    ffi_forward!(Capability::StyleRecommend, provider.style_preference())
}

/// 某个曲风下的歌曲
pub async fn style_songs(tag_id: String, limit: u32) -> Result<Vec<SongDto>, FfiError> {
    let provider = with_provider(Capability::StyleRecommend)?;
    let list = provider
        .style_songs(&tag_id, limit)
        .await
        .map_err(FfiError::from)?;
    Ok(list.into_iter().map(song_dto).collect())
}

/// 某个曲风下的歌单
pub async fn style_playlists(tag_id: String, limit: u32) -> Result<Vec<Playlist>, FfiError> {
    let tag_id = tag_id.as_str();
    ffi_forward!(
        Capability::StyleRecommend,
        provider.style_playlists(tag_id, limit)
    )
}

#[frb(mirror(SigninDay))]
pub struct _SigninDay {
    /// yyyy-mm-dd
    pub day: String,
    pub signed: bool,
}

#[frb(mirror(SigninStatus))]
pub struct _SigninStatus {
    pub signed_today: bool,
    /// 累计签到天数
    pub total_days: u32,
    /// 连续签到天数
    pub continuous_days: u32,
    /// 本周签到天数
    pub week_days: u32,
    /// 最近 7 天(新的在前)
    pub recent: Vec<SigninDay>,
    /// 本次签到得到云贝(只有刚签完非 0)
    pub today_point: u32,
}

/// 签到(需登录). 已签到时返回当前状态(today_point = 0, 不报错)
pub async fn sign_in() -> Result<SigninStatus, FfiError> {
    ffi_forward!(Capability::Signin, provider.sign_in())
}

/// 删除自己的评论(需登录)
pub async fn delete_comment(thread_id: String, comment_id: u64) -> Result<bool, FfiError> {
    let thread_id = thread_id.as_str();
    ffi_forward!(
        Capability::Comment,
        provider.delete_comment(thread_id, comment_id)
    )
}

#[frb(mirror(WikiFact))]
pub struct _WikiFact {
    /// 分组(曲风/语种/BPM/获奖成就...)
    pub label: String,
    /// 值(多个已用 " / " 拼好)
    pub value: String,
}

/// 歌曲百科(曲风/语种/BPM/获奖成就). 没有百科时返回空列表
pub async fn song_wiki(song_id: u64) -> Result<Vec<WikiFact>, FfiError> {
    ffi_forward!(Capability::Wiki, provider.song_wiki(song_id))
}

/// 新歌速递(按地区; area = all|zh|ea|jp|kr)
pub async fn new_songs_by_area(area: String, limit: u32) -> Result<Vec<SongDto>, FfiError> {
    let provider = with_provider(Capability::NewRelease)?;
    let list = provider
        .new_songs_by_area(&area, limit)
        .await
        .map_err(FfiError::from)?;
    Ok(list.into_iter().map(song_dto).collect())
}

/// 新碟上架(按地区)
pub async fn new_albums_by_area(area: String, limit: u32) -> Result<Vec<AlbumItem>, FfiError> {
    let area = area.as_str();
    ffi_forward!(
        Capability::NewRelease,
        provider.new_albums_by_area(area, limit)
    )
}

/// 热门歌手: 直接镜像 domain 类型 `HotArtist`.
#[frb(mirror(HotArtist))]
pub struct _HotArtist {
    pub id: u64,
    pub name: String,
    pub avatar_url: Option<String>,
    /// 粉丝数(列表页显示热度)
    pub fans: u64,
}

/// 热门歌手榜
pub async fn hot_artists(limit: u32, offset: u32) -> Result<Vec<HotArtist>, FfiError> {
    ffi_forward!(Capability::NewRelease, provider.hot_artists(limit, offset))
}

/// 黑胶会员等级
#[frb(mirror(VipMembership))]
pub struct _VipMembership {
    pub level: u32,
    pub red_vip_level: u32,
    pub expire_time_ms: u64,
    /// 到期时间晚于服务端 now 才算会员(过期后 vipLevel 仍是旧值, 别拿它判断)
    pub is_vip: bool,
    /// 年费剩余月数, 负数 = 未知
    pub annual_count: i32,
}

/// 黑胶成长值 / 等级卡
#[frb(mirror(VipGrowth))]
pub struct _VipGrowth {
    pub level: u32,
    pub level_name: String,
    pub growth_point: i64,
    pub today_score: i64,
    pub max_level: bool,
}

/// 黑胶任务
#[frb(mirror(VipTask))]
pub struct _VipTask {
    pub title: String,
    pub reward: String,
    pub growth_point: i32,
    pub progress: i64,
    /// 0 = 没有可量化目标(不显示进度条)
    pub target: i64,
    pub done: bool,
    pub show_progress: bool,
    pub url: Option<String>,
}

/// 黑胶会员总览(只读)
#[frb(mirror(VipOverview))]
pub struct _VipOverview {
    pub logged_in: bool,
    pub membership: Option<VipMembership>,
    pub growth: Option<VipGrowth>,
    pub daily_sign: Option<SigninStatus>,
    pub tasks: Vec<VipTask>,
    pub task_score: i64,
}

/// 黑胶会员总览: 会员等级/成长值/每日签到(云贝)/任务.
/// 未登录返回 logged_in=false 的空态; 四个子接口互相独立, 单个失败只让对应字段为 None.
pub async fn vip_overview() -> Result<VipOverview, FfiError> {
    let provider = with_provider(Capability::Vip)?;
    let o = provider.vip_overview().await.map_err(FfiError::from)?;
    Ok(o)
}

/// 账号听歌等级(用户等级)
#[frb(mirror(UserLevel))]
pub struct _UserLevel {
    /// 当前等级数字
    pub level: u32,
    /// 本等级已累计听歌数
    pub now_play_count: u64,
    /// 升到下一级所需累计听歌数
    pub next_play_count: u64,
    /// 本等级已累计登录天数
    pub now_login_count: u64,
    /// 升到下一级所需登录天数
    pub next_login_count: u64,
    /// 0..=1 的进度(按听歌数算)
    pub progress: f64,
    /// 该等级权益文案, 用 `$` 分隔多条
    pub privileges: String,
}

/// 一枚勋章
#[frb(mirror(UserMedal))]
pub struct _UserMedal {
    /// 唯一 id(字符串, 乐迷徽章形如 "20170503_1081839")
    pub code: String,
    pub name: String,
    pub pic_url: Option<String>,
    /// 佩戴/横排版图
    pub wear_pic_url: Option<String>,
    /// 达成条件文案
    pub condition: String,
    /// 是否已获得(以服务端 status == "OBTAIN" 为准)
    pub obtained: bool,
    /// 获得时间(毫秒), 未获得为 None
    pub obtain_time_ms: Option<u64>,
    /// 等级文本, 如 "Lv.4 乐迷"(仅乐迷徽章)
    pub level_title: Option<String>,
    /// 进度文案, 如 "当前进度1897/5000"
    pub progress_text: Option<String>,
    /// 获得比例文案, 如 "前0.033%获得该徽章"
    pub rank_text: Option<String>,
    /// 服务端状态原值(OBTAIN / NOT_OBTAIN_PROCESS / NOT_OBTAIN_NO_PROCESS / WILL_OBTAIN)
    pub status: String,
}

/// 账号听歌等级(需要登录)
pub async fn user_level() -> Result<UserLevel, FfiError> {
    ffi_forward!(Capability::ProfileDetail, provider.user_level())
}

/// 账号勋章墙(需要登录). 全部勋章按服务端分类顺序平铺.
pub async fn user_medals() -> Result<Vec<UserMedal>, FfiError> {
    let provider = with_provider(Capability::ProfileDetail)?;
    let wall = provider.user_medals().await.map_err(FfiError::from)?;
    Ok(wall.medals)
}
