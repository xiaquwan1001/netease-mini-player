//! 发现: 榜单目录 / 歌单分类 / 高质量歌单 / 新碟 / 相似内容.
//!
//! 拆分自原 api.rs (2026-11-20 架构审计 7.2: 单文件按域拆开),
//! 函数签名与行为与原文件逐字一致, 只是搬家。
//! 本文件里的 #[frb(mirror(..))] 就是 Dart 侧的类定义 -- 改这里 = 改 Dart API。

use super::*;

#[frb(mirror(ChartSummary))]
pub struct _ChartSummary {
    /// 榜单就是歌单, 直接喂给 playlist_songs / playlist_detail
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    /// "每周四更新" / "刚刚更新"
    pub update_frequency: String,
    pub track_count: u64,
    pub play_count: u64,
}

/// 排行榜列表(飙升/新歌/热歌/原创 + 语种/曲风榜)
pub async fn chart_list() -> Result<Vec<ChartSummary>, FfiError> {
    ffi_forward!(Capability::Chart, provider.charts())
}

/// 榜单 v2 目录里的一张榜单卡
#[frb(mirror(ToplistCatalogItem))]
pub struct _ToplistCatalogItem {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    /// "每周五更新"
    pub update_frequency: String,
    /// 实测恒 "PLAYLIST"
    pub target_type: String,
    pub can_play: bool,
}

/// 榜单 v2 目录的一个分组(categoryCode)
#[frb(mirror(ToplistCatalogGroup))]
pub struct _ToplistCatalogGroup {
    pub code: String,
    pub items: Vec<ToplistCatalogItem>,
}

/// 最新专辑(album_newest, 固定 12 张); 复用 AlbumItem
pub async fn newest_albums(limit: u32) -> Result<Vec<AlbumItem>, FfiError> {
    ffi_forward!(Capability::NewRelease, provider.newest_albums(limit))
}

/// 榜单 v2 目录(toplist_detail_v2, 按 categoryCode 分组)
pub async fn toplist_catalog() -> Result<Vec<ToplistCatalogGroup>, FfiError> {
    ffi_forward!(Capability::Chart, provider.toplist_catalog())
}

#[frb(mirror(PlaylistCategory))]
pub struct _PlaylistCategory {
    /// 一级分类(语种/风格/场景/情感/主题)
    pub group: String,
    /// 该分类下的子分类名(华语/欧美/流行…), 直接作为 playlists_by_category 的 cat
    pub subs: Vec<String>,
}

/// 歌单分类(歌单广场的筛选条)
pub async fn playlist_categories() -> Result<Vec<PlaylistCategory>, FfiError> {
    ffi_forward!(Capability::Playlist, provider.playlist_categories())
}

/// 某个分类下的歌单(按热度, offset 翻页)
pub async fn playlists_by_category(
    cat: String,
    limit: u32,
    offset: u32,
) -> Result<Vec<Playlist>, FfiError> {
    let provider = with_provider(Capability::Playlist)?;
    let list = provider
        .playlists_by_category(&cat, limit, offset)
        .await
        .map_err(FfiError::from)?;
    Ok(list)
}

/// 精品歌单(编辑精选)
pub async fn high_quality_playlists(cat: String, limit: u32) -> Result<Vec<Playlist>, FfiError> {
    let provider = with_provider(Capability::Playlist)?;
    let list = provider
        .high_quality_playlists(&cat, limit)
        .await
        .map_err(FfiError::from)?;
    Ok(list)
}

/// 专辑列表项: 直接镜像 domain 类型 `AlbumItem`.
#[frb(mirror(AlbumItem))]
pub struct _AlbumItem {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub artist: String,
    pub track_count: u64,
}

/// 我收藏的专辑(需登录)
pub async fn subscribed_albums(limit: u32) -> Result<Vec<AlbumItem>, FfiError> {
    ffi_forward!(Capability::AlbumSub, provider.subscribed_albums(limit))
}

/// 收藏/取消收藏专辑(需登录)
pub async fn set_album_subscribed(album_id: u64, subscribed: bool) -> Result<bool, FfiError> {
    ffi_forward!(
        Capability::AlbumSub,
        provider.set_album_subscribed(album_id, subscribed)
    )
}

/// 新碟上架(limit<=30, offset 翻页); 复用 subscribed_albums 的 AlbumItem
pub async fn new_albums(limit: u32, offset: u32) -> Result<Vec<AlbumItem>, FfiError> {
    ffi_forward!(Capability::NewRelease, provider.new_albums(limit, offset))
}

/// 相似歌曲
pub async fn similar_songs(song_id: u64, limit: u32) -> Result<Vec<SongDto>, FfiError> {
    let provider = with_provider(Capability::Similar)?;
    let list = provider
        .similar_songs(song_id, limit)
        .await
        .map_err(FfiError::from)?;
    Ok(list.into_iter().map(song_dto).collect())
}

/// 相似歌单
pub async fn similar_playlists(song_id: u64, limit: u32) -> Result<Vec<Playlist>, FfiError> {
    let provider = with_provider(Capability::Similar)?;
    let list = provider
        .similar_playlists(song_id, limit)
        .await
        .map_err(FfiError::from)?;
    Ok(list)
}

/// 相似歌手(需登录)
pub async fn similar_artists(artist_id: u64) -> Result<Vec<Artist>, FfiError> {
    ffi_forward!(Capability::Similar, provider.similar_artists(artist_id))
}
