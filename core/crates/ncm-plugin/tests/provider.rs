//! `ScriptProvider` 用例: 既有 `Provider` 能力(songUrl/search) + 能力声明 + 错误映射.

use std::sync::Arc;

use futures::executor::block_on;
use ncm_domain::TrackId;
use ncm_plugin::{
    MemoryStorage, MockTransport, PluginErrorKind, PluginSpec, SandboxConfig, ScriptProvider,
    TransportResponse,
};
use ncm_provider::{AudioLevel, Capability, Provider, ProviderErrorKind, ReadProvider, SearchQuery, SongUrlRequest};

fn reply(body: &str) -> Result<TransportResponse, ncm_plugin::TransportError> {
    Ok(TransportResponse {
        status: 200,
        headers: vec![],
        body: body.to_string(),
    })
}

fn spec(
    source: &str,
    transport: Arc<MockTransport>,
    config: SandboxConfig,
) -> PluginSpec {
    PluginSpec::new("demo", source, transport, Arc::new(MemoryStorage::new())).with_config(config)
}

#[test]
fn song_url_maps_to_stream_url() {
    let transport = Arc::new(MockTransport::new().on(
        "example.test/api/song/url",
        reply(r#"{"url":"https://cdn.test/a.mp3","br":320000}"#),
    ));
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/music_url.js"),
        transport.clone(),
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");

    assert_eq!(provider.id(), "script");
    assert_eq!(provider.name(), "demo");
    assert!(provider.supports(Capability::SongUrl));
    assert!(!provider.supports(Capability::Search));

    let request = SongUrlRequest {
        track: TrackId(42),
        level: AudioLevel::Exhigh,
    };
    let stream = block_on(provider.song_url(&request)).expect("取链应成功");
    assert_eq!(stream.url.as_deref(), Some("https://cdn.test/a.mp3"));
    assert_eq!(stream.quality, "exhigh", "quality 记录的是请求档位");
    assert_eq!(stream.format.as_deref(), Some("mp3"));
    assert_eq!(stream.br, Some(320_000));
    assert!(
        stream.expire_at.is_some_and(|v| v > 1_000_000_000),
        "expireAt 毫秒应折成秒: {:?}",
        stream.expire_at
    );

    // 位置参数契约: source / musicInfo / quality.
    let seen = transport.requests();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].body.as_deref(), Some("level=320k"));

    let logs = provider.take_logs();
    assert!(logs.iter().any(|l| l.contains("320k")), "logs: {logs:?}");
}

#[test]
fn search_maps_to_search_page() {
    let transport = Arc::new(MockTransport::new().on(
        "example.test/api/search",
        reply(
            r#"{"songs":[{"id":7,"name":"夜曲","singer":"周杰伦","albumName":"十一月的萧邦","interval":227}],"total":1}"#,
        ),
    ));
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/search.js"),
        transport,
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");
    assert_eq!(
        provider.capabilities(),
        &[Capability::Search],
        "能力声明由注册的事件决定"
    );

    let page = block_on(provider.search(&SearchQuery::new("夜曲"))).expect("搜索应成功");
    assert_eq!(page.total, 1);
    assert_eq!(page.songs.len(), 1);
    let song = &page.songs[0];
    assert_eq!(song.id, TrackId(7));
    assert_eq!(song.name, "夜曲");
    assert_eq!(song.artist_line(), "周杰伦");
    assert_eq!(song.album.as_ref().map(|a| a.name.as_str()), Some("十一月的萧邦"));
    assert_eq!(song.duration_ms, 227_000);
    assert!(!page.has_more);
}

#[test]
fn capabilities_union_when_both_events_registered() {
    let source = concat!(
        include_str!("fixtures/music_url.js"),
        "\n",
        include_str!("fixtures/search.js"),
    );
    let provider = ScriptProvider::load(spec(
        source,
        Arc::new(MockTransport::new()),
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");
    assert_eq!(
        provider.capabilities(),
        &[Capability::SongUrl, Capability::Search]
    );
}

#[test]
fn unsupported_capability_returns_unsupported() {
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/music_url.js"),
        Arc::new(MockTransport::new()),
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");
    let err = block_on(provider.search(&SearchQuery::new("x"))).expect_err("没注册 search");
    assert_eq!(err.kind, ProviderErrorKind::Unsupported);
}

#[test]
fn syntax_error_fails_load() {
    let err = ScriptProvider::load(spec(
        "lx.on('musicUrl', () => { ",
        Arc::new(MockTransport::new()),
        SandboxConfig::default(),
    ))
    .expect_err("语法错误必须装载失败");
    assert_eq!(err.kind, PluginErrorKind::Load);
    assert_eq!(err.to_provider_error().kind, ProviderErrorKind::Internal);
}

#[test]
fn null_url_maps_to_not_found() {
    let transport = Arc::new(MockTransport::new().on(
        "example.test/api/song/url",
        reply(r#"{"url":null}"#),
    ));
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/music_url.js"),
        transport,
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");
    let request = SongUrlRequest {
        track: TrackId(1),
        level: AudioLevel::Standard,
    };
    let err = block_on(provider.song_url(&request)).expect_err("脚本返回 null 时应 notFound");
    assert_eq!(err.kind, ProviderErrorKind::NotFound);
    assert!(!err.retryable);
}
