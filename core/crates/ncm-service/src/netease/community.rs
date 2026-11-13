//! 社区域: 动态/消息/私信/最近联系人/关注与粉丝.

use super::*;

impl NeteaseProvider {
    /// 某人关注的人. 响应形如 {code, follow:[{userId,nickname,avatarUrl,signature}]}
    pub(super) fn user_follows(
        &self,
        uid: u64,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<UserItem>>> {
        Box::pin(async move {
            let uid = self.resolve_uid(uid).await?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("uid", &uid.to_string())
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.user_follows(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            // 这个列表里的人都是我关注的
            Ok(parse_user_items(&resp.body, "follow", true))
        })
    }

    /// 某人的粉丝
    pub(super) fn user_followeds(
        &self,
        uid: u64,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<UserItem>>> {
        Box::pin(async move {
            let uid = self.resolve_uid(uid).await?;
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("uid", &uid.to_string())
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.user_followeds(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            // 粉丝列表里接口不给"我有没有关注 ta", 在 UI 里按需点关注
            Ok(parse_user_items(&resp.body, "followeds", false))
        })
    }

    /// 关注/取关某人: t=1 关注, 0 取关
    pub(super) fn set_follow(&self, uid: u64, follow: bool) -> BoxFuture<'_, ProviderResult<bool>> {
        Box::pin(async move {
            if uid == 0 {
                return Err(ProviderError::not_found("用户 id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("关注需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("id", &uid.to_string())
                .param("t", if follow { "1" } else { "0" });
            let resp = client.follow(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 我的关注/粉丝数: {code, follow, fans, ...}
    pub(super) fn follow_counts(&self) -> BoxFuture<'_, ProviderResult<FollowCount>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("关注数需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.user_subcount(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(FollowCount {
                follows: u64_of(&resp.body, "follow").unwrap_or(0),
                fans: u64_of(&resp.body, "fans").unwrap_or(0),
            })
        })
    }

    /// 未读消息计数(需登录)
    pub(super) fn message_counts(&self) -> BoxFuture<'_, ProviderResult<MessageCounts>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("消息需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.pl_count(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let n = |key: &str| -> u32 {
                resp.body.get(key).and_then(Value::as_u64).unwrap_or(0) as u32
            };
            Ok(MessageCounts {
                private: n("msg"),
                notices: n("notice"),
                comments: n("comment"),
                forwards: n("forward"),
            })
        })
    }

    /// 私信会话列表(需登录)
    pub(super) fn private_sessions(
        &self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<PrivateSession>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("私信需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.msg_private(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_private_sessions(&resp.body))
        })
    }

