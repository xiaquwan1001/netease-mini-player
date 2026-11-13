//! 评论域: 评论列表/热门/楼层/回复/点赞/分享.

use super::*;

impl NeteaseProvider {
    /// 评论点赞: vendor 用 (type,id) 拼 threadId, 这里反解 threadId
    pub(super) fn like_comment<'a>(
        &'a self,
        thread_id: &'a str,
        comment_id: u64,
        liked: bool,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let (resource_type, owner) = split_thread_id(thread_id).ok_or_else(|| {
                ProviderError::unsupported(format!("无法识别的 threadId: {thread_id}"))
            })?;
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("点赞评论需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("type", resource_type)
                .param("id", &owner)
                .param("cid", &comment_id.to_string())
                .param("t", if liked { "1" } else { "0" });
            let resp = client.comment_like(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 楼层回复: 某条评论下的回复列表
    pub(super) fn comment_replies<'a>(
        &'a self,
        thread_id: &'a str,
        parent_comment_id: u64,
        limit: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        Box::pin(async move {
            let (resource_type, owner) = split_thread_id(thread_id).ok_or_else(|| {
                ProviderError::unsupported(format!("无法识别的 threadId: {thread_id}"))
            })?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("type", resource_type)
                .param("id", &owner)
                .param("parentCommentId", &parent_comment_id.to_string())
                .param("limit", &limit.to_string());
            let resp = client.comment_floor(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut page = parse_comment_floor(&resp.body)?;
            page.thread_id = thread_id.to_string();
            Ok(page)
        })
    }

    /// 回复评论(需要登录)
    pub(super) fn reply_comment<'a>(
        &'a self,
        thread_id: &'a str,
        comment_id: u64,
        content: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let content = content.trim();
            if content.is_empty() {
                return Err(ProviderError::internal("回复内容不能为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("回复评论需要登录"));
            }
            // 主路: eapi 的老写接口(/api/resource/comments/{add,reply}), 与 api-enhanced
            // 旧版一致; 实测 weapi 的 /api/v1/resource/comments/reply 在**动态**(A_EV_2_*)
            // 上回 code=404, 而动态的评论读接口就在 /api/v1/resource/comments/{threadId}。
            let (path, data) = if comment_id == 0 {
                (
                    "/api/resource/comments/add",
                    serde_json::json!({
                        "threadId": thread_id,
                        "content": content,
                        "resourceType": "0",
                    }),
                )
            } else {
                (
                    "/api/resource/comments/reply",
                    serde_json::json!({
                        "threadId": thread_id,
                        "commentId": comment_id.to_string(),
                        "content": content,
                        "resourceType": "0",
                    }),
                )
            };
            let resp = client
                .request(path, data.clone(), write_option(&cookie, &domain, &ua))
                .await
                .map_err(map_error)?;
            // 老路不认这条资源(实测动态回 404)时回退 weapi 新版路径; 只有 404 才回退,
            // 其它错误(频率/内容)回退也发不出去, 反而可能重复发
            if resp.body.get("code").and_then(Value::as_i64) == Some(404) {
                let q = make_query(&cookie, &domain, &ua)
                    .param("threadId", thread_id)
                    .param("commentId", &comment_id.to_string())
                    .param("content", content);
                let retry = client.comment_reply(&q).await.map_err(map_error)?;
                if let Err(mut e) = check_body(&retry.body) {
                    // 带上请求上下文: 评论写失败只报 code 没法定位是哪条资源/哪一层
                    e.detail = format!(
                        "{}(eapi {path} 与 weapi 回退均失败, threadId={thread_id}, commentId={comment_id})",
                        e.detail
                    );
                    return Err(e);
                }
                return Ok(true);
            }
            if let Err(mut e) = check_body(&resp.body) {
                e.detail = format!(
                    "{}(写评论 {path}, threadId={thread_id}, commentId={comment_id})",
                    e.detail
                );
                return Err(e);
            }
            Ok(true)
        })
    }

    /// 删除自己的评论(需要登录)
    pub(super) fn delete_comment<'a>(
        &'a self,
        thread_id: &'a str,
        comment_id: u64,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("删除评论需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("threadId", thread_id)
                .param("commentId", &comment_id.to_string());
            let resp = client.comment_delete(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 评论列表: vendor 按 kind 分派到不同资源端点(song/playlist/album/podcast)
    pub(super) fn comments<'a>(
        &'a self,
        kind: &'a str,
        id: u64,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &id.to_string())
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = match kind {
                "song" => client.comment_music(&q).await,
                "playlist" => client.comment_playlist(&q).await,
                "album" => client.comment_album(&q).await,
                "podcast" => client.comment_dj(&q).await,
                // MV(R_MV_5_) / 视频(R_VI_62_)评论区: 形状与歌曲评论一致, 复用 parse_comments
                "mv" => client.comment_mv(&q).await,
                "video" => client.comment_video(&q).await,
                other => {
                    return Err(ProviderError::unsupported(format!(
                        "comments: 未知资源类型 {other} (应为 song|playlist|album|podcast)"
                    )));
                }
            };
            let resp = resp.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut page = parse_comments(&resp.body)?;
            page.thread_id = thread_id_for(kind, id).unwrap_or_default();
            Ok(page)
        })
    }

    /// 精彩评论(单独接口). threadId 反解出 vendor 的 type + id, 再按资源查。
    /// 动态(A_EV_2_)的 id 段是 `eventId_userId`, 热门接口只认 eventId, 这里不支持。
    pub(super) fn hot_comments<'a>(
        &'a self,
        thread_id: &'a str,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        Box::pin(async move {
            let (ty, rid) = split_thread_id(thread_id).ok_or_else(|| {
                ProviderError::unsupported(format!("hot_comments: 无法识别的 threadId {thread_id}"))
            })?;
            if ty == "6" {
                return Err(ProviderError::unsupported(
                    "hot_comments: 动态暂不支持热门评论",
                ));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("type", ty)
                .param("id", &rid)
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.comment_hot(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut page = parse_comments(&resp.body)?;
            page.thread_id = thread_id.to_string();
            Ok(page)
        })
    }

    /// 评论统计(实测: vendor comment_info_list = /api/resource/commentInfo/list, weapi).
    /// 入参是 type(资源类型数字) + ids(逗号分隔), **不是 threadId** —— 传 threadId 只会拿到空数组;
    /// 这里用 split_thread_id 把 threadId 反解成 (type, id). 动态(A_EV_2_)的 id 段是
    /// `eventId_userId`, 该接口不认, 直接 unsupported.
    pub(super) fn comment_stats<'a>(
        &'a self,
        thread_id: &'a str,
    ) -> BoxFuture<'a, ProviderResult<CommentStats>> {
        Box::pin(async move {
            let (ty, rid) = split_thread_id(thread_id).ok_or_else(|| {
                ProviderError::unsupported(format!(
                    "comment_stats: 无法识别的 threadId {thread_id}"
                ))
            })?;
            if ty == "6" {
                return Err(ProviderError::unsupported(
                    "comment_stats: 动态暂不支持评论统计",
                ));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("type", ty)
                .param("ids", &rid);
            let resp = client.comment_info_list(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            parse_comment_stats(&resp.body, thread_id)
        })
    }

    /// 分享资源到动态(需登录). kind 直接透传接口 type(song/playlist/album/podcast)
    pub(super) fn share_resource<'a>(
        &'a self,
        kind: &'a str,
        id: u64,
        msg: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("分享到动态需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("type", kind)
                .param("id", &id.to_string())
                .param("msg", msg);
            let resp = client.share_resource(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }
}

/// 资源类型 → 评论 threadId 前缀(与 vendor 的 RESOURCE_TYPE_MAP 对齐)
pub fn thread_id_for(kind: &str, id: u64) -> Option<String> {
    let prefix = match kind {
        "song" => "R_SO_4_",
        "mv" => "R_MV_5_",
        "playlist" => "A_PL_0_",
        "album" => "R_AL_3_",
        "podcast" | "djradio" => "A_DJ_1_",
        "video" => "R_VI_62_",
        "event" => "A_EV_2_",
        "program" => "A_DR_14_",
        _ => return None,
    };
    Some(format!("{prefix}{id}"))
}

/// threadId → (vendor 的 type 参数, id 段). 用于点赞/楼层这类"只吃 type+id"的接口.
/// 动态的 threadId 是 A_EV_2_<eventId>_<userId>, id 段要原样保留这两段.
pub fn split_thread_id(thread_id: &str) -> Option<(&'static str, String)> {
    const MAP: &[(&str, &str)] = &[
        ("R_SO_4_", "0"),
        ("R_MV_5_", "1"),
        ("A_PL_0_", "2"),
        ("R_AL_3_", "3"),
        ("A_DJ_1_", "4"),
        ("R_VI_62_", "5"),
        ("A_EV_2_", "6"),
        ("A_DR_14_", "7"),
    ];
    for (prefix, ty) in MAP {
        if let Some(rest) = thread_id.strip_prefix(prefix) {
            if rest.is_empty() {
                return None;
            }
            return Some((ty, rest.to_string()));
        }
    }
    None
}

/// 楼层回复: {code, data:{comments:[...], hasMore, time}}
pub fn parse_comment_floor(body: &Value) -> ProviderResult<CommentPage> {
    let data = body.get("data").unwrap_or(body);
    let arr = data.get("comments").and_then(Value::as_array);
    let Some(arr) = arr else {
        return Ok(CommentPage::default());
    };
    Ok(CommentPage {
        comments: arr.iter().filter_map(|v| parse_comment(v, false)).collect(),
        total: u64_of(data, "total").unwrap_or(0),
        has_more: data
            .get("hasMore")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        thread_id: String::new(),
    })
}

/// 评论条目形如 {commentId, user:{nickname,avatarUrl}, content, time, likedCount, liked}
pub(super) fn parse_comment(v: &Value, hot: bool) -> Option<Comment> {
    let id = u64_of(v, "commentId")?;
    let user = v.get("user");
    Some(Comment {
        id,
        user_id: user.and_then(|u| u64_of(u, "userId")).unwrap_or(0),
        user_name: user.and_then(|u| str_of(u, "nickname")).unwrap_or_default(),
        avatar_url: user.and_then(|u| str_of(u, "avatarUrl")),
        content: str_of(v, "content").unwrap_or_default(),
        time_ms: u64_of(v, "time").unwrap_or(0),
        liked_count: u64_of(v, "likedCount").unwrap_or(0),
        liked: v.get("liked").and_then(Value::as_bool).unwrap_or(false),
        reply_count: v
            .get("showFloorComment")
            .and_then(|f| u64_of(f, "replyCount"))
            .or_else(|| u64_of(v, "replyCount"))
            .unwrap_or(0),
        // 精彩评论的 ipLocation.location 是空串, 只有普通评论才有归属地
        ip_location: v
            .get("ipLocation")
            .and_then(|ip| str_of(ip, "location"))
            .map(|s| s.trim().to_string())
            .unwrap_or_default(),
        hot,
        // 楼层/回复: beReplied[0] 是被回复的那条(可能有多个, 取第一个即可满足展示)
        replied_to: v
            .get("beReplied")
            .and_then(Value::as_array)
            .and_then(|a| a.first())
            .and_then(|r| r.get("user"))
            .and_then(|u| str_of(u, "nickname"))
            .filter(|s| !s.trim().is_empty()),
        parent_id: u64_of(v, "parentCommentId").unwrap_or(0),
    })
}

/// 评论列表的响应形如 {code:200, total, more, hotComments:[...], comments:[...]}
/// 精彩评论在前(hotComments), 其后是最新评论, 按 commentId 去重.
pub fn parse_comments(body: &Value) -> ProviderResult<CommentPage> {
    let mut seen = std::collections::HashMap::new();
    let mut comments: Vec<Comment> = Vec::new();
    for (key, hot) in [("hotComments", true), ("comments", false)] {
        let Some(arr) = body.get(key).and_then(Value::as_array) else {
            continue;
        };
        for v in arr {
            let Some(c) = parse_comment(v, hot) else {
                continue;
            };
            match seen.get(&c.id).copied() {
                Some(idx) => {
                    // 同一条评论在热评和最新里各出现一次: 保留先到的(hot 版),
                    // 但热评常常没有 IP 归属地, 从后面那份补上
                    let existing: &mut Comment = &mut comments[idx];
                    if existing.ip_location.is_empty() {
                        existing.ip_location = c.ip_location;
                    }
                }
                None => {
                    seen.insert(c.id, comments.len());
                    comments.push(c);
                }
            }
        }
    }
    Ok(CommentPage {
        thread_id: String::new(),
        comments,
        total: u64_of(body, "total").unwrap_or(0),
        // 普通评论页用 more, 热门评论页(comment_hot)用 hasMore
        has_more: body
            .get("more")
            .or_else(|| body.get("hasMore"))
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

/// 评论统计(comment_info_list = /api/resource/commentInfo/list)的响应形如
///   {code:200, data:[{commentCount, commentCountDesc, commentUpgraded, comments, latestLikedUsers,
///                     liked, likedCount, musicianSaidCount, resourceId, resourceType, shareCount, threadId}]}
/// 实测要点:
/// - `data` 是**数组**(一个请求 id 对应一项), 这里只发一个 id, 取第一项;
/// - **没有 subscribedCount / hotCount**, 别按文档补齐字段;
/// - `data` 缺失、空数组、空对象都当"全 0"返回(用请求的 threadId 兜底), 不报错也不 panic ——
///   评论数缺失不该让整个详情页失败;
/// - 服务端回显的 threadId 优先(与请求一致), 缺失时用入参兜底.
pub fn parse_comment_stats(body: &Value, thread_id: &str) -> ProviderResult<CommentStats> {
    let first = body
        .get("data")
        .and_then(|d| match d {
            Value::Array(arr) => arr.first(),
            Value::Object(_) => Some(d),
            _ => None,
        })
        .filter(|v| v.is_object());
    let Some(v) = first else {
        return Ok(CommentStats {
            thread_id: thread_id.to_string(),
            ..Default::default()
        });
    };
    Ok(CommentStats {
        thread_id: str_of(v, "threadId")
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| thread_id.to_string()),
        resource_id: u64_of(v, "resourceId").unwrap_or(0),
        comment_count: u64_of(v, "commentCount").unwrap_or(0),
        comment_count_desc: str_of(v, "commentCountDesc").unwrap_or_default(),
        share_count: u64_of(v, "shareCount").unwrap_or(0),
        liked_count: u64_of(v, "likedCount").unwrap_or(0),
        liked: v.get("liked").and_then(Value::as_bool).unwrap_or(false),
        musician_said_count: u64_of(v, "musicianSaidCount").unwrap_or(0),
        comment_upgraded: v
            .get("commentUpgraded")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}
