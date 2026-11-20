//! 插件宿主的错误模型与到 ProviderError 的映射.
//!
//! 纪律: 脚本侧的任何失败都必须在宿主侧收口成 PluginError, 再按
//! ProviderError{kind,retryable,detail} 翻成产品既有的错误模型 —— UI 只按 kind 决策,
//! 所以插件不需要(也不允许)把 JS 异常原文直接冒到 UI.
//!
//! 映射表见 README「错误映射」; 改这里的 kind/retryable 等于改产品行为.
//!
//! # 为什么没有 `RequestDenied` / `Transport` 两个变体(分类收敛口径)
//!
//! 这两类曾经在枚举里占位, 但产品链路上**永远不会被构造**, 于是删掉并把落点写死:
//!
//! - **策略拒绝**(`GuardedTransport` 的白名单/预算): 走 `lx.request` 的产品链路里,
//!   沙箱只把 [`TransportError`](crate::TransportError) 的 `message` 交给脚本
//!   (`sandbox::HostState::request`); 脚本不捕获 ⇒ 以 JS 异常冒泡 ⇒ [`PluginErrorKind::Script`]
//!   ⇒ `Internal` + 不重试。宿主代码若**直接**调 trait object, 则是
//!   [`TransportError::to_provider_error`](crate::TransportError::to_provider_error) 的
//!   `Network` + 不重试 —— 两条路径都不经过本枚举, 所以这里不需要单独一类。
//! - **transport 层失败**(DNS/TLS/超时/非 2xx): 同样以 `message` 进脚本、以
//!   [`PluginErrorKind::Script`] 收口; 需要按状态码分档(`403 -> Forbidden`、`404 -> NotFound`)
//!   时由 [`TransportError::to_provider_error`](crate::TransportError::to_provider_error) 直接给
//!   `ProviderError`, 也不经过本枚举。
//! - 真正的"脚本侧超时"另有 [`PluginErrorKind::Timeout`] 一档(`Network` + 可重试)。
//!
//! 一句话: **失败分类收敛到 `Script` / `Network` / `Internal` 三个落点**(`Script`/`Protocol`/
//! `Memory`/`Load`/`Shutdown` -> `Internal`; `Timeout` -> `Network` 可重试; `Script` 覆盖了
//! 全部"脚本侧未捕获"的拒绝与网络错误), 不再为"是谁拒的"另开变体 —— 区分靠 `detail` 文案。
//!
//! 判据用例: `ncm-service` `manager_tests::undeclared_domain_request_is_denied_before_transport`
//! (产品链路 = `Internal` + 不重试), `ncm-plugin` `tests/sandbox.rs` 的
//! `policy_denial_kind_is_script_on_plugin_boundary`(插件边界 = `Script`)。

use ncm_provider::{ProviderError, ProviderErrorKind};

/// 插件宿主自己的错误分类(比 ProviderErrorKind 细, 便于日志与测试断言).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PluginErrorKind {
    /// 单次调用超过时间预算, 被 QuickJS interrupt 打断.
    Timeout,
    /// 撞到内存上限(QuickJS OOM).
    Memory,
    /// 脚本自己抛异常.
    Script,
    /// 脚本返回了宿主解析不了的值(形状不对).
    Protocol,
    /// 脚本没注册该事件.
    MissingHandler,
    /// 脚本明确表示取不到直链(返回 null / 空 url / 空结果).
    NoUrl,
    /// 加载/初始化阶段失败(语法错误、初始化超时、线程起不来).
    Load,
    /// 宿主 worker 线程已退出.
    Shutdown,
}

impl PluginErrorKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            PluginErrorKind::Timeout => "timeout",
            PluginErrorKind::Memory => "memoryLimit",
            PluginErrorKind::Script => "script",
            PluginErrorKind::Protocol => "protocol",
            PluginErrorKind::MissingHandler => "missingHandler",
            PluginErrorKind::NoUrl => "noUrl",
            PluginErrorKind::Load => "load",
            PluginErrorKind::Shutdown => "shutdown",
        }
    }
}

/// 一次插件调用/加载失败的完整描述.
#[derive(Debug, Clone)]
pub struct PluginError {
    pub kind: PluginErrorKind,
    pub retryable: bool,
    pub detail: String,
}

impl PluginError {
    pub fn new(kind: PluginErrorKind, retryable: bool, detail: impl Into<String>) -> Self {
        Self {
            kind,
            retryable,
            detail: detail.into(),
        }
    }

    pub fn timeout(detail: impl Into<String>) -> Self {
        Self::new(PluginErrorKind::Timeout, true, detail)
    }

    pub fn memory(detail: impl Into<String>) -> Self {
        Self::new(PluginErrorKind::Memory, false, detail)
    }

    pub fn script(detail: impl Into<String>) -> Self {
        Self::new(PluginErrorKind::Script, false, detail)
    }

    pub fn protocol(detail: impl Into<String>) -> Self {
        Self::new(PluginErrorKind::Protocol, false, detail)
    }

    pub fn no_url(detail: impl Into<String>) -> Self {
        Self::new(PluginErrorKind::NoUrl, false, detail)
    }

    pub fn missing_handler(detail: impl Into<String>) -> Self {
        Self::new(PluginErrorKind::MissingHandler, false, detail)
    }

    pub fn load(detail: impl Into<String>) -> Self {
        Self::new(PluginErrorKind::Load, false, detail)
    }

    pub fn shutdown(detail: impl Into<String>) -> Self {
        Self::new(PluginErrorKind::Shutdown, false, detail)
    }

    /// 翻成产品既有的错误模型(UI 只认这个).
    pub fn to_provider_error(&self) -> ProviderError {
        let kind = match self.kind {
            // 超时是瞬时的, 允许重试(与官方直链的超时同档).
            PluginErrorKind::Timeout => ProviderErrorKind::Network,
            // 策略拒绝与 transport 报错都从 `Script` 这里下来(见模块头「分类收敛口径」).
            PluginErrorKind::Script
            | PluginErrorKind::Protocol
            | PluginErrorKind::Memory
            | PluginErrorKind::Load
            | PluginErrorKind::Shutdown => ProviderErrorKind::Internal,
            // 没注册 = 这个插件不提供该能力, 与官方 provider 的 unsupported 同义.
            PluginErrorKind::MissingHandler => ProviderErrorKind::Unsupported,
            // 脚本明确说没有直链 = notFound(不重试, 由上层换源).
            PluginErrorKind::NoUrl => ProviderErrorKind::NotFound,
        };
        ProviderError::new(kind, self.retryable, self.detail.clone())
    }
}

impl std::fmt::Display for PluginError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.kind.as_str(), self.detail)
    }
}

impl std::error::Error for PluginError {}

impl From<PluginError> for ProviderError {
    fn from(value: PluginError) -> Self {
        value.to_provider_error()
    }
}
