//! `CommunityProvider` — 动态/社区。
//!
//! 归类口径与拆分理由见 `docs/remaining-batches.md` §12.2;
//! 组合面仍是 `crate::r#trait::Provider`(超 trait), 调用点不变.

use crate::error::{ProviderError, ProviderResult};
use crate::params::BoxFuture;
use ncm_domain::{CommentPage, FeedEvent, FeedPage};
pub trait CommunityProvider: Send + Sync {
    /// 关注动态(关注的人/艺人发布的内容, 需要登录)
    fn feed_events(
        &self,
        _limit: u32,
        _last_time: i64,
    ) -> BoxFuture<'_, ProviderResult<Vec<FeedEvent>>> {
        Box::pin(async { Err(ProviderError::unsupported("no feed")) })
    }

    /// 关注动态的一页(带真实游标, 见 FeedPage). 默认实现退化成一页无游标.
    fn feed_page(&self, _limit: u32, _last_time: i64) -> BoxFuture<'_, ProviderResult<FeedPage>> {
        Box::pin(async { Err(ProviderError::unsupported("no feed page")) })
    }

    /// 指定用户的动态(他人主页): vendor 的 event 只支持 pagesize/lasttime,
    /// provider 侧自己拼 uid. 对方没公开/没有动态时返回**空列表**.
    fn user_events(
        &self,
        _uid: u64,
        _limit: u32,
        _last_time: i64,
    ) -> BoxFuture<'_, ProviderResult<Vec<FeedEvent>>> {
        Box::pin(async { Err(ProviderError::unsupported("no user events")) })
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
}
