use super::Query;
use crate::error::Result;
/// 单曲"喜欢"状态 + 喜欢总数
///
/// **不是 api-enhanced 的模块**: 路径从网易云官方 Android 9.6.13 的二进制里抓到
/// (2026-10 社区逆向记录), 官方客户端播放页 ♥ 旁边的数字就来自这里。
/// 旧的 `/api/radio/like` 只能写、读不到总数; `/api/v3/song/detail` 也不带 likedCount。
///
/// 响应形如 `{code:200, liked:false, likedCount:352}`。
/// **需要登录**: 匿名(无 MUSIC_U)返回 `{code:301}`。
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 读取单曲的喜欢状态与喜欢总数(需要登录)
    /// 对应 GET /api/song/like/get?id=
    pub async fn song_like_get(&self, query: &Query) -> Result<ApiResponse> {
        let data = json!({
            "id": query.get_or("id", "0"),
        });
        // 明文 api 通道: 官方端点是 GET, 服务端同时接受 POST form(实测两者回包一致)
        self.request("/api/song/like/get", data, query.to_option(CryptoType::Api))
            .await
    }
}
