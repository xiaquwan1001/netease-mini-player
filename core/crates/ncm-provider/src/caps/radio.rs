//! `RadioProvider` — 播客/电台。
//!
//! 归类口径与拆分理由见 `docs/remaining-batches.md` §12.2;
//! 组合面仍是 `crate::r#trait::Provider`(超 trait), 调用点不变.

use crate::error::{ProviderError, ProviderResult};
use crate::params::BoxFuture;
use ncm_domain::{
    PodcastProgram, PodcastRadio, RadioExploreHome, RadioSubscriberPage, RadioToplist,
};
pub trait RadioProvider: Send + Sync {
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

    /// 播客/电台详情
    fn podcast_radio(&self, _radio_id: u64) -> BoxFuture<'_, ProviderResult<PodcastRadio>> {
        Box::pin(async { Err(ProviderError::unsupported("no podcast radio")) })
    }

    /// 已订阅的播客/电台(需要登录)
    fn subscribed_podcasts(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<PodcastRadio>>> {
        Box::pin(async { Err(ProviderError::unsupported("no subscribed podcasts")) })
    }

    /// 收藏/取消收藏播客/电台(需要登录; `subscribed = true` = 收藏)
    fn set_podcast_subscribed(
        &self,
        _radio_id: u64,
        _subscribed: bool,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no podcast subscribe")) })
    }

    // ---- 电台发现(只读; 能力声明 Capability::RadioExplore) ----

    /// 电台发现首页: 分类列表(dj_catelist) + 各分类精选(dj_category_recommend), 匿名可用.
    fn radio_explore_home(&self) -> BoxFuture<'_, ProviderResult<RadioExploreHome>> {
        Box::pin(async { Err(ProviderError::unsupported("no radio explore")) })
    }

    /// 某分类下的推荐电台(dj_recommend_type; cate_id 必须是真实分类 id, 0 返回空).
    fn radio_recommend<'a>(
        &'a self,
        _cate_id: u64,
    ) -> BoxFuture<'a, ProviderResult<Vec<PodcastRadio>>> {
        Box::pin(async { Err(ProviderError::unsupported("no radio recommend")) })
    }

    /// 电台榜单(kind: "hot"|"new"|"pay"|"hours"|"newcomer"|"popular"|"program").
    fn radio_toplist<'a>(&'a self, _kind: &'a str) -> BoxFuture<'a, ProviderResult<RadioToplist>> {
        Box::pin(async { Err(ProviderError::unsupported("no radio toplist")) })
    }

    /// 电台订阅者列表(只读; 订阅/取消订阅等写操作不做).
    /// 电台订阅者/听众列表. `time_ms` 是**时间游标**(首页传 None, 之后传上一页最后一条的 subscribe_time_ms).
    fn radio_subscribers<'a>(
        &'a self,
        _radio_id: u64,
        _limit: u32,
        _time_ms: Option<u64>,
    ) -> BoxFuture<'a, ProviderResult<RadioSubscriberPage>> {
        Box::pin(async { Err(ProviderError::unsupported("no radio subscribers")) })
    }
}
