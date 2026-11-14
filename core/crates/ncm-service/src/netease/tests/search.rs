//! 搜索/热词/建议相关单测.

use crate::netease::*;
use serde_json::json;

#[test]
fn search_mapping() {
    let body = json!({
        "code": 200,
        "result": {
            "songCount": 42,
            "hasMore": true,
            "songs": [{
                "id": 186016,
                "name": "晴天",
                "ar": [{"id": 6452, "name": "周杰伦"}],
                "al": {"id": 1, "name": "叶惠美", "picUrl": "http://p/1.jpg"},
                "dt": 269000,
                "fee": 1
            }]
        }
    });
    let page = parse_search(&body).unwrap();
    assert_eq!(page.total, 42);
    assert!(page.has_more);
    assert_eq!(page.songs.len(), 1);
    assert_eq!(page.songs[0].artist_line(), "周杰伦");
    assert_eq!(page.songs[0].album.as_ref().unwrap().name, "叶惠美");
}

#[test]
fn search_hot_and_default() {
    let hot = json!({"code": 200, "result": {"hots": [
        {"first": "晴天", "keyword": "晴天", "iconType": 1},
        {"first": "", "keyword": "周杰伦", "iconType": 0},
        {"keyword": "  "}
    ]}});
    let terms = parse_hot_search(&hot);
    assert_eq!(terms.len(), 2);
    assert_eq!(terms[0].rank, 1);
    assert_eq!(terms[0].keyword, "晴天");
    assert_eq!(terms[1].rank, 2);

    // 关键词和推荐理由是两回事: keyword 拿去搜, show 只用来展示
    let def = json!({"code": 200, "data": {
        "showKeyword": "🔥Mili 你的十月榜首", "realkeyword": "Mili"
    }});
    let d = parse_default_search(&def).unwrap();
    assert_eq!(d.keyword, "Mili");
    assert_eq!(d.show_text, "🔥Mili 你的十月榜首");
    // 只有 showKeyword 时退化成"用它当关键词"
    let only_show = json!({"code": 200, "data": {"showKeyword": "周杰伦"}});
    assert_eq!(parse_default_search(&only_show).unwrap().keyword, "周杰伦");
    assert_eq!(
        parse_default_search(&json!({"code": 200, "data": {}})),
        None
    );
}

#[test]
fn suggest_mapping_follows_order() {
    let body = json!({
        "code": 200,
        "result": {
            "order": ["songs", "artists", "albums", "playlists"],
            "songs": [{"id": 1, "name": "晴天", "artists": [{"name": "周杰伦"}], "album": {"picUrl": "http://p/s.jpg"}}],
            "artists": [{"id": 2, "name": "周杰伦", "picUrl": "http://p/ar.jpg"}],
            "albums": [{"id": 3, "name": "叶惠美", "artist": {"name": "周杰伦", "picUrl": "http://p/al.jpg"}}],
            "playlists": [{"id": 4, "name": "歌单", "coverImgUrl": "http://p/pl.jpg", "trackCount": 12}]
        }
    });
    let items = parse_suggest(&body);
    assert_eq!(items.len(), 4);
    assert_eq!(items[0].kind, "song");
    assert_eq!(items[0].title, "晴天");
    assert_eq!(items[1].kind, "artist");
    assert_eq!(items[1].subtitle, "歌手");
    assert_eq!(items[2].kind, "album");
    assert_eq!(items[2].subtitle, "周杰伦");
    assert_eq!(items[3].kind, "playlist");
    assert!(items[3].subtitle.contains("12"));
}

