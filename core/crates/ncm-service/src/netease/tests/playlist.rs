//! 歌单读写/分类/详情/最近播放相关单测.

use crate::netease::*;
use ncm_provider::ProviderErrorKind;
use serde_json::json;

/// ---- 歌单写接口 parse(2026-11-10 实测样例, 见 docs/b7-playlist-write-notes.md) ----
#[test]
fn created_playlist_from_top_level_id() {
    let body = json!({"code":200,"id":18580697682u64,"playlist":{"adType":0,"anonimous":false,
            "id":18580697682u64,"name":"B7抓包临时歌单 20261110-023344","privacy":0,
            "trackCount":0,"userId":1822714196u64,"subscribedCount":0,"tags":[]}});
    let p = parse_created_playlist(&body).expect("应能解析");
    assert_eq!(p.id, 18580697682);
    assert_eq!(p.name, "B7抓包临时歌单 20261110-023344");
}

#[test]
fn created_playlist_falls_back_to_playlist_id() {
    // 防御老形态: 顶层缺 id 时回退 playlist.id
    let p =
        parse_created_playlist(&json!({"code":200,"playlist":{"id":12345678901u64,"name":"X"}}))
            .expect("应能解析");
    assert_eq!(p.id, 12345678901);
    assert_eq!(p.name, "X");
}

#[test]
fn created_playlist_none_when_no_id() {
    assert!(parse_created_playlist(&json!({"code":500,"msg":"请求异常"})).is_none());
    assert!(parse_created_playlist(&json!({"code":200,"id":0})).is_none());
}

#[test]
fn playlist_edit_add_ok_track_ids_is_string_not_array() {
    // 实测原文: trackIds 是数组 JSON 文本(字符串), count=2; 成功无 message
    let body = json!({"cloudCount":0,"code":200,"count":2,
            "coverImgId":"109951167894836691",
            "coverImgUrl":"http://p3.music.126.net/Pz4sEpA7nsiyIdIrswTx9A==/109951167894836691.jpg",
            "trackIds":"[186016,26305527]"});
    let r = parse_playlist_edit_result(&body);
    assert!(r.ok);
    assert_eq!(r.code, 200);
    assert_eq!(r.count, Some(2));
    assert_eq!(r.message, None);
}

#[test]
fn playlist_edit_delete_ok_without_message() {
    let r = parse_playlist_edit_result(&json!({"code":200,"data":null,"message":null,"msg":null}));
    assert!(r.ok);
    assert_eq!(r.code, 200);
    assert_eq!(r.count, None);
    assert_eq!(r.message, None);
}

#[test]
fn playlist_edit_failure_extracts_msg() {
    // 实测: UA/身份形态不配套时服务端回 500「请求异常」
    let r = parse_playlist_edit_result(&json!({"code":500,"msg":"请求异常，请稍后重试"}));
    assert!(!r.ok);
    assert_eq!(r.code, 500);
    assert_eq!(r.message.as_deref(), Some("请求异常，请稍后重试"));
}

#[test]
fn playlist_detail_mapping() {
    let body = json!({
        "code": 200,
        "playlist": {
            "id": 9, "name": "歌单", "coverImgUrl": "http://p/pl.jpg",
            "description": "desc", "creator": {"nickname": "作者"},
            "trackCount": 30, "playCount": 999, "subscribed": true,
            "subscribedCount": 12, "shareCount": 3, "commentCount": 45,
            "tags": ["流行", "华语"]
        }
    });
    let d = parse_playlist_detail(&body).unwrap();
    assert_eq!(d.id, 9);
    assert_eq!(d.name, "歌单");
    assert_eq!(d.cover_url.as_deref(), Some("http://p/pl.jpg"));
    assert_eq!(d.creator_name, "作者");
    assert_eq!(d.track_count, 30);
    assert_eq!(d.play_count, 999);
    assert!(d.subscribed);
    assert_eq!(d.subscribed_count, 12);
    assert_eq!(d.comment_count, 45);
    assert_eq!(d.tags, vec!["流行".to_string(), "华语".to_string()]);
    // 缺 playlist 字段要报 NotFound 而不是 panic
    let err = parse_playlist_detail(&json!({"code": 200})).unwrap_err();
    assert_eq!(err.kind, ProviderErrorKind::NotFound);
}

#[test]
fn playlist_categories_mapping() {
    let body = json!({"code": 200,
    "categories": {"0": "语种", "1": "风格", "4": "主题"},
    "sub": [
        {"category": 1, "name": "流行"},
        {"category": 0, "name": "华语"},
        {"category": 4, "name": "综艺"},
        {"category": 0, "name": "欧美"}
    ]});
    let groups = parse_playlist_categories(&body);
    // 按 categories 的数字 key 排序: 语种 → 风格 → 主题, 空组被过滤
    assert_eq!(groups.len(), 3);
    assert_eq!(groups[0].group, "语种");
    assert_eq!(groups[0].subs, vec!["华语".to_string(), "欧美".to_string()]);
    assert_eq!(groups[1].group, "风格");
    assert_eq!(groups[1].subs, vec!["流行".to_string()]);
}

#[test]
fn playlists_and_albums_mapping() {
    let body = json!({"code": 200, "playlists": [
        {"id": 9, "name": "歌单一", "coverImgUrl": "https://p/c.jpg", "trackCount": 30}
    ]});
    let lists = parse_playlist_bucket(&body, "playlists");
    assert_eq!(lists.len(), 1);
    assert_eq!(lists[0].track_count, 30);

    let albums = json!({"code": 200, "data": [
        {"id": 5, "name": "专辑一", "picUrl": "https://p/a.jpg",
         "artist": {"id": 7, "name": "歌手"}, "size": 12},
        {"id": 6, "name": "专辑二", "picUrl": "yyimgs/rel",
         "artists": [{"name": "歌手B"}], "trackCount": 8}
    ]});
    let items = parse_album_items(&albums);
    assert_eq!(items.len(), 2);
    assert_eq!(items[0].artist, "歌手");
    assert_eq!(items[0].track_count, 12);
    assert_eq!(items[1].artist, "歌手B");
    assert!(items[1].cover_url.is_none());
}

#[test]
fn daily_playlists_mapping() {
    let body = json!({"code": 200, "recommend": [
        {"id": 11, "name": "pl", "picUrl": "http://p/1.jpg", "trackCount": 30, "playCount": 99}
    ]});
    let lists = parse_recommend_playlists(&body);
    assert_eq!(lists.len(), 1);
    assert_eq!(lists[0].id, 11);
    assert_eq!(lists[0].cover_url.as_deref(), Some("http://p/1.jpg"));
    assert!(!lists[0].special);
}

/// 最近播放三类共用的外层形状: data.list[].data
#[test]
fn recent_bucket_unwraps_item_data() {
    let body = json!({
        "code": 200,
        "data": {
            "list": [
                {"data": {"id": 1, "name": "野泳", "artists": [{"name": "祝游会"}], "size": 7}},
                {"playCount": 3},
                {"data": {"id": 2, "name": "", "size": 1}}
            ]
        }
    });
    let items = recent_items(&body);
    assert_eq!(items.len(), 2, "没有 data 对象的条目要丢掉");
    let album = parse_album_item(&items[0]).unwrap();
    assert_eq!(album.name, "野泳");
    assert_eq!(album.artist, "祝游会");
    assert_eq!(album.track_count, 7);
    assert!(parse_album_item(&items[1]).is_none(), "空名称的专辑要跳过");
}
