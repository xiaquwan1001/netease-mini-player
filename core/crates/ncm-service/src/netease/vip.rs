//! 会员域: 会员/成长值/签到权益/等级/勋章/数字专辑/已购.

use super::*;

impl NeteaseProvider {
    /// 黑胶会员总览(需要登录). 四个子接口并行, 单个失败只丢对应字段.
    pub(super) fn vip_overview(&self) -> BoxFuture<'_, ProviderResult<VipOverview>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                // 未登录不报鉴权错误: 回 logged_in=false, UI 走"登录后可见"空态.
                return Ok(VipOverview::default());
            }
            let mk = || make_query(&cookie, &domain, &ua);
            let (a, b, c, d) = futures::future::join4(
                client.vip_info_v2(&mk()),
                client.vip_growthpoint(&mk()),
                client.vip_sign_info(&mk()),
                client.vip_tasks(&mk()),
            )
            .await;
            let mut errs: Vec<ProviderError> = Vec::new();
            let membership = take_body(a, &mut errs)
                .as_ref()
                .and_then(parse_vip_membership);
            let growth = take_body(b, &mut errs).as_ref().and_then(parse_vip_growth);
            let sign = take_body(c, &mut errs).as_ref().map(parse_vip_sign);
            let (tasks, task_score) = take_body(d, &mut errs)
                .as_ref()
                .map(parse_vip_tasks)
                .unwrap_or_default();
            if membership.is_none() && growth.is_none() && sign.is_none() && tasks.is_empty() {
                if let Some(e) = errs.into_iter().next() {
                    return Err(e);
                }
            }
            Ok(VipOverview {
                logged_in: true,
                membership,
                growth,
                sign,
                tasks,
                task_score,
            })
        })
    }

    /// 账号听歌等级(/api/user/level, weapi, body {}).
    pub(super) fn user_level(&self) -> BoxFuture<'_, ProviderResult<UserLevel>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("查看等级需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.user_level(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_user_level(&resp.body)
                .ok_or_else(|| ProviderError::internal("user_level 响应缺少 data"))
        })
    }

    /// 账号勋章墙(/api/medal/user/page, eapi, body **必须带 uid**).
    ///
    /// uid 优先取等级接口里服务端回的 data.userId(不依赖本地缓存的 profile),
    /// 拿不到再回退 session.profile.user_id。实测空 uid 时服务端回 code=499.
    pub(super) fn user_medals(&self) -> BoxFuture<'_, ProviderResult<MedalWall>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("查看勋章需要登录"));
            }
            let uid = self
                .remote_uid(&client, &domain, &ua, &cookie)
                .await
                .ok_or_else(|| ProviderError::auth("拿不到账号 uid, 无法查勋章"))?;
            let q = make_query(&cookie, &domain, &ua).param("uid", &uid.to_string());
            // 该 eapi 端点限流很严(实测 2026-11-08: 不间断连打 5 次只通 2 次;
            // 每次隔 ≥10s 则 5/5 全通; "先打一次 user_level 再打勋章" 也照样被 reset
            // -> 触发条件在服务端, 与客户端连发次数无关). 这里做有界重试, 退避 1.5s/3s,
            // 收紧后实测 8/10(单次 5/10). 业务错误(301/499)不重试.
            let mut last: Option<ProviderError> = None;
            for delay_ms in [0u64, 1500, 3000] {
                if delay_ms > 0 {
                    tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
                }
                match client.user_medal(&q).await {
                    Ok(resp) => match check_body(&resp.body) {
                        Ok(()) => return Ok(parse_user_medals(&resp.body)),
                        // 业务错误不重试(301/499 之类重试也没用)
                        Err(e) => return Err(e),
                    },
                    Err(e) => {
                        let pe = map_error(e);
                        // 只有网络类错误值得重试
                        if pe.kind != ncm_provider::ProviderErrorKind::Network {
                            return Err(pe);
                        }
                        last = Some(pe);
                    }
                }
            }
            Err(last.unwrap_or_else(|| ProviderError::network("user_medal 重试耗尽")))
        })
    }

    /// 已购数字专辑(digitalAlbum/purchased, weapi). 实测顶层是 paidAlbums + total.
    pub(super) fn digital_album_purchased<'a>(
        &'a self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<DigitalAlbumPurchased>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("已购数字专辑需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string())
                .param("total", "true");
            let resp = client
                .digital_album_purchased(&q)
                .await
                .map_err(map_error)?;
            check_body(&resp.body)?;
            parse_digital_album_purchased(&resp.body)
        })
    }

    /// 已购单曲(song/purchased = /api/single/mybought/song/list, weapi).
    pub(super) fn song_purchased<'a>(
        &'a self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<SongPurchasedPage>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("已购单曲需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.song_purchased(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_song_purchased(&resp.body)
        })
    }

    /// 数字专辑详情(vipmall/albumproduct/detail, weapi, 入参 id).
    pub(super) fn digital_album_detail(
        &self,
        album_id: u64,
    ) -> BoxFuture<'_, ProviderResult<DigitalAlbumDetail>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("id", &album_id.to_string());
            let resp = client.digital_album_detail(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_digital_album_detail(&resp.body)
        })
    }

    /// 数字专辑销量(vipmall/albumproduct/album/query/sales, weapi, 入参键 albumIds).
    pub(super) fn digital_album_sales<'a>(
        &'a self,
        album_ids: &'a str,
    ) -> BoxFuture<'a, ProviderResult<Vec<DigitalAlbumSalesEntry>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua).param("ids", album_ids);
            let resp = client.digital_album_sales(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_digital_album_sales(&resp.body))
        })
    }

    /// 取当前登录账号 uid: 先问等级接口(data.userId, 服务端权威), 失败/缺失再回退本地缓存.
    /// 勋章接口的 uid 是**必填**(空串时服务端回 code=499).
    pub(super) async fn remote_uid(
        &self,
        client: &ApiClient,
        domain: &Option<String>,
        ua: &Option<String>,
        cookie: &str,
    ) -> Option<u64> {
        let resp = client
            .user_level(&make_query(cookie, domain, ua))
            .await
            .ok()?;
        if check_body(&resp.body).is_err() {
            return self.uid_cached();
        }
        resp.body
            .get("data")
            .and_then(|d| u64_of(d, "userId"))
            .filter(|u| *u > 0)
            .or_else(|| self.uid_cached())
    }
}

