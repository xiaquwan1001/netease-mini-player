//! 专辑/新碟/歌手/MV/榜单目录/热门相关单测.

use crate::netease::*;
use serde_json::json;

/// album_newest: 2026-11-09 实测形状(顶层 albums, 固定 12 张, 专辑对象同 album_new).
#[test]
fn album_newest_parses_real_shape() {
    let body = json!({
        "code": 200,
        "albums": [{
            "id": 404764114u64,
            "name": "Love Me Later 巡回演唱会LIVE TRACKS",
            "picUrl": "https://p4.music.126.net/RT7TwtwTJ8Gw-9qaltqjkw==/109951174134867745.jpg",
            "size": 10,
            "publishTime": 1792598400000u64,
            "artist": {"id": 12236125u64, "name": "王以太", "picUrl": "https://p4.music.126.net/x.jpg"},
            "songs": null
        }]
    });
    let albums = parse_album_items(&body);
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].id, 404764114);
    assert_eq!(albums[0].artist, "王以太");
    assert_eq!(albums[0].track_count, 10);
    assert!(albums[0]
        .cover_url
        .as_deref()
        .unwrap_or("")
        .starts_with("https://"));
}

/// album_newest: albums 缺失(code!=200 / 接口变更)时给空列表, 不 panic.
#[test]
fn album_newest_missing_albums_is_empty() {
    assert!(parse_album_items(&json!({"code": 301})).is_empty());
    assert!(parse_album_items(&json!({"code": 200, "albums": null})).is_empty());
}

/// artist_songs: 2026-11-22 实测形状(顶层 more + songs[], 歌曲为 NCM 歌曲 DTO).
#[test]
fn artist_songs_parses_real_shape() {
    let body = json!({
        "code": 200,
        "more": true,
        "songs": [
            {"id": 298317u64, "name": "屋顶", "dt": 319039u64, "fee": 0,
             "ar": [{"id": 9612u64, "name": "温岚"}, {"id": 6452u64, "name": "周杰伦"}],
             "al": {"id": 29597u64, "name": "有点野",
                    "picUrl": "https://p4.music.126.net/t1KaAJmIphZKdPq8JfItbA==/109951170514287417.jpg"},
             "privilege": {"st": -53918, "dl": 999000}},
            {"id": 210049u64, "name": "安静", "dt": 274573u64, "fee": 8,
             "ar": [{"id": 6452u64, "name": "周杰伦"}],
             "al": {"id": 18919u64, "name": "范特西", "picUrl": "https://p3.music.126.net/x.jpg"},
             "privilege": {"st": 0, "dl": 320000}}
        ]
    });
    let page = parse_artist_songs(&body);
    assert!(page.has_more);
    assert_eq!(page.songs.len(), 2);
    assert_eq!(page.songs[0].name, "屋顶");
    assert_eq!(page.songs[0].artists.len(), 2);
    assert_eq!(page.songs[0].artists[0].name, "温岚");
    assert_eq!(page.songs[0].album.as_ref().unwrap().name, "有点野");
    assert_eq!(page.songs[0].duration_ms, 319039);
    assert_eq!(page.songs[0].fee, Some(0));
}

/// mv_detail: 2026-11-22 实测形状(id=5436712 广岛之恋, brs 数组).
#[test]
fn mv_detail_parses_real_shape() {
    let body = json!({
        "code": 200,
        "data": {
            "id": 5436712u64, "name": "广岛之恋", "artistName": "莫文蔚",
            "duration": 378040u64, "playCount": 852564u64,
            "publishTime": "1997-10-01",
            "cover": "http://p4.music.126.net/abc.jpg",
            "brs": [{"br": 480, "point": 0, "size": 31157772.0}, {"br": 240, "point": 0, "size": 17639436.0}],
            "desc": null, "commentCount": 689u64
        },
        "subed": false
    });
    let d = parse_mv_detail(&body);
    assert_eq!(d.id, 5436712);
    assert_eq!(d.name, "广岛之恋");
    assert_eq!(d.artist_name, "莫文蔚");
    assert_eq!(d.duration_ms, 378040);
    assert_eq!(d.publish_time, "1997-10-01");
    assert_eq!(
        d.cover_url.as_deref(),
        Some("http://p4.music.126.net/abc.jpg")
    );
    assert_eq!(d.brs, vec![240, 480]);
    assert_eq!(d.max_br, 480);
    assert!(d.desc.is_none());
}

