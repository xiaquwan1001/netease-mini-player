//! 综合搜索 / 联想词 / 搜索历史 / 热搜(搜索入口的全部 FFI 面).
//!
//! 拆分自原 api.rs (2026-11-20 架构审计 7.2: 单文件按域拆开),
//! 函数签名与行为与原文件逐字一致, 只是搬家。
//! 本文件里的 #[frb(mirror(..))] 就是 Dart 侧的类定义 -- 改这里 = 改 Dart API。

pub(crate) use super::*;

// ---------------- 综合搜索(分板块) ----------------

#[frb(mirror(SearchArtist))]
pub struct _SearchArtist {
    pub id: u64,
    pub name: String,
    pub avatar_url: Option<String>,
    /// 别名, 已用 " / " 拼好
    pub alias: String,
    pub album_count: u64,
    pub music_count: u64,
}

#[frb(mirror(SearchAlbum))]
pub struct _SearchAlbum {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub artist: String,
    pub track_count: u64,
}

#[frb(mirror(SearchPlaylistItem))]
pub struct _SearchPlaylistItem {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub creator_name: String,
    pub track_count: u64,
    pub play_count: u64,
}

#[frb(mirror(SearchPodcast))]
pub struct _SearchPodcast {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub dj_name: String,
    pub program_count: u64,
    pub play_count: u64,
}

/// 搜索命中的 MV(镜像 domain 类型 MvItem)
#[frb(mirror(MvItem))]
pub struct _MvItem {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    /// 歌手名(多歌手已用 " / " 拼好)
    pub artist_name: String,
    pub play_count: u64,
}

/// 综合搜索结果: 单曲/歌手/专辑/歌单/播客/MV/用户 各一个板块
pub struct SearchBundleDto {
    pub songs: Vec<SongDto>,
    pub song_total: u64,
    pub artists: Vec<SearchArtist>,
    pub albums: Vec<SearchAlbum>,
    pub playlists: Vec<SearchPlaylistItem>,
    pub podcasts: Vec<SearchPodcast>,
    /// 用户(type=1002)
    pub users: Vec<UserItem>,
    /// MV(type=1004)
    pub mvs: Vec<MvItem>,
}

/// 综合搜索: 一次拿回所有板块(UI 分区展示).
pub async fn search_all(keywords: String, limit: u32) -> Result<SearchBundleDto, FfiError> {
    let provider = with_provider(Capability::SearchAll)?;
    let query = SearchQuery {
        keywords,
        limit,
        offset: 0,
    };
    let bundle = provider.search_all(&query).await.map_err(FfiError::from)?;
    Ok(SearchBundleDto {
        songs: bundle.songs.into_iter().map(song_dto).collect(),
        song_total: bundle.song_total,
        artists: bundle.artists,
        albums: bundle.albums,
        playlists: bundle.playlists,
        users: bundle.users,
        podcasts: bundle.podcasts,
        mvs: bundle.mvs,
    })
}

// ---------------- 搜索建议 / 历史 ----------------

/// 搜索联想项: 直接镜像 domain 类型 `SuggestItem`.
#[frb(mirror(SuggestItem))]
pub struct _SuggestItem {
    /// song | artist | album | playlist
    pub kind: String,
    pub id: u64,
    pub title: String,
    pub subtitle: String,
    pub cover_url: Option<String>,
}

/// 搜索建议(输入联想)
pub async fn search_suggest(keywords: String) -> Result<Vec<SuggestItem>, FfiError> {
    if keywords.trim().is_empty() {
        return Ok(Vec::new());
    }
    ffi_forward!(
        Capability::SearchSuggest,
        provider.search_suggest(keywords.trim())
    )
}

fn history_store() -> Result<ncm_service::HistoryStore, FfiError> {
    let dir = DATA_DIR
        .get()
        .ok_or_else(|| FfiError::internal("core not initialized"))?;
    ncm_service::HistoryStore::open(dir).map_err(FfiError::from)
}

/// 搜索历史(最近在前)
pub fn search_history() -> Result<Vec<String>, FfiError> {
    Ok(history_store()?.search_history())
}

/// 记一条搜索(去重, 最近在前), 返回新的历史列表
pub fn record_search(keyword: String) -> Result<Vec<String>, FfiError> {
    history_store()?
        .record_search(&keyword)
        .map_err(FfiError::from)
}

