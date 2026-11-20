//! 歌手详情与歌手资源(全部歌曲 / 专辑 / MV), 以及 MV 详情与播放直链.
//!
//! 拆分自原 api.rs (2026-11-20 架构审计 7.2: 单文件按域拆开),
//! 函数签名与行为与原文件逐字一致, 只是搬家。
//! 本文件里的 #[frb(mirror(..))] 就是 Dart 侧的类定义 -- 改这里 = 改 Dart API。

pub(crate) use super::*;

// ---------------- 歌手详情 ----------------

#[frb(mirror(AlbumBrief))]
pub struct _AlbumBrief {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub track_count: u64,
    pub publish_time: u64,
}

pub struct ArtistDetailDto {
    pub id: u64,
    pub name: String,
    pub avatar_url: Option<String>,
    pub cover_url: Option<String>,
    pub alias: Vec<String>,
    pub brief_desc: String,
    pub album_count: u64,
    pub music_count: u64,
    /// 粉丝数(0 = 上游没给, UI 不渲染该 chip)
    pub fans_count: u64,
    /// 当前账号是否已关注(匿名/失败 = false)
    pub followed: bool,
    /// 艺人绑定的用户账号 id(None = 该歌手没有绑定账号, 艺人页不显示动态 tab)
    pub user_id: Option<u64>,
    /// 艺人动态条数(0 = 未知/没有)
    pub event_count: u64,
    pub songs: Vec<SongDto>,
    pub albums: Vec<AlbumBrief>,
}

/// 歌手详情(头像/简介/热门歌曲/专辑)
pub async fn artist_detail(artist_id: u64) -> Result<ArtistDetailDto, FfiError> {
    let provider = with_provider(Capability::Artist)?;
    let a = provider
        .artist_detail(artist_id)
        .await
        .map_err(FfiError::from)?;
    Ok(ArtistDetailDto {
        id: a.id,
        name: a.name,
        avatar_url: a.avatar_url,
        cover_url: a.cover_url,
        alias: a.alias,
        brief_desc: a.brief_desc,
        album_count: a.album_count,
        music_count: a.music_count,
        fans_count: a.fans_count,
        followed: a.followed,
        user_id: a.user_id,
        event_count: a.event_count,
        songs: a.songs.into_iter().map(song_dto).collect(),
        albums: a.albums,
    })
}

// ---------------- 歌手全部歌曲 / MV ----------------

pub struct ArtistSongPageDto {
    pub songs: Vec<SongDto>,
    pub has_more: bool,
}

pub struct ArtistMvDto {
    pub id: u64,
    pub name: String,
    pub duration_ms: u64,
    pub play_count: u64,
    pub publish_time: String,
    pub cover_url: Option<String>,
}

pub struct MvDetailDto {
    pub id: u64,
    pub name: String,
    pub artist_name: String,
    pub duration_ms: u64,
    pub play_count: u64,
    pub publish_time: String,
    pub cover_url: Option<String>,
    pub max_br: u32,
    pub brs: Vec<u32>,
    pub desc: Option<String>,
}

pub struct MvUrlDto {
    pub url: Option<String>,
    pub r: u32,
    pub size: u64,
}

pub struct ArtistMvPageDto {
    pub mvs: Vec<ArtistMvDto>,
    pub has_more: bool,
}

/// 歌手全部歌曲一页(artist_songs, offset/limit 分页)
pub async fn artist_songs_page(
    artist_id: u64,
    offset: u32,
    limit: u32,
) -> Result<ArtistSongPageDto, FfiError> {
    let provider = with_provider(Capability::Artist)?;
    let page = provider
        .artist_songs_page(artist_id, offset, limit)
        .await
        .map_err(FfiError::from)?;
    Ok(ArtistSongPageDto {
        songs: page.songs.into_iter().map(song_dto).collect(),
        has_more: page.has_more,
    })
}

pub struct ArtistAlbumPageDto {
    pub albums: Vec<AlbumBrief>,
    pub has_more: bool,
}

/// 歌手专辑一页(artist_album, offset/limit 分页). 头部 albumSize 是真实总数,
/// 详情只带前 20 张, 专辑 tab 用这个接口翻完.
pub async fn artist_albums_page(
    artist_id: u64,
    offset: u32,
    limit: u32,
) -> Result<ArtistAlbumPageDto, FfiError> {
    let provider = with_provider(Capability::Artist)?;
    let page = provider
        .artist_albums_page(artist_id, offset, limit)
        .await
        .map_err(FfiError::from)?;
    Ok(ArtistAlbumPageDto {
        albums: page.albums,
        has_more: page.has_more,
    })
}

/// 歌手 MV 一页(artist_mv, offset/limit 分页)
pub async fn artist_mvs_page(
    artist_id: u64,
    offset: u32,
    limit: u32,
) -> Result<ArtistMvPageDto, FfiError> {
    let provider = with_provider(Capability::Artist)?;
    let page = provider
        .artist_mvs_page(artist_id, offset, limit)
        .await
        .map_err(FfiError::from)?;
    Ok(ArtistMvPageDto {
        mvs: page
            .mvs
            .into_iter()
            .map(|m| ArtistMvDto {
                id: m.id,
                name: m.name,
                duration_ms: m.duration_ms,
                play_count: m.play_count,
                publish_time: m.publish_time,
                cover_url: m.cover_url,
            })
            .collect(),
        has_more: page.has_more,
    })
}

/// MV 详情(mv_detail)
pub async fn mv_detail(mv_id: u64) -> Result<MvDetailDto, FfiError> {
    let provider = with_provider(Capability::Artist)?;
    let d = provider.mv_detail(mv_id).await.map_err(FfiError::from)?;
    Ok(MvDetailDto {
        id: d.id,
        name: d.name,
        artist_name: d.artist_name,
        duration_ms: d.duration_ms,
        play_count: d.play_count,
        publish_time: d.publish_time,
        cover_url: d.cover_url,
        max_br: d.max_br,
        brs: d.brs,
        desc: d.desc,
    })
}

/// MV 播放链接(mv_url, r=清晰度档位, 0 表示请求最高)
pub async fn mv_url(mv_id: u64, r: u32) -> Result<MvUrlDto, FfiError> {
    let provider = with_provider(Capability::Artist)?;
    let u = provider.mv_url(mv_id, r).await.map_err(FfiError::from)?;
    Ok(MvUrlDto {
        url: u.url,
        r: u.r,
        size: u.size,
    })
}

/// 关注/取消关注歌手(需要登录). 返回 true 表示接口接受.
pub async fn artist_sub_toggle(artist_id: u64, sub: bool) -> Result<bool, FfiError> {
    let provider = with_provider(Capability::Artist)?;
    provider
        .toggle_artist_sub(artist_id, sub)
        .await
        .map_err(FfiError::from)
}
