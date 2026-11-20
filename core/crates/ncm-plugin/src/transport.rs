//! 出站网络的最小注入面: 插件只能经 `lx.request` 走宿主注入的 [`Transport`].
//!
//! 生产实现挂在 `ncm-service`(`ncm_service::plugins::ReqwestTransport`, 复用 service 既有的
//! UA/连接超时/读超时/重试口径); 本 crate 只留 trait 与测试用 [`MockTransport`] ——
//! 依赖方向是 `ncm-service -> ncm-plugin`, 反向不成立, 宿主 HTTP 栈不许下沉到这里.
//!
//! 为什么是同步 trait: 宿主把插件放在自己的 worker 线程上跑, JS 侧的
//! `lx.request` 以 Promise 形式暴露给脚本, 但底层实现是同步阻塞的 —— 这样
//! 沙箱里不存在"半个请求在飞"的中间态, 超时/预算裁决点只有一个.

use std::sync::Mutex;

use ncm_provider::{ProviderError, ProviderErrorKind};

/// 脚本发起的一次请求(宿主侧看到的最终形态).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TransportRequest {
    pub url: String,
    /// 大写方法名(脚本没给时默认 `GET`).
    pub method: String,
    /// 原样透传(脚本可自带 UA/Cookie), 宿主不做改写.
    pub headers: Vec<(String, String)>,
    pub body: Option<String>,
}

/// transport 的应答. `body` 已是 UTF-8 文本.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TransportResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

/// transport 层失败(网络/DNS/TLS/超时/非 2xx).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportError {
    pub message: String,
    /// 传输层是否值得重试(连接失败=true, 4xx/证书错误=false ...).
    pub retryable: bool,
    /// HTTP 状态码(非 2xx 时由实现填上); 纯传输失败(超时/断连)为 `None`.
    ///
    /// 有这个字段才能把"403 是直链失效"和"超时是网络抖动"分开映射到 ProviderError,
    /// 否则上层只能看到一句字符串.
    pub status: Option<u16>,
}

impl TransportError {
    /// 纯传输失败(没有 HTTP 状态码).
    pub fn new(message: impl Into<String>, retryable: bool) -> Self {
        Self {
            message: message.into(),
            retryable,
            status: None,
        }
    }

    /// 超时: 一律可重试(与官方 provider 的 network 超时同档).
    pub fn timeout(message: impl Into<String>) -> Self {
        Self::new(message, true)
    }

    /// 非 2xx 应答. 可重试口径与 `ncm_service::cache::DownloadFailure` 一致:
    /// 401/403/404 是"这个地址已经不能用了", 原样重试没有意义; 其余(5xx/429/…)可以再试.
    pub fn http_status(status: u16, message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            retryable: !matches!(status, 401 | 403 | 404),
            status: Some(status),
        }
    }

    /// 收口到产品既有的错误模型: 状态码能分档的按档给 kind, 纯网络失败一律 `network`.
    pub fn to_provider_error(&self) -> ProviderError {
        let kind = match self.status {
            Some(401 | 403) => ProviderErrorKind::Forbidden,
            Some(404) => ProviderErrorKind::NotFound,
            _ => ProviderErrorKind::Network,
        };
        ProviderError::new(kind, self.retryable, self.message.clone())
    }
}

/// 宿主注入的出站实现.
pub trait Transport: Send + Sync {
    fn send(&self, request: &TransportRequest) -> Result<TransportResponse, TransportError>;
}

type MockReply = Result<TransportResponse, TransportError>;

/// 内存 mock: 按 URL 子串匹配预置应答, 同时记录收到的全部请求.
#[derive(Default)]
pub struct MockTransport {
    inner: Mutex<MockState>,
}

#[derive(Default)]
struct MockState {
    routes: Vec<(String, MockReply)>,
    seen: Vec<TransportRequest>,
}

impl MockTransport {
    pub fn new() -> Self {
        Self::default()
    }

    /// 注册一条应答: URL **包含** `url_pattern` 时命中(先注册先匹配).
    pub fn on(self, url_pattern: impl Into<String>, reply: MockReply) -> Self {
        self.expect(url_pattern, reply);
        self
    }

    pub fn expect(&self, url_pattern: impl Into<String>, reply: MockReply) {
        self.lock().routes.push((url_pattern.into(), reply));
    }

    /// 收到的请求(按时间顺序), 用于断言 method/headers/body 是否原样透传.
    pub fn requests(&self) -> Vec<TransportRequest> {
        self.lock().seen.clone()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, MockState> {
        // 中毒即续用: 这是测试/可观测用的缓存锁, 与 docs/remaining-batches.md §4.1 口径一致.
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Transport for MockTransport {
    fn send(&self, request: &TransportRequest) -> Result<TransportResponse, TransportError> {
        let mut state = self.lock();
        state.seen.push(request.clone());
        state
            .routes
            .iter()
            .find(|(pattern, _)| request.url.contains(pattern.as_str()))
            .map(|(_, reply)| reply.clone())
            .unwrap_or_else(|| {
                Err(TransportError::new(
                    format!("mock: no route for {}", request.url),
                    false,
                ))
            })
    }
}
