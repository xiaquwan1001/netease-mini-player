//! 云盘: 列表/删除/下载直链的离线单测.

use crate::netease::*;
use ncm_provider::ProviderErrorKind;
use serde_json::json;

/// 真实形状(2026-11 抓包): data[] 同时带云盘文件字段与内嵌 simpleSong.
#[test]
fn cloud_page_mapping() {
    let body = json!({
        "code": 200,
        "count": 2,
        "size": 7000000,
        "maxSize": 64424509440u64,
        "more": true,
        "data": [
            {
                "id": 111,
                "songId": 222,
                "fileName": "fallback.mp3",
                "fileSize": 4000000,
                "bitrate": 320000,
                "addTime": 1700000000000u64,
                "simpleSong": {
                    "id": 222,
                    "name": "云盘里的歌",
                    "ar": [{"id": 1, "name": "歌手A"}, {"id": 2, "name": "歌手B"}],
                    "al": {"id": 3, "name": "专辑C", "picUrl": "http://p1.music.126.net/c.jpg"}
                }
            },
            {
                "id": 333,
                "fileName": "no-meta.mp3",
                "fileSize": 3000000,
                "bitrate": 128000,
                "addTime": 1600000000000u64
            }
        ]
    });
    let page = parse_cloud_page(&body);
    assert_eq!(page.count, 2);
    assert_eq!(page.max_size, 64424509440);
    assert!(page.more);
    assert_eq!(page.songs.len(), 2);

    let s = &page.songs[0];
    assert_eq!(s.id, 111, "删除用的是云盘条目 id");
    assert_eq!(s.song_id, 222);
    assert_eq!(s.name, "云盘里的歌");
    assert_eq!(s.artist, "歌手A / 歌手B");
    assert_eq!(s.album, "专辑C");
    assert_eq!(
        s.cover_url.as_deref(),
        Some("http://p1.music.126.net/c.jpg")
    );
    assert_eq!(s.size, 4000000);
    assert_eq!(s.bitrate, 320000);
    assert_eq!(s.add_time, 1700000000000);

    // 没有 simpleSong: 歌名退回 fileName, songId 退回条目 id, 歌手/专辑空
    let s = &page.songs[1];
    assert_eq!(s.id, 333);
    assert_eq!(s.song_id, 333);
    assert_eq!(s.name, "no-meta.mp3");
    assert!(s.artist.is_empty());
    assert!(s.album.is_empty());
}

/// 空云盘 / 缺字段不应炸, 计数照样读得到
#[test]
fn cloud_page_empty_and_missing_fields() {
    let page = parse_cloud_page(&json!({"code": 200, "count": 0, "data": []}));
    assert!(page.songs.is_empty());
    assert_eq!(page.count, 0);
    assert_eq!(page.max_size, 0);
    assert!(!page.more);

    // 整条既没有 id 也没有 songId: 丢掉而不是给个 0 号条目
    let page = parse_cloud_page(&json!({"code": 200, "data": [{"fileName": "x.mp3"}]}));
    assert!(page.songs.is_empty());
}

/// 下载直链两种形状都要认
#[test]
fn cloud_song_url_shapes() {
    assert_eq!(
        parse_cloud_song_url(&json!({"code":200,"data":{"url":"http://m/a.mp3"}})).as_deref(),
        Some("http://m/a.mp3")
    );
    assert_eq!(
        parse_cloud_song_url(&json!({"code":200,"data":[{"url":"http://m/b.mp3"}]})).as_deref(),
        Some("http://m/b.mp3")
    );
    assert!(parse_cloud_song_url(&json!({"code":200,"data":{}})).is_none());
    assert!(parse_cloud_song_url(&json!({"code":200})).is_none());
}

/// 删除空 id 列表: 本地就报错, 不发请求
#[tokio::test]
async fn cloud_delete_rejects_empty_ids() {
    let p = NeteaseProvider::new(ncm_domain::Session::default());
    let err = p.cloud_delete(&[]).await.unwrap_err();
    assert_eq!(err.kind, ProviderErrorKind::Internal);
}
