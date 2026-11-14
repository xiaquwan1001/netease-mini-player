use super::Query;
use crate::error::Result;
/// 云盘歌曲详情(按 songId 批量)
/// 对应 Node.js module/user_cloud_detail.js
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 云盘歌曲详情
    /// 对应 /api/v1/cloud/get/byids
    ///
    /// 上游要求 songIds 是 **JSON 字符串**(逗号分隔的 id 会退化成空结果).
    pub async fn user_cloud_detail(&self, query: &Query) -> Result<ApiResponse> {
        let ids: Vec<serde_json::Value> = query
            .get_or("songIds", "")
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(|id| json!(id.parse::<i64>().unwrap_or(0)))
            .collect();
        let data = json!({
            "songIds": serde_json::to_string(&ids).unwrap_or_else(|_| "[]".to_string()),
        });
        self.request(
            "/api/v1/cloud/get/byids",
            data,
            query.to_option(CryptoType::Weapi),
        )
        .await
    }
}
