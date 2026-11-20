//! 出站白名单的**公开 API 面**回归: 站在下游 crate(`ncm-service::plugins`)的位置证明够用.
//!
//! `src/policy.rs` 里的用例都写在 crate 内的 `mod tests`, 只能证明"crate 自己看着对";
//! 但真正的使用者只经 `ncm_plugin::` 的 `pub use` 拿到类型, 且注入面是 `Arc<dyn Transport>`
//! trait object 而不是具体类型. 一旦哪个导出被收窄、`TransportError` 的字段语义被改、
//! 或 `Permissions` 的结构变了, 内部用例全绿而下游编译不过/语义漂移 —— 这个文件就是那道探针.
//!
//! 逐条边界(域名标签、scheme、IPv6 字面量)在 `src/policy.rs` 已经覆盖, 这里不重复,
//! 只断言"清单结构 -> 策略 -> trait object 通道 -> ProviderError 分档"这条跨界路径.

use std::sync::Arc;

use ncm_plugin::{
    DomainPolicy, GuardedTransport, MockTransport, Permissions, PluginManifest, Transport,
    TransportRequest, TransportResponse,
};

fn ok_response() -> TransportResponse {
    TransportResponse {
        status: 200,
        headers: Vec::new(),
        body: "ok".to_string(),
    }
}

fn get(url: &str) -> TransportRequest {
    TransportRequest {
        url: url.to_string(),
        method: "GET".to_string(),
        headers: Vec::new(),
        body: None,
    }
}

/// 下游真实路径: 清单 JSON -> `PluginManifest::parse` -> `Permissions` -> `DomainPolicy`.
///
/// 断言点: 结构体字段是 `pub` 可读可造、`from_permissions` 只吃不超出清单的域名.
#[test]
fn policy_from_permissions_matches_declared_domains_only() {
    let manifest = PluginManifest::parse(
        r#"{
            "id": "demo-lx",
            "name": "Demo 插件",
            "version": "1.0.0",
            "entry": "main.js",
            "permissions": {
                "lxEvents": ["musicUrl"],
                "requestDomains": ["api.example.com", "*.cdn.test"]
            }
        }"#,
    )
    .expect("清单应通过校验");

    // 下游就是这么读的: 字段公开, 不需要任何 crate 内辅助函数.
    let domains = &manifest.permissions.request_domains;
    assert_eq!(domains.len(), 2, "清单里的两条域名应原样可见: {domains:?}");

    let policy = DomainPolicy::from_permissions(&manifest.permissions);
    assert!(!policy.is_empty(), "声明了域名就不是空策略");
    assert!(
        policy.allows("https://api.example.com/song/url?id=1"),
        "清单声明的精确主机应放行"
    );
    assert!(
        policy.allows("https://a.b.cdn.test/x"),
        "清单声明的 `*.cdn.test` 应覆盖多级子域"
    );
    assert!(
        !policy.allows("https://evil.example.com/x"),
        "未声明的同级主机不许借着精确规则越界"
    );
    assert!(
        !policy.allows("https://cdn.test.evil/x"),
        "`*.cdn.test` 不许被后缀伪装骗过"
    );

    // `Permissions` 也可由下游直接构造(内存里的插件/测试夹具), 语义与解析路径一致.
    let hand_built = Permissions {
        lx_events: Vec::new(),
        request_domains: vec!["api.example.com".to_string()],
    };
    let hand_policy = DomainPolicy::from_permissions(&hand_built);
    assert!(
        hand_policy.allows("https://api.example.com/x") && !hand_policy.allows("https://a.api.example.com/x"),
        "手工构造的 Permissions 必须与清单解析出的同义"
    );
}

