//! 插件宿主的错误模型与到 ProviderError 的映射.
//!
//! 纪律: 脚本侧的任何失败都必须在宿主侧收口成 PluginError, 再按
//! ProviderError{kind,retryable,detail} 翻成产品既有的错误模型 —— UI 只按 kind 决策,
//! 所以插件不需要(也不允许)把 JS 异常原文直接冒到 UI.
//!
//! 映射表见 README「错误映射」; 改这里的 kind/retryable 等于改产品行为.

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
    /// 宿主拒绝了脚本的请求(非 http/https、超出次数/体积预算等).
    RequestDenied,
    /// 注入的 transport 报错(网络层).
    Transport,
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
            PluginErrorKind::RequestDenied => "requestDenied",
            PluginErrorKind::Transport => "transport",
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

    pub fn request_denied(detail: impl Into<String>) -> Self {
        Self::new(PluginErrorKind::RequestDenied, false, detail)
    }

    pub fn transport(detail: impl Into<String>, retryable: bool) -> Self {
        Self::new(PluginErrorKind::Transport, retryable, detail)
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
            PluginErrorKind::Transport => ProviderErrorKind::Network,
            PluginErrorKind::Script
            | PluginErrorKind::Protocol
            | PluginErrorKind::Memory
            | PluginErrorKind::RequestDenied
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
