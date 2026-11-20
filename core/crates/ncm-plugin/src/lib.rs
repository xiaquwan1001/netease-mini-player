//! 音源插件宿主(切片 1/切片 2 第一步): QuickJS 沙箱 + lx 兼容层 + `ScriptProvider`.
//!
//! # 边界(重要)
//!
//! - **未接入产品**: 没有 FFI 导出, 没有注册进 `ProviderRegistry` —— 产品默认路径
//!   完全不受影响(不能从 UI 触发插件).
//! - **真实网络与落盘都在宿主侧**: 本 crate 只定义 [`Transport`] / [`Storage`] 接缝,
//!   生产实现是 `ncm-service` 的 `plugins::ReqwestTransport`(复用 service 的 UA/超时/
//!   重试口径)与 [`FileStorage`](落盘目录由宿主传入).
//! - **门禁**: 因为 `ncm-service` 现在依赖本 crate, `tools/ci-gates.sh` 的
//!   rust-lint/rust-test **不再排除**它(独立门 `rust-plugin` 已删除)。
//! - **不新增 product trait**: `ScriptProvider` 实现的是 `ncm-provider` 里既有的
//!   `Provider`(本切片落地 `songUrl` + `search` 两个能力).
//! - **协议/加解密仍归 vendor**: 插件层只是宿主, 不碰网易云 eapi/weapi.
//! - **不新增 product trait**: `ScriptProvider` 实现的是 `ncm-provider` 里既有的
//!   `Provider`(本切片落地 `songUrl` + `search` 两个能力).
//! - **协议/加解密仍归 vendor**: 插件层只是宿主, 不碰网易云 eapi/weapi.
//!
//! # 三层结构
//!
//! | 模块 | 职责 |
//! |---|---|
//! | [`manifest`] | 插件清单(`manifest.json`)的纯数据形态与校验(可读错误, 不 panic) |
//! | [`policy`] | 出站域名白名单: 把 `permissions.requestDomains` 变成真判据(越界请求发不出去) |
//! | [`sandbox`] | QuickJS 实例、`lx.*` 注入、单次调用的时间/内存/请求预算 |
//! | [`transport`] / [`storage`] | 宿主注入面: 受控出站 + 命名空间隔离存储(内存/落盘两实现) |
//! | [`worker`] | `ScriptProvider`: 专属线程 + 异步 `Provider` 方法桥接 |
//! | [`convert`] | 脚本 JSON -> `ncm-domain` DTO(纯函数) |
//! | [`error`] | `PluginError` -> `ProviderError{kind,retryable,detail}` 映射 |
//!
//! # 最小用例
//!
//! ```no_run
//! use std::sync::Arc;
//! use ncm_plugin::{MemoryStorage, MockTransport, PluginSpec, ScriptProvider};
//! use ncm_provider::Provider;
//!
//! let transport = Arc::new(MockTransport::new());
//! let storage = Arc::new(MemoryStorage::new());
//! let provider = ScriptProvider::load(PluginSpec::new(
//!     "demo",
//!     "lx.on('musicUrl', async (source, info, type) => 'https://cdn.test/a.mp3')",
//!     transport,
//!     storage,
//! ))
//! .expect("load");
//! assert_eq!(provider.id(), "script");
//! ```

pub mod convert;
pub mod error;
pub mod manifest;
pub mod policy;
pub mod sandbox;
pub mod storage;
pub mod transport;
pub mod worker;

pub use error::{PluginError, PluginErrorKind};
pub use manifest::{
    check_api_version, ManifestError, Permissions, PluginManifest, HOST_API_VERSION, KNOWN_EVENTS,
    LEGACY_API_VERSION, MANIFEST_FILE, SUPPORTED_API_MAX, SUPPORTED_API_MIN,
};
pub use policy::{DomainPolicy, GuardedTransport};
pub use sandbox::{SandboxConfig, ScriptEngine};
pub use storage::{FileStorage, MemoryStorage, Storage};
pub use transport::{
    MockTransport, Transport, TransportError, TransportRequest, TransportResponse,
};
pub use worker::{PluginSpec, ScriptProvider};
