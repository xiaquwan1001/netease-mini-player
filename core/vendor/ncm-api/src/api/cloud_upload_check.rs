use super::Query;
use crate::error::Result;
/// 云盘上传: 文件查重 / 秒传判定
/// 对应 Node.js module/cloud_upload_token.js 的第一段
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 上传前查重: /api/cloud/upload/check
    ///
    /// body: {bitrate:"999000", ext:"", length:<字节>, md5:<hex>, songId:"0", version:1}
    /// 响应: {code, needUpload, songId, ...} —— needUpload=false 表示云端已有同 md5 文件(秒传)。
    pub async fn cloud_upload_check(&self, query: &Query) -> Result<ApiResponse> {
        let data = json!({
            "bitrate": "999000",
            "ext": "",
            "length": query.get_or("length", "0"),
            "md5": query.get_or("md5", ""),
            "songId": "0",
            "version": 1,
        });
        self.request(
            "/api/cloud/upload/check",
            data,
            query.to_option(CryptoType::default()),
        )
        .await
    }
}
