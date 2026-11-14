use super::Query;
use crate::error::Result;
/// 云盘歌曲删除
/// 对应 Node.js module/user_cloud_del.js
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 删除云盘歌曲
    /// 对应 /api/cloud/del
    ///
    /// 入参是**云盘条目 id**(data[].id), 不是歌曲 id; 上游同样要 JSON 字符串.
    pub async fn user_cloud_del(&self, query: &Query) -> Result<ApiResponse> {
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
        self.request("/api/cloud/del", data, query.to_option(CryptoType::Weapi))
            .await
    }
}
