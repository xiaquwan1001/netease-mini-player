//! 社交: 动态(feed) / 评论互动 / 关注关系 / 最近播放 / 私信与通知.
//!
//! 拆分自原 api.rs (2026-11-20 架构审计 7.2: 单文件按域拆开),
//! 函数签名与行为与原文件逐字一致, 只是搬家。
//! 本文件里的 #[frb(mirror(..))] 就是 Dart 侧的类定义 -- 改这里 = 改 Dart API。

pub(crate) use super::*;

pub struct FeedEventDto {
    pub id: u64,
    /// 评论/点赞用的 threadId
    pub thread_id: String,
    /// 发布者用户 id
    pub user_id: u64,
    /// song | playlist | album | program | text | other
    pub kind: String,
    pub user_name: String,
    pub avatar_url: Option<String>,
    pub text: String,
    pub song: Option<SongDto>,
    pub cover_url: Option<String>,
    pub images: Vec<String>,
    /// 视频动态的直链
    pub video_url: Option<String>,
    /// 动态自带标题(艺人长文)
    pub title: String,
    /// unix 毫秒
    pub time_ms: u64,
    pub liked: bool,
    pub liked_count: u64,
    pub share_count: u64,
    pub comment_count: u64,
}

/// 关注动态(需登录): 关注的人/艺人发布的单曲、歌单、专辑、节目或文字动态
pub async fn feed_events(limit: u32, last_time: i64) -> Result<Vec<FeedEventDto>, FfiError> {
    let provider = with_provider(Capability::Feed)?;
    let list = provider
        .feed_events(limit, last_time)
        .await
        .map_err(FfiError::from)?;
    Ok(list.into_iter().map(feed_event_dto).collect())
}

/// 关注动态的一页: 事件 + 真实翻页游标.
pub struct FeedPageDto {
    pub events: Vec<FeedEventDto>,
    /// 下一页游标(把本页的 last_time 原样传回 feedPage; 0 = 不能翻页)
    pub last_time: i64,
    /// 是否还有下一页
    pub more: bool,
}

/// 关注动态的一页(带游标). 与 feedEvents 并存:
/// feedEvents 只给第一页(老调用方兼容), 需要"加载更多"的界面用这个.
pub async fn feed_page(limit: u32, last_time: i64) -> Result<FeedPageDto, FfiError> {
    let provider = with_provider(Capability::Feed)?;
    let page = provider
        .feed_page(limit, last_time)
        .await
        .map_err(FfiError::from)?;
    Ok(FeedPageDto {
        events: page.events.into_iter().map(feed_event_dto).collect(),
        last_time: page.last_time,
        more: page.more,
    })
}

fn feed_event_dto(e: ncm_domain::FeedEvent) -> FeedEventDto {
    FeedEventDto {
        id: e.id,
        thread_id: e.thread_id,
        user_id: e.user_id,
        kind: e.kind,
        user_name: e.user_name,
        avatar_url: e.avatar_url,
        text: e.text,
        song: e.song.map(song_dto),
        cover_url: e.cover_url,
        images: e.images,
        video_url: e.video_url,
        title: e.title,
        time_ms: e.time_ms,
        liked: e.liked,
        liked_count: e.liked_count,
        share_count: e.share_count,
        comment_count: e.comment_count,
    }
}

/// 指定用户的动态(用户主页): uid = 目标用户, limit = 条数, last_time = 翻页游标(-1 = 第一页).
/// 对方没公开/没有动态时返回**空列表**(不是错误).
pub async fn user_events(
    uid: u64,
    limit: u32,
    last_time: i64,
) -> Result<Vec<FeedEventDto>, FfiError> {
    let provider = with_provider(Capability::Feed)?;
    let list = provider
        .user_events(uid, limit, last_time)
        .await
        .map_err(FfiError::from)?;
    Ok(list.into_iter().map(feed_event_dto).collect())
}

/// 动态评论区(threadId 来自 FeedEvent.thread_id)
pub async fn event_comments(
    thread_id: String,
    limit: u32,
    offset: u32,
) -> Result<CommentPage, FfiError> {
    ffi_forward!(
        Capability::Feed,
        provider.event_comments(&thread_id, limit, offset)
    )
}

/// 点赞/取消点赞一条动态
pub async fn like_event(thread_id: String, liked: bool) -> Result<bool, FfiError> {
    ffi_forward!(Capability::Feed, provider.like_event(&thread_id, liked))
}

