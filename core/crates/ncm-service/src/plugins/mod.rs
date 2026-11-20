//! 插件宿主的**宿主侧接缝**(切片 2 第一步): 真实网络 transport.
//!
//! 边界: 本模块只提供 `ncm-plugin` 所需的实现, **不接线** —— 没有 FFI 导出、没有注册进
//! `ProviderRegistry`、`Core::open` 也不构造任何插件宿主, 所以产品默认路径不受影响,
//! 插件仍然"不可从 UI 触发". 接入要单独评审风控与包体(见 `docs/remaining-batches.md` §11.C).
//!
//! 依赖方向: `ncm-service -> ncm-plugin`(plugin 只依赖 ncm-domain/ncm-provider, 无环).
//! 反过来不行: 宿主 HTTP 栈(UA/代理/超时/重试)必须留在 service 侧.

pub mod transport;

pub use transport::ReqwestTransport;
