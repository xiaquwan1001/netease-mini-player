//! `ArtistAlbumProvider` — 歌手/专辑/MV/收藏。
//!
//! 归类口径与拆分理由见 `docs/remaining-batches.md` §12.2;
//! 组合面仍是 `crate::r#trait::Provider`(超 trait), 调用点不变.

use crate::error::{ProviderError, ProviderResult};
use crate::params::BoxFuture;
use ncm_domain::{
    AlbumDetail, AlbumItem, Artist, ArtistAlbumPage, ArtistDetail, ArtistMvPage, ArtistSongPage,
    MvDetail, MvUrl,
};
pub trait ArtistAlbumProvider: Send + Sync {
    /// 歌手详情(头像/简介/热门歌曲/专辑)
    fn artist_detail(&self, _artist_id: u64) -> BoxFuture<'_, ProviderResult<ArtistDetail>> {
        Box::pin(async { Err(ProviderError::unsupported("no artist detail")) })
    }

    /// 歌手全部歌曲一页(offset/limit 分页, has_more=还有下一页)
    fn artist_songs_page<'a>(
        &'a self,
        _artist_id: u64,
        _offset: u32,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<ArtistSongPage>> {
        Box::pin(async { Err(ProviderError::unsupported("no artist songs")) })
    }

    /// 歌手专辑一页(offset/limit 分页, has_more=还有下一页)
    fn artist_albums_page<'a>(
        &'a self,
        _artist_id: u64,
        _offset: u32,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<ArtistAlbumPage>> {
        Box::pin(async { Err(ProviderError::unsupported("no artist albums")) })
    }

    /// 关注/取消关注歌手(需要登录). 返回 true 表示接口接受.
    fn toggle_artist_sub<'a>(
        &'a self,
        _artist_id: u64,
        _sub: bool,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no artist sub")) })
    }

    /// 歌手 MV 一页(offset/limit 分页, has_more=还有下一页)
    fn artist_mvs_page<'a>(
        &'a self,
        _artist_id: u64,
        _offset: u32,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<ArtistMvPage>> {
        Box::pin(async { Err(ProviderError::unsupported("no artist mvs")) })
    }

    /// MV 详情(mv_detail)
    fn mv_detail<'a>(&'a self, _mv_id: u64) -> BoxFuture<'a, ProviderResult<MvDetail>> {
        Box::pin(async { Err(ProviderError::unsupported("no mv detail")) })
    }

    /// MV 播放链接(mv_url, r=清晰度档位如 1080)
    fn mv_url<'a>(&'a self, _mv_id: u64, _r: u32) -> BoxFuture<'a, ProviderResult<MvUrl>> {
        Box::pin(async { Err(ProviderError::unsupported("no mv url")) })
    }

    /// 专辑详情(封面预览 + 曲目)
    fn album_detail(&self, _album_id: u64) -> BoxFuture<'_, ProviderResult<AlbumDetail>> {
        Box::pin(async { Err(ProviderError::unsupported("no album detail")) })
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

    /// 关注的艺人(需要登录)
    fn subscribed_artists(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Artist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no subscribed artists")) })
    }
}
