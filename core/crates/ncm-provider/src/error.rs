//! 统一错误模型: `ProviderError { kind, retryable, detail }`。
//!
//! 契约: 任何 provider 的外部错误都必须在这里收口, UI 只按 `kind` 决策。
//! `Display` 的 `"[kind] detail"` 形状是跨桥的**文本协议**(见 `ncm-ffi` 的 `ffi_forward!`),
//! 改格式等于改前端解析。

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderErrorKind {
    Network,
    Auth,
    RiskControl,
    NotFound,
    Unsupported,
    /// 服务端明确拒绝(隐私设置/权限不足), 与 Internal 区分开: 重试也不会变
    Forbidden,
    Internal,
}

impl ProviderErrorKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            ProviderErrorKind::Network => "network",
            ProviderErrorKind::Auth => "auth",
            ProviderErrorKind::RiskControl => "riskControl",
            ProviderErrorKind::NotFound => "notFound",
            ProviderErrorKind::Unsupported => "unsupported",
            ProviderErrorKind::Forbidden => "forbidden",
            ProviderErrorKind::Internal => "internal",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderError {
    pub kind: ProviderErrorKind,
    pub retryable: bool,
    pub detail: String,
}

impl ProviderError {
    pub fn new(kind: ProviderErrorKind, retryable: bool, detail: impl Into<String>) -> Self {
        Self {
            kind,
            retryable,
            detail: detail.into(),
        }
    }

    pub fn network(detail: impl Into<String>) -> Self {
        Self::new(ProviderErrorKind::Network, true, detail)
    }

    pub fn auth(detail: impl Into<String>) -> Self {
        Self::new(ProviderErrorKind::Auth, false, detail)
    }

    pub fn risk_control(detail: impl Into<String>) -> Self {
        Self::new(ProviderErrorKind::RiskControl, false, detail)
    }

    pub fn not_found(detail: impl Into<String>) -> Self {
        Self::new(ProviderErrorKind::NotFound, false, detail)
    }

    pub fn unsupported(detail: impl Into<String>) -> Self {
        Self::new(ProviderErrorKind::Unsupported, false, detail)
    }

    /// 服务端拒绝(隐私设置/无权限): 不可重试, detail 应当是用户能直接读的一句话
    pub fn forbidden(detail: impl Into<String>) -> Self {
        Self::new(ProviderErrorKind::Forbidden, false, detail)
    }

    pub fn internal(detail: impl Into<String>) -> Self {
        Self::new(ProviderErrorKind::Internal, false, detail)
    }
}

impl std::fmt::Display for ProviderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.kind.as_str(), self.detail)
    }
}

impl std::error::Error for ProviderError {}

pub type ProviderResult<T> = Result<T, ProviderError>;
