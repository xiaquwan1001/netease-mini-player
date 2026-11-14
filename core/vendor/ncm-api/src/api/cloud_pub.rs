use super::Query;
use crate::error::Result;
/// 云盘上传: 发布到云盘
/// 对应 Node.js module/cloud_upload_complete.js 的第二段
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 发布云盘歌曲: /api/cloud/pub/v2
    pub async fn cloud_pub(&self, query: &Query) -> Result<ApiResponse> {
        let data = json!({ "songid": query.get_or("songid", "0") });
        self.request(
            "/api/cloud/pub/v2",
            data,
            query.to_option(CryptoType::default()),
        )
        .await
    }
}
