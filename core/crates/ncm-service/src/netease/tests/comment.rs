//! 评论/楼层/回复/统计相关单测.

use crate::netease::*;
use serde_json::json;

/// MV/视频评论: /api/v1/resource/comments/R_MV_5_|R_VI_62_ 与歌曲评论同形,
/// parse_comments 直接复用(hotComments + comments + total + more).
#[test]
fn mv_video_comments_share_comment_page_shape() {
    let body = json!({
        "code": 200,
        "total": 1234u64,
        "more": true,
        "hotComments": [{"commentId": 1u64, "content": "神作", "likedCount": 99u64}],
        "comments": [{"commentId": 2u64, "content": "前排", "likedCount": 1u64}]
    });
    let page = parse_comments(&body).expect("parse ok");
    assert_eq!(page.total, 1234);
    assert!(page.has_more);
    assert_eq!(page.comments.len(), 2);
    assert!(page.comments[0].hot);
    assert!(!page.comments[1].hot);
    // kind → threadId 前缀映射早已存在
    assert_eq!(
        thread_id_for("mv", 5436712).as_deref(),
        Some("R_MV_5_5436712")
    );
    assert_eq!(
        thread_id_for("video", 144634).as_deref(),
        Some("R_VI_62_144634")
    );
}

/// comment_info_list: 实测字段(歌曲 186016), 只取 data[0], 服务端 threadId 优先
#[test]
fn comment_stats_parses_real_shape() {
    // 2026-11-09 实测: ncm raw comment_info_list type=0 ids=186016
    let body = json!({
        "code": 200,
        "data": [{
            "commentCount": 1_969_911u64,
            "commentCountDesc": "100w+",
            "commentUpgraded": false,
            "comments": null,
            "latestLikedUsers": null,
            "liked": false,
            "likedCount": 352,
            "musicianSaidCount": 0,
            "resourceId": 186016,
            "resourceType": 4,
            "shareCount": 109_723u64,
            "threadId": "R_SO_4_186016"
        }]
    });
    let s = parse_comment_stats(&body, "R_SO_4_186016").expect("stats");
    assert_eq!(s.thread_id, "R_SO_4_186016");
    assert_eq!(s.resource_id, 186016);
    assert_eq!(s.comment_count, 1_969_911);
    assert_eq!(s.comment_count_desc, "100w+");
    assert_eq!(s.share_count, 109_723);
    assert_eq!(s.liked_count, 352);
    assert!(!s.liked);
    assert_eq!(s.musician_said_count, 0);
    assert!(!s.comment_upgraded);
}

/// data 缺失 / 空数组 / 空对象 / null 都退化成全 0(threadId 用入参), 不能 panic 也不能报错
#[test]
fn comment_stats_tolerates_missing_data() {
    for body in [
        json!({"code": 200}),
        json!({"code": 200, "data": []}),
        json!({"code": 200, "data": {}}),
        json!({"code": 200, "data": null}),
    ] {
        let s = parse_comment_stats(&body, "A_PL_0_24381616").expect("stats");
        assert_eq!(s.thread_id, "A_PL_0_24381616", "body={body}");
        assert_eq!(s.comment_count, 0);
        assert_eq!(s.share_count, 0);
        assert_eq!(s.liked_count, 0);
        assert!(s.comment_count_desc.is_empty());
    }
}

/// 歌单/专辑/播客/视频共用同一形状, 只是数值不同(实测均为空 desc + 0 评论)
#[test]
fn comment_stats_shape_is_same_across_resource_types() {
    let cases = [
        ("A_PL_0_24381616", 24381616u64, 6u64),
        ("R_AL_3_32311", 32311, 10_519),
        ("A_DJ_1_32507038", 32507038, 0),
        ("R_VI_62_12147019", 12147019, 0),
    ];
    for (tid, rid, share) in cases {
        let body = json!({"code": 200, "data": [{
            "commentCount": 0, "commentCountDesc": "", "commentUpgraded": false,
            "comments": null, "latestLikedUsers": null, "liked": false, "likedCount": 0,
            "musicianSaidCount": 0, "resourceId": rid, "resourceType": 0,
            "shareCount": share, "threadId": tid
        }]});
        let s = parse_comment_stats(&body, tid).expect("stats");
        assert_eq!(s.thread_id, tid);
        assert_eq!(s.resource_id, rid);
        assert_eq!(s.share_count, share);
    }
}

#[test]
fn comments_mapping_hot_first_and_dedup() {
    let body = json!({
        "code": 200,
        "total": 123,
        "more": true,
        "hotComments": [
            {"commentId": 1, "user": {"nickname": "A", "avatarUrl": "http://p/a.jpg"},
             "content": "好", "time": 1700000000000u64, "likedCount": 10, "liked": true,
             "ipLocation": {"location": ""}},
            {"commentId": 2, "user": {"nickname": "B"}, "content": "赞"}
        ],
        "comments": [
            {"commentId": 2, "user": {"nickname": "B"}, "content": "赞",
             "ipLocation": {"location": "广东"}},
            {"commentId": 3, "user": {"nickname": "C"}, "content": "三"}
        ]
    });
    let page = parse_comments(&body).unwrap();
    assert_eq!(page.total, 123);
    assert!(page.has_more);
    // 精彩评论在前, 跨列表按 commentId 去重
    let ids: Vec<u64> = page.comments.iter().map(|c| c.id).collect();
    assert_eq!(ids, vec![1, 2, 3]);
    assert_eq!(page.comments[0].user_name, "A");
    assert_eq!(
        page.comments[0].avatar_url.as_deref(),
        Some("http://p/a.jpg")
    );
    assert_eq!(page.comments[0].time_ms, 1700000000000);
    assert_eq!(page.comments[0].liked_count, 10);
    assert!(page.comments[0].liked);
    assert!(!page.comments[2].liked);
    // 精彩评论带 hot 标记; 去重时保留先出现的 hot 版本, IP 归属地仍是空
    assert!(page.comments[0].hot);
    assert!(page.comments[1].hot);
    assert!(!page.comments[2].hot);
    assert!(page.comments[0].ip_location.is_empty());
    // 热评版没有 IP, 去重时从后面同一评论的普通版本补上
    assert_eq!(page.comments[1].ip_location, "广东");
    // 没有 ipLocation 字段时是空串(UI 不显示)
    assert!(page.comments[2].ip_location.is_empty());
}