/// mv_detail: desc 非空时保留.
#[test]
fn mv_detail_keeps_desc() {
    let body = json!({"code": 200, "data": {"id": 1u64, "name": "mv", "desc": "简介文本"}});
    assert_eq!(parse_mv_detail(&body).desc.as_deref(), Some("简介文本"));
}

/// mv_detail: data 缺失时空默认值(id=0).
#[test]
fn mv_detail_missing_data_is_default() {
    let d = parse_mv_detail(&json!({"code": 301}));
    assert_eq!(d.id, 0);
    assert!(d.name.is_empty());
    assert!(d.brs.is_empty());
    assert_eq!(d.max_br, 0);
}

/// mv_url: 2026-11-22 实测形状(data 单对象, 签名直链 + 实际档位).
#[test]
fn mv_url_parses_real_shape() {
    let body = json!({
        "code": 200,
        "data": {
            "code": 200, "expi": 3600u64, "fee": 0, "id": 5436712u64, "md5": "",
            "r": 480, "size": 31157772u64,
            "url": "http://vodkgeyttp8.vod.126.net/cloudmusic/a.mp4?wsSecret=x&wsTime=1"
        }
    });
    let u = parse_mv_url(&body);
    assert!(u.url.as_deref().unwrap().starts_with("http://vodkgeyttp8"));
    assert_eq!(u.r, 480);
    assert_eq!(u.size, 31157772);
}

/// mv_url: url 为 null(需要 VIP / 下架)时 url=None.
#[test]
fn mv_url_null_url_is_none() {
    let body = json!({"code": 200, "data": {"code": 200, "url": null, "r": 1080}});
    assert!(parse_mv_url(&body).url.is_none());
}

/// mv_url: data 缺失时全默认.
#[test]
fn mv_url_missing_data_is_default() {
    let u = parse_mv_url(&json!({"code": 404}));
    assert!(u.url.is_none());
    assert_eq!(u.r, 0);
    assert_eq!(u.size, 0);
}

/// mv_detail: brs 乱序/重复时升序去重, max_br 取最大.
#[test]
fn mv_detail_brs_sorted_deduped() {
    let body = json!({"code": 200, "data": {"id": 2u64, "name": "m",
            "brs": [{"br": 1080}, {"br": 480}, {"br": 1080}, {"br": 720}]}});
    let d = parse_mv_detail(&body);
    assert_eq!(d.brs, vec![480, 720, 1080]);
    assert_eq!(d.max_br, 1080);
}

/// artist_songs: more=false 表示没有下一页(最后一页).
#[test]
fn artist_songs_more_flag_ends_paging() {
    let body = json!({"code": 200, "more": false, "songs": [{"id": 1u64, "name": "a"}]});
    let page = parse_artist_songs(&body);
    assert!(!page.has_more);
    assert_eq!(page.songs.len(), 1);
}

/// artist_songs: songs 缺失(code!=200)时空列表 + more 缺失按 false.
#[test]
fn artist_songs_missing_fields_is_empty_page() {
    let page = parse_artist_songs(&json!({"code": 301}));
    assert!(page.songs.is_empty());
    assert!(!page.has_more);
}

/// artist_songs: privilege.st<0(无版权)时歌曲标记为不可播.
#[test]
fn artist_songs_privilege_marks_playable() {
    let body = json!({
        "code": 200, "more": true,
        "songs": [
            {"id": 1u64, "name": "无版权", "dt": 1000u64, "fee": 0,
             "ar": [], "al": null, "privilege": {"st": -200}},
            {"id": 2u64, "name": "可播", "dt": 1000u64, "fee": 0,
             "ar": [], "al": null, "privilege": {"st": 0}}
        ]
    });
    let page = parse_artist_songs(&body);
    assert!(!page.songs[0].playable);
    assert!(page.songs[1].playable);
}

