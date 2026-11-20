//! `Provider` 的入参类型与异步返回别名。
//!
//! 与 trait 本体解耦: 这些是纯数据/工具类型, 不参与"实现哪些方法"的约定。

use crate::capability::AudioLevel;
use ncm_domain::TrackId;
use serde::{Deserialize, Serialize};
use std::future::Future;
use std::pin::Pin;

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchQuery {
    pub keywords: String,
    pub limit: u32,
    pub offset: u32,
}

impl SearchQuery {
    pub fn new(keywords: impl Into<String>) -> Self {
        Self {
            keywords: keywords.into(),
            limit: 30,
            offset: 0,
        }
    }

    pub fn limit(mut self, v: u32) -> Self {
        self.limit = v;
        self
    }

    pub fn offset(mut self, v: u32) -> Self {
        self.offset = v;
        self
    }
}

/// 取链时**上层已经知道**的歌曲上下文。
///
/// 内置 provider 不看它(网易云接口只吃 trackId); 音源插件要用它拼上游 LX 的
/// `musicInfo` —— 缺了 `name/singer` 时, 依赖关键词中转的脚本(咪咕 oiapi / QQ keyword 系)
/// 必然取不到链。字段口径按 LX 社区脚本: `interval` 是**秒**, 其余是原样字符串。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SongUrlMeta {
    pub name: String,
    /// 多歌手以 `/` 连接(LX 脚本自己再拆), 与 `SongDto.artist` 同口径.
    pub singer: String,
    pub album_name: String,
    pub album_id: u64,
    /// 时长(秒). 上层只有毫秒时传 `duration_ms / 1000`.
    pub interval: u64,
    /// kw/kg 系按 hash 取链、QQ 按 songmid 取链的兼容字段; 网易云曲目一般没有.
    pub song_mid: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SongUrlRequest {
    pub track: TrackId,
    pub level: AudioLevel,
    /// 上层已知的歌曲上下文(插件侧拼 `musicInfo` 用; 缺省 = 只有 id).
    #[serde(default)]
    pub meta: Option<SongUrlMeta>,
}

impl SongUrlRequest {
    pub fn new(track: TrackId) -> Self {
        Self {
            track,
            level: AudioLevel::default(),
            meta: None,
        }
    }

    /// 带上歌曲上下文(链式, 供 FFI 取链路径使用).
    pub fn with_meta(mut self, meta: SongUrlMeta) -> Self {
        self.meta = Some(meta);
        self
    }
}

/// 听歌排行的统计区间.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RankingPeriod {
    /// 全部时间(总量排行)
    #[default]
    All,
    /// 最近一周
    Week,
}

impl RankingPeriod {
    /// 接口的 type 参数: 0 = 全部时间, 1 = 最近一周
    pub fn type_param(&self) -> &'static str {
        match self {
            RankingPeriod::All => "0",
            RankingPeriod::Week => "1",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "all" | "0" | "" => Some(RankingPeriod::All),
            "week" | "1" => Some(RankingPeriod::Week),
            _ => None,
        }
    }
}
