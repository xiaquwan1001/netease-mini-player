//! 音源插件宿主(切片 1): QuickJS 沙箱 + lx 兼容层 + `ScriptProvider`.
//!
//! # 边界(重要)
//!
//! - **实验性, 未接入产品**: 没有 FFI 导出, 没有注册进 `ProviderRegistry`,
//!   也没有真实网络 transport —— 产品默认路径完全不受影响.
//! - **门禁隔离**: 未接入产品, `tools/ci-gates.sh` 的 rust-lint/rust-test 用
//!   `--exclude ncm-plugin` 跳过它(审计 7.9), 独立门是 `tools/ci-gates.sh rust-plugin`;
//!   接入条件见 `docs/remaining-batches.md` §11.C。
//! - **不新增 product trait**: `ScriptProvider` 实现的是 `ncm-provider` 里既有的
//!   `Provider`(本切片落地 `songUrl` + `search` 两个能力).
//! - **协议/加解密仍归 vendor**: 插件层只是宿主, 不碰网易云 eapi/weapi.
//!
//! # 三层结构
//!
//! | 模块 | 职责 |
//! |---|---|
//! | [`sandbox`] | QuickJS 实例、`lx.*` 注入、单次调用的时间/内存/请求预算 |
//! | [`transport`] / [`storage`] | 宿主注入面: 受控出站 + 命名空间隔离存储(测试用内存实现) |
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
pub mod sandbox;
pub mod storage;
pub mod transport;
pub mod worker;

pub use error::{PluginError, PluginErrorKind};
pub use sandbox::{SandboxConfig, ScriptEngine};
pub use storage::{MemoryStorage, Storage};
pub use transport::{
    MockTransport, Transport, TransportError, TransportRequest, TransportResponse,
};
pub use worker::{PluginSpec, ScriptProvider};
