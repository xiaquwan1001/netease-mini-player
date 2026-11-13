//! 电台域: 播客/声音/电台榜单与订阅.

use super::*;

impl NeteaseProvider {
    /// 热门播客/电台
    pub(super) fn podcast_hot(
        &self,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<PodcastRadio>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("limit", &limit.to_string());
            let resp = client.dj_hot(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_podcast_hot(&resp.body))
        })
    }

    /// 某个播客的节目列表
    pub(super) fn podcast_programs(
        &self,
        radio_id: u64,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<PodcastProgram>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if radio_id == 0 {
                return Err(ProviderError::not_found("radio id 为空"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("rid", &radio_id.to_string())
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.dj_program(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_podcast_programs(&resp.body))
        })
    }

    /// 单个节目详情
    pub(super) fn podcast_program(
        &self,
        program_id: u64,
    ) -> BoxFuture<'_, ProviderResult<PodcastProgram>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("id", &program_id.to_string());
            let resp = client.dj_program_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_podcast_program(&resp.body)
        })
    }

    // ---- 电台发现(只读; 全部匿名可用) ----

    /// 电台发现首页: dj_catelist(分类) + dj_category_recommend(各分类精选), 并发拉取.
    pub(super) fn radio_explore_home(&self) -> BoxFuture<'_, ProviderResult<RadioExploreHome>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            let (cats, picks) =
                futures::future::join(client.dj_catelist(&q), client.dj_category_recommend(&q))
                    .await;
            let categories = parse_radio_categories(&cats.map_err(map_error)?.body);
            let picks_body = picks.map_err(map_error)?;
            check_body(&picks_body.body)?;
            Ok(RadioExploreHome {
                categories,
                picks: parse_radio_picks(&picks_body.body),
            })
        })
    }

    /// 某分类推荐电台(dj_recommend_type). cate_id=0 服务端返回空 djRadios, 原样透传空列表.
    pub(super) fn radio_recommend<'a>(
        &'a self,
        cate_id: u64,
    ) -> BoxFuture<'a, ProviderResult<Vec<PodcastRadio>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("type", &cate_id.to_string());
            let resp = client.dj_recommend_type(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(resp
                .body
                .get("djRadios")
                .and_then(Value::as_array)
                .map(|arr| arr.iter().filter_map(parse_radio).collect())
                .unwrap_or_default())
        })
    }

    /// 电台榜单(kind: hot/new/pay/hours/newcomer/popular/program).
    pub(super) fn radio_toplist<'a>(
        &'a self,
        kind: &'a str,
    ) -> BoxFuture<'a, ProviderResult<RadioToplist>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua);
            match kind {
                "hot" | "new" => {
                    // vendor 把 type "hot"→1 其余→0
                    let q = q.param("type", if kind == "hot" { "1" } else { "0" });
                    let resp = client.dj_toplist(&q).await.map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(parse_radio_toplist_radios(&resp.body))
                }
                "pay" => {
                    let resp = client.dj_toplist_pay(&q).await.map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(parse_radio_toplist_radios(&resp.body))
                }
                "hours" | "newcomer" | "popular" => {
                    let resp = match kind {
                        "hours" => client.dj_toplist_hours(&q).await,
                        "newcomer" => client.dj_toplist_newcomer(&q).await,
                        _ => client.dj_toplist_popular(&q).await,
                    }
                    .map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(parse_radio_toplist_djs(&resp.body))
                }
                "program" => {
                    let resp = client.dj_program_toplist(&q).await.map_err(map_error)?;
                    check_body(&resp.body)?;
                    Ok(parse_radio_toplist_programs(&resp.body))
                }
                other => Err(ProviderError::not_found(format!("未知电台榜单: {other}"))),
            }
        })
    }

    /// 电台订阅者列表(dj_subscriber; 游标 time=-1 表示最新一页).
    pub(super) fn radio_subscribers<'a>(
        &'a self,
        radio_id: u64,
        limit: u32,
        time_ms: Option<u64>,
    ) -> BoxFuture<'a, ProviderResult<RadioSubscriberPage>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if radio_id == 0 {
                return Err(ProviderError::not_found("radio id 为空"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &radio_id.to_string())
                .param("limit", &limit.to_string())
                // 游标是"上一页最后一条的 subscribeTime"(ms), 首页传 -1
                .param(
                    "time",
                    &time_ms
                        .map(|t| t.to_string())
                        .unwrap_or_else(|| "-1".to_string()),
                )
                .param("total", "true");
            let resp = client.dj_subscriber(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_radio_subscribers(&resp.body)
        })
    }

    /// 播客/电台详情
    pub(super) fn podcast_radio(
        &self,
        radio_id: u64,
    ) -> BoxFuture<'_, ProviderResult<PodcastRadio>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if radio_id == 0 {
                return Err(ProviderError::not_found("radio id 为空"));
            }
            let q = make_query(&cookie, &domain, &ua).param("rid", &radio_id.to_string());
            let resp = client.dj_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_podcast_radio_detail(&resp.body)
        })
    }

    /// 已订阅的播客/电台
    pub(super) fn subscribed_podcasts(
        &self,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<PodcastRadio>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("查看收藏播客需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.max(1).to_string())
                .param("offset", "0");
            let resp = client.dj_sublist(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_subscribed_podcasts(&resp.body))
        })
    }
}

