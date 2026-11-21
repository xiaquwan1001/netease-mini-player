//! 插件宿主的**宿主侧接缝**: 目录管理 + 真实网络 transport + provider 注册表 + Core 接线.
//!
//! 边界: 本模块提供 `ncm-plugin` 所需的宿主实现与装配, 并已由 [`host::PluginHost`] 接进
//! `Core::open`; 也已导出到 `ncm-ffi`(`api/plugin.rs` 的 8 个函数). 但**没有 UI 入口**,
//! 所以产品默认路径的行为不变: 缺省策略是**不扫描**([`host::PluginHostPolicy::default`]),
//! 开启必须显式调 `Core::plugin_set_enabled(true)`.
//!
//! 路由纪律: `ScriptProvider::id()` 恒为 `"script"`, 所以插件 provider **不进**
//! `ncm_provider::ProviderRegistry`, 一律按**插件 id** 走 [`host::PluginHost::provider`]
//! (见 `registry.rs` 头注释与 `docs/remaining-batches.md` §11.C).
//!
//! 依赖方向: `ncm-service -> ncm-plugin`(plugin 只依赖 ncm-domain/ncm-provider, 无环).
//!
//! **平台范围: 仅非 Android 目标** —— `rquickjs-sys` 0.12.2 只带桌面/服务端目标的预生成
//! bindings, 没有 `*-linux-android` 的 .rs, 交叉编译会 include! 失败; 故 `pub mod plugins`
//! 在 `cfg(target_os = "android")` 下整体不编译(见 `lib.rs` 与 `Cargo.toml` 的 target 段).
//! 反过来不行: 宿主 HTTP 栈(UA/代理/超时/重试)必须留在 service 侧.

pub mod host;
pub mod manager;
pub mod registry;
pub mod route;
pub mod transport;

/// 插件宿主的**共享句柄**: FFI 层靠它绕开 `Core` 的唯一一把锁做装载/扫描(切片 A).
///
/// 为什么要单独一把锁: `rescan`/`install_*`/`enable` 会真的装载 QuickJS(单插件装载预算
/// 8s), 若持 `Core` 锁执行, 期间**所有其它域**的 FFI 都排队. 现在换成独立 `RwLock`:
/// - 读类(`status/summaries/failures/rejected/sources/logs/ids/provider/policy/route_*`)取**读锁**
///   (纯内存遍历, 多个读并发不互斥);
/// - 写类(`rescan/install_*/enable/disable/uninstall/set_enabled/set_root/set_route_mode`)取**写锁**.
///
/// **锁序纪律**: 允许 `Core 锁 -> 这里`, **禁止**反过来 —— 插件侧的代码绝不回头拿 `Core` 锁
/// (所以插件 FFI 入口一个都不要再调 `super::core()`).
pub type PluginHostHandle = std::sync::Arc<std::sync::RwLock<PluginHost>>;

pub use host::{PluginHost, PluginHostPolicy, PluginHostStatus};
pub use manager::{
    check_https_url, ManagerError, ManagerErrorKind, PluginFailureRecord, PluginManager,
    PluginSummary, DEFAULT_ENTRY, MAX_CONSECUTIVE_FAILURES, MAX_SOURCE_BYTES, MAX_SOURCE_REDIRECTS,
};
pub use registry::{PluginRegistry, RegistryReport};
pub use route::{
    call_routed, last_route_event, plan, RouteDecision, RouteMode, RoutePlan, RouteReason,
    RouteTarget, RouteUsed, Routed,
};
pub use transport::{HttpsSourceFetcher, ReqwestTransport, SourceFetcher};
