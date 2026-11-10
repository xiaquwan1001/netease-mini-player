//! 歌单写接口(新建/批量加歌)的响应 DTO。
//! 字段口径与真实响应样例见 docs/b7-playlist-write-notes.md(2026-11-10 实测)。
//! 纯数据类型(本 crate 不依赖 serde_json); JSON 解析在 ncm-service/src/netease.rs 的 parse_* 函数。

use serde::{Deserialize, Serialize};

/// 新建歌单响应。
/// 实测: {"code":200,"id":18580697682,"playlist":{"id":18580697682,"name":"...","privacy":0,"trackCount":0,...}}
/// id 在顶层; playlist.id 是同值冗余(解析时双路提取)。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreatedPlaylist {
    /// 新歌单 id(0 = 无效)
    #[serde(default)]
    pub id: u64,
    /// 歌单名(顶层没有时回退 playlist.name, 都没有就是空串)
    #[serde(default)]
    pub name: String,
}

/// 歌单写操作(playlist_tracks / playlist_delete 等)的通用结果。
/// 实测:
/// - tracks add: {"cloudCount":0,"code":200,"count":2,"trackIds":"[186016,26305527]"}
///   (trackIds 是**字符串**——数组 JSON 文本, 不是数组; count = 服务端接受数, 可能小于提交数)
/// - delete: {"code":200,"data":null,"message":null,"msg":null}
/// - 失败(风控/参数异常): {"code":500,"msg":"请求异常,请稍后重试"}
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlaylistEditResult {
    #[serde(default)]
    pub code: i64,
    /// 服务端消息(成功时通常没有; message/msg 双字段兜底)
    #[serde(default)]
    pub message: Option<String>,
    /// 服务端接受数(只有 tracks add 给)
    #[serde(default)]
    pub count: Option<u64>,
    /// code == 200 视为接受
    #[serde(default)]
    pub ok: bool,
}
