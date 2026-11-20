//! `ReqwestTransport` 的离线用例: 本地假 HTTP 服务(127.0.0.1)收请求、按脚本回包.
//!
//! 写法沿用 `netease/tests/cloud.rs` 的 `spawn_fake_nos`: 裸 `TcpListener` + 手写
//! HTTP/1.1, 不引第三方 mock 服务器 —— 这样能断言到线上形状(方法/头/body).
//! 一律不联网.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use super::*;
use ncm_plugin::{MemoryStorage, PluginSpec, ScriptProvider};
use ncm_provider::ProviderErrorKind;

/// 一条预置应答(第 N 个连接用第 N 条; 连接数超出时重复最后一条).
#[derive(Debug, Clone)]
struct Reply {
    status: u16,
    body: &'static str,
    delay: Duration,
}

fn reply(status: u16, body: &'static str) -> Reply {
    Reply {
        status,
        body,
        delay: Duration::ZERO,
    }
}

fn slow_reply(delay: Duration) -> Reply {
    Reply {
        status: 200,
        body: "late",
        delay,
    }
}

/// 假服务收到的原始请求.
#[derive(Debug)]
struct Captured {
    request_line: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl Captured {
    fn header(&self, name: &str) -> Option<&str> {
        let want = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| *k == want)
            .map(|(_, v)| v.as_str())
    }
}

