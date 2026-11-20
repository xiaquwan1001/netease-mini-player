//! 沙箱层用例: 事件分发 / 请求注入 / 预算(时间·内存·次数·体积) / storage 隔离 / 逃逸面.
//!
//! 说明: `ScriptEngine` 是 `!Send`(rquickjs 未开 parallel feature), 所以所有
//! "可能挂住"的用例都在**子线程内部**建引擎, 外层用 `recv_timeout` 当守护时限 ——
//! 预算没生效时用例会以"守护时限触发"失败, 而不是把整个 test 进程挂死.

use std::sync::{mpsc, Arc};
use std::time::Duration;

use ncm_plugin::{
    DomainPolicy, GuardedTransport, MemoryStorage, MockTransport, Permissions, PluginError,
    PluginErrorKind, SandboxConfig, ScriptEngine, Transport, TransportError, TransportResponse,
};
use serde_json::{json, Value};

fn cfg() -> SandboxConfig {
    SandboxConfig {
        call_timeout: Duration::from_millis(300),
        memory_limit_bytes: 8 * 1024 * 1024,
        ..SandboxConfig::default()
    }
}

fn ok(body: &str) -> TransportResponse {
    TransportResponse {
        status: 200,
        headers: vec![],
        body: body.to_string(),
    }
}

fn engine_with(
    source: &str,
    transport: Arc<dyn Transport>,
    storage: Arc<MemoryStorage>,
    config: SandboxConfig,
    namespace: &str,
) -> ScriptEngine {
    ScriptEngine::new(source, config, transport, storage, namespace).expect("engine 装载失败")
}

fn engine(source: &str) -> ScriptEngine {
    engine_with(
        source,
        Arc::new(MockTransport::new()),
        Arc::new(MemoryStorage::new()),
        cfg(),
        "test",
    )
}

/// 在子线程里建引擎并调用一次; 超过 `guard` 没回来 = 预算没生效.
fn invoke_with_guard(
    source: &'static str,
    event: &'static str,
    args: Value,
    guard: Duration,
) -> Result<Value, PluginError> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut engine = engine(source);
        let _ = tx.send(engine.invoke(event, args));
    });
    match rx.recv_timeout(guard) {
        Ok(result) => result,
        Err(_) => panic!("沙箱在守护时限 {guard:?} 内没有返回: 时间/内存预算未生效(红相)"),
    }
}