pub(super) fn parse_radio(v: &Value) -> Option<PodcastRadio> {
    let id = u64_of(v, "id")?;
    Some(PodcastRadio {
        id,
        name: str_of(v, "name").unwrap_or_default(),
        cover_url: str_of(v, "picUrl").or_else(|| str_of(v, "coverUrl")),
        description: str_of(v, "desc")
            .or_else(|| str_of(v, "rcmdtext"))
            .unwrap_or_default(),
        dj_name: v
            .get("dj")
            .and_then(|d| str_of(d, "nickname"))
            .unwrap_or_default(),
        program_count: u64_of(v, "programCount").unwrap_or(0),
        play_count: u64_of(v, "playCount").unwrap_or(0),
    })
}

/// 热门播客的响应形如 {code:200, djRadios:[...]}
pub fn parse_podcast_hot(body: &Value) -> Vec<PodcastRadio> {
    body.get("djRadios")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_radio).collect())
        .unwrap_or_default()
}

pub(super) fn parse_program(v: &Value) -> Option<PodcastProgram> {
    let id = u64_of(v, "id")?;
    let radio = v.get("radio");
    Some(PodcastProgram {
        id,
        name: str_of(v, "name").unwrap_or_default(),
        cover_url: str_of(v, "coverUrl").or_else(|| str_of(v, "blurCoverUrl")),
        duration_ms: u64_of(v, "duration").unwrap_or(0),
        dj_name: v
            .get("dj")
            .and_then(|d| str_of(d, "nickname"))
            .unwrap_or_default(),
        radio_id: radio.and_then(|r| u64_of(r, "id")).unwrap_or(0),
        radio_name: radio.and_then(|r| str_of(r, "name")).unwrap_or_default(),
        description: str_of(v, "description").unwrap_or_default(),
        // 节目音频本体; 用它的 id 走 song_url 取直链(实测匿名可播)
        song: v
            .get("mainSong")
            .and_then(|s| parse_song_with(s, &std::collections::HashMap::new())),
    })
}

/// 节目列表的响应形如 {code:200, programs:[...], more}
pub fn parse_podcast_programs(body: &Value) -> Vec<PodcastProgram> {
    body.get("programs")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_program).collect())
        .unwrap_or_default()
}

/// 节目详情的响应形如 {code:200, program:{...}}
pub fn parse_podcast_program(body: &Value) -> ProviderResult<PodcastProgram> {
    body.get("program")
        .and_then(parse_program)
        .ok_or_else(|| ProviderError::not_found("program: missing program"))
}

