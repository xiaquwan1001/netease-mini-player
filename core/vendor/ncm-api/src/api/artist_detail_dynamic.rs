use super::Query;
use crate::error::Result;
/// 歌手动态信息
/// 对应 Node.js module/artist_detail_dynamic.js
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 歌手动态信息: /api/artist/detail/dynamic
    ///
    /// 上游 module/artist_detail_dynamic.js 只传 `{id}`, 用默认加密(与 artist_detail 一致)。
    /// 返回结构尚未纳入 vendor 类型, 先用原始 JSON(排障/建模用)。
    pub async fn artist_detail_dynamic(&self, query: &Query) -> Result<ApiResponse> {
        let data = json!({
            "id": query.get_or("id", "0")
        });
        self.request(
            "/api/artist/detail/dynamic",
            data,
            query.to_option(CryptoType::default()),
        )
        .await
    }
}
