//! 出站域名白名单(切片 2 第三步): 把清单里的 `permissions.requestDomains` 变成**真判据**.
//!
//! # 为什么这一层必须在这里
//!
//! 沙箱只留一条出站通道([`Transport`]), 所以"插件能不能访问某个域名"只能在通道口裁决:
//! 把宿主注入的 transport 包一层 [`GuardedTransport`], 越界请求**在发出去之前**就被拒
//! (拒绝不是重试类错误, 上层不会为此换源重试)。宿主 HTTP 栈、UA、超时口径一概不变。
//!
//! 口径(与 `manifest::validate_domain` 的写入规则一一对应):
//!
//! | `requestDomains` 项 | 匹配 | 不匹配 |
//! |---|---|---|
//! | `api.example.com` | 恰好 `api.example.com` | `x.api.example.com` / `example.com` / `api.example.com.evil` |
//! | `*.example.org` | 标签边界内的**自身与任意子域** `example.org` / `a.example.org` / `a.b.example.org` | `evil-example.org` / `example.org.evil` |
//! | 空列表(或没写 `permissions`) | —— | **任何**出站都被拒(未声明白名单 = 不出站) |
//!
//! 主机名比较一律小写 + 去掉末尾的点(FQDN 根点), 端口/路径/查询串/`userinfo` 不参与匹配
//! (`https://api.example.com:8443/x?y` 只看 `api.example.com`)。
//!
//! # 只认 http/https
//!
//! `file://`、`data:`、`ftp://` 这类"没有主机"或不该由插件宿主发起的 scheme 一律拒,
//! 即使白名单里写了 `localhost` 也一样 —— 白名单不是 scheme 的放行条。
//!
//! # 明确未做
//!
//! - 不做 IP 段/端口粒度授权(白名单只到主机名, 与清单校验的范围一致);
//! - 不做"按脚本粒度"授权: 一个插件一份白名单, 同插件内所有 `lx.request` 共用;
//! - 拒绝**只记在返回的错误里**, 不写落盘审计日志(接线切片再接诊断通道)。
//!
//! # 拒绝文案([`DomainPolicy::deny_reason`])
//!
//! 文案要能让插件作者自诊断, 固定带两件东西: **被拒的主机名** + **已声明的白名单规则**
//! ([`DomainPolicy::rules_summary`], 最多 `manifest::MAX_DOMAINS` = 16 条)。URL 的 path /
//! 查询串 / userinfo 一概不进文案 —— 脚本常把 token 放查询串里, 拒绝理由不该顺手抄进日志。
//!
//! # 预算语义(与 [`sandbox`](crate::sandbox) 的 `HostState::request` 对齐)
//!
//! **已经走到 transport 的请求照常消耗一次 `lx.request` 预算**, 哪怕它在通道口就被白名单拒:
//! 沙箱先 `requests += 1` 再调 transport, 所以"越界域名被拒"与"放行后网络失败"花掉的
//! 次数一样。反过来("被拒不计费")会变成绕预算的通道 —— 脚本能无限撞白名单而不花预算。
//!
//! 对称地有一处**不对称**: 沙箱自己能提前判死的请求(非法 JSON / 非 http(s) scheme /
//! headers 不合法)**不计数** —— `HostState::request` 里那几处 `return Err` 都在计数自增之前,
//! 因此它们连白名单那一层都到不了。两边语义各自有钉子:
//! `tests/sandbox.rs::denied_request_still_consumes_request_budget`(白名单拒 = 计费)与
//! `sandbox_level_rejection_does_not_consume_budget`(沙箱前置拒 = 不计费)。
//! 改沙箱里的自增位置必须同时跑这两条。

use std::sync::Arc;

use crate::manifest::Permissions;
use crate::transport::{Transport, TransportError, TransportRequest, TransportResponse};

/// 白名单的一条规则(已小写化).
#[derive(Debug, Clone, PartialEq, Eq)]
enum Rule {
    /// 精确主机名.
    Exact(String),
    /// `*.host`: `host` 自身与标签边界内的任意子域.
    Subtree(String),
}

/// 一个插件的出站白名单. 空策略 = 拒绝一切出站.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DomainPolicy {
    rules: Vec<Rule>,
}

impl DomainPolicy {
    /// 从清单的 `permissions.requestDomains` 建策略(清单校验已通过, 这里仍做防御性解析).
    pub fn from_permissions(perms: &Permissions) -> Self {
        Self::from_domains(perms.request_domains.iter().map(String::as_str))
    }

