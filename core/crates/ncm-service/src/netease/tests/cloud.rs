//! 云盘: 列表/删除/下载直链的离线单测.

use crate::netease::*;
use ncm_provider::ProviderErrorKind;
use serde_json::json;

/// 真实形状(2026-11-19 抓包): token 响应的 resourceId 是**数字**(84382086772)。
///
/// 回归: 旧代码用 `str_of` 只按字符串解析 ⇒ 拿到空串 ⇒ info/v2 缺 resourceId ⇒
/// 服务端 `{"code":400,"songId":"0"}`, 安卓端表现为「上传识别失败, internal code 400」。
#[test]
fn nos_token_resource_id_is_numeric_in_real_response() {
    let body = json!({
        "code": 200,
        "message": null,
        "result": {
            "bucket": "jd-musicrep-privatecloud-audio-public",
            "objectKey": "obj/xx/84382086772/1e7a/0da7/6418/d9e23.data",
            "resourceId": 84382086772u64,
            "token": "UPLOAD xxx"
        }
    });
    let result = body.get("result").expect("result");
    assert_eq!(
        str_of(result, "resourceId"),
        None,
        "反向证据: 只按字符串解析会拿到空串(这是修前的 bug)"
    );
    assert_eq!(
        str_or_num_of(result, "resourceId").as_deref(),
        Some("84382086772")
    );
}

/// 真实形状(2026-11-19 抓包): check 的 songId 是 128 位**十六进制串**, 必须原样回填给 info/v2。
#[test]
fn upload_check_song_id_hex_is_not_parsed_as_number() {
    const HEX: &str = "1B23A9CEAFF2E6B4B2173517C5A871FE8DEDA1B08CB70BB5799988A856BC7997E08685E3143A89952A5B7328303FDDBB4E3B1D28DD517C9C0131C84CB28618BD";
    let check = json!({"code": 200, "needUpload": true, "songId": HEX});
    assert_eq!(u64_of(&check, "songId"), None, "十六进制串不能被当数字解析");
    assert_eq!(str_or_num_of(&check, "songId").as_deref(), Some(HEX));
    // 服务端也可能给数字串: 两种都要能原样回填
    let numeric = json!({"code": 200, "needUpload": true, "songId": 12345});
    assert_eq!(str_or_num_of(&numeric, "songId").as_deref(), Some("12345"));
}

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

// ---------------------------------------------------------------------------
// 上传: 策略接缝 + 本地假 HTTP 服务(不触网)
// ---------------------------------------------------------------------------

use super::cloud::{
    build_upload_client, cloud_upload_plan, nos_content_type, upload_nos_whole_file,
    CLOUD_SINGLE_SHOT_CEILING,
};
use crate::cloud_chunk::UploadPlan;

/// 今天的分片接缝状态: 单请求上限未实测 ⇒ 无论多大都选单请求. 这条断言是**故意的**
/// "行为锁": 一旦有人把 `CLOUD_SINGLE_SHOT_CEILING` 改成数字(接线分片), 它会红,
/// 提醒同时补上假 HTTP 服务的"分片→合并"序列测试。
#[test]
fn cloud_upload_strategy_is_single_shot_until_ceiling_is_measured() {
    assert_eq!(
        CLOUD_SINGLE_SHOT_CEILING, None,
        "服务端单请求上限未实测(见 cloud_chunk 模块 TODO 第 4 条)"
    );
    for size in [1u64, 50 * 1024 * 1024, 300 * 1024 * 1024] {
        assert_eq!(
            cloud_upload_plan(size).expect("非空文件应当可规划"),
            UploadPlan::SingleShot
        );
    }
    let empty = cloud_upload_plan(0).expect_err("空文件必须拒绝");
    assert_eq!(empty.kind, ProviderErrorKind::Unsupported);
}

#[test]
fn nos_content_type_maps_audio_containers() {
    assert_eq!(nos_content_type("flac"), "audio/flac");
    assert_eq!(nos_content_type("m4a"), "audio/mp4");
    assert_eq!(nos_content_type("aac"), "audio/mp4");
    assert_eq!(nos_content_type("wav"), "audio/wav");
    assert_eq!(nos_content_type("ogg"), "audio/ogg");
    assert_eq!(nos_content_type("mp3"), "audio/mpeg");
    assert_eq!(nos_content_type("unknown"), "audio/mpeg");
}

/// 假 HTTP 服务收到的原始请求.
struct CapturedRequest {
    request_line: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl CapturedRequest {
    fn header(&self, name: &str) -> Option<&str> {
        let want = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| *k == want)
            .map(|(_, v)| v.as_str())
    }
}

