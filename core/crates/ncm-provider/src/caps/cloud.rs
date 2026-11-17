//! `CloudProvider` — 音乐云盘。
//!
//! 归类口径与拆分理由见 `docs/remaining-batches.md` §12.2;
//! 组合面仍是 `crate::r#trait::Provider`(超 trait), 调用点不变.

use crate::error::{ProviderError, ProviderResult};
use crate::params::BoxFuture;
use ncm_domain::{CloudPage, CloudUploadResult};
pub trait CloudProvider: Send + Sync {
    /// 音乐云盘列表(需要登录). 不含上传。
    fn user_cloud(&self, _limit: u32, _offset: u32) -> BoxFuture<'_, ProviderResult<CloudPage>> {
        Box::pin(async { Err(ProviderError::unsupported("no cloud")) })
    }

    /// 删除云盘歌曲(入参是云盘条目 id, 见 CloudSong::id)
    fn cloud_delete(&self, _ids: &[u64]) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async { Err(ProviderError::unsupported("no cloud delete")) })
    }

    /// 云盘歌曲下载直链(签名 URL, 约一小时过期)
    fn cloud_song_url(&self, _song_id: u64) -> BoxFuture<'_, ProviderResult<Option<String>>> {
        Box::pin(async { Err(ProviderError::unsupported("no cloud song url")) })
    }

    /// 上传本地音频到音乐云盘(需登录); 返回新歌 id/歌名. 默认不支持.
    fn cloud_upload(&self, _file_path: String) -> BoxFuture<'_, ProviderResult<CloudUploadResult>> {
        Box::pin(async { Err(ProviderError::unsupported("no cloud upload")) })
    }
}