    /// 从域名项建策略. 非法项(空串/含空白)直接丢弃 —— 它们本来就过不了清单校验,
    /// 丢弃等价于"这一条不用", 比 panic 或"放行"都安全.
    pub fn from_domains<'a, I>(domains: I) -> Self
    where
        I: IntoIterator<Item = &'a str>,
    {
        let mut rules = Vec::new();
        for domain in domains {
            let domain = domain.trim();
            if domain.is_empty() || domain.chars().any(char::is_whitespace) {
                continue;
            }
            let (subtree, body) = match domain.strip_prefix("*.") {
                Some(rest) => (true, rest),
                None => (false, domain),
            };
            let body = normalize_host(body);
            if body.is_empty() {
                continue;
            }
            rules.push(if subtree {
                Rule::Subtree(body)
            } else {
                Rule::Exact(body)
            });
        }
        Self { rules }
    }

    /// 一条规则都没声明: 出站全拒.
    pub fn is_empty(&self) -> bool {
        self.rules.is_empty()
    }

    /// 该 URL 是否可以出站. 无法解析出 http/https 主机名的 URL 一律 false.
    pub fn allows(&self, url: &str) -> bool {
        match host_of(url) {
            Some(host) => self.allows_host(&host),
            None => false,
        }
    }

    /// 已解析出的主机是否能出站(测试/宿主日志用).
    pub fn allows_host(&self, host: &str) -> bool {
        let host = normalize_host(host);
        if host.is_empty() {
            return false;
        }
        self.rules.iter().any(|rule| match rule {
            Rule::Exact(name) => *name == host,
            Rule::Subtree(suffix) => {
                host == *suffix
                    || (host.len() > suffix.len()
                        && host.ends_with(suffix.as_str())
                        && host.as_bytes()[host.len() - suffix.len() - 1] == b'.')
            }
        })
    }

    /// 已声明规则的可读形态(`api.example.com` / `*.example.org`), 顺序同清单.
    ///
    /// 给拒绝文案([`Self::deny_reason`])与宿主日志用: 让插件作者一眼看出"我声明的是什么"。
    /// 空策略返回空串(文案走另一档, 见 [`Self::deny_reason`])。
    pub fn rules_summary(&self) -> String {
        self.rules
            .iter()
            .map(|rule| match rule {
                Rule::Exact(name) => name.clone(),
                Rule::Subtree(suffix) => format!("*.{suffix}"),
            })
            .collect::<Vec<_>>()
            .join(", ")
    }

    /// 拒绝时给人看的原因(给 `TransportError::message` 用, 不含 URL 里的凭据).
    ///
    /// 两档文案都带**被拒的主机名**; 非空策略还列出**已声明的白名单**, 让脚本作者不翻清单
    /// 就能区分"没声明"与"声明写错了"(`*.example.com` 并不跨到 `evil.test`)。
    pub fn deny_reason(&self, url: &str) -> String {
        let host = host_of(url).unwrap_or_else(|| "<无主机>".to_string());
        if self.is_empty() {
            format!("出站被拒: 主机 `{host}` 不在白名单内(插件未声明 permissions.requestDomains)")
        } else {
            format!(
                "出站被拒: 主机 `{host}` 不匹配 permissions.requestDomains 里任何一条(已声明: {})",
                self.rules_summary()
            )
        }
    }
}

impl DomainPolicy {
    /// 该 URL 出站前的裁决; `Ok(())` 才允许发.
    pub fn check(&self, url: &str) -> Result<(), String> {
        if self.allows(url) {
            Ok(())
        } else {
            Err(self.deny_reason(url))
        }
    }
}

/// 把域名规范成比较形态: 小写 + 去末尾的点.
fn normalize_host(host: &str) -> String {
    host.trim().trim_end_matches('.').to_ascii_lowercase()
}