/// artist_mv: 2026-11-22 实测形状(顶层 hasMore + mvs[], imgurl16v9 是 16:9 封面).
#[test]
fn artist_mvs_parses_real_shape() {
    let body = json!({
        "code": 200,
        "hasMore": true,
        "mvs": [
            {"id": 22695250u64, "name": "任性 (5525 Live版)", "artistName": "周杰伦",
             "duration": 266000u64, "playCount": 106722u64, "publishTime": "2025-02-23",
             "imgurl": "http://p3.music.126.net/a.jpg",
             "imgurl16v9": "http://p4.music.126.net/b.jpg", "status": 0, "subed": false}
        ]
    });
    let page = parse_artist_mvs(&body);
    assert!(page.has_more);
    assert_eq!(page.mvs.len(), 1);
    let mv = &page.mvs[0];
    assert_eq!(mv.id, 22695250);
    assert_eq!(mv.name, "任性 (5525 Live版)");
    assert_eq!(mv.duration_ms, 266000);
    assert_eq!(mv.play_count, 106722);
    assert_eq!(mv.publish_time, "2025-02-23");
    assert_eq!(
        mv.cover_url.as_deref(),
        Some("http://p4.music.126.net/b.jpg")
    );
}

/// artist_mv: imgurl16v9 缺失时回退 imgurl.
#[test]
fn artist_mvs_cover_fallback_imgurl() {
    let body = json!({
        "code": 200, "hasMore": false,
        "mvs": [{"id": 1u64, "name": "mv", "duration": 1000u64,
                 "imgurl": "http://p3.music.126.net/fallback.jpg"}]
    });
    let page = parse_artist_mvs(&body);
    assert_eq!(
        page.mvs[0].cover_url.as_deref(),
        Some("http://p3.music.126.net/fallback.jpg")
    );
    assert!(!page.has_more);
}

/// artist_mv: mvs 缺失(接口失败/变更)时空列表, 不 panic.
#[test]
fn artist_mvs_missing_mvs_is_empty_page() {
    let page = parse_artist_mvs(&json!({"code": 301}));
    assert!(page.mvs.is_empty());
    assert!(!page.has_more);
}

/// artist_mv: name 缺失/为空的条目丢弃(脏数据防御).
#[test]
fn artist_mvs_drops_unnamed_entries() {
    let body = json!({
        "code": 200, "hasMore": true,
        "mvs": [
            {"id": 1u64, "name": "", "duration": 1u64},
            {"id": 2u64, "duration": 2u64},
            {"id": 3u64, "name": "正常", "duration": 3u64}
        ]
    });
    let page = parse_artist_mvs(&body);
    assert_eq!(page.mvs.len(), 1);
    assert_eq!(page.mvs[0].id, 3);
}

/// artist_songs: 翻页语义 —— 解析器按 offset/limit 由调用方控制, 响应只带 more.
/// 这里验证两次响应合并不重叠由 id 区分(模拟 page1/page2 实测).
#[test]
fn artist_songs_page_ids_distinguishable() {
    let p1 = parse_artist_songs(&json!({
        "code": 200, "more": true,
        "songs": [{"id": 298317u64, "name": "屋顶"}, {"id": 210049u64, "name": "安静"}]
    }));
    let p2 = parse_artist_songs(&json!({
        "code": 200, "more": false,
        "songs": [{"id": 1888354230u64, "name": "other"}]
    }));
    let mut ids: Vec<u64> = p1
        .songs
        .iter()
        .chain(p2.songs.iter())
        .map(|s| s.id.0)
        .collect();
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), 3);
    assert!(!p2.has_more);
}

/// toplist_detail_v2: 2026-11-09 实测形状(data[].categoryCode 分组 + list[] 榜单卡;
/// 无 trackUpdateTime / "更新 N 首", 元素带 canPlay/targetType).
#[test]
fn toplist_catalog_parses_real_shape() {
    let body = json!({
        "code": 200,
        "data": [
            {"categoryCode": "TOPPING", "displayType": "ONLY_COVER", "list": [
                {"id": 5059633707u64, "name": "网易云摇滚榜", "category": "MUSIC_STYLE",
                 "coverUrl": "https://p3.music.126.net/abc.jpg", "updateFrequency": "每周五更新",
                 "targetType": "PLAYLIST", "canPlay": true, "tracks": null, "trackRankList": null}
            ]},
            {"categoryCode": "GLOBAL", "list": [
                {"id": 60131u64, "name": "日本Oricon榜", "coverUrl": "https://p3.music.126.net/def.jpg",
                 "updateFrequency": "每天更新", "targetType": "PLAYLIST", "canPlay": true}
            ]}
        ]
    });
    let groups = parse_toplist_catalog(&body);
    assert_eq!(groups.len(), 2);
    assert_eq!(groups[0].code, "TOPPING");
    assert_eq!(groups[0].items.len(), 1);
    let it = &groups[0].items[0];
    assert_eq!(it.id, 5059633707);
    assert_eq!(it.name, "网易云摇滚榜");
    assert_eq!(it.update_frequency, "每周五更新");
    assert_eq!(it.target_type, "PLAYLIST");
    assert!(it.can_play);
    assert_eq!(groups[1].items[0].name, "日本Oricon榜");
}

