//! `RecommendProvider` — 推荐与发现: 日推/私人FM/新歌新碟/相似/曲风/榜单/历史推荐。
//!
//! 归类口径与拆分理由见 `docs/remaining-batches.md` §12.2;
//! 组合面仍是 `crate::r#trait::Provider`(超 trait), 调用点不变.

use crate::error::{ProviderError, ProviderResult};
use crate::params::BoxFuture;
use ncm_domain::{
    AlbumItem, Artist, ChartSummary, HotArtist, Playlist, PodcastRadio, Song, StyleTag,
    ToplistCatalogGroup,
};
pub trait RecommendProvider: Send + Sync {
    /// 每日推荐歌曲(原版"每日推荐")
    fn daily_recommend_songs(&self) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no daily recommend")) })
    }

    /// 每日推荐歌单(原版"推荐歌单")
    fn daily_recommend_playlists(&self) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no daily playlists")) })
    }

    /// 心动模式(基于当前曲目的智能连续播放)
    fn intelligence_songs(
        &self,
        _song_id: u64,
        _playlist_id: u64,
        _count: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no intelligence mode")) })
    }

    /// 私人 FM(需要登录)
    fn personal_fm(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no personal fm")) })
    }

    /// 最近播放(需要登录; 服务端记录)
    fn recent_songs(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no recent songs")) })
    }

    /// 推荐新音乐("新歌速递")
    fn new_songs(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no new songs")) })
    }

    /// 新碟上架(region = ALL|ZH|EA|KR|JP)
    fn new_albums(
        &self,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no new albums")) })
    }

    /// 新歌速递(按地区; area = all|zh|ea|jp|kr)
    fn new_songs_by_area<'a>(
        &'a self,
        _area: &'a str,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no new songs by area")) })
    }

    /// 新碟上架(按地区; area 同上)
    fn new_albums_by_area<'a>(
        &'a self,
        _area: &'a str,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no new albums by area")) })
    }

    /// 相似歌曲
    fn similar_songs(
        &self,
        _song_id: u64,
        _limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no similar songs")) })
    }

    /// 相似歌单
    fn similar_playlists(
        &self,
        _song_id: u64,
        _limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no similar playlists")) })
    }

    /// 相似歌手(需要登录)
    fn similar_artists(&self, _artist_id: u64) -> BoxFuture<'_, ProviderResult<Vec<Artist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no similar artists")) })
    }

    /// 每日推荐"不感兴趣"(需要登录): 把这首歌从以后的日推里排掉
    fn dislike_recommend_song(&self, _song_id: u64) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no recommend dislike")) })
    }

    /// 私人 FM"不再播放"(需要登录)
    fn trash_fm_song(&self, _song_id: u64) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no fm trash")) })
    }

    /// 历史日推可用日期(黑胶 VIP; 形如 "2024-06-20", 新的在前)
    fn history_recommend_dates(&self) -> BoxFuture<'_, ProviderResult<Vec<String>>> {
        Box::pin(async { Err(ProviderError::unsupported("no history recommend dates")) })
    }

    /// 某个日期的历史日推曲目
    fn history_recommend_songs<'a>(
        &'a self,
        _date: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no history recommend songs")) })
    }

    /// 最近播放的专辑(服务端记录, 需要登录)
    fn recent_albums(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no recent albums")) })
    }

    /// 最近播放的歌单(服务端记录, 需要登录)
    fn recent_playlists(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no recent playlists")) })
    }

    /// 最近播放的播客/电台(服务端记录, 需要登录)
    fn recent_podcasts(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<PodcastRadio>>> {
        Box::pin(async { Err(ProviderError::unsupported("no recent podcasts")) })
    }

    /// 我的曲风偏好(系统按听歌口味算出来的风格, 需要登录; 未登录可退化成通用曲风表).
    fn style_preference(&self) -> BoxFuture<'_, ProviderResult<Vec<StyleTag>>> {
        Box::pin(async { Err(ProviderError::unsupported("no style preference")) })
    }

    /// 某个曲风下的歌曲
    fn style_songs<'a>(
        &'a self,
        _tag_id: &'a str,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no style songs")) })
    }

    /// 某个曲风下的歌单
    fn style_playlists<'a>(
        &'a self,
        _tag_id: &'a str,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no style playlists")) })
    }

    /// 排行榜列表(飙升/新歌/热歌/原创 + 各语种/曲风榜)
    fn charts(&self) -> BoxFuture<'_, ProviderResult<Vec<ChartSummary>>> {
        Box::pin(async { Err(ProviderError::unsupported("no charts")) })
    }

    /// 最新专辑(album_newest, 实测固定 12 张, 无 total). 能力复用 Capability::NewRelease.
    fn newest_albums(&self, _limit: u32) -> BoxFuture<'_, ProviderResult<Vec<AlbumItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no newest albums")) })
    }

    /// 榜单 v2 目录(toplist_detail_v2, 按 categoryCode 分组的榜单卡).
    /// 能力复用 Capability::Chart.
    fn toplist_catalog(&self) -> BoxFuture<'_, ProviderResult<Vec<ToplistCatalogGroup>>> {
        Box::pin(async { Err(ProviderError::unsupported("no toplist catalog")) })
    }

    /// 热门歌手榜(按粉丝/热度倒序)
    fn hot_artists(
        &self,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<HotArtist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no hot artists")) })
    }
}
