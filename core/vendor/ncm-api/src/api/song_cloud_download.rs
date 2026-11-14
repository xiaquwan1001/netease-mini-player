use super::Query;
use crate::error::Result;
/// 云盘歌曲下载直链
/// 对应 Node.js module/song_cloud_download.js
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 云盘歌曲下载直链(eapi)
    /// 对应 /api/cloud/dowonload —— **上游路径就是拼错的 dowonload**, 不要"修正"成 download.
    pub async fn song_cloud_download(&self, query: &Query) -> Result<ApiResponse> {
        let data = json!({
            "songId": query.get_or("songId", "0"),
        });
        self.request(
            "/api/cloud/dowonload",
            data,
            query.to_option(CryptoType::Eapi),
        )
        .await
    }
}