/// toplist_detail_v2: data 缺失/空数组/空分组都返回空目录.
#[test]
fn toplist_catalog_missing_data_is_empty() {
    assert!(parse_toplist_catalog(&json!({"code": 200})).is_empty());
    assert!(parse_toplist_catalog(&json!({"code": 200, "data": []})).is_empty());
    let groups = parse_toplist_catalog(&json!({"code": 200, "data": [{"categoryCode": "X"}]}));
    assert_eq!(groups.len(), 1);
    assert!(groups[0].items.is_empty());
}

#[test]
fn hot_artists_mapping() {
    let body = json!({
        "artists": [
            {"id": 3684, "name": "林俊杰", "picUrl": "http://p/1.jpg", "fansCount": 16908300},
            {"id": 0, "name": "", "fansCount": 1}
        ]
    });
    let list = parse_hot_artists(&body);
    assert_eq!(list.len(), 1, "空名字要跳过");
    assert_eq!(list[0].name, "林俊杰");
    assert_eq!(list[0].fans, 16908300);
    assert_eq!(list[0].avatar_url.as_deref(), Some("http://p/1.jpg"));
}

#[test]
fn album_mapping() {
    let body = json!({
        "code": 200,
        "album": {"id": 9, "name": "叶惠美", "picUrl": "http://p/al.jpg", "artist": {"name": "周杰伦"}, "description": "d"},
        "songs": [{"id": 1, "name": "以父之名", "ar": [{"name": "周杰伦"}], "al": {"id": 9, "name": "叶惠美"}, "dt": 1}]
    });
    let d = parse_album(&body).unwrap();
    assert_eq!(d.id, 9);
    assert_eq!(d.name, "叶惠美");
    assert_eq!(d.artist, "周杰伦");
    assert_eq!(d.songs.len(), 1);
}

/// 新碟: weekData 与 monthData 合并去重, 再按 limit 截断
#[test]
fn new_albums_merge_and_dedupe() {
    let album = |id: u64, name: &str| {
        json!({"id": id, "name": name, "picUrl": "http://p/a.jpg",
                   "artist": {"name": "歌手"}, "size": 3})
    };
    let body = json!({
        "code": 200,
        "weekData": [album(1, "Growth")],
        "monthData": [album(1, "Growth"), album(2, "Iceberg"), album(3, "家后")]
    });
    let list = parse_new_albums(&body, 2);
    assert_eq!(list.len(), 2, "同一张碟只出现一次, 且按 limit 截断");
    assert_eq!(list[0].name, "Growth");
    assert_eq!(list[1].name, "Iceberg");
    assert_eq!(list[0].track_count, 3);
    assert_eq!(list[0].artist, "歌手");
}

#[test]
fn new_release_and_similar_mapping() {
    // 新歌: 曲目嵌在 result[].song 里
    let newsong = json!({"code": 200, "result": [
        {"id": 9, "name": "外层名", "song": {"id": 1, "name": "新歌一", "ar": [{"name": "A"}], "dt": 1000}},
        {"id": 10, "name": "没有 song 字段"}
    ]});
    let songs = parse_new_songs(&newsong);
    assert_eq!(songs.len(), 1);
    assert_eq!(songs[0].name, "新歌一");

    // 相似歌曲: 直接是 songs 数组
    let simi = json!({"code": 200, "songs": [
        {"id": 2, "name": "像它", "ar": [{"name": "B"}], "dt": 2000, "fee": 1}
    ]});
    let similar = parse_song_bucket(&simi, "songs");
    assert_eq!(similar.len(), 1);
    assert_eq!(similar[0].name, "像它");

    // 相似歌手
    let artists = json!({"code": 200, "artists": [
        {"id": 3, "name": "歌手C", "picUrl": "https://p/c.jpg"},
        {"id": 4, "name": "歌手D", "picUrl": "yyimgs/rel"}
    ]});
    let list = parse_similar_artists(&artists);
    assert_eq!(list.len(), 2);
    assert_eq!(list[0].avatar_url.as_deref(), Some("https://p/c.jpg"));
    assert!(list[1].avatar_url.is_none());
}

