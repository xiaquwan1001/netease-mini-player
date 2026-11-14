//! 消息/私信/动态/关注相关单测.

use crate::netease::*;
use serde_json::json;

/// 私信里的 msg/lastMsg 是 JSON 字符串, 富消息要退到 generalMsg 的标题/摘要
#[test]
fn msg_text_unwraps_json_and_rich_payload() {
    assert_eq!(msg_text("你好"), "你好", "纯文本原样返回");
    assert_eq!(msg_text(r#"{"msg":"在吗"}"#), "在吗");
    assert_eq!(
        msg_text(r#"{"generalMsg":{"title":"本月等级权益已更新"},"pushMsg":"push"}"#),
        "本月等级权益已更新",
        "富消息优先用 generalMsg 标题"
    );
    assert_eq!(msg_text("  "), "");
}

#[test]
fn private_sessions_and_history_mapping() {
    let sessions = json!({
        "code": 200,
        "msgs": [
            {"fromUser": {"userId": 7, "nickname": "VIP", "avatarUrl": "http://a/1.jpg"},
             "lastMsg": "{\"msg\":\"本月权益已更新\"}", "lastMsgTime": 1700000000000u64, "newMsgCount": 6},
            {"fromUser": {"userId": 8, "nickname": "好友"}, "lastMsg": "hi", "lastMsgTime": 1600000000000u64, "newMsgCount": 0}
        ]
    });
    let list = parse_private_sessions(&sessions);
    assert_eq!(list.len(), 2);
    assert_eq!(list[0].user_id, 7);
    assert_eq!(list[0].last_message, "本月权益已更新");
    assert_eq!(list[0].unread, 6);
    assert_eq!(list[1].last_message, "hi");

    let history = json!({
        "code": 200,
        "msgs": [
            {"id": 2, "fromUser": {"userId": 42, "nickname": "我"}, "msg": "{\"msg\":\"在的\"}", "time": 200},
            {"id": 1, "fromUser": {"userId": 7, "nickname": "VIP"}, "msg": "你好", "time": 100}
        ]
    });
    let list = parse_private_history(&history, 42);
    assert_eq!(list.len(), 2);
    assert!(!list[0].from_me, "接口给的是倒序, 解析后老的在前");
    assert_eq!(list[0].content, "你好");
    assert!(list[1].from_me);
    assert_eq!(list[1].content, "在的");
}

#[test]
fn notices_and_comment_messages_mapping() {
    let notices = json!({
        "code": 200,
        "notices": [
            {"id": 11, "time": 1779, "pushMsg": "push 文案",
             "notice": "{\"generalNotice\":{\"actionDesc\":\"赞了你的主页背景\"},\"user\":{\"nickname\":\"小明\",\"avatarUrl\":\"http://a/2.jpg\"}}"},
            {"id": 12, "time": 1778, "pushMsg": "", "notice": "garbage"}
        ]
    });
    let list = parse_notices(&notices);
    assert_eq!(list.len(), 2);
    assert_eq!(list[0].actor, "小明");
    assert_eq!(list[0].text, "赞了你的主页背景");
    assert_eq!(list[0].time_ms, 1779);
    assert_eq!(list[1].text, "系统通知", "解析不出来的通知给兜底文案");

    let comments = json!({
        "code": 200,
        "comments": [
            {"commentId": 21, "content": "来了来了", "beRepliedContent": "我: 「旧评论」",
             "time": 1777, "user": {"userId": 5, "nickname": "小红"},
             "resourceJson": "{\"name\":\"我喜欢的音乐\",\"id\":9}"},
            {"commentId": 22, "content": "", "time": 1776}
        ]
    });
    let list = parse_comment_messages(&comments);
    assert_eq!(list.len(), 1, "空评论要丢掉");
    assert_eq!(list[0].actor, "小红");
    assert_eq!(list[0].text, "来了来了");
    assert_eq!(list[0].detail, "我喜欢的音乐", "优先显示被评论的资源名");
}

/// @我: 真实空响应(2026-11 实测, 本账号没有 @我 消息) — 顶层 forwards/lasttime/more/newCount
#[test]
fn forwards_empty_real_response() {
    let body = json!({"code": 200, "forwards": [], "lasttime": 0, "more": false, "newCount": 0});
    assert!(parse_forwards(&body).is_empty());
    // 缺 forwards 键 / 条目不是对象都不炸
    assert!(parse_forwards(&json!({"code": 301})).is_empty());
    assert!(parse_forwards(&json!({"code": 200, "forwards": [null, 1, "x"]})).is_empty());
}

/// @我 非空形状未实测, 用合成条目覆盖防御式解析的各分支
#[test]
fn forwards_synthetic_items_defensive() {
    let body = json!({
        "code": 200,
        "forwards": [
            // 形状 A: 顶层 content/user + eventId, content 是 JSON 字符串, 秒级时间
            {"id": 9001, "time": 1700000000i64, "type": 2,
             "content": "{\"msg\":\"转发一句话\"}",
             "user": {"userId": 7, "nickname": "小明", "avatarUrl": "http://a/1.jpg"},
             "eventId": 42},
            // 形状 B: fromUser + event{id,pics} + json 兜底正文
            {"id": 9002, "forwardTime": 1600000000i64,
             "fromUser": {"userId": 8, "nickname": "小红"},
             "event": {"id": 43, "pics": [{"picUrl": "http://p/1.jpg"}]},
             "json": "{\"msg\":\"看看图\"}"},
            // 无法识别 id → 跳过
            {"user": {"userId": 9, "nickname": "路人"}}
        ]
    });
    let list = parse_forwards(&body);
    assert_eq!(list.len(), 2, "解析不出 id 的条目跳过");
    assert_eq!(list[0].id, Some(9001));
    assert_eq!(list[0].event_id, Some(42));
    assert_eq!(list[0].user_id, Some(7));
    assert_eq!(list[0].nickname.as_deref(), Some("小明"));
    assert_eq!(list[0].comment.as_deref(), Some("转发一句话"));
    assert_eq!(list[0].forward_type, Some(2));
    assert_eq!(
        list[0].time_ms,
        Some(1_700_000_000_000),
        "秒级时间戳归一成毫秒"
    );
    assert_eq!(list[1].id, Some(9002));
    assert_eq!(list[1].event_id, Some(43));
    assert_eq!(list[1].user_id, Some(8));
    assert_eq!(list[1].comment.as_deref(), Some("看看图"));
    assert_eq!(list[1].pic_url.as_deref(), Some("http://p/1.jpg"));
    assert!(list[1].avatar_url.is_none());
}

/// 最近联系人: 真实形状(2026-11 实测 data.follow)
#[test]
fn recent_contacts_follow_mapping() {
    let body = json!({
        "code": 200,
        "data": {"follow": [
            {"userId": 32953014u64, "nickname": "云音乐VIP",
             "avatarUrl": "https://p4.music.126.net/a.jpg",
             "mutual": false, "onlined": false, "vipType": 11, "gender": 0,
             "userType": 10, "remarkName": "", "py": "VIP"},
            {"userId": 2, "nickname": "好友", "mutual": true, "onlined": true,
             "remarkName": "老王"},
            {"nickname": "幽灵"}
        ]}
    });
    let list = parse_recent_contacts(&body);
    assert_eq!(list.len(), 2, "没有 userId 的条目跳过");
    assert_eq!(list[0].user_id, 32953014);
    assert_eq!(list[0].nickname, "云音乐VIP");
    assert_eq!(list[0].vip_type, 11);
    assert!(!list[0].mutual && !list[0].onlined);
    assert_eq!(list[0].remark_name, None, "空 remarkName 归 None");
    assert_eq!(list[1].remark_name.as_deref(), Some("老王"));
    assert!(list[1].mutual && list[1].onlined);
    // 顶层不是 data.follow 也不炸
    assert!(parse_recent_contacts(&json!({"code": 200})).is_empty());
}

#[test]
fn feed_event_mapping() {
    let body = json!({"code": 200, "event": [
        {
            "id": 100,
            "type": 18,
            "eventTime": 1700000000000u64,
            "user": {"nickname": "某艺人", "avatarUrl": "http://p/u.jpg"},
            "json": {
                "msg": "分享一首歌",
                "song": {
                    "id": 7, "name": "新歌", "ar": [{"name": "某艺人"}],
                    "al": {"id": 3, "name": "专辑", "picUrl": "http://p/c.jpg"}, "dt": 1000, "fee": 1
                }
            }
        },
        {
            "id": 101,
            "eventType": 13,
            "eventTime": 1700000001000u64,
            "user": {"nickname": "好友"},
            "json": "{\"playlist\":{\"coverImgUrl\":\"http://p/pl.jpg\"},\"comment\":\"推荐歌单\"}"
        }
    ]});
    let events = parse_feed_events(&body);
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].kind, "song");
    assert_eq!(events[0].user_name, "某艺人");
    assert_eq!(events[0].song.as_ref().unwrap().name, "新歌");
    assert_eq!(events[0].cover_url.as_deref(), Some("http://p/c.jpg"));
    assert_eq!(events[0].time_ms, 1700000000000);
    assert_eq!(events[1].kind, "playlist");
    assert_eq!(events[1].text, "推荐歌单");
    assert_eq!(events[1].cover_url.as_deref(), Some("http://p/pl.jpg"));
}

#[test]
fn feed_event_detail_fields() {
    // 线上(2026-11-06)真实字段: pics 是对象数组, info 里有 threadId/likedCount,
    // user 里有 userId, json 里可能带 title. 这些是详情页/点赞/评论的依据.
    let body = json!({"code": 200, "event": [{
        "id": 38024377972u64,
        "type": 35,
        "eventTime": 1793228407720u64,
        "user": {"nickname": "某艺人", "userId": 1373758224u64,
                 "avatarUrl": "http://p/u.jpg"},
        "json": {"msg": "长文正文", "title": "标题一句"},
        "pics": [
            {"originUrl": "http://p/1.jpg", "pcSquareUrl": "http://p/1s.jpg"},
            {"originUrl": "http://p/2.jpg", "videoUrl": "http://v/2.mp4"}
        ],
        "info": {
            "threadId": "A_EV_2_38024377972_1373758224",
            "liked": true, "likedCount": 30, "shareCount": 4, "commentCount": 3
        }
    }]});
    let e = &parse_feed_events(&body)[0];
    assert_eq!(e.kind, "text");
    assert_eq!(e.user_id, 1373758224);
    assert_eq!(e.thread_id, "A_EV_2_38024377972_1373758224");
    assert_eq!(e.title, "标题一句");
    assert_eq!(
        e.images,
        vec!["http://p/1.jpg".to_string(), "http://p/2.jpg".to_string()]
    );
    assert_eq!(e.video_url.as_deref(), Some("http://v/2.mp4"));
    assert!(e.liked);
    assert_eq!(e.liked_count, 30);
    assert_eq!(e.share_count, 4);
    assert_eq!(e.comment_count, 3);
}

/// 需求 5: 对方把关注/粉丝列表设成私密时上游给 code=400 且**没有列表数组**,
/// 必须映射成 Forbidden(不可重试) + 用户能读的文案, 不能落成 internal.
#[test]
fn follow_list_hidden_maps_to_forbidden() {
    let e = check_follow_list(
        &json!({"code": 400}),
        "follow",
        "该用户已设置关注列表不可见",
    )
    .expect_err("code=400 且没有 follow 数组应报错");
    assert_eq!(e.kind, ProviderErrorKind::Forbidden);
    assert!(!e.retryable);
    assert_eq!(e.detail, "该用户已设置关注列表不可见");

    let e = check_follow_list(
        &json!({"code": 400}),
        "followeds",
        "该用户已设置粉丝列表不可见",
    )
    .expect_err("code=400 且没有 followeds 数组应报错");
    assert_eq!(e.kind, ProviderErrorKind::Forbidden);
    assert_eq!(e.detail, "该用户已设置粉丝列表不可见");

    // 正常/空列表: 不是隐私限制
    assert!(check_follow_list(&json!({"code": 200, "follow": []}), "follow", "x").is_ok());
    assert!(check_follow_list(
        &json!({"code": 200, "follow": [{"userId": 1}]}),
        "follow",
        "x"
    )
    .is_ok());
    // 没有 code 字段(老响应)也放行
    assert!(check_follow_list(&json!({"follow": []}), "follow", "x").is_ok());

    // 其它业务码仍走通用映射: 8821 -> RiskControl, 400 之外未知码 -> Internal
    let e = check_follow_list(&json!({"code": 8821}), "follow", "x").unwrap_err();
    assert_eq!(e.kind, ProviderErrorKind::RiskControl);
    let e = check_follow_list(&json!({"code": 500}), "follow", "x").unwrap_err();
    assert_eq!(e.kind, ProviderErrorKind::Internal);
    // 关键回归: 「不可见」不能被误判成参数错误(Auth)
    let e = check_follow_list(&json!({"code": 400}), "follow", "x").unwrap_err();
    assert_ne!(e.kind, ProviderErrorKind::Auth);
}

/// 需求 11: 动态分页游标(lasttime/more)要被解析出来并原样回传
#[test]
fn feed_page_cursor_mapping() {
    let body = json!({
        "code": 200,
        "lasttime": 1700000000000i64,
        "more": true,
        "event": [
            {"id": 1, "type": 18, "eventTime": 1699999999000i64,
             "user": {"userId": 9, "nickname": "好友", "avatarUrl": "http://a/1.jpg"},
             "json": {"msg": "hi"}}
        ]
    });
    let page = parse_feed_page(&body);
    assert_eq!(page.events.len(), 1);
    assert_eq!(page.events[0].id, 1);
    assert_eq!(page.last_time, 1700000000000);
    assert!(page.more);

    // more 缺失: 有事件 + 有游标 ⇒ 推断还能翻
    let page = parse_feed_page(&json!({
        "code": 200,
        "lasttime": 1700000000000i64,
        "event": [{"id": 2, "type": 18, "eventTime": 1, "user": {"nickname": "x"}}]
    }));
    assert!(page.more);

    // 到底了: 上游明确 more=false
    let page = parse_feed_page(&json!({
        "code": 200, "lasttime": 1690000000000i64, "more": false,
        "event": [{"id": 3, "type": 18, "eventTime": 1, "user": {"nickname": "x"}}]
    }));
    assert!(!page.more);

    // 空响应 / 没有游标: 不 panic, 游标 0 表示不能翻页
    let page = parse_feed_page(&json!({"code": 200}));
    assert!(page.events.is_empty());
    assert_eq!(page.last_time, 0);
    assert!(!page.more);

    // lastTime 驼峰包装也要认
    let page = parse_feed_page(&json!({"code": 200, "lastTime": 1690000000123i64}));
    assert_eq!(page.last_time, 1690000000123);
}