#[test]
fn hot_comments_page_shape() {
    // vendor comment_hot 的响应: {code, hasMore, hotComments:[...], total}
    // 注意用的是 hasMore(不是普通评论页的 more), 总数也是"热门评论"的总数
    let body = json!({
        "code": 200,
        "hasMore": true,
        "total": 9405,
        "hotComments": [
            {"commentId": 7, "user": {"nickname": "D"}, "content": "热",
             "likedCount": 444050, "ipLocation": {"location": ""}},
            {"commentId": 8, "user": {"nickname": "E"}, "content": "也热"}
        ]
    });
    let page = parse_comments(&body).unwrap();
    assert_eq!(page.total, 9405);
    assert!(page.has_more);
    assert_eq!(page.comments.len(), 2);
    assert!(page.comments.iter().all(|c| c.hot));
    assert_eq!(page.comments[0].liked_count, 444050);
}

#[test]
fn thread_id_roundtrip_and_split() {
    assert_eq!(thread_id_for("song", 42).as_deref(), Some("R_SO_4_42"));
    assert_eq!(thread_id_for("playlist", 7).as_deref(), Some("A_PL_0_7"));
    assert!(thread_id_for("unknown", 1).is_none());

    assert_eq!(split_thread_id("R_SO_4_42"), Some(("0", "42".to_string())));
    assert_eq!(split_thread_id("A_PL_0_7"), Some(("2", "7".to_string())));
    // 动态的 id 段要保留 eventId_userId
    assert_eq!(
        split_thread_id("A_EV_2_38024377972_1373758224"),
        Some(("6", "38024377972_1373758224".to_string()))
    );
    assert!(split_thread_id("R_SO_4_").is_none());
    assert!(split_thread_id("garbage").is_none());
}

/// 楼层/回复的归属信息: `beReplied[0].user.nickname` → replied_to, `parentCommentId` → parent_id.
/// 少了这两个字段, 回复在列表里就长得跟独立评论一样(用户报的 bug).
#[test]
fn comment_reply_attribution() {
    let floor = json!({"code": 200, "data": {"comments": [
        {"commentId": 11, "content": "回复主评论", "user": {"userId": 9, "nickname": "A"},
         "parentCommentId": 7, "beReplied": [{"user": {"userId": 3, "nickname": "楼主"},
                                             "content": "原评论", "status": 0}]},
        // 顶层评论: 没有 parentCommentId/beReplied
        {"commentId": 12, "content": "独立评论", "user": {"userId": 8, "nickname": "B"}},
        // beReplied 里没有昵称: 不能报空字符串, 必须落到 None
        {"commentId": 13, "content": "x", "user": {"userId": 8}, "beReplied": [{"user": {}}]}
    ]}});
    let page = parse_comment_floor(&floor).unwrap();
    assert_eq!(page.comments[0].parent_id, 7);
    assert_eq!(page.comments[0].replied_to.as_deref(), Some("楼主"));
    assert_eq!(page.comments[1].parent_id, 0);
    assert_eq!(page.comments[1].replied_to, None);
    assert_eq!(page.comments[2].replied_to, None);
}

#[test]
fn comment_floor_and_users_mapping() {
    let floor = json!({"code": 200, "data": {
        "comments": [
            {"commentId": 1, "content": "回复一", "user": {"userId": 9, "nickname": "A", "avatarUrl": "https://p/a.jpg"},
             "likedCount": 2, "liked": true, "showFloorComment": {"replyCount": 3}},
            {"commentId": 2, "content": "回复二", "user": {"nickname": "B"}}
        ],
        "hasMore": true, "total": 2
    }});
    let page = parse_comment_floor(&floor).unwrap();
    assert_eq!(page.comments.len(), 2);
    assert_eq!(page.comments[0].user_id, 9);
    assert_eq!(page.comments[0].reply_count, 3);
    assert!(page.comments[0].liked);
    assert!(page.has_more);

    let follows = json!({"code": 200, "follow": [
        {"userId": 11, "nickname": "关注的人", "avatarUrl": "https://p/f.jpg", "signature": "hi"},
        {"userId": 12, "nickname": "另一个"}
    ]});
    let users = parse_user_items(&follows, "follow", true);
    assert_eq!(users.len(), 2);
    assert_eq!(users[0].signature, "hi");
    assert!(users[0].followed);
    assert_eq!(users[1].avatar_url, None);

    let followeds = json!({"code": 200, "followeds": [
        {"userId": 13, "nickname": "粉丝"}
    ]});
    let fans = parse_user_items(&followeds, "followeds", false);
    assert_eq!(fans.len(), 1);
    assert!(!fans[0].followed);
}