#[test]
fn music_url_dispatch_and_request_injection() {
    let transport = Arc::new(MockTransport::new().on(
        "example.test/api/song/url",
        Ok(ok(r#"{"url":"https://cdn.test/a.mp3","br":320000}"#)),
    ));
    let mut engine = engine_with(
        include_str!("fixtures/music_url.js"),
        transport.clone(),
        Arc::new(MemoryStorage::new()),
        cfg(),
        "test",
    );

    let out = engine
        .invoke("musicUrl", json!(["script", { "id": 42 }, "320k"]))
        .expect("musicUrl 应成功");
    assert_eq!(out["url"], "https://cdn.test/a.mp3");
    assert_eq!(out["br"], 320000);
    assert_eq!(out["type"], "mp3");

    let seen = transport.requests();
    assert_eq!(seen.len(), 1, "脚本应该正好发一次请求");
    assert_eq!(seen[0].method, "POST", "method 必须原样透传");
    assert_eq!(seen[0].body.as_deref(), Some("level=320k"));
    assert_eq!(
        seen[0].headers,
        vec![("User-Agent".to_string(), "minincm-plugin/1".to_string())]
    );

    let logs = engine.take_logs();
    assert!(
        logs.iter().any(|line| line.contains("resolve")),
        "lx.log 必须落到宿主日志: {logs:?}"
    );
}

#[test]
fn transport_error_surfaces_as_script_error() {
    let transport = Arc::new(MockTransport::new().on(
        "example.test/api/song/url",
        Err(TransportError::new("dns boom", true)),
    ));
    let mut engine = engine_with(
        include_str!("fixtures/music_url.js"),
        transport,
        Arc::new(MemoryStorage::new()),
        cfg(),
        "test",
    );
    let err = engine
        .invoke("musicUrl", json!(["script", { "id": 1 }, "320k"]))
        .expect_err("transport 报错时脚本会 reject");
    assert_eq!(err.kind, PluginErrorKind::Script);
    assert!(err.detail.contains("dns boom"), "detail: {}", err.detail);
}

#[test]
fn timeout_interrupts_infinite_loop() {
    let err = invoke_with_guard(
        include_str!("fixtures/loop.js"),
        "musicUrl",
        json!([]),
        Duration::from_secs(10),
    )
    .expect_err("死循环必须被时间预算打断");
    assert_eq!(err.kind, PluginErrorKind::Timeout, "detail: {}", err.detail);
    assert!(err.retryable, "超时对上层是可重试的");
}

#[test]
fn memory_limit_stops_memory_bomb() {
    let err = invoke_with_guard(
        include_str!("fixtures/memory_bomb.js"),
        "musicUrl",
        json!([]),
        Duration::from_secs(30),
    )
    .expect_err("内存炸弹必须被内存上限拒绝");
    assert_eq!(err.kind, PluginErrorKind::Memory, "detail: {}", err.detail);
}

#[test]
fn storage_is_namespaced_between_plugins() {
    let storage = Arc::new(MemoryStorage::new());
    let mut a = engine_with(
        include_str!("fixtures/storage.js"),
        Arc::new(MockTransport::new()),
        storage.clone(),
        cfg(),
        "ns-a",
    );
    let mut b = engine_with(
        include_str!("fixtures/storage.js"),
        Arc::new(MockTransport::new()),
        storage.clone(),
        cfg(),
        "ns-b",
    );

    a.invoke("musicUrl", json!(["script", { "write": "alpha" }]))
        .expect("写 storage 应成功");
    let read_a = a
        .invoke("musicUrl", json!(["script", {}]))
        .expect("读 storage 应成功");
    let read_b = b
        .invoke("musicUrl", json!(["script", {}]))
        .expect("另一个 namespace 读 storage 应成功");

    assert_eq!(read_a["value"], "alpha");
    assert_eq!(read_a["keys"], json!(["k"]));
    assert_eq!(read_b["value"], Value::Null, "namespace 之间必须隔离");
    assert_eq!(read_b["keys"], json!([]));
}

#[test]
fn storage_persists_between_calls_in_one_engine() {
    let mut engine = engine(include_str!("fixtures/storage.js"));
    engine
        .invoke("musicUrl", json!(["script", { "write": 7 }]))
        .expect("写 storage 应成功");
    let read = engine
        .invoke("musicUrl", json!(["script", {}]))
        .expect("读 storage 应成功");
    assert_eq!(read["value"], 7);
}

#[test]
fn request_count_budget_is_enforced() {
    let transport = Arc::new(MockTransport::new().on("example.test", Ok(ok("{}"))));
    let config = SandboxConfig {
        max_requests_per_call: 3,
        ..cfg()
    };
    let mut engine = engine_with(
        include_str!("fixtures/budget.js"),
        transport.clone(),
        Arc::new(MemoryStorage::new()),
        config,
        "test",
    );
    let err = engine
        .invoke("musicUrl", json!([]))
        .expect_err("第 4 次请求必须被拒");
    assert!(err.detail.contains("上限"), "detail: {}", err.detail);
    assert_eq!(transport.requests().len(), 3, "只有预算内的请求能出站");
}

/// 白名单拒绝的请求**照常消耗** `lx.request` 预算(`src/policy.rs` 顶部「预算语义」的钉子).
///
/// 判据是二选一的强断言: 两次越界被拒后, 第 3 次(域名已合法)必须先撞次数预算 ——
/// 只要实现把 `requests += 1` 挪到 transport 成功之后, 第 3 次就会真的出站, 用例立即变红。
/// 顺带钉住拒绝文案的可诊断性: 脚本收到的错误里带被拒主机 + 已声明的白名单。
#[test]
fn denied_request_still_consumes_request_budget() {
    let mock = Arc::new(MockTransport::new().on("api.example.com", Ok(ok("{}"))));
    let policy = DomainPolicy::from_permissions(&Permissions {
        lx_events: vec!["musicUrl".to_string()],
        request_domains: vec!["api.example.com".to_string()],
    });
    let guarded: Arc<dyn Transport> = Arc::new(GuardedTransport::new(mock.clone(), policy));
    let config = SandboxConfig {
        max_requests_per_call: 2,
        ..cfg()
    };
    let mut engine = engine_with(
        include_str!("fixtures/denied_budget.js"),
        guarded,
        Arc::new(MemoryStorage::new()),
        config,
        "test",
    );
    let out = engine
        .invoke("musicUrl", json!([]))
        .expect("脚本自己吞掉了全部错误, 调用本身应成功");
    let errors: Vec<String> = serde_json::from_value(out).expect("脚本应返回错误文案数组");
    assert_eq!(errors.len(), 3, "三次请求都应拿到文案: {errors:?}");

    for (idx, text) in errors.iter().take(2).enumerate() {
        assert!(
            text.contains("denied.test"),
            "第 {idx} 次拒绝文案必须带被拒主机(插件作者要能自诊断): {text}"
        );
        assert!(
            text.contains("api.example.com"),
            "第 {idx} 次拒绝文案必须列出已声明的白名单: {text}"
        );
    }
    assert!(
        errors[2].contains("上限"),
        "第 3 次必须因预算耗尽被拒 —— 说明前两次被拒的请求也计费了: {}",
        errors[2]
    );
    assert!(
        !errors[2].starts_with("OK"),
        "域名合法的第 3 次不许真出站: {}",
        errors[2]
    );
    assert!(
        mock.requests().is_empty(),
        "被拒的两次一次都不许落到内层 transport, 第 3 次也不许: {:?}",
        mock.requests()
    );
}

/// 对照面: 沙箱**前置**拒的请求(非 http(s) scheme)**不**消耗预算 —— 那几处 `return Err`
/// 都在 `requests += 1` 之前。与上一条合起来才是完整口径: *能走到 transport 的*被拒请求计费,
/// 连沙箱都过不了的请求不计费(`src/policy.rs` 模块头「预算语义」的钉子)。
#[test]
fn sandbox_level_rejection_does_not_consume_budget() {
    let mock = Arc::new(MockTransport::new().on("api.example.com", Ok(ok("{}"))));
    let config = SandboxConfig {
        max_requests_per_call: 1,
        ..cfg()
    };
    let mut engine = engine_with(
        include_str!("fixtures/sandbox_denied_budget.js"),
        mock.clone(),
        Arc::new(MemoryStorage::new()),
        config,
        "test",
    );
    let out = engine
        .invoke("musicUrl", json!([]))
        .expect("脚本自己吞掉错误");
    let out: Vec<String> = serde_json::from_value(out).expect("脚本应返回文案数组");
    assert!(
        out[0].contains("http/https"),
        "file:// 应该在沙箱层就被拒: {}",
        out[0]
    );
    assert_eq!(
        out[1], "OK 200",
        "上一次被拒不能吃掉预算 —— 否则这里会是「超过上限」: {out:?}"
    );
    assert_eq!(
        mock.requests().len(),
        1,
        "只有合法那一次能出站: {:?}",
        mock.requests()
    );
}

#[test]
fn request_scheme_allowlist_blocks_file_and_unknown() {
    let transport = Arc::new(MockTransport::new());
    let script = "lx.on('musicUrl', async () => { await lx.request({ url: 'file:///etc/passwd' }); return 'leak'; });";
    let mut engine = engine_with(
        script,
        transport.clone(),
        Arc::new(MemoryStorage::new()),
        cfg(),
        "test",
    );
    let err = engine
        .invoke("musicUrl", json!([]))
        .expect_err("file:// 必须被拒");
    assert!(err.detail.contains("http/https"), "detail: {}", err.detail);
    assert!(
        transport.requests().is_empty(),
        "被拒的请求不能到达 transport"
    );
}

#[test]
fn response_size_budget_is_enforced() {
    let body = "x".repeat(4096);
    let transport = Arc::new(MockTransport::new().on("example.test", Ok(ok(&body))));
    let config = SandboxConfig {
        max_response_bytes: 1024,
        ..cfg()
    };
    let script = "lx.on('musicUrl', async () => { const r = await lx.request({ url: 'https://example.test/big' }); return r.body.length; });";
    let mut engine = engine_with(
        script,
        transport,
        Arc::new(MemoryStorage::new()),
        config,
        "test",
    );
    let err = engine
        .invoke("musicUrl", json!([]))
        .expect_err("超大响应必须被拒");
    assert!(err.detail.contains("响应体"), "detail: {}", err.detail);
}

#[test]
fn sandbox_has_no_host_escape_hatch() {
    let mut engine = engine(include_str!("fixtures/escape.js"));
    let out = engine.invoke("musicUrl", json!([])).expect("探针应成功");
    for key in [
        "require",
        "process",
        "fetch",
        "XMLHttpRequest",
        "Deno",
        "module",
    ] {
        assert_eq!(out[key], "undefined", "{key} 不应出现在沙箱里: {out}");
    }
}

#[test]
fn utils_crypto_md5_matches_known_vectors() {
    let mut engine = engine(include_str!("fixtures/md5.js"));
    let out = engine.invoke("musicUrl", json!([])).expect("md5 应成功");
    assert_eq!(out["abc"], "900150983cd24fb0d6963f7d28e17f72");
    assert_eq!(out["empty"], "d41d8cd98f00b204e9800998ecf8427e");
}

#[test]
fn missing_handler_maps_to_missing_handler_kind() {
    let mut engine = engine(include_str!("fixtures/music_url.js"));
    let err = engine
        .invoke("search", json!([{ "keywords": "x" }]))
        .expect_err("没注册的事件必须报错");
    assert_eq!(err.kind, PluginErrorKind::MissingHandler);
    assert_eq!(
        err.to_provider_error().kind,
        ncm_provider::ProviderErrorKind::Unsupported
    );
}

#[test]
fn script_throw_maps_to_internal() {
    let script = "lx.on('musicUrl', () => { throw new Error('boom'); });";
    let mut engine = engine(script);
    let err = engine
        .invoke("musicUrl", json!([]))
        .expect_err("脚本抛错应失败");
    assert_eq!(err.kind, PluginErrorKind::Script);
    assert!(err.detail.contains("boom"), "detail: {}", err.detail);
    assert_eq!(
        err.to_provider_error().kind,
        ncm_provider::ProviderErrorKind::Internal
    );
    assert!(!err.retryable);
}

#[test]
fn handlers_follow_registration_order() {
    let engine = engine(include_str!("fixtures/music_url.js"));
    assert_eq!(engine.handlers(), &["musicUrl".to_string()]);
}
