use super::Query;
use crate::error::Result;
/// 发送私信
/// 对应 Node.js module/send_text.js
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 发送私信: POST /api/msg/private/send (weapi)
    ///
    /// 上游参数: type="text", msg=<内容>, userIds="[<uid>]" —— userIds 是字符串化的
    /// JSON 数组(服务端按文本解析), 不能直接传数组, 与 Node 实现保持一致。
    pub async fn send_text(&self, query: &Query) -> Result<ApiResponse> {
        let data = json!({
            "type": "text",
            "msg": query.get_or("msg", ""),
            "userIds": format!("[{}]", query.get_or("user_ids", "0")),
        });
        self.request(
            "/api/msg/private/send",
            data,
            query.to_option(CryptoType::Weapi),
        )
        .await
    }
}
