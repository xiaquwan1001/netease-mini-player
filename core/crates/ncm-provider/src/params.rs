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

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct SongUrlRequest {
    pub track: TrackId,
    pub level: AudioLevel,
}

impl SongUrlRequest {
    pub fn new(track: TrackId) -> Self {
        Self {
            track,
            level: AudioLevel::default(),
        }
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