    /// 私信历史(需登录)
    pub(super) fn private_history(
        &self,
        user_id: u64,
        limit: u32,
        before_ms: u64,
    ) -> BoxFuture<'_, ProviderResult<Vec<PrivateMessage>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("私信需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("uid", &user_id.to_string())
                .param("limit", &limit.to_string())
                .param("before", &before_ms.to_string());
            let resp = client.msg_private_history(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let me = self.uid_cached().unwrap_or(0);
            Ok(parse_private_history(&resp.body, me))
        })
    }

    /// 通知(需登录)
    pub(super) fn message_notices(
        &self,
        limit: u32,
        last_time_ms: u64,
    ) -> BoxFuture<'_, ProviderResult<Vec<InboxItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("通知需要登录"));
            }
            let before = if last_time_ms == 0 {
                -1
            } else {
                last_time_ms as i64
            };
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("lasttime", &before.to_string());
            let resp = client.msg_notices(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_notices(&resp.body))
        })
    }

    /// 评论/回复消息(需登录)
    pub(super) fn comment_messages(
        &self,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<InboxItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("评论消息需要登录"));
            }
            let uid = self.uid().await?;
            let q = make_query(&cookie, &domain, &ua)
                .param("uid", &uid.to_string())
                .param("limit", &limit.to_string())
                .param("before", "-1");
            let resp = client.msg_comments(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_comment_messages(&resp.body))
        })
    }

    /// 消息中心"@我"(需登录). vendor 的 msg_forwards 只发 offset/limit, 没有
    /// lasttime 游标 → last_time_ms 保留参数形状, 当前恒取最新一页.
    pub(super) fn forward_messages(
        &self,
        limit: u32,
        _last_time_ms: u64,
    ) -> BoxFuture<'_, ProviderResult<Vec<ForwardItem>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("@我需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.to_string())
                .param("offset", "0");
            let resp = client.msg_forwards(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_forwards(&resp.body))
        })
    }

    /// 最近联系人(需登录). vendor 的 msg_recentcontact 发空 body, limit 只能客户端截断.
    pub(super) fn recent_contacts(
        &self,
        limit: u32,
    ) -> BoxFuture<'_, ProviderResult<Vec<RecentContact>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("最近联系人需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua);
            let resp = client.msg_recentcontact(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut list = parse_recent_contacts(&resp.body);
            if (limit as usize) < list.len() {
                list.truncate(limit as usize);
            }
            Ok(list)
        })
    }

    /// 关注动态: /api/v1/event/get 返回"我关注的人"的动态(含艺人发布).
    pub(super) fn feed_events(
        &self,
        limit: u32,
        last_time: i64,
    ) -> BoxFuture<'_, ProviderResult<Vec<FeedEvent>>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("查看关注动态需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("pagesize", &limit.max(1).to_string())
                .param("lasttime", &last_time.to_string());
            let resp = client.event(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_feed_events(&resp.body))
        })
    }

    /// 指定用户的动态(他人主页/好友主页): vendor 的 event 只支持 pagesize/lasttime,
    /// 这里在 service 侧直接请求同一端点(/api/v1/event/get)并带 uid.
    /// 拿不到数据(隐私设置/无动态/接口非 200)一律返回空列表, 不报错.
    pub(super) fn user_events(
        &self,
        uid: u64,
        limit: u32,
        last_time: i64,
    ) -> BoxFuture<'_, ProviderResult<Vec<FeedEvent>>> {
        Box::pin(async move {
            if uid == 0 {
                return Ok(Vec::new());
            }
            let (client, domain, ua, cookie) = self.snapshot();
            let body = serde_json::json!({
                "uid": uid,
                "limit": limit.clamp(1, 100),
                "lasttime": last_time,
            });
            let resp = client
                .request(
                    "/api/v1/event/get",
                    body,
                    weapi_option(&cookie, &domain, &ua),
                )
                .await
                .map_err(map_error)?;
            // 非 200(隐私/未登录/风控)按"没数据"处理
            if check_body(&resp.body).is_err() {
                return Ok(Vec::new());
            }
            let mut list = parse_feed_events(&resp.body);
            if (limit as usize) < list.len() {
                list.truncate(limit as usize);
            }
            Ok(list)
        })
    }

    /// 动态评论: vendor 走 /api/v1/resource/comments/<threadId>.
    pub(super) fn event_comments<'a>(
        &'a self,
        thread_id: &'a str,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'a, ProviderResult<CommentPage>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            let q = make_query(&cookie, &domain, &ua)
                .param("threadId", thread_id)
                .param("limit", &limit.to_string())
                .param("offset", &offset.to_string());
            let resp = client.comment_event(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            let mut page = parse_comments(&resp.body)?;
            page.thread_id = thread_id.to_string();
            Ok(page)
        })
    }

    /// 动态点赞: vendor resource_like, type=6 表示动态, 传 threadId.
    pub(super) fn like_event<'a>(
        &'a self,
        thread_id: &'a str,
        liked: bool,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("点赞动态需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("type", "6")
                .param("threadId", thread_id)
                .param("t", if liked { "1" } else { "0" });
            let resp = client.resource_like(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 转发动态: /api/event/forward
    pub(super) fn forward_event<'a>(
        &'a self,
        event_id: u64,
        user_id: u64,
        msg: &'a str,
    ) -> BoxFuture<'a, ProviderResult<bool>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("转发动态需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("evId", &event_id.to_string())
                .param("uid", &user_id.to_string())
                .param("forwards", msg);
            let resp = client.event_forward(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }
}