/// 从 URL 里取主机名(小写). 只接受 http/https, 其余 scheme 返回 `None`.
pub fn host_of(url: &str) -> Option<String> {
    let (scheme, rest) = url.trim().split_once("://")?;
    if !(scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https")) {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next()?;
    // 去掉 userinfo(脚本可能带 token@host 形态), 只保留主机部分.
    let host_port = match authority.rsplit_once('@') {
        Some((_, host)) => host,
        None => authority,
    };
    let host = if let Some(inner) = host_port.strip_prefix('[') {
        // IPv6 字面量: [::1]:8080 —— 取方括号内的部分.
        let end = inner.find(']')?;
        &inner[..end]
    } else {
        host_port.split(':').next()?
    };
    let host = normalize_host(host);
    if host.is_empty() {
        None
    } else {
        Some(host)
    }
}

/// 把宿主 transport 包一层白名单: 越界请求在**发出去之前**被拒.
///
/// 拒绝形态是 [`TransportError`] 且 `retryable = false`, `status = None`。两条消费路径不同,
/// 别把两者混为一谈:
///
/// - 宿主代码直接调本 trait object(或自己调 [`TransportError::to_provider_error`]):
///   → `ProviderErrorKind::Network` + `retryable = false`;
/// - 经沙箱的 `lx.request`(产品链路): 沙箱只把 `message` 回给脚本
///   ([`sandbox`](crate::sandbox) 的 `HostState::request`), 脚本没捕获就变成
///   `PluginErrorKind::Script` → `ProviderErrorKind::Internal`(`ncm-service` 的
///   `manager_tests` 把这条口径写死为"白名单拒绝 = Internal + 不重试")。
///
/// 两条路径共同保证的只有两件: **文案带被拒主机 + 已声明白名单**, 且**不重试**。
/// `lx.request` 预算: 走到这里的请求已经计过费(见模块头「预算语义」)。
pub struct GuardedTransport {
    inner: Arc<dyn Transport>,
    policy: Arc<DomainPolicy>,
}

impl GuardedTransport {
    pub fn new(inner: Arc<dyn Transport>, policy: DomainPolicy) -> Self {
        Self {
            inner,
            policy: Arc::new(policy),
        }
    }

    /// 本实例的策略(宿主做日志/汇总时读).
    pub fn policy(&self) -> &DomainPolicy {
        &self.policy
    }
}

impl std::fmt::Debug for GuardedTransport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GuardedTransport")
            .field("rules", &self.policy.rules.len())
            .finish_non_exhaustive()
    }
}

