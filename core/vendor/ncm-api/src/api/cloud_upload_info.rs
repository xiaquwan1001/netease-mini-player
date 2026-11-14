use super::Query;
use crate::error::Result;
/// 云盘上传: 提交歌曲信息
/// 对应 Node.js module/cloud_upload_complete.js 的第一段
use crate::request::{ApiClient, ApiResponse, CryptoType};
use serde_json::json;

impl ApiClient {
    /// 提交云盘歌曲信息: /api/upload/cloud/info/v2
    ///
    /// body: {md5, songid, filename, song, album, artist, bitrate:"999000", resourceId}
    pub async fn cloud_upload_info(&self, query: &Query) -> Result<ApiResponse> {
        let data = json!({
            "md5": query.get_or("md5", ""),
            "songid": query.get_or("songid", "0"),
            "filename": query.get_or("filename", ""),
            "song": query.get_or("song", ""),
            "album": query.get_or("album", "未知专辑"),
            "artist": query.get_or("artist", "未知艺术家"),
            "bitrate": "999000",
            "resourceId": query.get_or("resourceId", ""),
        });
        self.request(
            "/api/upload/cloud/info/v2",
            data,
            query.to_option(CryptoType::default()),
        )
        .await
    }
}
