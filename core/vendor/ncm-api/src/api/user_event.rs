use super::Query;
use crate::error::Result;
/// 指定用户的动态
/// 对应 Node.js module/user_event.js
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 指定用户的动态(他人主页/艺人绑定账号的「动态」)
    ///
    /// **端点是路径参数** `/api/event/get/{uid}`, 不是 `/api/v1/event/get` + body.uid:
    /// 后者只认登录用户的关注关系, uid 字段被服务端直接丢弃(实测: 传别人的 uid
    /// 返回的仍是自己的关注流)。这里用上游同款明文 api 通道; 响应顶层是
    /// `events`(复数) + `lasttime` + `more` + `size`。
    pub async fn user_event(&self, query: &Query) -> Result<ApiResponse> {
        let uid = query.get_or("uid", "0");
        let data = json!({
            "getcounts": true,
            "time": query.get_or("lasttime", "-1").parse::<i64>().unwrap_or(-1),
            "limit": query.get_or("limit", "30").parse::<i64>().unwrap_or(30),
            "total": false,
        });
        self.request(
            &format!("/api/event/get/{uid}"),
            data,
            query.to_option(CryptoType::Api),
        )
        .await
    }
}