#[test]
fn suggest_keywords_dedup_and_order() {
    let body = json!({"code": 200, "result": {"allMatch": [
        {"keyword": "晴天周杰伦", "type": 1, "alg": "x"},
        {"keyword": " 晴天 ", "type": 1, "alg": "y"},
        {"keyword": "晴天周杰伦", "type": 1},
        {"keyword": "", "type": 1},
        {"keyword": "   ", "type": 1},
        {"keyword": "晴天弦乐版", "type": 1},
        {"keyword": "晴天有点孤单玩具丢在旁边", "type": 1},
        {"keyword": "第7条应被截断", "type": 1}
    ]}});
    let kws = parse_suggest_keywords(&body);
    // 去重保序 + 去空白 + 丢弃空串 + 最多 6 条
    assert_eq!(
        kws,
        vec![
            "晴天周杰伦",
            "晴天",
            "晴天弦乐版",
            "晴天有点孤单玩具丢在旁边",
            "第7条应被截断"
        ]
    );
}

#[test]
fn suggest_keywords_empty_and_missing_keyword() {
    // web 分支的空命中形态: result 是空对象
    assert!(parse_suggest_keywords(&json!({"code": 200, "result": {}})).is_empty());
    // 无 result / allMatch 不是数组 / 缺 keyword 或 keyword 非字符串
    assert!(parse_suggest_keywords(&json!({"code": 200})).is_empty());
    assert!(parse_suggest_keywords(&json!({"code": 200, "result": {"allMatch": "x"}})).is_empty());
    let body = json!({"code": 200, "result": {"allMatch": [
        {"type": 1, "alg": "no-keyword"},
        {"keyword": null},
        {"keyword": 123},
        {"keyword": "唯一有效"}
    ]}});
    assert_eq!(parse_suggest_keywords(&body), vec!["唯一有效".to_string()]);
    // 超过 6 条时截断
    let many: Vec<Value> = (0..9)
        .map(|i| json!({"keyword": format!("k{i}")}))
        .collect();
    let body = json!({"code": 200, "result": {"allMatch": many}});
    assert_eq!(parse_suggest_keywords(&body).len(), 6);
}

#[test]
fn search_exact_with_orders() {
    let body = json!({"code": 200, "result": {
        "orders": ["artist", "playlist", "voice"],
        "artist": [{"id": 6452, "name": "周杰伦", "picUrl": "http://p4/head.jpg",
                    "alias": ["Jay Chou"], "alg": "埋点"}],
        "playlist": [{"id": 8181670003u64, "name": "听薛之谦热门精选",
                      "coverImgUrl": "http://p1/cover.jpg", "trackCount": 40,
                      "playCount": 17158528, "specialType": 0}],
        "voice": [{"resourceId": 2543533915u64, "resourceName": "声音",
                   "resourceType": "voice", "internalType": null,
                   "baseInfo": {"id": 2543533915u64, "name": "霉霉横扫Billboard",
                                "coverUrl": "http://p4/voice.jpg",
                                "listenerCount": 1109996,
                                "dj": {"nickname": "伦敦酒吐座"},
                                "radio": {"name": "Billboard风云录", "programCount": 15}}}]
    }});
    let ex = parse_search_exact(&body);
    assert_eq!(ex.orders, vec!["artist", "playlist", "voice"]);
    assert!(!ex.is_empty());
    assert_eq!(ex.artists.len(), 1);
    assert_eq!(ex.artists[0].id, 6452);
    assert_eq!(ex.artists[0].name, "周杰伦");
    assert_eq!(
        ex.artists[0].avatar_url.as_deref(),
        Some("http://p4/head.jpg")
    );
    assert_eq!(ex.playlists.len(), 1);
    assert_eq!(ex.playlists[0].id, 8181670003);
    assert_eq!(ex.playlists[0].track_count, 40);
    assert_eq!(
        ex.playlists[0].cover_url.as_deref(),
        Some("http://p1/cover.jpg")
    );
    assert!(!ex.playlists[0].special);
    assert_eq!(ex.podcasts.len(), 1);
    assert_eq!(ex.podcasts[0].id, 2543533915);
    assert_eq!(ex.podcasts[0].name, "霉霉横扫Billboard");
    assert_eq!(ex.podcasts[0].dj_name, "伦敦酒吐座");
    assert_eq!(ex.podcasts[0].program_count, 15);
    assert_eq!(ex.podcasts[0].play_count, 1109996);
}

