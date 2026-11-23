//! 内容详情: 专辑详情 / 歌单详情与订阅 / 数字专辑 / 评论读取与发布 / 分享.
//!
//! 拆分自原 api.rs (2026-11-20 架构审计 7.2: 单文件按域拆开),
//! 函数签名与行为与原文件逐字一致, 只是搬家。
//! 本文件里的 #[frb(mirror(..))] 就是 Dart 侧的类定义 -- 改这里 = 改 Dart API。

pub(crate) use super::*;

// ---------------- 专辑封面预览 ----------------

pub struct AlbumDetailDto {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub artist: String,
    pub description: String,
    pub songs: Vec<SongDto>,
}

pub async fn album_detail(album_id: u64) -> Result<AlbumDetailDto, FfiError> {
    let provider = with_provider(Capability::Album)?;
    let album = provider
        .album_detail(album_id)
        .await
        .map_err(FfiError::from)?;
    Ok(AlbumDetailDto {
        id: album.id,
        name: album.name,
        cover_url: album.cover_url,
        artist: album.artist,
        description: album.description,
        songs: album.songs.into_iter().map(song_dto).collect(),
    })
}

// ---------------- 歌单详情 / 评论 / 分享 ----------------

/// 歌单详情: 直接镜像 domain 类型 `PlaylistDetail`.
#[frb(mirror(PlaylistDetail))]
pub struct _PlaylistDetail {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub description: String,
    /// 创建者昵称
    pub creator_name: String,
    /// 创建者 uid(0 = 未知); 与 my_uid() 相同即可编辑这个歌单
    pub creator_id: u64,
    pub track_count: u64,
    pub play_count: u64,
    /// 当前账号是否已收藏
    pub subscribed: bool,
    pub subscribed_count: u64,
    pub share_count: u64,
    pub comment_count: u64,
    pub tags: Vec<String>,
}

/// 歌单详情(歌单页头部信息)
pub async fn playlist_detail(playlist_id: u64) -> Result<PlaylistDetail, FfiError> {
    ffi_forward!(
        Capability::PlaylistDetail,
        provider.playlist_detail(playlist_id)
    )
}

/// 收藏/取消收藏歌单(需登录)
pub async fn set_playlist_subscribed(playlist_id: u64, subscribed: bool) -> Result<bool, FfiError> {
    let provider = with_provider(Capability::PlaylistDetail)?;
    provider
        .set_playlist_subscribed(playlist_id, subscribed)
        .await
        .map_err(FfiError::from)
}

#[frb(mirror(Comment))]
pub struct _Comment {
    pub id: u64,
    /// 评论者 uid(0 = 未知)
    pub user_id: u64,
    pub user_name: String,
    pub avatar_url: Option<String>,
    pub content: String,
    /// 发布时间(unix 毫秒)
    pub time_ms: u64,
    pub liked_count: u64,
    /// 当前账号是否已赞
    pub liked: bool,
    /// 该评论下的回复数(>0 才显示"回复 N")
    pub reply_count: u64,
    /// IP 归属地(如 "广东"); 精彩评论通常为空
    pub ip_location: String,
    /// 是否精彩评论
    pub hot: bool,
    /// 这条评论回复的是谁(被回复者昵称); None = 顶层评论. UI 据此显示"回复 @某人"
    pub replied_to: Option<String>,
    /// 所属主评论 id(0 = 没有父级)
    pub parent_id: u64,
}

#[frb(mirror(CommentPage))]
pub struct _CommentPage {
    /// 这条线程的 threadId(点赞/回复要用)
    pub thread_id: String,
    /// 精彩评论在前(hotComments), 其后是最新评论, 按 commentId 去重
    pub comments: Vec<Comment>,
    pub total: u64,
    pub has_more: bool,
}

