//! `PlaylistWriteProvider` — 歌单/喜欢 写操作。
//!
//! 归类口径与拆分理由见 `docs/remaining-batches.md` §12.2;
//! 组合面仍是 `crate::r#trait::Provider`(超 trait), 调用点不变.

use crate::error::{ProviderError, ProviderResult};
use crate::params::BoxFuture;
use ncm_domain::TrackId;
pub trait PlaylistWriteProvider: Send + Sync {
    /// 红心/取消红心. 返回 true 表示操作被接受.
    fn set_like<'a>(
        &'a self,
        _track: TrackId,
        _liked: bool,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no like")) })
    }

    /// 收藏曲目到指定歌单(需要登录). 返回 true 表示接口接受.
    fn add_to_playlist(
        &self,
        _playlist_id: u64,
        _track: TrackId,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist edit")) })
    }

    /// 新建歌单(需要登录), 返回新歌单 id. privacy: 0=公开 10=私密
    fn create_playlist<'a>(
        &'a self,
        _name: &'a str,
        _privacy: u8,
    ) -> BoxFuture<'a, ProviderResult<u64>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist create")) })
    }

    /// 批量把曲目加入歌单(需要登录). song_ids 应由调用方去重;
    /// 服务端对已存在的曲目会跳过(count 可小于提交数), 返回 true 表示接口接受.
    fn playlist_tracks_add<'a>(
        &'a self,
        _playlist_id: u64,
        _song_ids: &'a [u64],
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist tracks add")) })
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

    /// 收藏/取消收藏歌单(需要登录). 返回 true 表示操作被接受.
    fn set_playlist_subscribed(
        &self,
        _playlist_id: u64,
        _subscribed: bool,
    ) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist subscribe")) })
    }
}
