//! 电台发现(只读): 分类 / 推荐 / 榜单 / 订阅者.
//!
//! 拆分自原 api.rs (2026-11-20 架构审计 7.2: 单文件按域拆开),
//! 函数签名与行为与原文件逐字一致, 只是搬家。
//! 本文件里的 #[frb(mirror(..))] 就是 Dart 侧的类定义 -- 改这里 = 改 Dart API。

pub(crate) use super::*;

// ---------------- 电台发现(只读) ----------------

#[frb(mirror(RadioCategory))]
pub struct _RadioCategory {
    pub id: u64,
    pub name: String,
    pub cover_url: String,
}

#[frb(mirror(RadioPick))]
pub struct _RadioPick {
    pub category_id: u64,
    pub category_name: String,
    pub radios: Vec<PodcastRadio>,
}

#[frb(mirror(RadioExploreHome))]
pub struct _RadioExploreHome {
    pub categories: Vec<RadioCategory>,
    pub picks: Vec<RadioPick>,
}

#[frb(mirror(RadioRankedRadio))]
pub struct _RadioRankedRadio {
    pub rank: u32,
    /// 上期名次(-1 表示新上榜)
    pub last_rank: i32,
    pub radio_id: u64,
    pub name: String,
    pub cover_url: String,
    pub dj_name: String,
    pub category: String,
    pub play_count: u64,
    pub program_count: u64,
    pub sub_count: u64,
    pub score: u64,
    pub rcmd_text: String,
}

#[frb(mirror(RadioRankedDj))]
pub struct _RadioRankedDj {
    pub rank: u32,
    pub last_rank: i32,
    pub user_id: u64,
    pub nickname: String,
    pub avatar_url: String,
    pub score: u64,
    pub followed_count: u64,
}

pub struct RadioRankedProgramDto {
    pub rank: u32,
    pub last_rank: i32,
    pub program: PodcastProgramDto,
}

pub struct RadioToplistDto {
    pub kind: String,
    pub radios: Vec<RadioRankedRadio>,
    pub djs: Vec<RadioRankedDj>,
    pub programs: Vec<RadioRankedProgramDto>,
}

#[frb(mirror(RadioSubscriber))]
pub struct _RadioSubscriber {
    pub user_id: u64,
    pub nickname: String,
    pub avatar_url: String,
    pub signature: String,
    pub subscribe_time_ms: u64,
}

#[frb(mirror(RadioSubscriberPage))]
pub struct _RadioSubscriberPage {
    pub has_more: bool,
    pub subscribers: Vec<RadioSubscriber>,
}

/// 电台发现首页: 分类(dj_catelist) + 各分类精选(dj_category_recommend), 匿名可用.
pub async fn radio_explore_home() -> Result<RadioExploreHome, FfiError> {
    ffi_forward!(Capability::RadioExplore, provider.radio_explore_home())
}

/// 某分类推荐电台(dj_recommend_type; cate_id 必须是真实分类 id).
pub async fn radio_recommend(cate_id: u64) -> Result<Vec<PodcastRadio>, FfiError> {
    ffi_forward!(Capability::RadioExplore, provider.radio_recommend(cate_id))
}

/// 电台榜单(kind: hot/new/pay/hours/newcomer/popular/program).
pub async fn radio_toplist(kind: String) -> Result<RadioToplistDto, FfiError> {
    let provider = with_provider(Capability::RadioExplore)?;
    let r = provider
        .radio_toplist(&kind)
        .await
        .map_err(FfiError::from)?;
    Ok(RadioToplistDto {
        kind,
        radios: r.radios,
        djs: r.djs,
        programs: r
            .programs
            .into_iter()
            .map(|x| RadioRankedProgramDto {
                rank: x.rank,
                last_rank: x.last_rank,
                program: program_dto(x.program),
            })
            .collect(),
    })
}

/// 电台订阅者列表(只读).
pub async fn radio_subscribers(
    radio_id: u64,
    limit: u32,
    time_ms: Option<u64>,
) -> Result<RadioSubscriberPage, FfiError> {
    ffi_forward!(
        Capability::RadioExplore,
        provider.radio_subscribers(radio_id, limit, time_ms)
    )
}