/// 起一个只听 127.0.0.1 的假 HTTP 服务: 收**一个**请求, 按 `status`/`body` 回包.
/// 返回 (base_url, join handle → 捕获到的请求).
fn spawn_fake_nos(
    status: u16,
    response_body: &'static str,
) -> (String, std::thread::JoinHandle<CapturedRequest>) {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("绑定本地端口");
    let addr = listener.local_addr().expect("取本地端口");
    let handle = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("接受连接");
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(10)))
            .expect("设读超时");
        // 先读到请求头结束(CRLF CRLF), 再按 Content-Length 读 body
        let mut raw = Vec::new();
        let mut buf = [0u8; 4096];
        let header_end = loop {
            if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                break pos + 4;
            }
            let n = stream.read(&mut buf).expect("读请求头");
            assert!(n > 0, "客户端在请求头读完前断开");
            raw.extend_from_slice(&buf[..n]);
        };
        let head = String::from_utf8_lossy(&raw[..header_end]).to_string();
        let mut lines = head.split("\r\n");
        let request_line = lines.next().unwrap_or_default().to_string();
        let headers: Vec<(String, String)> = lines
            .filter(|l| !l.is_empty())
            .filter_map(|l| l.split_once(':'))
            .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))
            .collect();
        let content_length: usize = headers
            .iter()
            .find(|(k, _)| k == "content-length")
            .and_then(|(_, v)| v.parse().ok())
            .unwrap_or(0);
        let mut body = raw[header_end..].to_vec();
        while body.len() < content_length {
            let n = stream.read(&mut buf).expect("读 body");
            assert!(n > 0, "body 没读完客户端就断开了");
            body.extend_from_slice(&buf[..n]);
        }
        body.truncate(content_length);
        let response = format!(
            "HTTP/1.1 {status} X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response_body}",
            response_body.len()
        );
        stream.write_all(response.as_bytes()).expect("回包");
        stream.flush().ok();
        CapturedRequest {
            request_line,
            headers,
            body,
        }
    });
    (format!("http://{addr}"), handle)
}

/// 单请求路径的**完整形状**: URL 参数(offset=0&complete=true&version=1.0)、三个头、原始 body.
/// 这条序列是上游 `plugins/songUpload.js` 的同款, 也是分片接线的对照物。
#[tokio::test]
async fn upload_nos_whole_file_posts_evidenced_single_shot_request() {
    let (base, handle) = spawn_fake_nos(200, "");
    let http = build_upload_client().expect("建上传客户端");
    let bytes = b"ID3\x04\x00fake-audio-bytes".to_vec();

    upload_nos_whole_file(
        &http,
        &base,
        "nos-token-abc",
        "md5deadbeef",
        "cloud/ab.mp3",
        bytes.clone(),
        "mp3",
    )
    .await
    .expect("2xx 应当成功");

    let cap = handle.join().expect("假服务线程未 panic");
    assert_eq!(
        cap.request_line,
        "POST /jd-musicrep-privatecloud-audio-public/cloud%2Fab.mp3\
         ?offset=0&complete=true&version=1.0 HTTP/1.1",
        "URL 参数是协议的关键证据(上游 songUpload.js 同款)"
    );
    assert_eq!(cap.header("x-nos-token"), Some("nos-token-abc"));
    assert_eq!(cap.header("content-md5"), Some("md5deadbeef"));
    assert_eq!(cap.header("content-type"), Some("audio/mpeg"));
    assert_eq!(cap.body, bytes, "body 必须是整份文件字节");
}

/// 非 2xx: 收口成 `internal`(不可重试), detail 带状态码与截断后的响应体.
#[tokio::test]
async fn upload_nos_whole_file_maps_non_2xx_to_error() {
    let (base, handle) = spawn_fake_nos(500, "boom-from-nos");
    let http = build_upload_client().expect("建上传客户端");

    let err = upload_nos_whole_file(&http, &base, "tok", "md5", "k.mp3", b"abc".to_vec(), "flac")
        .await
        .expect_err("5xx 必须报错");
    let cap = handle.join().expect("假服务线程未 panic");
    assert_eq!(cap.header("content-type"), Some("audio/flac"));
    assert_eq!(err.kind, ProviderErrorKind::Internal);
    assert!(!err.retryable, "上传失败保持不可重试(与既有五步流程一致)");
    assert!(err.detail.contains("HTTP 500"), "{}", err.detail);
    assert!(err.detail.contains("boom-from-nos"), "{}", err.detail);
}
