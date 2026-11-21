//! 切片 B/C 的判据用例(`docs/audit/2026-11-21-plugin-isolation-phase2.md`):
//! ① 调用队列有界且满时**立即拒绝**(可重试), ② 同一首在飞取链请求合并, ③ 取链吃独立(更紧)预算.

use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, Instant};

use futures::executor::block_on;
use ncm_domain::TrackId;
use ncm_plugin::{
    MemoryStorage, MockTransport, PluginSpec, SandboxConfig, ScriptProvider, TransportResponse,
};
use ncm_provider::{AudioLevel, ProviderErrorKind, ProviderResult, ReadProvider, SongUrlRequest};

/// 与 `fixtures/busy_music_url.js` 里的忙等时长对齐(留余量判断"立即拒绝").
const BUSY_SOURCE: &str = include_str!("fixtures/busy_music_url.js");
const STREAM_URL: &str = "https://cdn.test/merged.mp3";

fn ok(body: &str) -> Result<TransportResponse, ncm_plugin::TransportError> {
    Ok(TransportResponse {
        status: 200,
        headers: vec![],
        body: body.to_string(),
    })
}

fn transport() -> Arc<MockTransport> {
    Arc::new(MockTransport::new().on(
        "example.test/api/song/url",
        ok(r#"{"url":"https://cdn.test/merged.mp3"}"#),
    ))
}

fn spec(source: &str, transport: Arc<MockTransport>, config: SandboxConfig) -> PluginSpec {
    PluginSpec::new("slow", source, transport, Arc::new(MemoryStorage::new())).with_config(config)
}

fn request(track: u64) -> SongUrlRequest {
    SongUrlRequest {
        track: TrackId(track),
        level: AudioLevel::Exhigh,
        meta: None,
    }
}

#[test]
fn timeout_for_prefers_the_tighter_budget() {
    let cfg = SandboxConfig::default();
    assert_eq!(cfg.timeout_for("musicUrl"), Duration::from_secs(4));
    assert_eq!(cfg.timeout_for("search"), Duration::from_secs(8));
    assert_eq!(cfg.timeout_for("lyric"), Duration::from_secs(8));

    // 通用预算比取链预算还紧时, 取链不得反而被放宽.
    let tight = SandboxConfig {
        call_timeout: Duration::from_secs(2),
        ..SandboxConfig::default()
    };
    assert_eq!(tight.timeout_for("musicUrl"), Duration::from_secs(2));
}

#[test]
fn concurrent_same_track_requests_coalesce_into_one_script_call() {
    let transport = transport();
    let provider = Arc::new(
        ScriptProvider::load(spec(
            BUSY_SOURCE,
            transport.clone(),
            SandboxConfig::default(),
        ))
        .expect("插件应加载成功"),
    );

    const CALLS: usize = 10;
    let barrier = Arc::new(Barrier::new(CALLS));
    let mut handles = Vec::new();
    for _ in 0..CALLS {
        let provider = provider.clone();
        let barrier = barrier.clone();
        handles.push(thread::spawn(move || {
            let req = request(7);
            barrier.wait();
            block_on(provider.song_url(&req)).map(|stream| stream.url)
        }));
    }
    let results: Vec<ProviderResult<Option<String>>> = handles
        .into_iter()
        .map(|handle| handle.join().expect("线程不应 panic"))
        .collect();

    for result in &results {
        assert_eq!(
            result.as_ref().expect("合并后 10 次都应成功").as_deref(),
            Some(STREAM_URL)
        );
    }
    let hits = transport.requests().len();
    assert!(hits <= 2, "同一首并发取链应合并, 实际打了 {hits} 次网络");
}

#[test]
fn call_queue_is_bounded_and_rejects_immediately() {
    let transport = transport();
    let provider = Arc::new(
        ScriptProvider::load(spec(
            BUSY_SOURCE,
            transport.clone(),
            SandboxConfig::default(),
        ))
        .expect("插件应加载成功"),
    );

    // 不同 track ⇒ 不会被合并, 4 个并发至少有 1 个撞上队列上界(深度 2).
    const CALLS: usize = 4;
    let barrier = Arc::new(Barrier::new(CALLS));
    let mut handles = Vec::new();
    for track in 0..CALLS as u64 {
        let provider = provider.clone();
        let barrier = barrier.clone();
        handles.push(thread::spawn(move || {
            let req = request(track);
            barrier.wait();
            let started = Instant::now();
            let result = block_on(provider.song_url(&req));
            (started.elapsed(), result)
        }));
    }
    let results: Vec<(Duration, ProviderResult<_>)> = handles
        .into_iter()
        .map(|handle| handle.join().expect("线程不应 panic"))
        .collect();

    let rejected: Vec<&(Duration, ProviderResult<_>)> = results
        .iter()
        .filter(|(_, result)| result.is_err())
        .collect();
    assert!(
        (1..=2).contains(&rejected.len()),
        "队列深度 2 时应拒 1~2 次, 实际 {}",
        rejected.len()
    );
    for (elapsed, result) in &rejected {
        let err = result.as_ref().expect_err("已筛过");
        assert_eq!(
            err.kind,
            ProviderErrorKind::Network,
            "detail: {}",
            err.detail
        );
        assert!(err.retryable, "队列满要可重试");
        assert!(err.detail.contains("排队"), "detail: {}", err.detail);
        // 忙等 250ms ⇒ 立即拒绝必须远早于它(宽松阈值, 重负载下也不假红).
        assert!(
            *elapsed < Duration::from_millis(200),
            "拒绝应立即可返回, 实际 {elapsed:?}"
        );
    }
    let accepted = CALLS - rejected.len();
    assert_eq!(
        transport.requests().len(),
        accepted,
        "被拒绝的调用不应打到网络"
    );
}

#[test]
fn song_url_uses_its_own_tighter_budget() {
    // 死循环脚本: 通用预算 5s, 取链预算 300ms ⇒ 必须由取链预算收口(而不是等满 5s).
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/loop.js"),
        Arc::new(MockTransport::new()),
        SandboxConfig {
            call_timeout: Duration::from_secs(5),
            song_url_timeout: Duration::from_millis(300),
            ..SandboxConfig::default()
        },
    ))
    .expect("死循环脚本能装载(抛错/死循环发生在调用期)");

    let started = Instant::now();
    let err = block_on(provider.song_url(&request(1))).expect_err("死循环必须被取链预算打断");
    let elapsed = started.elapsed();
    assert_eq!(
        err.kind,
        ProviderErrorKind::Network,
        "detail: {}",
        err.detail
    );
    assert!(err.retryable, "超时应当可重试");
    assert!(
        elapsed < Duration::from_secs(3),
        "应走 300ms 取链预算而不是 5s 通用预算, 实际 {elapsed:?}"
    );
}