/// 关注/粉丝列表: {code, follow:[{userId,nickname,avatarUrl,signature}]} /
/// 粉丝接口把数组放在 "followeds"
pub fn parse_user_items(body: &Value, key: &str, followed: bool) -> Vec<UserItem> {
    let arr = body
        .get(key)
        .or_else(|| body.get("data"))
        .and_then(Value::as_array);
    let Some(arr) = arr else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| {
            let id = u64_of(v, "userId").or_else(|| u64_of(v, "id"))?;
            let name = str_of(v, "nickname")
                .or_else(|| str_of(v, "name"))
                .unwrap_or_default();
            if name.is_empty() {
                return None;
            }
            Some(UserItem {
                id,
                name,
                avatar_url: str_of(v, "avatarUrl")
                    .or_else(|| str_of(v, "picUrl"))
                    .filter(|s| s.starts_with("http")),
                signature: str_of(v, "signature").unwrap_or_default(),
                followed,
            })
        })
        .collect()
}

/// 私信/通知里那段 JSON 字符串(`"{\"msg\":\"...\"}"`)抽成一句纯文本。
/// 富消息(卡片/会员通知)没有 `msg`, 就退到 generalMsg 的标题/摘要/pushMsg。
pub fn msg_text(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let Ok(v) = serde_json::from_str::<Value>(trimmed) else {
        return trimmed.to_string();
    };
    if let Some(s) = v.get("msg").and_then(Value::as_str) {
        if !s.trim().is_empty() {
            return s.to_string();
        }
    }
    // 富消息(会员/活动卡片): 标题比 pushMsg 长文案更适合当列表摘要
    if let Some(g) = v.get("generalMsg") {
        for key in ["title", "inboxBriefContent", "noticeMsg", "subTitle"] {
            if let Some(s) = str_of(g, key) {
                if !s.trim().is_empty() {
                    return s;
                }
            }
        }
    }
    if let Some(s) = v.get("pushMsg").and_then(Value::as_str) {
        if !s.trim().is_empty() {
            return s.to_string();
        }
    }
    String::new()
}