/// 评论统计(评论数/分享数/点赞数). 实测形状见 ncm_domain::CommentStats 的文档注释:
/// 没有 subscribedCount(收藏数) 与 hotCount(热门评论数) —— 别在 UI 里显示这两个.
#[frb(mirror(CommentStats))]
pub struct _CommentStats {
    /// 评论线程 id(R_SO_4_/A_PL_0_/R_AL_3_/A_DJ_1_/R_VI_62_…)
    pub thread_id: String,
    /// 资源 id
    pub resource_id: u64,
    /// 评论总数
    pub comment_count: u64,
    /// 评论数的官方展示文案("100w+"/"999+"/空串)
    pub comment_count_desc: String,
    /// 分享数
    pub share_count: u64,
    /// 该 thread 被点赞数
    pub liked_count: u64,
    /// 当前账号是否点过赞(匿名恒 false)
    pub liked: bool,
    /// 作者参与评论数
    pub musician_said_count: u64,
    /// 评论区是否已升级到新版(服务端灰度, 实测恒 false)
    pub comment_upgraded: bool,
}

/// 单曲喜欢状态 + 喜欢总数(官方 App 的 /api/song/like/get; 需要登录).
/// 与 CommentStats.likedCount 区分: 那个是评论线程被点赞数, 这里是歌曲喜欢人数.
#[frb(mirror(SongLikeState))]
pub struct _SongLikeState {
    /// 当前账号是否喜欢了这首歌
    pub liked: bool,
    /// 喜欢这首歌的人数
    pub liked_count: u64,
}

/// 已购数字专辑的一项(实测形状见 ncm_domain::DigitalAlbumPurchasedEntry 注释)
#[frb(mirror(DigitalAlbumPurchasedEntry))]
pub struct _DigitalAlbumPurchasedEntry {
    pub album_id: u64,
    pub album_name: String,
    pub artist_id: u64,
    pub artist_name: String,
    pub cover_url: String,
    /// 购买时间(毫秒时间戳)
    pub paid_time_ms: u64,
    /// 购买数量
    pub bought_count: u64,
}

#[frb(mirror(DigitalAlbumPurchased))]
pub struct _DigitalAlbumPurchased {
    /// 服务端给的已购总数(分页用)
    pub total: u64,
    pub albums: Vec<DigitalAlbumPurchasedEntry>,
}

/// 已购单曲的一项(元素形状未实测到, 字段宽松)
#[frb(mirror(PurchasedSongEntry))]
pub struct _PurchasedSongEntry {
    pub song_id: u64,
    pub name: String,
    pub artist_name: String,
    pub cover_url: String,
    pub paid_time_ms: u64,
}

#[frb(mirror(SongPurchasedPage))]
pub struct _SongPurchasedPage {
    pub count: u64,
    pub has_more: bool,
    pub songs: Vec<PurchasedSongEntry>,
}

/// 数字专辑详情(album + product 平铺, 实测形状见 ncm_domain::DigitalAlbumDetail)
#[frb(mirror(DigitalAlbumDetail))]
pub struct _DigitalAlbumDetail {
    pub album_id: u64,
    pub name: String,
    pub artist_id: u64,
    pub artist_name: String,
    pub cover_url: String,
    /// 当前账号是否已购
    pub has_album: bool,
    /// 售价(元)
    pub price: f64,
    /// 上架时间(毫秒时间戳)
    pub pub_time_ms: u64,
    /// product.saleNum(实测恒 0, 真实销量用 digital_album_sales)
    pub sale_num: u64,
    pub tags: Vec<String>,
    /// 简介(descr 拼接, 已过滤 </br>)
    pub description: String,
}

#[frb(mirror(DigitalAlbumSalesEntry))]
pub struct _DigitalAlbumSalesEntry {
    pub album_id: String,
    pub sales: u64,
}

/// 已购数字专辑(需登录; limit/offset 分页)
pub async fn digital_album_purchased(
    limit: u32,
    offset: u32,
) -> Result<DigitalAlbumPurchased, FfiError> {
    ffi_forward!(
        Capability::DigitalAlbum,
        provider.digital_album_purchased(limit, offset)
    )
}

