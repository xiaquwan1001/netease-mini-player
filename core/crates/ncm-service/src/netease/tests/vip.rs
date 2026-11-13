//! 会员/数字专辑/已购相关单测.

use crate::netease::*;
use serde_json::json;

/// digitalAlbum/purchased: 2026-11-09 实测形状(顶层 paidAlbums + total, 封面叫 cover)
#[test]
fn digital_album_purchased_parses_real_shape() {
    let body = json!({
        "code": 200,
        "total": 2,
        "paidAlbums": [{
            "albumId": 120605500u64,
            "albumName": "冀西南林路行",
            "artist": {"id": 13223, "name": "万能青年旅店"},
            "cover": "https://p4.music.126.net/aEehIWg8Qk5DXLGf0XZHqw==/109951166554891221.jpg",
            "paidTime": 1638063971559u64,
            "boughtCount": 1,
            "sub": false,
            "channel": 0,
            "valid": 99
        }, {
            "albumId": 162008967u64,
            "albumName": "伍六七之暗影宿命 原声大碟",
            "artist": {"id": 56085302, "name": "伍六七"},
            "cover": "https://p3.music.126.net/MJOV25-FS6XdLEjqDddt-g==/109951168553533864.jpg",
            "paidTime": 1687007720179u64,
            "boughtCount": 1
        }]
    });
    let p = parse_digital_album_purchased(&body).expect("purchased");
    assert_eq!(p.total, 2);
    assert_eq!(p.albums.len(), 2);
    let first = &p.albums[0];
    assert_eq!(first.album_id, 120605500);
    assert_eq!(first.album_name, "冀西南林路行");
    assert_eq!(first.artist_id, 13223);
    assert_eq!(first.artist_name, "万能青年旅店");
    assert!(first.cover_url.starts_with("https://"));
    assert_eq!(first.paid_time_ms, 1638063971559);
    assert_eq!(first.bought_count, 1);
}

/// paidAlbums 缺失 / null / 空数组都当空列表, total 仍取服务端值
#[test]
fn digital_album_purchased_tolerates_missing_albums() {
    for body in [
        json!({"code": 200, "total": 2}),
        json!({"code": 200, "total": 2, "paidAlbums": null}),
        json!({"code": 200, "total": 0, "paidAlbums": []}),
    ] {
        let p = parse_digital_album_purchased(&body).expect("purchased");
        assert!(p.albums.is_empty(), "body={body}");
        assert_eq!(p.total, if p.total == 0 { 0 } else { 2 });
    }
    // 元素缺 albumId 的坏条目直接跳过, 不 panic
    let bad = json!({"code": 200, "total": 1, "paidAlbums": [{"albumName": "x"}]});
    let p = parse_digital_album_purchased(&bad).expect("purchased");
    assert!(p.albums.is_empty());
}

/// song_purchased: 实测(无已购单曲)为 data.{count,hasMore,list:[]}; list 元素宽松兼容两种命名
#[test]
fn song_purchased_parses_pagination_and_empty() {
    let empty =
        json!({"code": 200, "data": {"count": 0, "hasMore": false, "list": []}, "message": ""});
    let p = parse_song_purchased(&empty).expect("purchased");
    assert_eq!(p.count, 0);
    assert!(!p.has_more);
    assert!(p.songs.is_empty());

    let listed = json!({"code": 200, "data": {"count": 1, "hasMore": true, "list": [
        {"id": 186016u64, "name": "晴天", "artist": {"name": "周杰伦"}, "cover": "https://c", "paidTime": 1700000000000u64},
        {"songId": 999, "songName": "别名兼容", "artistName": "A/B"}
    ]}});
    let p = parse_song_purchased(&listed).expect("purchased");
    assert_eq!(p.count, 1);
    assert!(p.has_more);
    assert_eq!(p.songs.len(), 2);
    assert_eq!(p.songs[0].song_id, 186016);
    assert_eq!(p.songs[0].artist_name, "周杰伦");
    assert_eq!(p.songs[1].song_id, 999);
    assert_eq!(p.songs[1].name, "别名兼容");
}