/// 转发一条动态(附转发语)
pub async fn forward_event(event_id: u64, user_id: u64, msg: String) -> Result<bool, FfiError> {
    ffi_forward!(
        Capability::Feed,
        provider.forward_event(event_id, user_id, &msg)
    )
}

/// 评论点赞/取消点赞(threadId 来自 CommentPage.thread_id)
pub async fn like_comment(
    thread_id: String,
    comment_id: u64,
    liked: bool,
) -> Result<bool, FfiError> {
    let provider = with_provider(Capability::Comment)?;
    provider
        .like_comment(&thread_id, comment_id, liked)
        .await
        .map_err(FfiError::from)
}

/// 某条评论下的回复(楼层)
pub async fn comment_replies(
    thread_id: String,
    parent_comment_id: u64,
    limit: u32,
) -> Result<CommentPage, FfiError> {
    ffi_forward!(
        Capability::Comment,
        provider.comment_replies(&thread_id, parent_comment_id, limit)
    )
}

/// 回复某条评论(需登录)
pub async fn reply_comment(
    thread_id: String,
    comment_id: u64,
    content: String,
) -> Result<bool, FfiError> {
    let provider = with_provider(Capability::Comment)?;
    provider
        .reply_comment(&thread_id, comment_id, &content)
        .await
        .map_err(FfiError::from)
}

/// 用户列表项: 直接镜像 domain 类型 `UserItem`.
#[frb(mirror(UserItem))]
pub struct _UserItem {
    pub id: u64,
    pub name: String,
    pub avatar_url: Option<String>,
    pub signature: String,
    /// 是否已关注(关注列表恒 true; 粉丝列表按未关注处理)
    pub followed: bool,
}

/// 某人关注的人(uid = 0 用当前账号)
pub async fn user_follows(uid: u64, limit: u32, offset: u32) -> Result<Vec<UserItem>, FfiError> {
    ffi_forward!(
        Capability::Follow,
        provider.user_follows(uid, limit, offset)
    )
}

/// 某人的粉丝(uid = 0 用当前账号)
pub async fn user_followeds(uid: u64, limit: u32, offset: u32) -> Result<Vec<UserItem>, FfiError> {
    ffi_forward!(
        Capability::Follow,
        provider.user_followeds(uid, limit, offset)
    )
}

/// 关注/取关某人(需登录)
pub async fn set_follow(uid: u64, follow: bool) -> Result<bool, FfiError> {
    let provider = with_provider(Capability::Follow)?;
    provider
        .set_follow(uid, follow)
        .await
        .map_err(FfiError::from)
}

/// 关注/粉丝数: 直接镜像 domain 类型 `FollowCount`.
#[frb(mirror(FollowCount))]
pub struct _FollowCount {
    pub follows: u64,
    pub fans: u64,
}

/// 我的关注/粉丝数(需登录)
pub async fn follow_counts() -> Result<FollowCount, FfiError> {
    ffi_forward!(Capability::Follow, provider.follow_counts())
}

/// 最近播放的专辑(需登录)
pub async fn recent_albums(limit: u32) -> Result<Vec<AlbumItem>, FfiError> {
    ffi_forward!(Capability::Recent, provider.recent_albums(limit))
}

/// 最近播放的歌单(需登录)
pub async fn recent_playlists(limit: u32) -> Result<Vec<Playlist>, FfiError> {
    let provider = with_provider(Capability::Recent)?;
    let list = provider
        .recent_playlists(limit)
        .await
        .map_err(FfiError::from)?;
    Ok(list)
}

/// 最近播放的播客/电台(需登录)
pub async fn recent_podcasts(limit: u32) -> Result<Vec<PodcastRadio>, FfiError> {
    ffi_forward!(Capability::Recent, provider.recent_podcasts(limit))
}

pub struct MessageCountsDto {
    pub private: u32,
    pub notices: u32,
    pub comments: u32,
    pub forwards: u32,
    /// 四项之和(角标用)
    pub total: u32,
}

/// 未读消息计数(需登录)
pub async fn message_counts() -> Result<MessageCountsDto, FfiError> {
    let provider = with_provider(Capability::Message)?;
    let c = provider.message_counts().await.map_err(FfiError::from)?;
    Ok(MessageCountsDto {
        private: c.private,
        notices: c.notices,
        comments: c.comments,
        forwards: c.forwards,
        total: c.total(),
    })
}