/// 已购单曲(需登录; limit/offset 分页)
pub async fn song_purchased(limit: u32, offset: u32) -> Result<SongPurchasedPage, FfiError> {
    ffi_forward!(
        Capability::DigitalAlbum,
        provider.song_purchased(limit, offset)
    )
}

/// 数字专辑详情(只读; 不提供下单)
pub async fn digital_album_detail(album_id: u64) -> Result<DigitalAlbumDetail, FfiError> {
    ffi_forward!(
        Capability::DigitalAlbum,
        provider.digital_album_detail(album_id)
    )
}

/// 数字专辑销量(album_ids 逗号分隔)
pub async fn digital_album_sales(
    album_ids: String,
) -> Result<Vec<DigitalAlbumSalesEntry>, FfiError> {
    // 借用先摊成 Copy 的 `&str`, 免得路由调用把 `album_ids` 搬进闭包(闭包要被调两次).
    let album_ids = album_ids.as_str();
    ffi_forward!(
        Capability::DigitalAlbum,
        provider.digital_album_sales(album_ids)
    )
}

/// 评论列表: kind = song | playlist | album | podcast
pub async fn comments(
    kind: String,
    resource_id: u64,
    limit: u32,
    offset: u32,
) -> Result<CommentPage, FfiError> {
    let kind = kind.as_str();
    ffi_forward!(
        Capability::Comment,
        provider.comments(kind, resource_id, limit, offset)
    )
}

/// 评论列表 + 排序(2026-11-23): `sort` = 0 推荐 / 1 热度 / 2 时间(最新在前).
///
/// 上游就是同一个评论端点上的 `sortType` 参数(vendor 透传), 所以分页语义
/// (limit/offset + hasMore)与 [`comments`] 完全一致, UI 换页签只是换 sort。
/// 匿名 + 非 0 排序可能被风控回 -462 ⇒ 照常变成 `[kind]` 可重试错误。
pub async fn comments_sorted(
    kind: String,
    resource_id: u64,
    limit: u32,
    offset: u32,
    sort: u32,
) -> Result<CommentPage, FfiError> {
    let kind = kind.as_str();
    ffi_forward!(
        Capability::Comment,
        provider.comments_sorted(kind, resource_id, limit, offset, sort)
    )
}

/// 评论统计: threadId 形如 R_SO_4_186016 / A_PL_0_24381616(也可用 thread_id_for 现拼).
/// 缺数据时返回全 0, 不抛错; 只有 threadId 非法/动态才报 unsupported.
pub async fn comment_stats(thread_id: String) -> Result<CommentStats, FfiError> {
    let thread_id = thread_id.as_str();
    ffi_forward!(Capability::Comment, provider.comment_stats(thread_id))
}

/// 单曲喜欢状态 + 喜欢总数(需要登录; 官方 App 的 /api/song/like/get).
///
/// 匿名调用会得到 auth 错误(上游回 301), UI 侧当作"不显示数量"处理即可。
pub async fn song_like_state(track_id: u64) -> Result<SongLikeState, FfiError> {
    ffi_forward!(Capability::SongLike, provider.song_like_state(track_id))
}

/// 精彩评论(可单独翻页): threadId 来自 comments() 的返回
pub async fn hot_comments(
    thread_id: String,
    limit: u32,
    offset: u32,
) -> Result<CommentPage, FfiError> {
    let thread_id = thread_id.as_str();
    ffi_forward!(
        Capability::Comment,
        provider.hot_comments(thread_id, limit, offset)
    )
}

/// 分享资源到动态(需登录). kind = song | playlist | album | podcast
pub async fn share_resource(kind: String, resource_id: u64, msg: String) -> Result<bool, FfiError> {
    let provider = with_provider(Capability::Share)?;
    provider
        .share_resource(&kind, resource_id, &msg)
        .await
        .map_err(FfiError::from)
}