/// 起一个只听 127.0.0.1 的假 HTTP 服务.
///
/// 收连接直到「服务完最后一条应答后再静默 400ms」为止(这个静默窗口用来发现
/// 客户端不该发的那次重试), 返回 (base_url, join handle -> 捕获到的请求).
fn spawn_fake(replies: Vec<Reply>) -> (String, JoinHandle<Vec<Captured>>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("绑定本地端口");
    listener.set_nonblocking(true).expect("设非阻塞");
    let addr = listener.local_addr().expect("取本地端口");
    let handle = std::thread::spawn(move || {
        let mut captured: Vec<Captured> = Vec::new();
        let mut idle_until = Instant::now() + Duration::from_millis(1500);
        loop {
            if Instant::now() > idle_until {
                break;
            }
            match listener.accept() {
                Ok((mut stream, _)) => {
                    stream.set_nonblocking(false).expect("设阻塞");
                    stream
                        .set_read_timeout(Some(Duration::from_secs(5)))
                        .expect("设读超时");
                    let request = read_request(&mut stream);
                    let chosen = replies
                        .get(captured.len())
                        .or_else(|| replies.last())
                        .cloned()
                        .unwrap_or_else(|| reply(200, ""));
                    if !chosen.delay.is_zero() {
                        std::thread::sleep(chosen.delay);
                    }
                    // 客户端可能已经超时断开, 回包失败是预期内的(用例只看客户端侧)
                    let _ = write_response(&mut stream, chosen.status, chosen.body);
                    captured.push(request);
                    idle_until = Instant::now() + Duration::from_millis(400);
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(_) => break,
            }
        }
        captured
    });
    (format!("http://{addr}"), handle)
}

fn read_request(stream: &mut std::net::TcpStream) -> Captured {
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
    Captured {
        request_line,
        headers,
        body,
    }
}

fn write_response(
    stream: &mut std::net::TcpStream,
    status: u16,
    body: &str,
) -> std::io::Result<()> {
    let response = format!(
        "HTTP/1.1 {status} X\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(response.as_bytes())?;
    stream.flush()
}

/// 测试客户端: 短超时 + 固定 UA(生产 UA 由 `ReqwestTransport::new` 注入).
fn test_transport(timeout: Duration, retries: u32) -> ReqwestTransport {
    let client = reqwest::blocking::Client::builder()
        .user_agent("minincm-plugin-test/1")
        .timeout(timeout)
        .build()
        .expect("建测试客户端");
    ReqwestTransport::with_client(client).with_retries(retries)
}

fn post_to(base: &str) -> TransportRequest {
    TransportRequest {
        url: format!("{base}/api/song/url?id=42"),
        method: "POST".to_string(),
        headers: vec![("X-Test".to_string(), "1".to_string())],
        body: Some("level=320k".to_string()),
    }
}

#[test]
fn send_passes_request_through_and_returns_response() {
    let (base, server) = spawn_fake(vec![reply(200, r#"{"url":"https://cdn.test/a.mp3"}"#)]);
    let transport = test_transport(Duration::from_secs(5), 0);

    let response = transport.send(&post_to(&base)).expect("请求应成功");
    assert_eq!(response.status, 200);
    assert!(
        response.body.contains("cdn.test/a.mp3"),
        "body: {}",
        response.body
    );
    assert!(
        response
            .headers
            .iter()
            .any(|(k, _)| k.eq_ignore_ascii_case("content-type")),
        "响应头要交回脚本: {:?}",
        response.headers
    );

    let captured = server.join().expect("假服务不应 panic");
    assert_eq!(captured.len(), 1, "不重试时只该发一次");
    assert!(
        captured[0]
            .request_line
            .starts_with("POST /api/song/url?id=42 HTTP/1.1"),
        "request_line: {}",
        captured[0].request_line
    );
    assert_eq!(captured[0].header("x-test"), Some("1"), "脚本头原样透传");
    assert_eq!(
        captured[0].header("user-agent"),
        Some("minincm-plugin-test/1"),
        "客户端默认 UA(生产是 identity::platform_profile 那套)"
    );
    assert_eq!(captured[0].body, b"level=320k".to_vec(), "body 原样透传");
}

#[test]
fn non_2xx_maps_to_provider_error_kind() {
    // 与 `TransportError::http_status` 的可重试口径一致: 401/403/404 不可重试, 其余可重试.
    let cases: [(u16, ProviderErrorKind, bool); 3] = [
        (403, ProviderErrorKind::Forbidden, false),
        (404, ProviderErrorKind::NotFound, false),
        (500, ProviderErrorKind::Network, true),
    ];
    for (status, want_kind, want_retryable) in cases {
        let (base, server) = spawn_fake(vec![reply(status, "blocked")]);
        let transport = test_transport(Duration::from_secs(5), 0);

        let err = transport
            .send(&post_to(&base))
            .expect_err("非 2xx 必须是传输失败");
        assert_eq!(err.status, Some(status), "状态码要带上, 否则上层分不了档");
        assert_eq!(err.retryable, want_retryable, "http {status} 的重试口径");

        let mapped = err.to_provider_error();
        assert_eq!(mapped.kind, want_kind, "http {status} -> {mapped:?}");
        assert_eq!(mapped.retryable, want_retryable);
        assert!(
            mapped.detail.contains(&status.to_string()),
            "detail 要能看出状态码: {}",
            mapped.detail
        );

        let captured = server.join().expect("假服务不应 panic");
        assert_eq!(captured.len(), 1, "重试次数 0 时只该连一次");
    }
}

#[test]
fn timeout_maps_to_retryable_network_error() {
    let (base, server) = spawn_fake(vec![slow_reply(Duration::from_millis(500))]);
    let transport = test_transport(Duration::from_millis(120), 0);

    let err = transport
        .send(&post_to(&base))
        .expect_err("响应太慢必须超时");
    assert!(err.retryable, "超时可重试: {err:?}");
    assert_eq!(err.status, None, "纯传输失败没有 HTTP 状态码");
    let mapped = err.to_provider_error();
    assert_eq!(mapped.kind, ProviderErrorKind::Network);
    assert!(mapped.retryable);
    assert!(
        mapped.detail.contains("超时"),
        "detail 要能看出是超时: {}",
        mapped.detail
    );
    let _ = server.join();
}

#[test]
fn retryable_failure_is_retried_exactly_once() {
    // 第一次 503, 第二次 200: 生产重试档位(1)下应当自动恢复, 且只多连一次.
    let (base, server) = spawn_fake(vec![reply(503, "busy"), reply(200, r#"{"ok":true}"#)]);
    let transport = test_transport(
        Duration::from_secs(5),
        crate::plugins::transport::TRANSPORT_RETRIES,
    );

    let response = transport.send(&post_to(&base)).expect("重试一次后应成功");
    assert_eq!(response.status, 200);
    assert!(response.body.contains("ok"));

    let captured = server.join().expect("假服务不应 panic");
    assert_eq!(captured.len(), 2, "恰好两次尝试: {captured:?}");
}

#[test]
fn non_retryable_failure_is_not_retried() {
    let (base, server) = spawn_fake(vec![reply(403, "nope")]);
    let transport = test_transport(Duration::from_secs(5), 3);

    let err = transport.send(&post_to(&base)).expect_err("403 不可重试");
    assert_eq!(err.status, Some(403));
    let captured = server.join().expect("假服务不应 panic");
    assert_eq!(captured.len(), 1, "403 不许重试: {captured:?}");
}

#[test]
fn script_provider_song_url_works_over_real_transport() {
    // 端到端: 脚本 -> 沙箱 lx.request -> ReqwestTransport -> 本地假 HTTP 服务.
    let (base, server) = spawn_fake(vec![reply(
        200,
        r#"{"url":"https://cdn.test/real.mp3","br":320000}"#,
    )]);
    let script = format!(
        "lx.on('musicUrl', async (source, info, quality) => {{\n  const res = await lx.request({{ url: '{base}/url', method: 'POST', body: 'level=' + quality }});\n  const data = JSON.parse(res.body);\n  return {{ url: data.url, type: 'mp3', br: data.br }};\n}});"
    );
    let provider = ScriptProvider::load(PluginSpec::new(
        "demo",
        script,
        Arc::new(test_transport(Duration::from_secs(5), 0)),
        Arc::new(MemoryStorage::new()),
    ))
    .expect("插件应加载成功");

    let request = ncm_provider::SongUrlRequest {
        track: ncm_domain::TrackId(42),
        level: ncm_provider::AudioLevel::Exhigh,
    };
    let stream =
        futures::executor::block_on(ncm_provider::ReadProvider::song_url(&provider, &request))
            .expect("真实 transport 取链应成功");
    assert_eq!(stream.url.as_deref(), Some("https://cdn.test/real.mp3"));
    assert_eq!(stream.br, Some(320_000));

    let captured = server.join().expect("假服务不应 panic");
    assert_eq!(captured.len(), 1);
    assert_eq!(captured[0].body, b"level=320k".to_vec());
}

#[test]
fn script_provider_surfaces_non_2xx_as_error() {
    // 契约现状(README 错误映射): 非 2xx 在脚本侧是 rejection, 脚本不 catch 就变成 script 错误,
    // 即 ProviderErrorKind::Internal(detail 里保留 http 状态码). 这条锁住"不会把 403 当成功".
    let (base, server) = spawn_fake(vec![reply(403, "blocked")]);
    let script = format!(
        "lx.on('musicUrl', async () => {{\n  const res = await lx.request({{ url: '{base}/url' }});\n  return {{ url: res.body }};\n}});"
    );
    let provider = ScriptProvider::load(PluginSpec::new(
        "demo",
        script,
        Arc::new(test_transport(Duration::from_secs(5), 0)),
        Arc::new(MemoryStorage::new()),
    ))
    .expect("插件应加载成功");

    let request = ncm_provider::SongUrlRequest {
        track: ncm_domain::TrackId(1),
        level: ncm_provider::AudioLevel::Standard,
    };
    let err =
        futures::executor::block_on(ncm_provider::ReadProvider::song_url(&provider, &request))
            .expect_err("403 不能当成功");
    assert_eq!(err.kind, ProviderErrorKind::Internal);
    assert!(
        err.detail.contains("403"),
        "detail 要留下状态码: {}",
        err.detail
    );
    let _ = server.join();
}