/// digital_album_detail: 专辑字段在 album, 价格/上架/标签在 product, descr 过滤 </br>
#[test]
fn digital_album_detail_parses_real_shape() {
    // 2026-11-09 实测: ncm raw digital_album_detail id=120605500
    let body = json!({
        "code": 200,
        "hasAlbum": true,
        "boughtCnt": 1,
        "album": {
            "albumId": 120605500u64,
            "albumName": "冀西南林路行",
            "artistName": "万能青年旅店",
            "artistId": 13223,
            "coverUrl": "https://p4.music.126.net/aEehIWg8Qk5DXLGf0XZHqw==/109951166554891221.jpg"
        },
        "product": {
            "price": 22.0,
            "pubTime": 1608566401510u64,
            "saleNum": 0,
            "tags": ["独家", "无损品质收听＆下载"],
            "descr": [{"resource": "发端似乎在2013年", "type": 1}, {"resource": "</br>", "type": 1}, {"resource": "西郊有密林", "type": 1}]
        }
    });
    let d = parse_digital_album_detail(&body).expect("detail");
    assert_eq!(d.album_id, 120605500);
    assert_eq!(d.name, "冀西南林路行");
    assert_eq!(d.artist_name, "万能青年旅店");
    assert!(d.has_album);
    assert!((d.price - 22.0).abs() < f64::EPSILON);
    assert_eq!(d.pub_time_ms, 1608566401510);
    assert_eq!(d.sale_num, 0);
    assert_eq!(d.tags, vec!["独家", "无损品质收听＆下载"]);
    assert_eq!(d.description, "发端似乎在2013年\n西郊有密林");
    // 缺 product 只退化字段, album 缺失才是 not_found
    let no_product = json!({"code": 200, "album": {"albumId": 1, "albumName": "x"}});
    let d = parse_digital_album_detail(&no_product).expect("detail");
    assert_eq!(d.price, 0.0);
    assert!(d.tags.is_empty());
    assert!(parse_digital_album_detail(&json!({"code": 200})).is_err());
}

/// digital_album_sales: data 是 {专辑id串: 销量} map, 不是数组
#[test]
fn digital_album_sales_parses_map() {
    let body = json!({"code": 200, "data": {"120605500": 1300052u64, "162008967": 7u64}});
    let s = parse_digital_album_sales(&body);
    assert_eq!(s.len(), 2);
    assert!(s.contains(&DigitalAlbumSalesEntry {
        album_id: "120605500".into(),
        sales: 1300052
    }));
    // data 缺失/非对象 → 空列表, 不报错
    assert!(parse_digital_album_sales(&json!({"code": 200})).is_empty());
    assert!(parse_digital_album_sales(&json!({"code": 200, "data": []})).is_empty());
}

/// vip_info_v2: is_vip 只看 expireTime > now(vipCode/vipLevel 过期后仍是旧值)
#[test]
fn vip_membership_is_vip_by_expire_time() {
    let body = json!({
        "code": 200,
        "data": {
            "now": 1_794_021_180_859u64,
            "redVipLevel": 3,
            "redVipAnnualCount": -1,
            "associator": {"vipCode": 100, "vipLevel": 3, "expireTime": 1_794_326_399_000u64}
        }
    });
    let m = parse_vip_membership(&body).expect("membership");
    assert_eq!(m.level, 3);
    assert_eq!(m.red_vip_level, 3);
    assert!(m.is_vip, "expireTime 晚于 now 应算会员");
    assert_eq!(m.annual_count, -1);

    // 同一个账号, 把 now 挪到过期之后 -> 不再是会员(但 vipLevel 仍是 3)
    let expired = json!({
        "code": 200,
        "data": {
            "now": 1_800_000_000_000u64,
            "associator": {"vipLevel": 3, "expireTime": 1_794_326_399_000u64}
        }
    });
    let m = parse_vip_membership(&expired).expect("membership");
    assert!(!m.is_vip);
    assert_eq!(m.level, 3);
    assert_eq!(m.red_vip_level, 0);
}