#[test]
fn search_exact_empty_orders_is_fake_success() {
    // 实测的"空命中伪装成功": code=200 但 result 只有空 orders, 各类型 key 不存在
    let body = json!({"code": 200, "result": {"orders": []}});
    let ex = parse_search_exact(&body);
    assert!(ex.is_empty());
    assert!(
        ex.orders.is_empty()
            && ex.artists.is_empty()
            && ex.playlists.is_empty()
            && ex.podcasts.is_empty()
    );
    // 没有 result(400 之类)也当无命中, 不 panic
    assert!(parse_search_exact(&json!({"code": 400})).is_empty());
    assert!(parse_search_exact(&json!({})).is_empty());
    // orders 有值但对应数组缺失: 保留 orders, 实体为空
    let ex = parse_search_exact(&json!({"code": 200, "result": {"orders": ["song"]}}));
    assert_eq!(ex.orders, vec!["song"]);
    assert!(ex.artists.is_empty());
}

#[test]
fn hot_search_detail_rank_and_fields() {
    let body = json!({"code": 200, "message": null, "trp": null, "data": [
        {"searchWord": "天龙八部之宿敌", "score": 91197, "iconType": 4,
         "iconUrl": "http://p1/icon.png", "content": "", "source": 0, "url": ""},
        {"searchWord": "无 意", "score": 65196, "iconType": 2, "alg": "埋点"},
        {"searchWord": "  ", "score": 1, "iconType": 0},
        {"searchWord": "季候风"}
    ]});
    let items = parse_hot_search_detail(&body);
    assert_eq!(items.len(), 3); // 空白词被丢弃
    assert_eq!(items[0].rank, 1);
    assert_eq!(items[0].keyword, "天龙八部之宿敌");
    assert_eq!(items[0].score, 91197);
    assert_eq!(items[0].icon_type, 4);
    assert_eq!(items[1].keyword, "无 意"); // 中间空格原样保留
    assert_eq!(items[1].rank, 2);
    assert_eq!(items[2].keyword, "季候风");
    assert_eq!(items[2].rank, 3);
    assert_eq!(items[2].score, 0); // 缺字段默认 0
    assert_eq!(items[2].icon_type, 0);
    // 无 data / 空数组
    assert!(parse_hot_search_detail(&json!({"code": 200})).is_empty());
    assert!(parse_hot_search_detail(&json!({"code": 200, "data": []})).is_empty());
}

/// 需求 10(后端): 搜索补 MV(type=1004, result.mvs)
#[test]
fn search_mvs_mapping() {
    let result = json!({
        "mvs": [
            {"id": 11, "name": "晴天 (MV)", "cover": "http://p1/mv.jpg",
             "artistName": "周杰伦", "playCount": 123456},
            {"id": 12, "name": "没有 artistName", "picUrl": "http://p1/mv2.jpg",
             "artists": [{"name": "A"}, {"name": "B"}]},
            {"id": 13, "name": "缺封面"}
        ]
    });
    let mvs = parse_search_mvs(&result);
    assert_eq!(mvs.len(), 3);
    assert_eq!(mvs[0].id, 11);
    assert_eq!(mvs[0].cover_url.as_deref(), Some("http://p1/mv.jpg"));
    assert_eq!(mvs[0].artist_name, "周杰伦");
    assert_eq!(mvs[0].play_count, 123456);
    // artistName 缺失时用 artists[].name 拼
    assert_eq!(mvs[1].artist_name, "A / B");
    assert_eq!(mvs[1].cover_url.as_deref(), Some("http://p1/mv2.jpg"));
    assert_eq!(mvs[2].cover_url, None);
    assert_eq!(mvs[2].play_count, 0);

    // 没有 mvs / 空的 / id 为 0 或没名字的丢掉
    assert!(parse_search_mvs(&json!({})).is_empty());
    assert!(parse_search_mvs(&json!({"mvs": []})).is_empty());
    let mvs = parse_search_mvs(&json!({"mvs": [{"id": 0, "name": "x"}, {"id": 2, "name": ""}]}));
    assert!(mvs.is_empty());
}
