//! 每日推荐 / 心动模式 / 私人 FM / 历史日推 / 推荐页订阅(播客/艺人).
//!
//! 拆分自原 api.rs (2026-11-20 架构审计 7.2: 单文件按域拆开),
//! 函数签名与行为与原文件逐字一致, 只是搬家。
//! 本文件里的 #[frb(mirror(..))] 就是 Dart 侧的类定义 -- 改这里 = 改 Dart API。

pub(crate) use super::*;

// ---------------- 每日推荐 / 心动模式 ----------------

/// 每日推荐歌曲(原版每日推荐)
pub async fn daily_recommend_songs() -> Result<Vec<SongDto>, FfiError> {
    let provider = with_provider(Capability::DailyRecommend)?;
    let songs = provider
        .daily_recommend_songs()
        .await
        .map_err(FfiError::from)?;
    Ok(songs.into_iter().map(song_dto).collect())
}

/// 每日推荐歌单(原版推荐歌单, 需要登录)
pub async fn daily_recommend_playlists() -> Result<Vec<Playlist>, FfiError> {
    ffi_forward!(
        Capability::DailyRecommend,
        provider.daily_recommend_playlists()
    )
}

/// 心动模式: 以当前曲目为种子, 在 playlist_id(0 = 不限定)里续播 count 首
pub async fn heart_mode_songs(
    song_id: u64,
    playlist_id: u64,
    count: u32,
) -> Result<Vec<SongDto>, FfiError> {
    let provider = with_provider(Capability::DailyRecommend)?;
    let songs = provider
        .intelligence_songs(song_id, playlist_id, count)
        .await
        .map_err(FfiError::from)?;
    Ok(songs.into_iter().map(song_dto).collect())
}

// ---------------- 推荐页(私人 FM) / 我的(收藏播客/关注艺人/动态) ----------------

/// 私人 FM(需登录)
pub async fn personal_fm(limit: u32) -> Result<Vec<SongDto>, FfiError> {
    let provider = with_provider(Capability::PersonalFm)?;
    let songs = provider.personal_fm(limit).await.map_err(FfiError::from)?;
    Ok(songs.into_iter().map(song_dto).collect())
}

/// 已收藏/订阅的播客(需登录)
pub async fn subscribed_podcasts(limit: u32) -> Result<Vec<PodcastRadio>, FfiError> {
    ffi_forward!(Capability::Podcast, provider.subscribed_podcasts(limit))
}

/// 歌手(简化版): 直接镜像 domain 类型 `Artist`.
#[frb(mirror(Artist))]
pub struct _Artist {
    pub id: u64,
    pub name: String,
    pub avatar_url: Option<String>,
}

/// 关注的艺人(需登录)
pub async fn subscribed_artists(limit: u32) -> Result<Vec<Artist>, FfiError> {
    ffi_forward!(Capability::Feed, provider.subscribed_artists(limit))
}

/// 私人 FM"不再播放"(需登录)
pub async fn trash_fm_song(song_id: u64) -> Result<bool, FfiError> {
    ffi_forward!(Capability::PersonalFm, provider.trash_fm_song(song_id))
}

/// 历史日推可用日期(黑胶 VIP; 新的在前)
pub async fn history_recommend_dates() -> Result<Vec<String>, FfiError> {
    ffi_forward!(
        Capability::DailyRecommend,
        provider.history_recommend_dates()
    )
}

/// 某个日期的历史日推曲目
pub async fn history_recommend_songs(date: String) -> Result<Vec<SongDto>, FfiError> {
    ffi_forward!(Capability::DailyRecommend, provider.history_recommend_songs(&date), map_each song_dto)
}

/// 推荐新音乐("新歌速递")
pub async fn new_songs(limit: u32) -> Result<Vec<SongDto>, FfiError> {
    ffi_forward!(Capability::NewRelease, provider.new_songs(limit), map_each song_dto)
}
