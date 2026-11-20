//! 收藏(红心)与歌单: 红心状态、我的歌单、歌单增删改、收藏到歌单.
//!
//! 拆分自原 api.rs (2026-11-20 架构审计 7.2: 单文件按域拆开),
//! 函数签名与行为与原文件逐字一致, 只是搬家。
//! 本文件里的 #[frb(mirror(..))] 就是 Dart 侧的类定义 -- 改这里 = 改 Dart API。

pub(crate) use super::*;

// ---------------- 收藏(红心)与歌单 ----------------

/// 歌单(列表项): 直接镜像 domain 类型 `Playlist`.
#[frb(mirror(Playlist))]
pub struct _Playlist {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub track_count: u64,
    /// 是否"我喜欢的音乐"
    pub special: bool,
    /// 是否"我收藏的"(true = 收藏, false = 创建)
    pub subscribed: bool,
}

/// "我喜欢的音乐"里的曲目 id(红心状态的唯一真相)
pub async fn liked_ids() -> Result<Vec<u64>, FfiError> {
    let provider = with_provider(Capability::Playlist)?;
    let ids = provider.liked_ids().await.map_err(FfiError::from)?;
    Ok(ids.into_iter().map(|t| t.0).collect())
}

/// 红心/取消红心(需登录)
pub async fn set_liked(track_id: u64, liked: bool) -> Result<bool, FfiError> {
    ffi_forward!(
        Capability::Playlist,
        provider.set_like(ncm_domain::TrackId::new(track_id), liked)
    )
}

/// 我的歌单(含"我喜欢的音乐")
pub async fn my_playlists() -> Result<Vec<Playlist>, FfiError> {
    ffi_forward!(Capability::Playlist, provider.user_playlists())
}

/// 某个歌单的曲目
pub async fn playlist_songs(playlist_id: u64) -> Result<Vec<SongDto>, FfiError> {
    let provider = with_provider(Capability::Playlist)?;
    let songs = provider
        .playlist_songs(playlist_id)
        .await
        .map_err(FfiError::from)?;
    Ok(songs.into_iter().map(song_dto).collect())
}

/// "我喜欢的音乐"曲目详情(按收藏时间从新到旧)
pub async fn liked_songs() -> Result<Vec<SongDto>, FfiError> {
    let provider = with_provider(Capability::Playlist)?;
    // 优先用歌单详情的 addTime(真实收藏时间)排序; 老 provider 回落到 likelist 顺序
    match provider.liked_songs_ordered().await {
        Ok(songs) if !songs.is_empty() => return Ok(songs.into_iter().map(song_dto).collect()),
        Ok(_) => {}
        Err(_) => {}
    }
    let ids = provider.liked_ids().await.map_err(FfiError::from)?;
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    // 先把 id 拼成一次详情请求(vendor 的 song_detail 只认逗号分隔), 分块避免 URL 过长
    // 详情接口不保证按请求顺序返回(还可能缺曲), 用 id→Song 映射按 likelist 顺序还原
    let mut by_id: std::collections::HashMap<u64, ncm_domain::Song> =
        std::collections::HashMap::new();
    for chunk in ids.chunks(500) {
        let joined = chunk
            .iter()
            .map(|t| t.0.to_string())
            .collect::<Vec<_>>()
            .join(",");
        let detail = provider
            .songs_detail(&joined)
            .await
            .map_err(FfiError::from)?;
        for s in detail {
            by_id.insert(s.id.0, s);
        }
    }
    Ok(ids
        .iter()
        .filter_map(|t| by_id.remove(&t.0))
        .map(song_dto)
        .collect())
}

/// 新建歌单(需登录), 返回新歌单 id. privacy: 0=公开 10=私密
pub async fn create_playlist(name: String, privacy: u32) -> Result<u64, FfiError> {
    let name = name.as_str();
    ffi_forward!(
        Capability::PlaylistEdit,
        provider.create_playlist(name, privacy as u8)
    )
}

/// 删除歌单(需登录, 且只能删自己的)
pub async fn delete_playlist(playlist_id: u64) -> Result<bool, FfiError> {
    ffi_forward!(
        Capability::PlaylistEdit,
        provider.delete_playlist(playlist_id)
    )
}

/// 改歌单名
pub async fn rename_playlist(playlist_id: u64, name: String) -> Result<bool, FfiError> {
    let name = name.as_str();
    ffi_forward!(
        Capability::PlaylistEdit,
        provider.rename_playlist(playlist_id, name)
    )
}

/// 改歌单简介
pub async fn update_playlist_desc(playlist_id: u64, desc: String) -> Result<bool, FfiError> {
    let desc = desc.as_str();
    ffi_forward!(
        Capability::PlaylistEdit,
        provider.update_playlist_desc(playlist_id, desc)
    )
}

/// 把一首歌移出歌单(需登录)
pub async fn remove_from_playlist(playlist_id: u64, track_id: u64) -> Result<bool, FfiError> {
    ffi_forward!(
        Capability::PlaylistEdit,
        provider.remove_track(playlist_id, ncm_domain::TrackId::new(track_id))
    )
}

/// 每日推荐"不感兴趣"(需登录)
pub async fn dislike_recommend_song(song_id: u64) -> Result<bool, FfiError> {
    ffi_forward!(
        Capability::DailyRecommend,
        provider.dislike_recommend_song(song_id)
    )
}
