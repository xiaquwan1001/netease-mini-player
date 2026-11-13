//! 电台/播客相关单测.

use crate::netease::*;
use ncm_provider::ProviderErrorKind;
use serde_json::json;

// ---- B10 电台补充(只读) ----

/// dj_catelist: 顶层直接是 categories, 没有 code; 缺字段要兜底
#[test]
fn radio_categories_parses_real_shape() {
    let body = json!({"categories": [
        {"id": 3, "name": "情感", "pic56x56Url": "https://p4.music.126.net/x.jpg",
         "picWebUrl": "https://p3.music.126.net/y.jpg"},
        {"id": 2, "name": "音乐播客"}
    ]});
    let cats = parse_radio_categories(&body);
    assert_eq!(cats.len(), 2);
    assert_eq!(cats[0].id, 3);
    assert_eq!(cats[0].name, "情感");
    assert!(cats[0].cover_url.starts_with("https://"));
    assert!(cats[1].cover_url.is_empty());
    // 空/缺 categories → 空列表不报错
    assert!(parse_radio_categories(&json!({})).is_empty());
}

/// dj_category_recommend: data 是数组, radios 元素与 DjRadio 同形状(icon 可 null)
#[test]
fn radio_picks_parses_real_shape() {
    let body = json!({"code": 200, "data": [
        {"categoryId": 3, "categoryName": "情感", "radios": [
            {"id": 526564706, "name": "伴听FM", "picUrl": "https://x.jpg",
             "playCount": 6555956u64, "programCount": 18, "subCount": 0,
             "lastProgramName": "想和你把生活过成一首诗", "radioFeeType": 0, "icon": null,
             "dj": {"nickname": "小北"}}
        ]}
    ]});
    let picks = parse_radio_picks(&body);
    assert_eq!(picks.len(), 1);
    assert_eq!(picks[0].category_id, 3);
    assert_eq!(picks[0].radios.len(), 1);
    assert_eq!(picks[0].radios[0].name, "伴听FM");
    assert_eq!(picks[0].radios[0].dj_name, "小北");
    // data 缺失 → 空
    assert!(parse_radio_picks(&json!({"code": 200})).is_empty());
}

/// dj_toplist: 顶层 toplist, 元素带 rank/score/lastRank, rcmdtext 全小写
#[test]
fn radio_toplist_radios_parses_real_shape() {
    let body = json!({"code": 200, "toplist": [
        {"rank": 1, "lastRank": 3, "score": 116563u64, "category": "创作翻唱", "categoryId": 2001,
         "id": 792868378u64, "name": "一条小团团OvO的翻唱合集", "picUrl": "http://p2.music.126.net/x.jpg",
         "playCount": 131838544u64, "programCount": 56, "subCount": 456521u64,
         "creatorName": "一条小团团OvO", "dj": {"nickname": "一条小团团OvO"},
         "rcmdtext": "可神经可温柔的宝藏女声"}
    ]});
    let t = parse_radio_toplist_radios(&body);
    assert_eq!(t.radios.len(), 1);
    let r = &t.radios[0];
    assert_eq!(r.rank, 1);
    assert_eq!(r.last_rank, 3);
    assert_eq!(r.radio_id, 792868378);
    assert_eq!(r.dj_name, "一条小团团OvO");
    assert_eq!(r.rcmd_text, "可神经可温柔的宝藏女声");
    assert_eq!(r.play_count, 131838544);
    // pay 榜形状(在 data.list 下) + 缺 dj 用 creatorName 兜底 + lastRank=-1
    let pay = json!({"code": 200, "data": {"list": [
        {"rank": 1, "lastRank": -1, "id": 988499285u64, "name": "猫小九历险记",
         "picUrl": "https://p3.music.126.net/y.jpg", "creatorName": "奇喵君故事", "score": 11104632u64}
    ]}});
    let t = parse_radio_toplist_radios(&pay);
    assert_eq!(t.radios.len(), 1);
    assert_eq!(t.radios[0].dj_name, "奇喵君故事");
    assert_eq!(t.radios[0].last_rank, -1);
    assert_eq!(t.radios[0].program_count, 0);
    // 缺 toplist → 空
    assert!(parse_radio_toplist_radios(&json!({"code": 200}))
        .radios
        .is_empty());
}

/// 主播榜(hours/newcomer/popular): data.list 是用户, 字段 nickName(驼峰)
#[test]
fn radio_toplist_djs_parses_real_shape() {
    let body = json!({"code": 200, "data": {"list": [
        {"rank": 1, "lastRank": 2, "id": 287921940u64, "nickName": "开心锤锤",
         "avatarUrl": "http://p1.music.126.net/z.jpg", "score": 3581801u64,
         "userFollowedCount": 79757u64, "userType": 4, "avatarDetail": null}
    ]}});
    let t = parse_radio_toplist_djs(&body);
    assert_eq!(t.djs.len(), 1);
    let d = &t.djs[0];
    assert_eq!(d.rank, 1);
    assert_eq!(d.user_id, 287921940);
    assert_eq!(d.nickname, "开心锤锤");
    assert_eq!(d.followed_count, 79757);
    // data.list 缺失 → 空
    assert!(parse_radio_toplist_djs(&json!({"code": 200}))
        .djs
        .is_empty());
    assert!(parse_radio_toplist_djs(&json!({"code": 200, "data": {}}))
        .djs
        .is_empty());
}

