//! `MessageProvider` — 消息中心。
//!
//! 归类口径与拆分理由见 `docs/remaining-batches.md` §12.2;
//! 组合面仍是 `crate::r#trait::Provider`(超 trait), 调用点不变.

use crate::error::{ProviderError, ProviderResult};
use crate::params::BoxFuture;
use ncm_domain::{
    ForwardItem, InboxItem, MessageCounts, PrivateMessage, PrivateSession, RecentContact,
};
pub trait MessageProvider: Send + Sync {
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

    /// 发送私信(需登录). 上游 /api/msg/private/send, 纯文本.
    fn private_send(&self, _user_id: u64, _content: String) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no private send")) })
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