/// vip_growthpoint: 今日成长值藏在 userLevel.extJson(JSON 字符串) 里
#[test]
fn vip_growth_reads_today_score_from_ext_json() {
    let body = json!({
        "code": 200,
        "data": {
            "levelCard": {"level": 3, "levelName": "黑胶·叁"},
            "userLevel": {
                "level": 3,
                "levelName": "黑胶·叁",
                "growthPoint": 2195,
                "maxLevel": false,
                "extJson": "{\"yearMonth\":\"202610\",\"todayScore\":6,\"totalScore\":0}"
            }
        }
    });
    let g = parse_vip_growth(&body).expect("growth");
    assert_eq!(g.level, 3);
    assert_eq!(g.level_name, "黑胶·叁");
    assert_eq!(g.growth_point, 2195);
    assert_eq!(g.today_score, 6);
    assert!(!g.max_level);

    // extJson 坏掉时不能 panic, 今日成长值退 0
    let broken = json!({"data": {"userLevel": {"growthPoint": 1, "extJson": "not-json"}}});
    let g = parse_vip_growth(&broken).expect("growth");
    assert_eq!(g.today_score, 0);
}

/// vip_sign_info: 只回最近 7 天, score > 0 才算已签(recordId/time 未签时也是 0)
#[test]
fn vip_sign_uses_score_not_record_id() {
    let body = json!({
        "code": 200,
        "data": [
            {"timeStr": "2026-11-05", "today": false, "score": 0, "recordId": 0, "time": 0},
            {"timeStr": "2026-11-06", "today": false, "score": 3, "recordId": 0, "time": 0},
            {"timeStr": "2026-11-07", "today": true, "score": 3, "recordId": 0, "time": 0}
        ]
    });
    let s = parse_vip_sign(&body);
    assert_eq!(s.days.len(), 3);
    assert_eq!(s.week_signed, 2);
    assert!(!s.days[0].signed);
    assert!(s.days[1].signed);
    assert!(s.signed_today);
    assert!(s.days[2].today);

    let empty = json!({"code": 200, "data": []});
    let s = parse_vip_sign(&empty);
    assert!(s.days.is_empty());
    assert!(!s.signed_today);
    assert_eq!(s.week_signed, 0);
}

/// vip_tasks: name 空回退 action; targets=null 时 target=0(不显示进度条); status=2 算完成
#[test]
fn vip_tasks_flatten_and_fallback_title() {
    let body = json!({
        "code": 200,
        "data": {
            "taskScore": 7,
            "taskList": [
                {"seqName": "个性化任务", "taskItems": [
                    {"action": "浏览黑胶时光机", "name": "", "description": "成长值+3",
                     "growthPoint": 3, "currentProgress": 0, "targets": null,
                     "showProgress": true, "status": 0,
                     "url": "https://music.163.com/prime/m/viptimemachine"},
                    {"action": "听歌 60 分钟", "name": "每日听歌", "description": "成长值+2",
                     "growthPoint": 2, "currentProgress": 60, "targets": 60,
                     "showProgress": true, "status": 0},
                    {"action": "已完成的任务", "name": "", "description": "云贝+10",
                     "growthPoint": 0, "currentProgress": 0, "targets": null,
                     "showProgress": false, "status": 2}
                ]}
            ]
        }
    });
    let (tasks, score) = parse_vip_tasks(&body);
    assert_eq!(score, 7);
    assert_eq!(tasks.len(), 3);
    assert_eq!(tasks[0].title, "浏览黑胶时光机");
    assert_eq!(tasks[0].reward, "成长值+3");
    assert_eq!(tasks[0].target, 0);
    assert!(!tasks[0].done);
    assert!(tasks[0].url.is_some());
    assert_eq!(tasks[1].title, "每日听歌");
    assert_eq!(tasks[1].target, 60);
    assert!(tasks[1].done);
    assert!(tasks[2].done);
    assert!(!tasks[2].show_progress);
}

/// 未登录时 vip_overview 不该报鉴权错误, 而是 logged_in=false 的空态
#[tokio::test]
async fn vip_overview_anonymous_is_empty_state() {
    let provider = NeteaseProvider::new(Session::default());
    let o = provider.vip_overview().await.expect("anonymous ok");
    assert!(!o.logged_in);
    assert!(o.membership.is_none());
    assert!(o.tasks.is_empty());
}