impl Transport for GuardedTransport {
    fn send(&self, request: &TransportRequest) -> Result<TransportResponse, TransportError> {
        if let Err(reason) = self.policy.check(&request.url) {
            return Err(TransportError::new(reason, false));
        }
        self.inner.send(request)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::MockTransport;

    fn policy(domains: &[&str]) -> DomainPolicy {
        DomainPolicy::from_domains(domains.iter().copied())
    }

    fn good_response() -> TransportResponse {
        TransportResponse {
            status: 200,
            headers: Vec::new(),
            body: "ok".to_string(),
        }
    }

    fn request(url: &str) -> TransportRequest {
        TransportRequest {
            url: url.to_string(),
            method: "GET".to_string(),
            headers: Vec::new(),
            body: None,
        }
    }

    #[test]
    fn exact_rule_matches_only_that_host() {
        let p = policy(&["api.example.com"]);
        assert!(p.allows("https://api.example.com/v1/url?id=1"));
        assert!(!p.allows("https://x.api.example.com/v1"));
        assert!(!p.allows("https://example.com/"));
        assert!(!p.allows("https://notapi.example.com/"));
    }

    #[test]
    fn exact_rule_ignores_port_path_query_case_and_fqdn_dot() {
        let p = policy(&["api.example.com"]);
        for url in [
            "https://API.Example.COM:8443/a/b?c=d#e",
            "http://api.example.com.",
            "https://user:pass@api.example.com/x",
        ] {
            assert!(p.allows(url), "{url} 应该放行");
        }
    }

    #[test]
    fn subtree_rule_covers_apex_and_subdomains() {
        let p = policy(&["*.example.org"]);
        for url in [
            "https://example.org/",
            "https://a.example.org/",
            "https://a.b.example.org/x",
        ] {
            assert!(p.allows(url), "{url} 应该放行");
        }
    }

    #[test]
    fn subtree_rule_respects_label_boundary() {
        let p = policy(&["*.example.org"]);
        for url in [
            "https://evil-example.org/",
            "https://example.org.evil/",
            "https://example.or/",
        ] {
            assert!(!p.allows(url), "{url} 必须被拒");
        }
    }

    #[test]
    fn empty_policy_denies_everything() {
        let p = DomainPolicy::default();
        assert!(p.is_empty());
        assert!(!p.allows("https://api.example.com/"));
        let reason = p.deny_reason("https://api.example.com/");
        assert!(reason.contains("未声明"), "{reason}");
    }

    #[test]
    fn non_http_schemes_are_always_denied() {
        let p = policy(&["localhost", "example.com"]);
        for url in [
            "file:///etc/passwd",
            "data:text/plain,hi",
            "ftp://example.com/x",
            "example.com/no-scheme",
        ] {
            assert!(!p.allows(url), "{url} 必须被拒");
        }
        assert!(host_of("file:///etc/passwd").is_none());
    }

    #[test]
    fn guard_denies_without_touching_inner_transport() {
        let mock = Arc::new(MockTransport::new());
        mock.expect("api.example.com", Ok(good_response()));
        let guard = GuardedTransport::new(mock.clone(), policy(&["api.example.com"]));

        let err = guard
            .send(&request("https://evil.test/steal"))
            .expect_err("越界域名必须被拒");
        assert!(!err.retryable);
        assert_eq!(err.status, None);
        assert!(err.message.contains("evil.test"), "{}", err.message);
        assert!(
            mock.requests().is_empty(),
            "被拒的请求不许真的发出去: {:?}",
            mock.requests()
        );
    }

    #[test]
    fn guard_forwards_allowed_request_unmodified() {
        let mock = Arc::new(MockTransport::new());
        mock.expect("api.example.com", Ok(good_response()));
        let guard = GuardedTransport::new(mock.clone(), policy(&["*.example.com"]));

        let mut req = request("https://api.example.com/url?id=42");
        req.method = "POST".to_string();
        req.body = Some("{\"a\":1}".to_string());
        req.headers = vec![("X-Test".to_string(), "1".to_string())];

        let resp = guard.send(&req).expect("白名单内应放行");
        assert_eq!(resp.status, 200);
        assert_eq!(mock.requests(), vec![req.clone()]);
    }

    #[test]
    fn guard_with_empty_policy_denies_and_is_not_retryable() {
        let mock = Arc::new(MockTransport::new());
        mock.expect("api.example.com", Ok(good_response()));
        let guard = GuardedTransport::new(mock.clone(), DomainPolicy::default());
        let err = guard
            .send(&request("https://api.example.com/"))
            .expect_err("空白名单 = 全拒");
        assert!(!err.retryable);
        let provider_error = err.to_provider_error();
        assert_eq!(
            provider_error.kind,
            ncm_provider::ProviderErrorKind::Network
        );
        assert!(!provider_error.retryable);
        assert!(mock.requests().is_empty());
    }

    #[test]
    fn deny_reason_names_host_and_declared_rules_but_not_url_secrets() {
        let p = policy(&["api.example.com", "*.cdn.test"]);
        let reason = p.deny_reason("https://evil.test/steal?token=s3cret#frag");
        assert!(
            reason.contains("evil.test"),
            "拒绝理由必须带被拒的主机: {reason}"
        );
        assert!(
            reason.contains("api.example.com") && reason.contains("*.cdn.test"),
            "拒绝理由必须列出已声明的白名单, 否则插件作者只能去翻清单: {reason}"
        );
        assert!(
            !reason.contains("s3cret"),
            "拒绝理由不许把 URL 查询串/凭据抄进去: {reason}"
        );
        assert_eq!(p.rules_summary(), "api.example.com, *.cdn.test");
    }

    #[test]
    fn deny_reason_for_empty_policy_says_nothing_declared() {
        let reason = DomainPolicy::default().deny_reason("https://evil.test/x");
        assert!(reason.contains("evil.test"), "{reason}");
        assert!(
            reason.contains("未声明"),
            "空策略要说清是「没声明」: {reason}"
        );
        assert_eq!(DomainPolicy::default().rules_summary(), "");
    }

    #[test]
    fn policy_from_permissions_uses_declared_domains() {
        let perms = Permissions {
            lx_events: vec!["musicUrl".to_string()],
            request_domains: vec!["api.example.com".to_string(), "*.cdn.test".to_string()],
        };
        let p = DomainPolicy::from_permissions(&perms);
        assert!(p.allows("https://api.example.com/x"));
        assert!(p.allows("https://a.cdn.test/x"));
        assert!(!p.allows("https://other.test/x"));
    }

    #[test]
    fn malformed_entries_are_dropped_not_widened() {
        let p = policy(&["", "  ", "has space.com", "*."]);
        assert!(p.is_empty(), "非法项不许变成放行: {p:?}");
        assert!(!p.allows("https://has space.com/"));
    }

    #[test]
    fn ip_literal_rules_match_exactly() {
        let p = policy(&["127.0.0.1"]);
        assert!(p.allows("http://127.0.0.1:8080/api"));
        assert!(!p.allows("http://127.0.0.2/api"));
    }

    #[test]
    fn host_of_handles_ipv6_and_authority_edges() {
        assert_eq!(host_of("http://[::1]:8080/x"), Some("::1".to_string()));
        assert_eq!(host_of("https://a.test?q=1"), Some("a.test".to_string()));
        assert_eq!(host_of("https://a.test#frag"), Some("a.test".to_string()));
        assert_eq!(host_of("https://"), None);
        assert_eq!(host_of("https:///path"), None);
    }
}
