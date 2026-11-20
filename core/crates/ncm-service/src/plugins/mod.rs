//! 插件宿主的**宿主侧接缝**(切片 2 第一步): 真实网络 transport.
//!
//! 边界: 本模块只提供 `ncm-plugin` 所需的实现, **不接线** —— 没有 FFI 导出、没有注册进
//! `ProviderRegistry`、`Core::open` 也不构造任何插件宿主, 所以产品默认路径不受影响,
//! 插件仍然"不可从 UI 触发". 接入要单独评审风控与包体(见 `docs/remaining-batches.md` §11.C).
//!
//! 依赖方向: `ncm-service -> ncm-plugin`(plugin 只依赖 ncm-domain/ncm-provider, 无环).
//!
//! **平台范围: 仅非 Android 目标** —— `rquickjs-sys` 0.12.2 只带桌面/服务端目标的预生成
//! bindings, 没有 `*-linux-android` 的 .rs, 交叉编译会 include! 失败; 故 `pub mod plugins`
//! 在 `cfg(target_os = "android")` 下整体不编译(见 `lib.rs` 与 `Cargo.toml` 的 target 段).
//! 反过来不行: 宿主 HTTP 栈(UA/代理/超时/重试)必须留在 service 侧.

pub mod manager;
pub mod transport;

pub use manager::{ManagerError, ManagerErrorKind, PluginManager, PluginSummary};
pub use transport::ReqwestTransport;