/// 宿主注入面是 `Arc<dyn Transport>`: 包了守卫之后仍然能当 trait object 用,
/// 且被拒的请求**根本走不到**内层 transport.
#[test]
fn guard_works_as_trait_object_and_denies_before_inner() {
    let mock = Arc::new(MockTransport::new());
    mock.expect("api.example.com", Ok(ok_response()));

    let policy = DomainPolicy::from_permissions(&Permissions {
        lx_events: Vec::new(),
        request_domains: vec!["api.example.com".to_string()],
    });
    // 下游(manager.rs)就是这么装配的: 内层是 trait object, 守卫自己也塞进 trait object.
    let inner: Arc<dyn Transport> = mock.clone();
    let guarded: Arc<dyn Transport> = Arc::new(GuardedTransport::new(inner, policy));

    let err = guarded
        .send(&get("https://evil.test/steal?token=1"))
        .expect_err("越界主机必须被 trait object 这一层拒掉");
    assert!(!err.retryable, "白名单拒绝不是重试类错误");
    assert_eq!(err.status, None, "白名单拒绝没有 HTTP 状态码");
    assert!(
        mock.requests().is_empty(),
        "被拒请求不许落到内层 transport: {:?}",
        mock.requests()
    );

    let resp = guarded
        .send(&get("https://api.example.com/url?id=42"))
        .expect("白名单内的请求应原样转发");
    assert_eq!(resp.status, 200, "内层应答应原样返回");
    assert_eq!(
        mock.requests(),
        vec![get("https://api.example.com/url?id=42")],
        "只有放行的那一条进内层, 且请求体未被改写"
    );
}

/// 越界拒绝跨到产品错误模型: `Network` + 不可重试 + 无状态码(上层换源而非原地重试).
#[test]
fn denial_maps_to_network_provider_error_non_retryable() {
    let mock = Arc::new(MockTransport::new());
    mock.expect("api.example.com", Ok(ok_response()));
    let guarded = GuardedTransport::new(
        mock.clone(),
        DomainPolicy::from_permissions(&Permissions {
            lx_events: Vec::new(),
            request_domains: vec!["*.example.com".to_string()],
        }),
    );

    let err = guarded
        .send(&get("https://evil.test/x"))
        .expect_err("`*.example.com` 不覆盖 evil.test");
    assert!(!err.retryable, "拒绝必须是不可重试的");
    assert_eq!(err.status, None, "拒绝不带 HTTP 状态码");
    assert!(
        !err.message.is_empty(),
        "拒绝原因必须可读(给脚本回错误文案用)"
    );
    assert!(
        err.message.contains("evil.test"),
        "拒绝文案必须带被拒的主机名(插件作者靠它自诊断): {}",
        err.message
    );
    assert!(
        err.message.contains("*.example.com"),
        "拒绝文案必须列出已声明的白名单, 否则作者只能去翻清单: {}",
        err.message
    );

    let provider_error = err.to_provider_error();
    assert_eq!(
        provider_error.kind,
        ncm_provider::ProviderErrorKind::Network,
        "白名单拒绝应归到 network 档(不是 forbidden/not_found)"
    );
    assert!(
        provider_error.detail.contains("evil.test")
            && provider_error.detail.contains("*.example.com"),
        "落到 ProviderError.detail 的文案同样要带主机名 + 已声明白名单: {}",
        provider_error.detail
    );
    assert!(
        !provider_error.retryable,
        "ProviderError 也必须标不可重试, 否则上层会为越界请求反复换源重试"
    );
    assert!(
        mock.requests().is_empty(),
        "拒绝路径不许发出去任何字节: {:?}",
        mock.requests()
    );
}

/// 没写 `permissions` 的插件 = 空策略 = 全拒, 且这个状态对外可观测(`is_empty`).
#[test]
fn manifest_without_permissions_yields_empty_denying_policy() {
    let manifest = PluginManifest::parse(
        r#"{
            "id": "no-perm",
            "name": "无权限声明",
            "version": "0.0.1",
            "entry": "main.js"
        }"#,
    )
    .expect("`permissions` 可省略");

    let policy = DomainPolicy::from_permissions(&manifest.permissions);
    assert!(policy.is_empty(), "未声明域名就是空策略");
    assert_eq!(
        policy,
        DomainPolicy::default(),
        "空清单策略必须与 default() 等价(下游可据此跳过包一层守卫)"
    );

    let mock = Arc::new(MockTransport::new());
    mock.expect("api.example.com", Ok(ok_response()));
    let guarded = GuardedTransport::new(mock.clone(), policy);
    assert!(
        guarded.policy().is_empty(),
        "守卫必须暴露自己拿到的策略(宿主日志/汇总用)"
    );

    let err = guarded
        .send(&get("https://api.example.com/x"))
        .expect_err("空白名单 = 任何出站都拒");
    assert!(!err.retryable, "空白名单的拒绝同样不可重试");
    assert_eq!(err.status, None, "空白名单的拒绝同样没有状态码");
    assert!(
        mock.requests().is_empty(),
        "空策略下内层 transport 一次都不该被调用: {:?}",
        mock.requests()
    );
}
