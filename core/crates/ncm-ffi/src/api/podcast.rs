//! 播客: 热门电台 / 单集列表与单集详情.
//!
//! 拆分自原 api.rs (2026-11-20 架构审计 7.2: 单文件按域拆开),
//! 函数签名与行为与原文件逐字一致, 只是搬家。
//! 本文件里的 #[frb(mirror(..))] 就是 Dart 侧的类定义 -- 改这里 = 改 Dart API。

pub(crate) use super::*;

// ---------------- 播客 ----------------

#[frb(mirror(PodcastRadio))]
pub struct _PodcastRadio {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub description: String,
    pub dj_name: String,
    /// 主播 uid(0 = 该通道不带, UI 按不可点处理)
    pub dj_id: u64,
    pub program_count: u64,
    pub play_count: u64,
    /// 已收藏: None = 接口没给(列表/搜索), 不要当成 false
    pub subed: Option<bool>,
    pub sub_count: u64,
}

pub struct PodcastProgramDto {
    pub id: u64,
    pub name: String,
    pub cover_url: Option<String>,
    pub duration_ms: u64,
    pub dj_name: String,
    pub radio_id: u64,
    pub radio_name: String,
    pub description: String,
    /// 节目音频本体(播放用 song.id 取直链)
    pub song: Option<SongDto>,
}

/// 热门播客/电台
pub async fn podcast_hot(limit: u32) -> Result<Vec<PodcastRadio>, FfiError> {
    ffi_forward!(Capability::Podcast, provider.podcast_hot(limit))
}

/// 播客/电台详情: 列表通道不带 `subed`/`subCount`(收藏态), 详情页用它补齐
/// (2026-11-22 F5: 顶部要画「收藏」而不是「听众」, 状态必须准确)。
pub async fn podcast_radio(radio_id: u64) -> Result<PodcastRadio, FfiError> {
    ffi_forward!(Capability::Podcast, provider.podcast_radio(radio_id))
}

/// 某个播客的节目列表
pub async fn podcast_programs(
    radio_id: u64,
    limit: u32,
    offset: u32,
) -> Result<Vec<PodcastProgramDto>, FfiError> {
    let provider = with_provider(Capability::Podcast)?;
    let list = provider
        .podcast_programs(radio_id, limit, offset)
        .await
        .map_err(FfiError::from)?;
    Ok(list.into_iter().map(program_dto).collect())
}

/// 单个节目详情
pub async fn podcast_program(program_id: u64) -> Result<PodcastProgramDto, FfiError> {
    let provider = with_provider(Capability::Podcast)?;
    let p = provider
        .podcast_program(program_id)
        .await
        .map_err(FfiError::from)?;
    Ok(program_dto(p))
}

/// 收藏/取消收藏播客(电台): 需要登录; 成功后由调用方回写本地状态(与歌单/专辑同款口径)。
pub async fn set_podcast_subscribed(radio_id: u64, subscribed: bool) -> Result<bool, FfiError> {
    ffi_forward!(
        Capability::Podcast,
        provider.set_podcast_subscribed(radio_id, subscribed)
    )
}
