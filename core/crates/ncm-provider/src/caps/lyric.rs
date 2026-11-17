//! `LyricProvider` — 歌词(逐行 LRC / 逐字 YRC)。
//!
//! 归类口径与拆分理由见 `docs/remaining-batches.md` §12.2;
//! 组合面仍是 `crate::r#trait::Provider`(超 trait), 调用点不变.

use crate::error::{ProviderError, ProviderResult};
use crate::params::BoxFuture;
use ncm_domain::{Lyric, TrackId, WordLyric};
pub trait LyricProvider: Send + Sync {
    fn lyric<'a>(&'a self, track: TrackId) -> BoxFuture<'a, ProviderResult<Lyric>>;

    /// 逐字歌词(YRC). 默认不支持; 解析失败在实现内部退化为整词行, 不返回错误.
    fn word_lyric<'a>(&'a self, _track: TrackId) -> BoxFuture<'a, ProviderResult<WordLyric>> {
        Box::pin(async { Err(ProviderError::unsupported("no word lyric")) })
    }
}