#[test]
fn charts_mapping() {
    let body = json!({"code": 200, "list": [
        {"id": 19723756, "name": "飙升榜", "coverImgUrl": "https://p/a.jpg",
         "updateFrequency": "刚刚更新", "trackCount": 100, "playCount": 6522631680u64,
         "tracks": [{"id": 1, "name": "t"}]},
        {"id": 3778678, "name": "热歌榜", "coverImgUrl": "yyimgs/rel", "updateFrequency": "更新17首"},
        {"id": 2, "name": ""}
    ]});
    let charts = parse_charts(&body);
    assert_eq!(charts.len(), 2);
    assert_eq!(charts[0].name, "飙升榜");
    assert_eq!(charts[0].update_frequency, "刚刚更新");
    // 相对图片地址丢掉
    assert!(charts[1].cover_url.is_none());
}

/// 新歌速递: data[] 是完整 song 对象(artists/album/duration/privilege)
#[test]
fn top_songs_mapping() {
    let body = json!({
        "code": 200,
        "data": [
            {"id": 1, "name": "最重要的听众", "artists": [{"id": 9, "name": "法老"}],
             "album": {"id": 3, "name": "专辑", "picUrl": "http://p/1.jpg"},
             "duration": 334000, "fee": 0, "privilege": {"st": 0}},
            {"id": 2, "name": "Masterpiece", "artists": [{"id": 10, "name": "LNGSHOT"}],
             "duration": 170000, "fee": 1, "privilege": {"st": -200}}
        ]
    });
    let songs = parse_top_songs(&body);
    assert_eq!(songs.len(), 2);
    assert_eq!(songs[0].artist_line(), "法老");
    assert_eq!(songs[0].duration_ms, 334000);
    assert_eq!(songs[0].album.as_ref().unwrap().name, "专辑");
    assert!(songs[0].playable);
    assert!(!songs[1].playable, "privilege.st=-200 要标成不可播");
    assert!(songs[1].is_vip());
}

/// 歌手详情: 粉丝数/关注态/绑定账号 userId(2026-11 用户反馈 1/11).
///
/// 真实形状(2026-11 匿名实测 /api/artist/head/info/get + /api/artist/follow/count/get):
/// - data.artist 里有 albumSize/musicSize, 但**没有** fansCount
/// - data.user 只在艺人绑定了用户账号时出现(周杰伦主条目 6452 没有)
/// - 粉丝数/关注态来自另一个端点, 形如 {data:{fansCnt, isFollow, followCnt}}
#[test]
fn artist_detail_parses_fans_followed_and_user_id() {
    let detail = json!({
        "code": 200,
        "data": {
            "artist": {
                "id": 54526285u64,
                "name": "杰伦",
                "alias": ["Jay"],
                "briefDesc": "简介",
                "albumSize": 3,
                "musicSize": 42,
                "avatar": "https://p/a.jpg",
                "cover": "https://p/c.jpg"
            },
            "user": {"userId": 131317247u64, "nickname": "杰伦"},
            "eventCount": 7
        }
    });
    let top = json!({"code": 200, "songs": []});
    let albums = json!({"code": 200, "hotAlbums": []});
    let follow = json!({
        "code": 200,
        "data": {"fansCnt": 19227240u64, "followCnt": 0, "isFollow": true}
    });
    let a = parse_artist_detail_with_follow(&detail, &top, &albums, &follow);
    assert_eq!(a.id, 54526285);
    assert_eq!(a.album_count, 3);
    assert_eq!(a.music_count, 42);
    assert_eq!(a.fans_count, 19227240);
    assert!(a.followed);
    assert_eq!(a.user_id, Some(131317247));
    assert_eq!(a.event_count, 7);
}

/// 没有绑定账号的歌手: user_id 为 None(艺人页据此不生成「动态」tab), 粉丝接口失败时 0/false
#[test]
fn artist_detail_without_bound_user_has_no_user_id() {
    let detail = json!({
        "code": 200,
        "data": {"artist": {"id": 6452u64, "name": "周杰伦", "albumSize": 48, "musicSize": 591}}
    });
    let a = parse_artist_detail(&detail, &json!({"songs": []}), &json!({"hotAlbums": []}));
    assert_eq!(a.user_id, None);
    assert_eq!(a.fans_count, 0);
    assert!(!a.followed);
}