pub fn clear_search_history() -> Result<bool, FfiError> {
    history_store()?.clear_search().map_err(FfiError::from)?;
    Ok(true)
}

/// 记一次播放到本地历史(未登录/离线时的"最近听过"来源)
pub fn remember_play(song: SongDto) -> Result<bool, FfiError> {
    let domain = song_from_dto(&song);
    history_store()?
        .record_play(&domain)
        .map_err(FfiError::from)?;
    Ok(true)
}

/// 本地播放历史
pub fn local_recent_songs(limit: u32) -> Result<Vec<SongDto>, FfiError> {
    let n = limit.max(1) as usize;
    Ok(history_store()?
        .played()
        .into_iter()
        .take(n)
        .map(song_dto)
        .collect())
}

/// 最近听过: 登录时优先服务端记录, 失败/未登录回落到本地历史
pub async fn recent_songs(limit: u32) -> Result<Vec<SongDto>, FfiError> {
    let logged_in = {
        let guard = core()?.lock().map_err(FfiError::from)?;
        guard.session.is_logged_in()
    };
    if logged_in {
        if let Ok(provider) = with_provider(Capability::Recent) {
            if let Ok(list) = provider.recent_songs(limit).await {
                if !list.is_empty() {
                    return Ok(list.into_iter().map(song_dto).collect());
                }
            }
        }
    }
    local_recent_songs(limit)
}

// ---------------- 搜索页(热词/推荐词) ----------------

#[frb(mirror(HotSearchTerm))]
pub struct _HotSearchTerm {
    /// 1 开始的名次
    pub rank: u32,
    pub keyword: String,
}

/// 热门搜索榜(按热度排序)
pub async fn hot_search() -> Result<Vec<HotSearchTerm>, FfiError> {
    ffi_forward!(Capability::SearchHot, provider.hot_search())
}

// ---------------- 搜索增强(B4): 纯词联想 / 精确实体改写 / 热搜详情 ----------------

/// 精确实体改写的结果: 直接镜像 domain SearchExact.
/// 注意: orders 为空即"无命中"(接口把空命中伪装成 code=200), 此时三个数组也都为空.
#[frb(mirror(SearchExact))]
pub struct _SearchExact {
    /// 命中类型顺序, 原样保留 (artist / playlist / voice / ...)
    pub orders: Vec<String>,
    pub artists: Vec<Artist>,
    pub playlists: Vec<Playlist>,
    pub podcasts: Vec<PodcastRadio>,
}

/// 联想下拉的纯关键词候选(最多 6 条, 已去重保序). 空/异常返回空 Vec, 不报错.
pub async fn search_suggest_keywords(keywords: String) -> Result<Vec<String>, FfiError> {
    ffi_forward!(
        Capability::SearchSuggest,
        provider.search_suggest_keywords(&keywords)
    )
}

/// 精确实体改写(歌手/歌单/电台各最多 1 条). 无命中时返回 orders 为空的 DTO, 不是错误.
pub async fn search_exact(keywords: String) -> Result<SearchExact, FfiError> {
    ffi_forward!(Capability::SearchSuggest, provider.search_exact(&keywords))
}

/// 热搜榜详情行: 带热度分与榜位(比 HotSearchTerm 多 score/icon_type)
#[frb(mirror(HotSearchDetailItem))]
pub struct _HotSearchDetailItem {
    pub keyword: String,
    /// 1 开始的榜位
    pub rank: u32,
    pub score: u64,
    /// 角标种类: 0 无图标, 2/4/5 等(未知值原样透传)
    pub icon_type: u32,
}

/// 热搜榜详情(20 条, 带 score/rank; 需要登录态更稳)
pub async fn hot_search_detail() -> Result<Vec<HotSearchDetailItem>, FfiError> {
    ffi_forward!(Capability::SearchHot, provider.hot_search_detail())
}

#[frb(mirror(DefaultSearch))]
pub struct _DefaultSearch {
    /// 真正要搜索的关键词(不含推荐理由)
    pub keyword: String,
    /// 官方展示文案, 形如 "🔥Mili 你的十月榜首"
    pub show_text: String,
    pub image_url: Option<String>,
}

/// 默认/推荐搜索词("猜你想搜"); 接口没有时返回 null
pub async fn default_search() -> Result<Option<DefaultSearch>, FfiError> {
    ffi_forward!(Capability::SearchHot, provider.default_search())
}