/// 电台分类(dj_catelist). **顶层直接是 categories, 没有 code 字段**, 判断空数组即可.
pub fn parse_radio_categories(body: &Value) -> Vec<RadioCategory> {
    body.get("categories")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|c| {
                    Some(RadioCategory {
                        id: u64_of(c, "id")?,
                        name: str_of(c, "name").unwrap_or_default(),
                        cover_url: str_of(c, "pic56x56Url").unwrap_or_default(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 各分类精选(dj_category_recommend 的 data[] 元素 = {categoryId, categoryName, radios}).
pub fn parse_radio_picks(body: &Value) -> Vec<RadioPick> {
    body.get("data")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .map(|g| RadioPick {
                    category_id: u64_of(g, "categoryId").unwrap_or(0),
                    category_name: str_of(g, "categoryName").unwrap_or_default(),
                    radios: g
                        .get("radios")
                        .and_then(Value::as_array)
                        .map(|rs| rs.iter().filter_map(parse_radio).collect())
                        .unwrap_or_default(),
                })
                .collect()
        })
        .unwrap_or_default()
}

/// dj_toplist(顶层 toplist, 元素是 DjRadio 超集 + rank/score/lastRank).
/// 注意推荐语字段是 rcmdtext(全小写).
pub(super) fn ranked_radio(v: &Value) -> Option<RadioRankedRadio> {
    Some(RadioRankedRadio {
        rank: u32_of(v, "rank")?,
        last_rank: i32_of(v, "lastRank").unwrap_or(-1),
        radio_id: u64_of(v, "id")?,
        name: str_of(v, "name").unwrap_or_default(),
        cover_url: str_of(v, "picUrl").unwrap_or_default(),
        dj_name: v
            .get("dj")
            .and_then(|d| str_of(d, "nickname"))
            .or_else(|| str_of(v, "creatorName"))
            .unwrap_or_default(),
        category: str_of(v, "category").unwrap_or_default(),
        play_count: u64_of(v, "playCount").unwrap_or(0),
        program_count: u64_of(v, "programCount").unwrap_or(0),
        sub_count: u64_of(v, "subCount").unwrap_or(0),
        score: u64_of(v, "score").unwrap_or(0),
        rcmd_text: str_of(v, "rcmdtext").unwrap_or_default(),
    })
}

pub fn parse_radio_toplist_radios(body: &Value) -> RadioToplist {
    let radios = body
        .get("toplist")
        .or_else(|| body.get("data").and_then(|d| d.get("list")))
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(ranked_radio).collect())
        .unwrap_or_default();
    RadioToplist {
        radios,
        ..RadioToplist::default()
    }
}

/// 主播榜(hours/newcomer/popular): data.list, 元素是用户(nickName 驼峰).
pub fn parse_radio_toplist_djs(body: &Value) -> RadioToplist {
    let djs = body
        .get("data")
        .and_then(|d| d.get("list"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|d| {
                    Some(RadioRankedDj {
                        rank: u32_of(d, "rank")?,
                        last_rank: i32_of(d, "lastRank").unwrap_or(-1),
                        user_id: u64_of(d, "id")?,
                        nickname: str_of(d, "nickName").unwrap_or_default(),
                        avatar_url: str_of(d, "avatarUrl").unwrap_or_default(),
                        score: u64_of(d, "score").unwrap_or(0),
                        followed_count: u64_of(d, "userFollowedCount").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    RadioToplist {
        djs,
        ..RadioToplist::default()
    }
}

/// 节目榜(dj_program_toplist): 顶层 toplist, 元素 = {rank,lastRank,program}.
pub fn parse_radio_toplist_programs(body: &Value) -> RadioToplist {
    let programs = body
        .get("toplist")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|e| {
                    Some(RadioRankedProgram {
                        rank: u32_of(e, "rank")?,
                        last_rank: i32_of(e, "lastRank").unwrap_or(-1),
                        program: e.get("program").and_then(parse_program)?,
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    RadioToplist {
        programs,
        ..RadioToplist::default()
    }
}

/// 电台订阅者(dj_subscriber): 顶层 hasMore + subscribers(完整 user 对象).
pub fn parse_radio_subscribers(body: &Value) -> ProviderResult<RadioSubscriberPage> {
    let subs = body
        .get("subscribers")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| {
                    Some(RadioSubscriber {
                        user_id: u64_of(s, "userId")?,
                        nickname: str_of(s, "nickname").unwrap_or_default(),
                        avatar_url: str_of(s, "avatarUrl").unwrap_or_default(),
                        signature: str_of(s, "signature").unwrap_or_default(),
                        subscribe_time_ms: u64_of(s, "subscribeTime").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(RadioSubscriberPage {
        has_more: body
            .get("hasMore")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        subscribers: subs,
    })
}

/// 电台详情(dj_detail)的响应形如 {code:200, data:{id,name,picUrl,desc,dj:{nickname},programCount,playCount}}
pub fn parse_podcast_radio_detail(body: &Value) -> ProviderResult<PodcastRadio> {
    body.get("data")
        .and_then(parse_radio)
        .ok_or_else(|| ProviderError::not_found("podcast_radio: missing data"))
}

/// multimatch 的 `voice` 是"播客节目"对象, 结构与 dj_detail 完全不同:
///   {resourceId, resourceName, resourceType:"voice", internalType:null,
///    baseInfo:{id, name, coverUrl, trackCount, listenerCount, dj:{nickname}, radio:{name, programCount}}}
/// 映射成 [`PodcastRadio`]: id/name 取 baseInfo.id/name(播客**单集**),
/// dj_name 取 baseInfo.dj.nickname, program_count 取 baseInfo.radio.programCount,
/// play_count 取 baseInfo.listenerCount.
pub(super) fn parse_voice_radio(v: &Value) -> Option<PodcastRadio> {
    let base = v.get("baseInfo").unwrap_or(v);
    let id = u64_of(base, "id").or_else(|| u64_of(v, "resourceId"))?;
    if id == 0 {
        return None;
    }
    let name = str_of(base, "name")
        .or_else(|| str_of(v, "resourceName"))
        .unwrap_or_default();
    let radio = base.get("radio");
    Some(PodcastRadio {
        id,
        name,
        cover_url: str_of(base, "coverUrl")
            .or_else(|| base.get("radio").and_then(|r| str_of(r, "picUrl")))
            .filter(|s| !s.is_empty()),
        description: String::new(),
        dj_name: base
            .get("dj")
            .and_then(|d| str_of(d, "nickname"))
            .unwrap_or_default(),
        program_count: radio.and_then(|r| u64_of(r, "programCount")).unwrap_or(0),
        play_count: u64_of(base, "listenerCount").unwrap_or(0),
    })
}

/// 已订阅播客的响应形如 {code:200, djRadios:[{id,name,picUrl,...}]}
/// 部分通道返回 data:[{radio:{...}}], 两种都认.
pub fn parse_subscribed_podcasts(body: &Value) -> Vec<PodcastRadio> {
    let arr = body
        .get("djRadios")
        .or_else(|| body.get("data"))
        .or_else(|| body.get("radios"))
        .and_then(Value::as_array);
    let Some(arr) = arr else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| parse_radio(v.get("radio").unwrap_or(v)))
        .collect()
}
