//! `CommentProvider` — 评论与分享。
//!
//! 归类口径与拆分理由见 `docs/remaining-batches.md` §12.2;
//! 组合面仍是 `crate::r#trait::Provider`(超 trait), 调用点不变.

use crate::error::{ProviderError, ProviderResult};
use crate::params::BoxFuture;
use ncm_domain::{CommentPage, CommentStats};
pub trait CommentProvider: Send + Sync {
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

    /// 评论统计(评论总数/分享数/点赞数). 能力复用 Capability::Comment.
    /// threadId 形如 R_SO_4_186016 / A_PL_0_24381616, 来自 CommentPage.thread_id 或 thread_id_for.
    fn comment_stats<'a>(
        &'a self,
        _thread_id: &'a str,
    ) -> BoxFuture<'a, ProviderResult<CommentStats>> {
        Box::pin(async { Err(ProviderError::unsupported("no comment stats")) })
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

    /// 删除自己的评论(需要登录)
    fn delete_comment<'a>(
        &'a self,
        _thread_id: &'a str,
        _comment_id: u64,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no comment delete")) })
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
}
