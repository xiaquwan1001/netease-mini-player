use super::Query;
use crate::error::Result;
/// 云盘歌曲列表
/// 对应 Node.js module/user_cloud.js
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 云盘歌曲列表(分页)
    /// 对应 /api/v1/cloud/get
    pub async fn user_cloud(&self, query: &Query) -> Result<ApiResponse> {
        let data = json!({
            "limit": query.get_i64("limit", 30),
            "offset": query.get_i64("offset", 0),
        });
        self.request(
            "/api/v1/cloud/get",
            data,
            query.to_option(CryptoType::Weapi),
        )
        .await
    }
}
