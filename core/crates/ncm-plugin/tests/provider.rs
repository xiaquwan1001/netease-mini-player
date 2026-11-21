//! `ScriptProvider` 用例: 既有 `Provider` 能力(songUrl/search) + 能力声明 + 错误映射.

use std::sync::Arc;

use futures::executor::block_on;
use ncm_domain::TrackId;
use ncm_plugin::{
    MemoryStorage, MockTransport, PluginErrorKind, PluginSpec, SandboxConfig, ScriptProvider,
    TransportResponse,
};
use ncm_provider::{
    AudioLevel, Capability, LyricProvider, Provider, ProviderErrorKind, ReadProvider, SearchQuery,
    SongUrlRequest,
};

fn reply(body: &str) -> Result<TransportResponse, ncm_plugin::TransportError> {
    Ok(TransportResponse {
        status: 200,
        headers: vec![],
        body: body.to_string(),
    })
}

fn spec(source: &str, transport: Arc<MockTransport>, config: SandboxConfig) -> PluginSpec {
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
        meta: None,
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
fn lx_request_only_script_is_song_url_capable() {
    // 上游 LX 脚本只注册 `request`; 能力声明与取链都必须照常工作.
    let transport = Arc::new(MockTransport::new().on(
        "example.test/api/song/url",
        reply(r#"{"url":"https://cdn.test/lx.mp3"}"#),
    ));
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/lx_request_event.js"),
        transport,
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");

    // 上游单入口: request 同时声明取链与歌词(脚本对某个 action 驳回时路由层回落内置).
    assert_eq!(
        provider.capabilities(),
        &[Capability::SongUrl, Capability::Lyric]
    );
    let request = SongUrlRequest {
        track: TrackId(99),
        level: AudioLevel::Exhigh,
        meta: None,
    };
    let stream = block_on(provider.song_url(&request)).expect("取链应成功");
    assert_eq!(stream.url.as_deref(), Some("https://cdn.test/lx.mp3"));
}

#[test]
fn lyric_maps_object_payload_and_sends_lyric_action() {
    // 上游 LX 的歌词返回: {lyric, tlyric}; 宿主要把它落成 ncm_domain::Lyric.
    let transport = Arc::new(MockTransport::new().on(
        "example.test/api/lyric",
        reply(r#"{"lyric":"[00:01.00]原文","tlyric":"[00:01.00]翻译"}"#),
    ));
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/lx_lyric.js"),
        transport.clone(),
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");
    assert!(provider.supports(Capability::Lyric));

    let lyric = block_on(provider.lyric(TrackId(42))).expect("歌词应成功");
    assert_eq!(lyric.lrc.as_deref(), Some("[00:01.00]原文"));
    assert_eq!(lyric.translated.as_deref(), Some("[00:01.00]翻译"));
    assert_eq!(lyric.romaji, None);

    // 发出的是 action:'lyric'(不是 musicUrl), info.type 也是 'lyric'.
    let seen = transport.requests();
    assert_eq!(seen.len(), 1);
    let body: serde_json::Value =
        serde_json::from_str(seen[0].body.as_deref().unwrap_or("null")).expect("请求体应是 JSON");
    assert_eq!(body["action"], "lyric");
    assert_eq!(body["type"], "lyric");
    assert_eq!(body["musicInfo"]["id"], 42);
    assert_eq!(body["source"], "wy", "按 inited.sources 挑平台代号");
}

#[test]
fn lyric_plain_string_is_lrc() {
    // 有的源只给原文一段纯字符串: 当 lrc, 翻译为空.
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/lx_lyric_plain.js"),
        Arc::new(MockTransport::new()),
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");
    let lyric = block_on(provider.lyric(TrackId(7))).expect("歌词应成功");
    assert_eq!(
        lyric.lrc.as_deref(),
        Some("[00:01.00]一句原文\n[00:05.00]另一句")
    );
    assert_eq!(lyric.translated, None);
}

#[test]
fn lyric_empty_payload_is_unsupported() {
    // 空 payload(lyric/tlyric 都是空串)与"没有歌词"同义: unsupported, 由路由回落内置.
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/lx_lyric_empty.js"),
        Arc::new(MockTransport::new()),
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");
    let err = block_on(provider.lyric(TrackId(3))).expect_err("空 payload 必须 unsupported");
    assert_eq!(err.kind, ProviderErrorKind::Unsupported);
    assert!(!err.retryable);
}

#[test]
fn lyric_without_request_handler_is_unsupported() {
    // 脚本没注册 request/lyric: 与"不提供歌词"同义(不是 internal).
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/music_url.js"),
        Arc::new(MockTransport::new()),
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");
    assert!(!provider.supports(Capability::Lyric));
    let err = block_on(provider.lyric(TrackId(1))).expect_err("没注册歌词事件");
    assert_eq!(err.kind, ProviderErrorKind::Unsupported);
}

#[test]
fn lyric_event_registered_directly_declares_lyric_only() {
    // 契约 v1 的宿主事件名(非上游单入口): 直接注册 lyric 只声明歌词能力.
    let provider = ScriptProvider::load(spec(
        "lx.on('lyric', function (source, info) { return { lyric: '[00:00.00]' + info.id }; });",
        Arc::new(MockTransport::new()),
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");
    assert_eq!(provider.capabilities(), &[Capability::Lyric]);
    let lyric = block_on(provider.lyric(TrackId(11))).expect("歌词应成功");
    assert_eq!(lyric.lrc.as_deref(), Some("[00:00.00]11"));
}

#[test]
fn song_url_passes_song_context_as_music_info() {
    // name/singer/interval 是「关键词中转」脚本的唯一入口; songmid/hash 是 kw/kg/QQ 系的兼容键.
    let transport = Arc::new(MockTransport::new().on(
        "example.test/api/echo",
        reply(r#"{"url":"https://cdn.test/meta.mp3"}"#),
    ));
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/music_info_echo.js"),
        transport.clone(),
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");

    let mut request = SongUrlRequest::new(TrackId(7));
    request.level = AudioLevel::Lossless;
    request = request.with_meta(ncm_provider::SongUrlMeta {
        name: "夜曲".into(),
        singer: "周杰伦".into(),
        album_name: "十一月的萧邦".into(),
        album_id: 12345,
        interval: 227,
        song_mid: Some("0039MnYb0qxYhV".into()),
    });
    let stream = block_on(provider.song_url(&request)).expect("取链应成功");
    assert_eq!(stream.url.as_deref(), Some("https://cdn.test/meta.mp3"));

    let seen = transport.requests();
    assert_eq!(seen.len(), 1);
    let body: serde_json::Value =
        serde_json::from_str(seen[0].body.as_deref().unwrap_or("null")).expect("请求体应是 JSON");
    let info = &body["info"];
    assert_eq!(info["name"], "夜曲");
    assert_eq!(info["singer"], "周杰伦");
    assert_eq!(info["albumName"], "十一月的萧邦");
    assert_eq!(info["albumId"], 12345);
    assert_eq!(info["interval"], 227);
    assert_eq!(info["songmid"], "0039MnYb0qxYhV");
    assert_eq!(info["hash"], "0039MnYb0qxYhV");
    assert_eq!(info["id"], 7);
    assert_eq!(info["type"], "flac");
    assert_eq!(body["quality"], "flac");
    assert_eq!(body["source"], "script");
}

#[test]
fn song_url_without_meta_sends_empty_context() {
    // 没传上下文时字段仍在(空串/0), 脚本不必额外判空.
    let transport = Arc::new(MockTransport::new().on(
        "example.test/api/echo",
        reply(r#"{"url":"https://cdn.test/plain.mp3"}"#),
    ));
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/music_info_echo.js"),
        transport.clone(),
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");

    let request = SongUrlRequest {
        track: TrackId(9),
        level: AudioLevel::Exhigh,
        meta: None,
    };
    block_on(provider.song_url(&request)).expect("取链应成功");
    let seen = transport.requests();
    let body: serde_json::Value =
        serde_json::from_str(seen[0].body.as_deref().unwrap_or("null")).expect("请求体应是 JSON");
    assert_eq!(body["info"]["name"], "");
    assert_eq!(body["info"]["interval"], 0);
    assert!(
        body["info"].get("songmid").is_none(),
        "没有 songmid 就别造一个"
    );
}

#[test]
fn declared_sources_come_from_inited_handshake() {
    // 上游 LX 的 `send('inited', {sources})` 是脚本自报平台的唯一来源; 宿主只读不改路由.
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/inited_sources.js"),
        Arc::new(MockTransport::new()),
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");

    assert_eq!(
        provider.declared_sources(),
        vec!["kw".to_string(), "tx".to_string(), "wy".to_string()],
        "按字典序去重, 与 sources 的 key 一一对应"
    );
    assert_eq!(provider.name(), "demo");
    assert!(provider.supports(Capability::SongUrl));
}

#[test]
fn declared_sources_is_empty_without_inited() {
    // 没发 inited(或形状不对)就是空: 不猜、不报错.
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/music_url.js"),
        Arc::new(MockTransport::new()),
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");
    assert!(provider.declared_sources().is_empty());
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
    assert_eq!(
        song.album.as_ref().map(|a| a.name.as_str()),
        Some("十一月的萧邦")
    );
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
    let transport =
        Arc::new(MockTransport::new().on("example.test/api/song/url", reply(r#"{"url":null}"#)));
    let provider = ScriptProvider::load(spec(
        include_str!("fixtures/music_url.js"),
        transport,
        SandboxConfig::default(),
    ))
    .expect("插件应加载成功");
    let request = SongUrlRequest {
        track: TrackId(1),
        level: AudioLevel::Standard,
        meta: None,
    };
    let err = block_on(provider.song_url(&request)).expect_err("脚本返回 null 时应 notFound");
    assert_eq!(err.kind, ProviderErrorKind::NotFound);
    assert!(!err.retryable);
}
