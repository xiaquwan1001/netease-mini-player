use super::Query;
use crate::error::Result;
/// 云盘上传: 申请 NOS 对象存储上传 token
/// 对应 Node.js module/cloud_upload_token.js 的第二段
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 申请 NOS 上传 token: /api/nos/token/alloc (weapi)
    ///
    /// body: {bucket, ext, filename, local:false, nos_product:3, type:"audio", md5}
    /// 响应: result.{token, objectKey, resourceId}
    pub async fn cloud_nos_token(&self, query: &Query) -> Result<ApiResponse> {
        let data = json!({
            "bucket": query.get_or("bucket", "jd-musicrep-privatecloud-audio-public"),
            "ext": query.get_or("ext", "mp3"),
            "filename": query.get_or("filename", ""),
            "local": false,
            "nos_product": 3,
            "type": "audio",
            "md5": query.get_or("md5", ""),
        });
        self.request(
            "/api/nos/token/alloc",
            data,
            query.to_option(CryptoType::Weapi),
        )
        .await
    }
}
