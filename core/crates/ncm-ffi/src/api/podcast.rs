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
    pub program_count: u64,
    pub play_count: u64,
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
