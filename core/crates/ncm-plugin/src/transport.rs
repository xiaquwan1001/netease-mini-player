//! 出站网络的最小注入面: 插件只能经 `lx.request` 走宿主注入的 [`Transport`].
//!
//! 本切片**不接真实网络**: 生产集成留到后续切片(见 README「未做项」),
//! 测试/回归台用 [`MockTransport`] 在内存里应答.
//!
//! 为什么是同步 trait: 宿主把插件放在自己的 worker 线程上跑, JS 侧的
//! `lx.request` 以 Promise 形式暴露给脚本, 但底层实现是同步阻塞的 —— 这样
//! 沙箱里不存在"半个请求在飞"的中间态, 超时/预算裁决点只有一个.

use std::sync::Mutex;

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

/// transport 层失败(网络/DNS/TLS/超时).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportError {
    pub message: String,
    /// 传输层是否值得重试(连接失败=true, 4xx/证书错误=false ...).
    pub retryable: bool,
}

impl TransportError {
    pub fn new(message: impl Into<String>, retryable: bool) -> Self {
        Self {
            message: message.into(),
            retryable,
        }
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
