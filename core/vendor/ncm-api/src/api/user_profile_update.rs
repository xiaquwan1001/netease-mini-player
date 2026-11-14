use super::Query;
use crate::error::Result;
/// 编辑用户资料(签名/昵称等)
/// 对应 Node.js module/user_update.js
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 编辑用户资料: POST /api/user/profile/update (weapi)
    ///
    /// 上游 module/user_update.js 的 body:
    /// `{nickname, signature, gender, birthday, province, city}`;
    /// JS 里 undefined 字段会被 JSON.stringify 丢掉 ⇒ 只传想改的字段即可(局部更新),
    /// 所以这里按 Query 里出现的参数逐个带上, 缺省字段不发。
    pub async fn user_profile_update(&self, query: &Query) -> Result<ApiResponse> {
        let mut map = serde_json::Map::new();
        for key in [
            "nickname",
            "signature",
            "gender",
            "birthday",
            "province",
            "city",
        ] {
            if let Some(value) = query.get(key) {
                map.insert(key.to_string(), json!(value));
            }
        }
        self.request(
            "/api/user/profile/update",
            serde_json::Value::Object(map),
            query.to_option(CryptoType::Weapi),
        )
        .await
    }
}