/// 节目榜: toplist 元素 = {rank,lastRank,program}; program 与 dj_program 同形状
#[test]
fn radio_toplist_programs_parses_real_shape() {
    let body = json!({"code": 200, "toplist": [
        {"rank": 1, "lastRank": 3, "program": {
            "id": 3731681674u64, "name": "罗言新歌", "coverUrl": "https://p3.music.126.net/a.jpg",
            "duration": 92400, "description": "比冬天先来的是罗言的新歌",
            "dj": {"nickname": "_XXXTENTACION-_"}, "mainSong": {"id": 1, "name": "s"}}}
    ]});
    let t = parse_radio_toplist_programs(&body);
    assert_eq!(t.programs.len(), 1);
    assert_eq!(t.programs[0].rank, 1);
    assert_eq!(t.programs[0].program.name, "罗言新歌");
    assert_eq!(t.programs[0].program.duration_ms, 92400);
    // 缺 program 的条目跳过
    let partial = json!({"code": 200, "toplist": [
        {"rank": 2, "lastRank": 1},
        {"rank": 3, "lastRank": 2, "program": {"id": 9u64, "name": "p"}}
    ]});
    let t = parse_radio_toplist_programs(&partial);
    assert_eq!(t.programs.len(), 1);
    assert_eq!(t.programs[0].program.id, 9);
}

/// dj_subscriber: 顶层 hasMore + subscribers(完整 user 对象)
#[test]
fn radio_subscribers_parses_real_shape() {
    let body = json!({"code": 200, "hasMore": true, "subscribers": [
        {"userId": 1594251132u64, "nickname": "饱饭三餐何来忧", "avatarUrl": "http://x.jpg",
         "signature": "一个喜欢音乐的过客！", "subscribeTime": 1793611157940u64, "userType": 0}
    ]});
    let p = parse_radio_subscribers(&body).expect("subs");
    assert!(p.has_more);
    assert_eq!(p.subscribers.len(), 1);
    assert_eq!(p.subscribers[0].user_id, 1594251132);
    assert_eq!(p.subscribers[0].subscribe_time_ms, 1793611157940);
    // subscribers 缺失/为空 → 空页不报错
    let empty = parse_radio_subscribers(&json!({"code": 200, "hasMore": false})).expect("empty");
    assert!(!empty.has_more);
    assert!(empty.subscribers.is_empty());
}

#[test]
fn podcast_mapping() {
    let hot = json!({"code": 200, "djRadios": [
        {"id": 5, "name": "电台", "picUrl": "http://p/r.jpg", "desc": "d", "dj": {"nickname": "主播"}, "programCount": 33, "playCount": 100}
    ]});
    let radios = parse_podcast_hot(&hot);
    assert_eq!(radios.len(), 1);
    assert_eq!(radios[0].dj_name, "主播");
    assert_eq!(radios[0].program_count, 33);

    let programs = json!({"code": 200, "programs": [{
        "id": 6, "name": "单集", "coverUrl": "http://p/c.jpg", "duration": 22125,
        "dj": {"nickname": "主播"}, "radio": {"id": 5, "name": "电台"}, "description": "dd",
        "mainSong": {"id": 1442398087, "name": "单集", "artists": [{"name": "主播"}], "album": {"id": 0, "name": ""}, "duration": 22125, "fee": 0}
    }]});
    let list = parse_podcast_programs(&programs);
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].radio_id, 5);
    assert_eq!(list[0].duration_ms, 22125);
    assert_eq!(list[0].song.as_ref().unwrap().id.0, 1442398087);
}

#[test]
fn podcast_radio_detail_mapping() {
    let body = json!({
        "code": 200,
        "data": {"id": 5, "name": "电台", "picUrl": "http://p/r.jpg", "desc": "d",
                 "dj": {"nickname": "主播"}, "programCount": 33, "playCount": 100}
    });
    let r = parse_podcast_radio_detail(&body).unwrap();
    assert_eq!(r.id, 5);
    assert_eq!(r.name, "电台");
    assert_eq!(r.cover_url.as_deref(), Some("http://p/r.jpg"));
    assert_eq!(r.dj_name, "主播");
    assert_eq!(r.program_count, 33);
    let err = parse_podcast_radio_detail(&json!({"code": 200})).unwrap_err();
    assert_eq!(err.kind, ProviderErrorKind::NotFound);
}

#[test]
fn subscribed_podcasts_and_artists() {
    let subs = json!({"code": 200, "djRadios": [
        {"id": 5, "name": "订阅电台", "picUrl": "http://p/r.jpg", "dj": {"nickname": "主播"}, "programCount": 3}
    ]});
    let radios = parse_subscribed_podcasts(&subs);
    assert_eq!(radios.len(), 1);
    assert_eq!(radios[0].name, "订阅电台");

    let artists = json!({"code": 200, "data": [
        {"id": 6452, "name": "周杰伦", "picUrl": "http://p/a.jpg"},
        {"id": 0}
    ]});
    let list = parse_subscribed_artists(&artists);
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].name, "周杰伦");
}
