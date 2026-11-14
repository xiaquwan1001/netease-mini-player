use super::Query;
use crate::error::Result;
/// 歌手关注数/粉丝数
/// 对应 Node.js module/artist_follow_count.js
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 歌手粉丝数 + 当前账号是否关注(匿名可用)
    ///
    /// 实测响应: {code:200, data:{fansCnt, followCnt, isFollow, followDay, ...}}
    /// 注意参数名是 `id`(不是 artistId, 后者会返回 code=400 参数错误)。
    pub async fn artist_follow_count(&self, query: &Query) -> Result<ApiResponse> {
        let data = json!({
            "id": query.get_or("id", "0")
        });
        self.request(
            "/api/artist/follow/count/get",
            data,
            query.to_option(CryptoType::Weapi),
        )
        .await
    }
}
