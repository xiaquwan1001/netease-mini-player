//! `PlaylistReadProvider` — 歌单/喜欢列表/听歌排行 只读。
//!
//! 归类口径与拆分理由见 `docs/remaining-batches.md` §12.2;
//! 组合面仍是 `crate::r#trait::Provider`(超 trait), 调用点不变.

use crate::error::{ProviderError, ProviderResult};
use crate::params::{BoxFuture, RankingPeriod};
use ncm_domain::{PlayRankEntry, Playlist, PlaylistCategory, PlaylistDetail, Song, TrackId};
pub trait PlaylistReadProvider: Send + Sync {
    /// 当前账号的歌单列表(含"我喜欢的音乐")
    fn user_playlists<'a>(&'a self) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlists")) })
    }

    /// 任意用户的公开歌单(不需要登录).
    fn user_playlists_of<'a>(
        &'a self,
        _uid: u64,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no user playlists")) })
    }

    /// 某个歌单的曲目
    fn playlist_songs<'a>(&'a self, _playlist_id: u64) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist songs")) })
    }

    /// 歌单详情(歌单页头部信息)
    fn playlist_detail(&self, _playlist_id: u64) -> BoxFuture<'_, ProviderResult<PlaylistDetail>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist detail")) })
    }

    /// 歌单分类(语种/风格/场景/情感/主题)
    fn playlist_categories(&self) -> BoxFuture<'_, ProviderResult<Vec<PlaylistCategory>>> {
        Box::pin(async { Err(ProviderError::unsupported("no playlist categories")) })
    }

    /// 某个分类下的歌单(按热度/最新排序, 支持 offset 翻页)
    fn playlists_by_category<'a>(
        &'a self,
        _cat: &'a str,
        _limit: u32,
        _offset: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no category playlists")) })
    }

    /// 精品歌单(编辑精选)
    fn high_quality_playlists<'a>(
        &'a self,
        _cat: &'a str,
        _limit: u32,
    ) -> BoxFuture<'a, ProviderResult<Vec<Playlist>>> {
        Box::pin(async { Err(ProviderError::unsupported("no high quality playlists")) })
    }

    /// "我喜欢的音乐"里的曲目 id(用于红心状态)
    fn liked_ids<'a>(&'a self) -> BoxFuture<'a, ProviderResult<Vec<TrackId>>> {
        Box::pin(async { Err(ProviderError::unsupported("no liked ids")) })
    }

    /// "我喜欢的音乐"曲目, 按收藏时间从新到旧(服务端 addTime 排序).
    fn liked_songs_ordered(&self) -> BoxFuture<'_, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no liked songs")) })
    }

    /// 听歌排行(需要登录): 全部时间 / 最近一周. 顺序即名次.
    fn play_ranking(
        &self,
        _period: RankingPeriod,
    ) -> BoxFuture<'_, ProviderResult<Vec<PlayRankEntry>>> {
        Box::pin(async { Err(ProviderError::unsupported("no play ranking")) })
    }

    /// 他人常听排行: 与 [`play_ranking`](Self::play_ranking) 同一端点, 但 uid 由调用方给.
    /// 对方没公开/没有记录时返回**空列表**(不报错), 让 UI 显示"暂无数据".
    fn play_ranking_of(
        &self,
        _uid: u64,
        _period: RankingPeriod,
    ) -> BoxFuture<'_, ProviderResult<Vec<PlayRankEntry>>> {
        Box::pin(async { Err(ProviderError::unsupported("no user play ranking")) })
    }
}
