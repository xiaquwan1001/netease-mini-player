//! 音乐云盘: 列表 / 删除 / 下载直链(上传本轮未做).
//!
//! 拆分自原 api.rs (2026-11-20 架构审计 7.2: 单文件按域拆开),
//! 函数签名与行为与原文件逐字一致, 只是搬家。
//! 本文件里的 #[frb(mirror(..))] 就是 Dart 侧的类定义 -- 改这里 = 改 Dart API。

pub(crate) use super::*;

// ---------------- 音乐云盘 ----------------
// 说明: 云盘列表/删除/下载直链已接通上游; **上传(分片 NOS)本轮不做**。

/// 云盘条目(镜像 domain 类型 CloudSong)
#[frb(mirror(CloudSong))]
pub struct _CloudSong {
    /// 云盘条目 id(删除用这个, 不是 song_id)
    pub id: u64,
    /// 歌曲 id(播放/详情用)
    pub song_id: u64,
    pub name: String,
    /// 歌手(多歌手已用 " / " 拼好)
    pub artist: String,
    pub album: String,
    pub cover_url: Option<String>,
    /// 文件字节数
    pub size: u64,
    /// 码率(bps)
    pub bitrate: u64,
    /// 上传时间(unix 毫秒)
    pub add_time: u64,
}

/// 云盘列表页(镜像 domain 类型 CloudPage)
#[frb(mirror(CloudPage))]
pub struct _CloudPage {
    pub songs: Vec<CloudSong>,
    /// 云盘总曲目数
    pub count: u64,
    /// 已用容量(字节)
    pub size: u64,
    /// 容量上限(字节; 0 = 未知)
    pub max_size: u64,
    /// 本页之后是否还有(翻页靠 offset += songs.length)
    pub more: bool,
}

/// 音乐云盘列表(需要登录). offset 翻页.
pub async fn user_cloud(limit: u32, offset: u32) -> Result<CloudPage, FfiError> {
    let provider = with_provider(Capability::Cloud)?;
    provider
        .user_cloud(limit, offset)
        .await
        .map_err(FfiError::from)
}

/// 删除云盘歌曲(需要登录). ids 是**云盘条目 id**(CloudSong.id).
pub async fn cloud_delete(ids: Vec<u64>) -> Result<bool, FfiError> {
    let provider = with_provider(Capability::Cloud)?;
    provider.cloud_delete(&ids).await.map_err(FfiError::from)
}

/// 云盘歌曲下载直链(需要登录; 签名 URL 约一小时过期).
// UI 未用(2026-11-20 审计 7.2: ui/lib + ui/test 全量 grep 零命中) ⇒ `#[frb(ignore)]` 从 Dart API
// 摘掉后观察期已过, **结论: 有意保留**(2026-11-22 审计 C 收口, 分类见 docs/api-coverage.md
// 「有意保留(4)」), 不再按「候选删除」处理。
#[frb(ignore)]
pub async fn cloud_song_url(song_id: u64) -> Result<Option<String>, FfiError> {
    let provider = with_provider(Capability::Cloud)?;
    provider
        .cloud_song_url(song_id)
        .await
        .map_err(FfiError::from)
}
