//! `VipProvider` — 黑胶会员/云贝签到/数字专辑。
//!
//! 归类口径与拆分理由见 `docs/remaining-batches.md` §12.2;
//! 组合面仍是 `crate::r#trait::Provider`(超 trait), 调用点不变.

use crate::error::{ProviderError, ProviderResult};
use crate::params::BoxFuture;
use ncm_domain::{
    DigitalAlbumDetail, DigitalAlbumPurchased, DigitalAlbumSalesEntry, MedalWall, SigninStatus,
    SongPurchasedPage, UserLevel, VipOverview,
};
pub trait VipProvider: Send + Sync {
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

    /// 已购数字专辑(digitalAlbum/purchased; 需要登录).
    fn digital_album_purchased<'a>(
        &'a self,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'a, ProviderResult<DigitalAlbumPurchased>> {
        Box::pin(async { Err(ProviderError::unsupported("no digital album purchased")) })
    }

    /// 已购单曲(song/purchased, 分页; 需要登录).
    fn song_purchased<'a>(
        &'a self,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'a, ProviderResult<SongPurchasedPage>> {
        Box::pin(async { Err(ProviderError::unsupported("no song purchased")) })
    }

    /// 数字专辑详情(vipmall/albumproduct/detail, 只读).
    fn digital_album_detail(
        &self,
        _album_id: u64,
    ) -> BoxFuture<'_, ProviderResult<DigitalAlbumDetail>> {
        Box::pin(async { Err(ProviderError::unsupported("no digital album detail")) })
    }

    /// 数字专辑销量(逗号分隔的专辑 id 串 → 每个专辑一条销量).
    fn digital_album_sales<'a>(
        &'a self,
        _album_ids: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<DigitalAlbumSalesEntry>>> {
        Box::pin(async { Err(ProviderError::unsupported("no digital album sales")) })
    }
}