/// 私信会话列表: {code, msgs:[{fromUser:{userId,nickname,avatarUrl},
/// lastMsg(JSON 字符串), lastMsgTime, newMsgCount}], newMsgCount}
pub fn parse_private_sessions(body: &Value) -> Vec<PrivateSession> {
    body.get("msgs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|m| {
                    let user = m.get("fromUser").or_else(|| m.get("toUser"))?;
                    let user_id = u64_of(user, "userId")?;
                    Some(PrivateSession {
                        user_id,
                        nickname: str_of(user, "nickname").unwrap_or_default(),
                        avatar_url: str_of(user, "avatarUrl"),
                        last_message: str_of(m, "lastMsg")
                            .map(|s| msg_text(&s))
                            .unwrap_or_default(),
                        last_time_ms: u64_of(m, "lastMsgTime").unwrap_or(0),
                        unread: u64_of(m, "newMsgCount").unwrap_or(0) as u32,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 私信历史: {code, msgs:[{id, fromUser:{userId,nickname,avatarUrl}, toUser, msg(JSON 字符串), time}]}
/// 接口按时间倒序给, 这里翻成正序(老的在前), 方便 UI 直接往下排。
pub fn parse_private_history(body: &Value, my_uid: u64) -> Vec<PrivateMessage> {
    let mut out: Vec<PrivateMessage> = body
        .get("msgs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|m| {
                    let from = m.get("fromUser").or_else(|| m.get("realFromUser"));
                    let from_user = from.and_then(|u| u64_of(u, "userId")).unwrap_or(0);
                    let content = str_of(m, "msg").map(|s| msg_text(&s)).unwrap_or_default();
                    if content.is_empty() {
                        return None;
                    }
                    Some(PrivateMessage {
                        id: u64_of(m, "id").unwrap_or(0),
                        from_me: my_uid != 0 && from_user == my_uid,
                        nickname: from.and_then(|u| str_of(u, "nickname")).unwrap_or_default(),
                        avatar_url: from.and_then(|u| str_of(u, "avatarUrl")),
                        content,
                        time_ms: u64_of(m, "time").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    out.reverse();
    out
}

/// 通知: {code, notices:[{id, time, notice(JSON 字符串:
/// {generalNotice:{actionDesc,content,nativeUrl}, user:{userId,nickname,avatarUrl}})}]}
pub fn parse_notices(body: &Value) -> Vec<InboxItem> {
    body.get("notices")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .map(|n| {
                    let raw = str_of(n, "notice").unwrap_or_default();
                    let inner: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);
                    let general = inner.get("generalNotice");
                    let user = inner.get("user");
                    let mut text = general
                        .and_then(|g| str_of(g, "actionDesc"))
                        .unwrap_or_default();
                    let detail = general
                        .and_then(|g| str_of(g, "content"))
                        .unwrap_or_default();
                    if text.is_empty() {
                        // 没 actionDesc 的系统通知: 用 pushMsg/notice 兜底
                        text = str_of(n, "pushMsg")
                            .filter(|s| !s.trim().is_empty())
                            .unwrap_or_else(|| "系统通知".to_string());
                    }
                    InboxItem {
                        id: u64_of(n, "id").unwrap_or(0),
                        kind: "notice".to_string(),
                        actor: user.and_then(|u| str_of(u, "nickname")).unwrap_or_default(),
                        avatar_url: user.and_then(|u| str_of(u, "avatarUrl")),
                        text,
                        detail,
                        time_ms: u64_of(n, "time").unwrap_or(0),
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 评论/回复消息: {code, comments:[{commentId, content, beRepliedContent, time,
/// user:{userId,nickname,avatarUrl}, resourceJson(JSON 字符串:{name,...})}]}
pub fn parse_comment_messages(body: &Value) -> Vec<InboxItem> {
    body.get("comments")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|c| {
                    let text = str_of(c, "content").unwrap_or_default();
                    if text.is_empty() {
                        return None;
                    }
                    let user = c.get("user");
                    // 附注优先级: 被回复的资源名 > 我方原评论("我: 「...」")
                    let resource = str_of(c, "resourceJson")
                        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
                        .and_then(|v| str_of(&v, "name"))
                        .unwrap_or_default();
                    let replied = str_of(c, "beRepliedContent").unwrap_or_default();
                    let detail = if !resource.is_empty() {
                        resource
                    } else {
                        replied
                    };
                    Some(InboxItem {
                        id: u64_of(c, "commentId").unwrap_or(0),
                        kind: "comment".to_string(),
                        actor: user.and_then(|u| str_of(u, "nickname")).unwrap_or_default(),
                        avatar_url: user.and_then(|u| str_of(u, "avatarUrl")),
                        text,
                        detail,
                        time_ms: u64_of(c, "time").unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// @我: {code, forwards:[...], lasttime, more, newCount}
/// 真实空账号响应(2026-11 实测): {"code":200,"forwards":[],"lasttime":0,"more":false,"newCount":0}
/// 非空条目形状未实测(空账号拿不到), 按邻近接口(msg_private/notices)风格做防御式解析,
/// 兼容: {id|msgId, time|forwardTime, type, content|comment, json(JSON 字符串),
/// user|fromUser:{userId,nickname,avatarUrl}, eventId|event.id, picUrl|json.pics[].picUrl}.
/// 解析不出任何 id 的条目直接跳过.
pub fn parse_forwards(body: &Value) -> Vec<ForwardItem> {
    body.get("forwards")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|f| {
                    let event = f.get("event");
                    let id = u64_of(f, "id").or_else(|| u64_of(f, "msgId"));
                    let event_id =
                        u64_of(f, "eventId").or_else(|| event.and_then(|e| u64_of(e, "id")));
                    if id.is_none() && event_id.is_none() {
                        return None;
                    }
                    let user = f.get("user").or_else(|| f.get("fromUser"));
                    let mut comment = str_of(f, "content")
                        .or_else(|| str_of(f, "comment"))
                        .map(|s| msg_text(&s))
                        .unwrap_or_default();
                    if comment.is_empty() {
                        comment = str_of(f, "json").map(|s| msg_text(&s)).unwrap_or_default();
                    }
                    // 图片: 顶层 picUrl > 顶层对象/转发原动态(pics[].picUrl|urlCommon)
                    let pic_url = str_of(f, "picUrl")
                        .or_else(|| pics_of(f))
                        .or_else(|| event.and_then(pics_of))
                        .or_else(|| {
                            str_of(f, "json")
                                .and_then(|s| serde_json::from_str::<Value>(&s).ok())
                                .and_then(|v| pics_of(&v))
                        });
                    Some(ForwardItem {
                        id,
                        event_id,
                        user_id: user.and_then(|u| u64_of(u, "userId")),
                        nickname: user.and_then(|u| str_of(u, "nickname")),
                        avatar_url: user.and_then(|u| str_of(u, "avatarUrl")),
                        comment: if comment.is_empty() {
                            None
                        } else {
                            Some(comment)
                        },
                        time_ms: u64_of(f, "time")
                            .or_else(|| u64_of(f, "forwardTime"))
                            .map(normalize_ms),
                        forward_type: u64_of(f, "type").map(|t| t as u32),
                        pic_url,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 最近联系人: {code, data:{follow:[{userId, nickname, avatarUrl, mutual, onlined,
/// vipType, gender, userType, remarkName, py, avatarDetail{...}}]}}
/// 实测(2026-11): 只有 data.follow 一个数组, 是"可发起私信的联系人/关注列表",
/// 不是"最近聊天"; 顺序是服务端顺序.
pub fn parse_recent_contacts(body: &Value) -> Vec<RecentContact> {
    body.get("data")
        .and_then(|d| d.get("follow"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|c| {
                    let user_id = u64_of(c, "userId")?;
                    Some(RecentContact {
                        user_id,
                        nickname: str_of(c, "nickname").unwrap_or_default(),
                        avatar_url: str_of(c, "avatarUrl").filter(|s| s.starts_with("http")),
                        mutual: c.get("mutual").and_then(Value::as_bool).unwrap_or(false),
                        onlined: c.get("onlined").and_then(Value::as_bool).unwrap_or(false),
                        vip_type: u64_of(c, "vipType").unwrap_or(0) as u32,
                        remark_name: str_of(c, "remarkName").filter(|s| !s.trim().is_empty()),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub(super) fn event_kind(event_type: i64) -> &'static str {
    match event_type {
        18 => "song",
        13 => "playlist",
        19 => "album",
        17 | 22 => "program",
        // 35 是"发动态/文字+图", 5..8 是更老版本的文字动态
        5..=8 | 35 => "text",
        _ => "other",
    }
}

/// 动态配图. 线上 pics 是对象数组(2026-11-06 实测), 用 originUrl 拿最大图,
/// 退化到 pcSquareUrl/pcRectangleUrl/squareUrl/rectangleUrl;
/// 老的字符串数组形态也认.
pub fn parse_event_images(value: &Value) -> Vec<String> {
    let Some(arr) = value.as_array() else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| {
            v.as_str().map(str::to_string).or_else(|| {
                [
                    "originUrl",
                    "pcSquareUrl",
                    "pcRectangleUrl",
                    "squareUrl",
                    "rectangleUrl",
                    "thumbUrl",
                    "url",
                ]
                .iter()
                .find_map(|key| str_of(v, key))
            })
        })
        .filter(|s| !s.is_empty())
        .take(9)
        .collect()
}

/// 从 pics 里捞视频直链(部分动态把视频挂在配图节点上)
pub(super) fn video_from_pics(value: &Value) -> Option<String> {
    let arr = value.as_array()?;
    arr.iter().find_map(|v| {
        ["videoUrl", "videoOriginalUrl"]
            .iter()
            .find_map(|key| str_of(v, key))
            .filter(|s| !s.is_empty())
    })
}

/// 关注动态的响应形如
///   {code:200, events:[{id, eventType, eventTime, user:{nickname,avatarUrl},
///                       json:{song:{...}, comment:"..."}|"...", pics:[...]}], lasttime}
/// json 有时是字符串(需要再解析一次), 各种 eventType 的字段名也不统一,
/// 这里只提取 UI 能直接展示的最小集合.
pub fn parse_feed_events(body: &Value) -> Vec<FeedEvent> {
    // 线上实测(2026-11-05, /api/v1/event/get)顶层字段叫 event(单数);
    // 旧包装/其它通道可能给 events, 两种都认.
    let Some(arr) = body
        .get("event")
        .or_else(|| body.get("events"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    let privileges = parse_privileges(body);
    let mut out = Vec::new();
    for event in arr {
        let Some(id) = u64_of(event, "id") else {
            continue;
        };
        // 线上字段是 type, 老接口叫 eventType
        let event_type = event
            .get("type")
            .or_else(|| event.get("eventType"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        // json 可能是对象, 也可能是字符串
        let payload_owned = event.get("json").and_then(|j| match j {
            Value::String(s) => serde_json::from_str::<Value>(s).ok(),
            other => Some(other.clone()),
        });
        let payload = payload_owned.as_ref();
        let info = event.get("info");
        let song_value = payload
            .and_then(|p| p.get("song").or_else(|| p.get("songInfo")))
            .or_else(|| info.and_then(|i| i.get("song")));
        let song = song_value.and_then(|s| parse_song_with(s, &privileges));
        let text = payload
            .and_then(|p| {
                str_of(p, "msg")
                    .or_else(|| str_of(p, "comment"))
                    .or_else(|| str_of(p, "description"))
            })
            .or_else(|| info.and_then(|i| str_of(i, "comment")))
            .unwrap_or_default();
        // 配图在顶层 pics(线上实测), 少数通道塞在 json.pics/imgs 里
        let pics_value = event
            .get("pics")
            .or_else(|| payload.and_then(|p| p.get("pics").or_else(|| p.get("imgs"))));
        let images = pics_value.map(parse_event_images).unwrap_or_default();
        // 视频动态: 封面照旧用图片, 直链单独给 UI(点击交给系统播放器/浏览器)
        let video = payload
            .and_then(|p| p.get("video").or_else(|| p.get("mv")))
            .or_else(|| event.get("video"));
        let video_url = video
            .and_then(|v| {
                str_of(v, "playUrl")
                    .or_else(|| str_of(v, "playUrlHd"))
                    .or_else(|| str_of(v, "url"))
            })
            .or_else(|| pics_value.and_then(video_from_pics))
            .filter(|s| !s.is_empty());
        // 动态自带标题(艺人长文常用), 空串就当没有
        let title = payload
            .and_then(|p| str_of(p, "title"))
            .unwrap_or_default()
            .trim()
            .to_string();
        let cover_url = song
            .as_ref()
            .and_then(Song::cover_url)
            .or_else(|| {
                payload.and_then(|p| {
                    str_of(p, "coverUrl")
                        .or_else(|| str_of(p, "coverImgUrl"))
                        .or_else(|| p.get("album").and_then(|a| str_of(a, "picUrl")))
                        .or_else(|| p.get("playlist").and_then(|x| str_of(x, "coverImgUrl")))
                })
            })
            .or_else(|| images.first().cloned())
            .or_else(|| {
                video
                    .and_then(|v| str_of(v, "coverUrl").or_else(|| str_of(v, "cover")))
                    .filter(|s| !s.is_empty())
            });
        let user = event.get("user");
        let user_name = user
            .and_then(|u| str_of(u, "nickname"))
            .or_else(|| payload.and_then(|p| str_of(p, "nickname")))
            .unwrap_or_default();
        let avatar_url = user.and_then(|u| str_of(u, "avatarUrl"));
        let user_id = user.and_then(|u| u64_of(u, "userId")).unwrap_or(0);
        // 评论/点赞都按 threadId 走, 优先 info.threadId, 兜底 info.commentThread.id
        let thread_id = info
            .and_then(|i| str_of(i, "threadId"))
            .or_else(|| {
                info.and_then(|i| i.get("commentThread"))
                    .and_then(|c| str_of(c, "id"))
            })
            .unwrap_or_default();
        let liked = info
            .and_then(|i| i.get("liked"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let liked_count = info.and_then(|i| u64_of(i, "likedCount")).unwrap_or(0);
        let share_count = info.and_then(|i| u64_of(i, "shareCount")).unwrap_or(0);
        let comment_count = info.and_then(|i| u64_of(i, "commentCount")).unwrap_or(0);
        let time_ms = u64_of(event, "eventTime")
            .or_else(|| u64_of(event, "time"))
            .unwrap_or(0);
        out.push(FeedEvent {
            id,
            thread_id,
            user_id,
            kind: event_kind(event_type).to_string(),
            user_name,
            avatar_url,
            text,
            song,
            cover_url,
            images,
            video_url,
            title,
            time_ms,
            liked,
            liked_count,
            share_count,
            comment_count,
        });
    }
    out
}
