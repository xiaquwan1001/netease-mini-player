//! `ReadProvider` — 读取核心: 搜索/取链/歌曲详情/热搜/搜索建议/百科/喜欢状态。
//!
//! 归类口径与拆分理由见 `docs/remaining-batches.md` §12.2;
//! 组合面仍是 `crate::r#trait::Provider`(超 trait), 调用点不变.

use crate::error::{ProviderError, ProviderResult};
use crate::params::{BoxFuture, SearchQuery, SongUrlRequest};
use ncm_domain::{
    DefaultSearch, HotSearchDetailItem, HotSearchTerm, SearchBundle, SearchExact, SearchPage, Song,
    SongLikeState, StreamUrl, SuggestItem, WikiFact,
};
pub trait ReadProvider: Send + Sync {
    fn search<'a>(&'a self, query: &'a SearchQuery) -> BoxFuture<'a, ProviderResult<SearchPage>>;

    /// 综合搜索: 单曲/歌手/专辑/歌单/播客分板块.
    /// 默认退化成只搜单曲(兼容只实现 search 的 provider).
    fn search_all<'a>(
        &'a self,
        query: &'a SearchQuery,
    ) -> BoxFuture<'a, ProviderResult<SearchBundle>> {
        Box::pin(async move {
            let page = self.search(query).await?;
            Ok(SearchBundle {
                songs: page.songs,
                song_total: page.total,
                ..SearchBundle::default()
            })
        })
    }

    fn song_url<'a>(&'a self, req: &'a SongUrlRequest) -> BoxFuture<'a, ProviderResult<StreamUrl>>;

    /// 批量取曲目详情(逗号分隔的 id)
    fn songs_detail<'a>(&'a self, _ids: &'a str) -> BoxFuture<'a, ProviderResult<Vec<Song>>> {
        Box::pin(async { Err(ProviderError::unsupported("no song detail")) })
    }

    /// 单曲的官方 MV id. **没有 MV 是空态(`Ok(None)`), 不是错误** ——
    /// 只有网络/风控/无权限才上抛, 调用方据此决定要不要显示 MV 入口.
    fn song_mv_id(&self, _song_id: u64) -> BoxFuture<'_, ProviderResult<Option<u64>>> {
        Box::pin(async { Err(ProviderError::unsupported("no song mv")) })
    }

    /// 搜索建议(输入联想)
    fn search_suggest<'a>(
        &'a self,
        _keywords: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<SuggestItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no search suggest")) })
    }

    /// 联想下拉的**纯关键词候选**(最多 6 条, 已去重保序).
    ///
    /// 与 `search_suggest` 的区别: 后者回的是「实体卡片」( songs/artists/albums/playlists 分段),
    /// 这里只是可点的候选词串, 适合输入框下方的简版下拉.
    /// 能力声明复用 [`Capability::SearchSuggest`].
    fn search_suggest_keywords<'a>(
        &'a self,
        _keywords: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<String>>> {
        Box::pin(async { Err(ProviderError::unsupported("no suggest keywords")) })
    }

    /// 精确实体改写: 关键词命中歌手/歌单/电台时的"最精确那一条".
    ///
    /// 注意**空命中伪装成功**: provider 侧必须把 orders 为空的结果翻成 [`SearchExact::default()`],
    /// 不要当错误抛. 能力声明复用 [`Capability::SearchSuggest`].
    fn search_exact<'a>(
        &'a self,
        _keywords: &'a str,
    ) -> BoxFuture<'a, ProviderResult<SearchExact>> {
        Box::pin(async { Err(ProviderError::unsupported("no search exact")) })
    }

    /// 搜索热词榜(已按热度排序, rank 从 1 开始)
    fn hot_search(&self) -> BoxFuture<'_, ProviderResult<Vec<HotSearchTerm>>> {
        Box::pin(async { Err(ProviderError::unsupported("no hot search")) })
    }

    /// 热搜榜详情(带热度分与榜位, 比 [`Self::hot_search`] 的瘦热词多 score/rank).
    /// 能力声明复用 [`Capability::SearchHot`].
    fn hot_search_detail(&self) -> BoxFuture<'_, ProviderResult<Vec<HotSearchDetailItem>>> {
        Box::pin(async { Err(ProviderError::unsupported("no hot search detail")) })
    }

    /// 默认/推荐搜索词("猜你想搜"): keyword 是要搜的词, show 是推荐理由文案
    fn default_search(&self) -> BoxFuture<'_, ProviderResult<Option<DefaultSearch>>> {
        Box::pin(async { Err(ProviderError::unsupported("no default search")) })
    }

    /// 歌曲百科(曲风/语种/BPM/获奖成就...). 没有百科时返回空列表.
    fn song_wiki(&self, _song_id: u64) -> BoxFuture<'_, ProviderResult<Vec<WikiFact>>> {
        Box::pin(async { Err(ProviderError::unsupported("no song wiki")) })
    }

    /// 单曲喜欢状态 + 喜欢总数(需要登录; 老 provider 不支持时报 unsupported).
    fn song_like_state(&self, _song_id: u64) -> BoxFuture<'_, ProviderResult<SongLikeState>> {
        Box::pin(async { Err(ProviderError::unsupported("no song like state")) })
    }
}
