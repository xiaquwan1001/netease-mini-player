use super::Query;
use crate::error::Result;
/// 云盘上传: 查询文件处理(转码)状态
/// 对应前端上传流程里的 /api/v1/cloud/music/status
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 查询云盘新歌处理状态: /api/v1/cloud/music/status
    ///
    /// body: {songIds:[<id>...]} —— 上游按数组解析, 这里把 query 的
    /// `song_ids`(逗号分隔)转成**字符串化 JSON 数组**, 与 vendor 里其它数组参数一致。
    pub async fn cloud_music_status(&self, query: &Query) -> Result<ApiResponse> {
        let ids: Vec<i64> = query
            .get_or("song_ids", "")
            .split(',')
            .filter_map(|s| s.trim().parse::<i64>().ok())
            .collect();
        let data = json!({
            "songIds": serde_json::to_string(&ids).unwrap_or_else(|_| "[]".to_string()),
        });
        self.request(
            "/api/v1/cloud/music/status",
            data,
            query.to_option(CryptoType::Weapi),
        )
        .await
    }
}