/// vip_info_v2: data.associator + redVipLevel.
/// is_vip 判定用 associator.expireTime > now(服务端 data.now, 缺省本机时间);
/// **不要**按 vipCode/vipLevel 判断 —— 过期账号这两个字段仍是旧值.
pub fn parse_vip_membership(body: &Value) -> Option<VipMembership> {
    let data = body.get("data")?;
    let associator = data.get("associator").unwrap_or(&Value::Null);
    let expire_time_ms = u64_of(associator, "expireTime").unwrap_or(0);
    let now = u64_of(data, "now").unwrap_or_else(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    });
    Some(VipMembership {
        level: u64_of(associator, "vipLevel").unwrap_or(0) as u32,
        red_vip_level: data
            .get("redVipLevel")
            .and_then(Value::as_i64)
            .unwrap_or(0)
            .max(0) as u32,
        expire_time_ms,
        is_vip: expire_time_ms > 0 && expire_time_ms > now,
        // 负数(= 未知/非年费)保留原值, 由 UI 决定怎么显示
        annual_count: data
            .get("redVipAnnualCount")
            .and_then(Value::as_i64)
            .unwrap_or(-1) as i32,
    })
}

/// vip_growthpoint: data.userLevel(成长值/今日成长值) + data.levelCard(等级名/图).
/// 今日成长值藏在 userLevel.extJson 这个"JSON 字符串"里(不是对象).
pub fn parse_vip_growth(body: &Value) -> Option<VipGrowth> {
    let data = body.get("data")?;
    let user = data.get("userLevel").unwrap_or(&Value::Null);
    let card = data.get("levelCard").unwrap_or(&Value::Null);
    let mut level_name = str_of(card, "levelName").unwrap_or_default();
    if level_name.trim().is_empty() {
        level_name = str_of(user, "levelName").unwrap_or_default();
    }
    let today_score = str_of(user, "extJson")
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v.get("todayScore").and_then(Value::as_i64))
        .unwrap_or(0);
    Some(VipGrowth {
        level: u64_of(user, "level")
            .or_else(|| u64_of(card, "level"))
            .unwrap_or(0) as u32,
        level_name,
        growth_point: user.get("growthPoint").and_then(Value::as_i64).unwrap_or(0),
        today_score,
        max_level: user
            .get("maxLevel")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

/// vip_sign_info: data 是**数组, 只回最近 7 天**(不是月份/累计).
/// score > 0 才算已签 —— 未签的那天 recordId/time 也是 0, 拿它们判断会全判成"已签".
pub fn parse_vip_sign(body: &Value) -> VipSign {
    let days: Vec<VipSignDay> = body
        .get("data")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|v| {
                    let date = str_of(v, "timeStr")?;
                    let score = u64_of(v, "score").unwrap_or(0) as u32;
                    Some(VipSignDay {
                        date,
                        signed: score > 0,
                        today: v.get("today").and_then(Value::as_bool).unwrap_or(false),
                        score,
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let signed_today = days.iter().any(|d| d.today && d.signed);
    let week_signed = days.iter().filter(|d| d.signed).count() as u32;
    VipSign {
        days,
        signed_today,
        week_signed,
    }
}

/// vip_tasks: data.taskList[].taskItems[] 平铺.
/// 实测 name 常为空串(action 才是可读标题); targets 为 null = 没有可量化目标(不显示进度条).
/// 非 null 的 targets 形状未实测, 这里兼容 数字 / 数组 两种.
pub fn parse_vip_tasks(body: &Value) -> (Vec<VipTask>, i64) {
    let data = body.get("data").unwrap_or(&Value::Null);
    let task_score = data.get("taskScore").and_then(Value::as_i64).unwrap_or(0);
    let mut out: Vec<VipTask> = Vec::new();
    if let Some(groups) = data.get("taskList").and_then(Value::as_array) {
        for g in groups {
            let Some(items) = g.get("taskItems").and_then(Value::as_array) else {
                continue;
            };
            for it in items {
                let name = str_of(it, "name").unwrap_or_default();
                let action = str_of(it, "action").unwrap_or_default();
                let title = if name.trim().is_empty() { action } else { name };
                if title.trim().is_empty() {
                    continue;
                }
                let target = match it.get("targets") {
                    Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
                    Some(Value::Array(a)) => a.len() as i64,
                    _ => 0,
                };
                let progress = it
                    .get("currentProgress")
                    .and_then(Value::as_i64)
                    .unwrap_or(0);
                let status = it.get("status").and_then(Value::as_i64).unwrap_or(0);
                out.push(VipTask {
                    title,
                    reward: str_of(it, "description").unwrap_or_default(),
                    growth_point: it.get("growthPoint").and_then(Value::as_i64).unwrap_or(0) as i32,
                    progress,
                    target,
                    done: status == 2 || (target > 0 && progress >= target),
                    show_progress: it
                        .get("showProgress")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    url: str_of(it, "url").filter(|u| !u.trim().is_empty()),
                });
            }
        }
    }
    (out, task_score)
}

/// user_level: data = {level, nowPlayCount, nextPlayCount, nowLoginCount, nextLoginCount,
/// progress, info, userId}. 实测(2026-11-08): level=9, 2301/12000, progress=0.19175(= 听歌数比).
/// data 缺失时返回 None(由调用方按"接口成功但没有数据"处理).
pub fn parse_user_level(body: &Value) -> Option<UserLevel> {
    let data = body.get("data")?;
    if !data.is_object() {
        return None;
    }
    Some(UserLevel {
        level: u64_of(data, "level").unwrap_or(0) as u32,
        now_play_count: u64_of(data, "nowPlayCount").unwrap_or(0),
        next_play_count: u64_of(data, "nextPlayCount").unwrap_or(0),
        now_login_count: u64_of(data, "nowLoginCount").unwrap_or(0),
        next_login_count: u64_of(data, "nextLoginCount").unwrap_or(0),
        // progress 实测是 f64(0.19175), 但防御性兼容字符串形态
        progress: data
            .get("progress")
            .and_then(|v| {
                v.as_f64()
                    .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
            })
            .unwrap_or(0.0),
        privileges: str_of(data, "info").unwrap_or_default(),
    })
}

/// user_medal: data.categoryMedalBlockVos[].medalVOS[] 平铺.
///
/// 实测(2026-11-08, uid=1822714196): 5 个分类共 200 枚, status 分布
/// OBTAIN 157 / NOT_OBTAIN_PROCESS 16 / NOT_OBTAIN_NO_PROCESS 14 / WILL_OBTAIN 13;
/// data.medalNum = 157 = OBTAIN 枚数。data.obtainMedals 是同一批对象里已获得的那部分,
/// **只解析 categoryMedalBlockVos**, 否则会重复计数。
///
/// medalCode 是字符串(乐迷徽章形如 "20170503_1081839"), 缺 code 的条目直接跳过。
pub fn parse_user_medals(body: &Value) -> MedalWall {
    let data = body.get("data").unwrap_or(&Value::Null);
    let mut medals: Vec<UserMedal> = Vec::new();
    if let Some(groups) = data.get("categoryMedalBlockVos").and_then(Value::as_array) {
        for g in groups {
            let Some(items) = g.get("medalVOS").and_then(Value::as_array) else {
                continue;
            };
            for m in items {
                let Some(code) = str_of(m, "medalCode").filter(|c| !c.trim().is_empty()) else {
                    continue;
                };
                let status = str_of(m, "status").unwrap_or_default();
                medals.push(UserMedal {
                    code,
                    name: str_of(m, "medalName").unwrap_or_default(),
                    pic_url: str_of(m, "medalPicUrl").filter(|u| !u.trim().is_empty()),
                    wear_pic_url: str_of(m, "wearPic").filter(|u| !u.trim().is_empty()),
                    condition: str_of(m, "acceptCondition").unwrap_or_default(),
                    obtained: status == "OBTAIN",
                    obtain_time_ms: u64_of(m, "obtainTime").filter(|t| *t > 0),
                    level_title: str_of(m, "levelTitle").filter(|s| !s.trim().is_empty()),
                    progress_text: str_of(m, "progress").filter(|s| !s.trim().is_empty()),
                    rank_text: str_of(m, "rankText").filter(|s| !s.trim().is_empty()),
                    status,
                });
            }
        }
    }
    let medal_num = u64_of(data, "medalNum")
        .map(|n| n as u32)
        // 兜底: 接口没给 medalNum 时按 obtainTime 数(实测与 OBTAIN 枚数等价)
        .unwrap_or_else(|| medals.iter().filter(|m| m.obtained).count() as u32);
    MedalWall { medal_num, medals }
}

/// 已购数字专辑(digitalAlbum/purchased)的响应形如
///   {code:200, total:2, paidAlbums:[{albumId, albumName, artist:{id,name}, cover, paidTime,
///                                     boughtCount, sub, channel, valid, …}]}
/// 实测要点(2026-11-09):
/// - **顶层是 paidAlbums + total, 没有 data 包装**; 分页字段只有 total, 没有 hasMore/more;
/// - `paidTime` 是毫秒时间戳, `boughtCount` 是购买数量, 封面字段就叫 `cover`;
/// - paidAlbums 缺失/为 null 时当空列表(总数仍取 total), 不报错.
pub fn parse_digital_album_purchased(body: &Value) -> ProviderResult<DigitalAlbumPurchased> {
    let albums = body
        .get("paidAlbums")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|a| {
                    Some(DigitalAlbumPurchasedEntry {
                        album_id: u64_of(a, "albumId")?,
                        album_name: str_of(a, "albumName").unwrap_or_default(),
                        artist_id: a.get("artist").and_then(|x| u64_of(x, "id")).unwrap_or(0),
                        artist_name: a
                            .get("artist")
                            .and_then(|x| str_of(x, "name"))
                            .unwrap_or_default(),
                        cover_url: str_of(a, "cover").unwrap_or_default(),
                        paid_time_ms: u64_of(a, "paidTime").unwrap_or(0),
                        bought_count: u64_of(a, "boughtCount").unwrap_or(0),
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    Ok(DigitalAlbumPurchased {
        total: u64_of(body, "total").unwrap_or(0),
        albums,
    })
}

/// 已购单曲(song/purchased)的响应形如
///   {code:200, data:{count:0, hasMore:false, list:[]}}
/// 本账号无已购单曲, list 元素形状未实测到, 字段宽松取常见命名(id/name/paidTime 等).
pub fn parse_song_purchased(body: &Value) -> ProviderResult<SongPurchasedPage> {
    let data = body.get("data");
    let songs = data
        .and_then(|d| d.get("list"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|s| {
                    Some(PurchasedSongEntry {
                        song_id: u64_of(s, "id").or_else(|| u64_of(s, "songId"))?,
                        name: str_of(s, "name")
                            .or_else(|| str_of(s, "songName"))
                            .unwrap_or_default(),
                        artist_name: s
                            .get("artist")
                            .and_then(|x| str_of(x, "name"))
                            .or_else(|| str_of(s, "artistName"))
                            .unwrap_or_default(),
                        cover_url: str_of(s, "cover")
                            .or_else(|| str_of(s, "picUrl"))
                            .unwrap_or_default(),
                        paid_time_ms: u64_of(s, "paidTime")
                            .or_else(|| u64_of(s, "purchaseTime"))
                            .unwrap_or(0),
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    Ok(SongPurchasedPage {
        count: data.and_then(|d| u64_of(d, "count")).unwrap_or(0),
        has_more: data
            .and_then(|d| d.get("hasMore"))
            .and_then(Value::as_bool)
            .unwrap_or(false),
        songs,
    })
}

/// 数字专辑详情(vipmall/albumproduct/detail)的响应形如
///   {code:200, hasAlbum:true, boughtCnt:1,
///    album:{albumId, albumName, artistName, artistId, coverUrl, …},
///    product:{price:22.0, pubTime, saleNum, tags:[…], descr:[{resource,type}], …}}
/// 实测要点: 专辑字段在 album, 价格/上架/标签在 product; descr 的 `</br>` 是分隔占位要过滤.
pub fn parse_digital_album_detail(body: &Value) -> ProviderResult<DigitalAlbumDetail> {
    let album = body
        .get("album")
        .ok_or_else(|| ProviderError::not_found("digital_album_detail: missing album"))?;
    let product = body.get("product");
    let tags = product
        .and_then(|p| p.get("tags"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    let description = product
        .and_then(|p| p.get("descr"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|d| d.get("resource").and_then(Value::as_str))
                .filter(|s| *s != "</br>")
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default();
    Ok(DigitalAlbumDetail {
        album_id: u64_of(album, "albumId").unwrap_or(0),
        name: str_of(album, "albumName").unwrap_or_default(),
        artist_id: u64_of(album, "artistId").unwrap_or(0),
        artist_name: str_of(album, "artistName").unwrap_or_default(),
        cover_url: str_of(album, "coverUrl").unwrap_or_default(),
        has_album: body
            .get("hasAlbum")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        price: product
            .and_then(|p| p.get("price"))
            .and_then(Value::as_f64)
            .unwrap_or(0.0),
        pub_time_ms: product.and_then(|p| u64_of(p, "pubTime")).unwrap_or(0),
        sale_num: product.and_then(|p| u64_of(p, "saleNum")).unwrap_or(0),
        tags,
        description,
    })
}

/// 数字专辑销量(vipmall/albumproduct/album/query/sales)的响应形如
///   {code:200, data:{"120605500":1300052}}
/// `data` 是 {专辑id字符串: 销量} 的 map, 不是数组(实测, 与工单里 bizType/limit 的说法不符).
pub fn parse_digital_album_sales(body: &Value) -> Vec<DigitalAlbumSalesEntry> {
    body.get("data")
        .and_then(Value::as_object)
        .map(|m| {
            m.iter()
                .filter_map(|(k, v)| {
                    Some(DigitalAlbumSalesEntry {
                        album_id: k.clone(),
                        sales: v.as_u64()?,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}