#[frb(mirror(PrivateSession))]
pub struct _PrivateSession {
    pub user_id: u64,
    pub nickname: String,
    pub avatar_url: Option<String>,
    pub last_message: String,
    pub last_time_ms: u64,
    pub unread: u32,
}

/// 私信会话列表(需登录)
pub async fn private_sessions(limit: u32, offset: u32) -> Result<Vec<PrivateSession>, FfiError> {
    ffi_forward!(
        Capability::Message,
        provider.private_sessions(limit, offset)
    )
}

#[frb(mirror(PrivateMessage))]
pub struct _PrivateMessage {
    pub id: u64,
    pub from_me: bool,
    pub nickname: String,
    pub avatar_url: Option<String>,
    pub content: String,
    pub time_ms: u64,
}

/// 与某人的私信历史(需登录, 老的在前; before_ms = 0 取最新一页)
pub async fn private_history(
    user_id: u64,
    limit: u32,
    before_ms: u64,
) -> Result<Vec<PrivateMessage>, FfiError> {
    ffi_forward!(
        Capability::Message,
        provider.private_history(user_id, limit, before_ms)
    )
}

/// 发送私信(需登录). 纯文本, 成功后应重拉 [private_history] 刷新会话.
pub async fn private_send(user_id: u64, content: String) -> Result<bool, FfiError> {
    ffi_forward!(Capability::Message, provider.private_send(user_id, content))
}

#[frb(mirror(InboxItem))]
pub struct _InboxItem {
    pub id: u64,
    /// notice | comment
    pub kind: String,
    pub actor: String,
    pub avatar_url: Option<String>,
    pub text: String,
    pub detail: String,
    pub time_ms: u64,
    /// 触发人 uid(未知为 None)
    pub user_id: Option<u64>,
    /// 评论线程 id(R_SO_4_x 一类; 通知类一般为 None)
    pub thread_id: Option<String>,
    /// 评论 id(用于定位/回复)
    pub comment_id: Option<u64>,
}

/// 通知(需登录, 新的在前; last_time_ms = 0 取最新一页)
pub async fn message_notices(limit: u32, last_time_ms: u64) -> Result<Vec<InboxItem>, FfiError> {
    ffi_forward!(
        Capability::Message,
        provider.message_notices(limit, last_time_ms)
    )
}

/// 评论/回复消息(需登录, 新的在前)
pub async fn comment_messages(limit: u32) -> Result<Vec<InboxItem>, FfiError> {
    ffi_forward!(Capability::Message, provider.comment_messages(limit))
}

#[frb(mirror(ForwardItem))]
pub struct _ForwardItem {
    pub id: Option<u64>,
    pub event_id: Option<u64>,
    pub user_id: Option<u64>,
    pub nickname: Option<String>,
    pub avatar_url: Option<String>,
    pub comment: Option<String>,
    pub time_ms: Option<u64>,
    pub forward_type: Option<u32>,
    pub pic_url: Option<String>,
}

/// 消息中心"@我"(需登录; last_time_ms 预留游标形状, 接口实际用 offset/limit, 恒取最新一页)
pub async fn forward_messages(limit: u32, last_time_ms: u64) -> Result<Vec<ForwardItem>, FfiError> {
    ffi_forward!(
        Capability::Message,
        provider.forward_messages(limit, last_time_ms)
    )
}

#[frb(mirror(RecentContact))]
pub struct _RecentContact {
    pub user_id: u64,
    pub nickname: String,
    pub avatar_url: Option<String>,
    pub mutual: bool,
    pub onlined: bool,
    pub vip_type: u32,
    pub remark_name: Option<String>,
}

/// 最近联系人(需登录; "可发起私信的联系人/关注列表", 服务端顺序)
pub async fn recent_contacts(limit: u32) -> Result<Vec<RecentContact>, FfiError> {
    ffi_forward!(Capability::Message, provider.recent_contacts(limit))
}

/// 当前登录账号 uid(0 = 未登录/未同步). 用于判断歌单是不是自己的(能不能编辑)
pub fn my_uid() -> Result<u64, FfiError> {
    let guard = core()?.lock().map_err(FfiError::from)?;
    Ok(guard
        .session
        .profile
        .as_ref()
        .map(|p| p.user_id)
        .unwrap_or(0))
}
