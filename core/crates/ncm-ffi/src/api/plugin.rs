//! 插件管理导出层: 宿主状态 / 列表 / 失败视图 / 单插件启停 / 重扫 / 总开关.
//!
//! 这是 `ncm-service::plugins::host` 的**唯一 FFI 出口**(切片 2 第六步; 没有 UI 页面).
//! 本文件只做两件事: 取 `Core` 锁、把 DTO 摊平成桥接类型. 所有决策(缺省不扫描、
//! 单插件状态、失败隔离)都在 `PluginHost` 里, 这里**不重复判断**.
//!
//! # 错误口径: 只有一条
//!
//! 可失败操作返回 `Result<_, FfiError>`, `FfiError` 由 `ProviderError` 经
//! [`From`](super::FfiError) 翻译而来 —— 与其它域**同一个词表**
//! (`network/auth/riskControl/notFound/unsupported/forbidden/internal`).
//! 宿主层已经把 `ManagerError` 收敛到 `ProviderError`(翻译点只有
//! `host::to_provider_error` 一处, 映射表在 `plugins/host.rs` 头注释), 所以本层
//! **不新增**错误分支, 也不按文本前缀猜. 具体表现:
//!
//! | 场景 | kind | retryable |
//! |---|---|---|
//! | 总开关没开就 `plugin_enable/disable/rescan` | `forbidden` | false |
//! | 宿主构造失败(根目录/出站客户端建不出来) | `internal` | false |
//! | 插件 id 没登记(目录不存在/清单坏) | `notFound` | false |
//! | 清单形状不成立 | `unsupported` | false |
//! | 当前平台不带插件宿主(Android) | `unsupported` | false |
//!
//! 读类接口(`plugin_status/summaries/failures/rejected`)在总开关关闭时**不报错**,
//! 给空视图 + `status.enabled == false`(UI 靠它解释"为什么列表是空的").
//! 这与 `Core` 侧语义逐字一致, 本层没有额外规则.
//!
//! # 并发: 这些都拿 `Core` 的唯一一把锁
//!
//! 导出函数是同步实现(`frb` 给 Dart 生成 `Future`, 但 Rust 侧不 await), 每次调用锁
//! `MUTEX<Core>`. `plugin_rescan`/`plugin_set_enabled(true)` 会真的扫盘并装载 QuickJS,
//! **持锁期间其它域调用会等待** ⇒ UI 侧串行调用、给个 loading 态, 别并发轮询.
//!
//! # Android: 编译通过 + 空视图(不是 `cfg` 掉函数)
//!
//! 插件宿主只在非 Android 目标编译(`rquickjs-sys` 0.12.2 没有 `*-linux-android`
//! 的预生成 bindings, 见 `ncm-service` 的 `Cargo.toml` target 段与
//! `docs/remaining-batches.md` §11.C). 本模块**故意不** `cfg` 掉导出函数:
//! Dart 侧 API 形状必须两端一致, 否则桥接代码/调用方要在编译期分平台.
//! 于是 Android 分支:
//!
//! - 读类 ⇒ `Ok(空视图)`, 其中 `PluginStatusDto.supported = false` 且 `error` 写明原因;
//! - 写类(`enable/disable/rescan/set_enabled`) ⇒ `Err(unsupported)`, detail 带操作名.
//!
//! 两个分支共用同一批 DTO 构造函数(`unsupported_status` / `unsupported_error`),
//! 所以 "空视图语义" 在 Linux 上就能单测(`plugin_tests::android_view_is_empty_and_explicit`),
//! 只有 `#[cfg(target_os = "android")]` 那几行本身需要 Android 目标编译才验证
//! (`cargo check --target aarch64-linux-android -p ncm_ffi`).

pub(crate) use super::*;

use ncm_provider::{ProviderError, ProviderErrorKind};

// ------------------------------- DTO -------------------------------

/// 宿主状态: 一句话回答"插件现在能不能用、为什么不能用".
pub struct PluginStatusDto {
    /// 本平台是否带插件宿主(Android = false ⇒ 其余字段恒为缺省).
    pub supported: bool,
    /// 策略文件(`plugin_host.json`)里的总开关; 缺省 false = 不扫描.
    pub enabled: bool,
    /// 注册表真的建起来了(总开关打开且构造成功).
    pub active: bool,
    /// 生效的插件根目录(未启用时也给 = "开了之后会用的那个").
    pub root: String,
    /// 构造/重扫失败原因(`active == false` 且有值 ⇒ 是失败而非"没开").
    pub error: Option<String>,
    /// 已装载成 provider 的插件 id(字典序).
    pub loaded: Vec<String>,
    /// 失败条目数(扫描/清单/装载失败, 不含"停用").
    pub failed: u32,
}

/// 一个插件目录的摘要(含坏条目的原因).
pub struct PluginSummaryDto {
    pub id: String,
    pub name: String,
    pub version: String,
    pub enabled: bool,
    /// 清单声明的出站白名单(装载时强制生效); 空 = 出站全拒.
    pub request_domains: Vec<String>,
    /// `Some(reason)` = 这个目录没装上(清单坏/路径不安全/重复 id ...).
    pub error: Option<String>,
}

/// 失败条目: 键是目录名或插件 id(见 `PluginHost::failures`).
pub struct PluginFailureDto {
    pub id: String,
    pub detail: String,
}

/// 最近一次扫描被拒收的条目(跨目录同 id / 目录不可访问).
pub struct PluginRejectedDto {
    pub entry: String,
    pub detail: String,
}

/// 重扫结果(全量重建, 没有热重载).
pub struct PluginRescanDto {
    /// 本次扫描新登记成功的插件 id(字典序).
    pub scanned: Vec<String>,
    /// 刷新后处于"已装载"的 id.
    pub loaded: Vec<String>,
    /// 已登记但未启用 ⇒ 不装载(**不是错误**).
    pub skipped: Vec<String>,
    /// 失败条目.
    pub failed: Vec<PluginFailureDto>,
}

// ---------------------- 平台无关的构造函数 ----------------------

/// `usize` -> `u32`(桥接侧统一用 `u32` 计数, 饱和而不是回绕).
#[cfg(not(target_os = "android"))]
fn count(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

/// Android 的"无宿主"状态视图(读类接口的返回值).
///
/// 也用作 `PluginStatusDto` 的空视图基准: `supported = false` 是唯一的平台信号,
/// `error` 必须非空 —— 别让 UI 以为"只是没开".
///
/// 非 Android 构建里它只被单测调用(生产调用点是 `#[cfg(target_os = "android")]` 分支),
/// 所以显式 `allow(dead_code)`: 别为了消警告把它 cfg 掉 —— 那空视图语义就没法在
/// Linux 上单测了.
#[allow(dead_code)]
fn unsupported_status() -> PluginStatusDto {
    PluginStatusDto {
        supported: false,
        enabled: false,
        active: false,
        root: String::new(),
        error: Some(PLATFORM_DETAIL.to_string()),
        loaded: Vec::new(),
        failed: 0,
    }
}

/// Android 的"无宿主"错误(写类接口的返回值).
///
/// **仍经 [`ProviderError`] 中转**, 所以 `kind` 来自同一张词表(`unsupported`),
/// `retryable = false`(重试不会变出 bindings).
#[allow(dead_code)] // 同 `unsupported_status`: Linux 上只被单测调用
fn unsupported_error(op: &str) -> FfiError {
    FfiError::from(ProviderError::new(
        ProviderErrorKind::Unsupported,
        false,
        format!("{op}: {PLATFORM_DETAIL}"),
    ))
}

#[cfg(target_os = "android")]
const PLATFORM_DETAIL: &str =
    "当前平台(Android)不带插件宿主: rquickjs-sys 0.12.2 无 Android 预生成 bindings, \
插件相关接口只返回空视图/不支持; 桌面端(Linux/Windows)可用";
#[cfg(not(target_os = "android"))]
#[allow(dead_code)] // 只被上面两个 Android 专用构造函数引用
const PLATFORM_DETAIL: &str = "当前平台不带插件宿主";

// ---------------------- 非 Android 的 DTO 转换 ----------------------

#[cfg(not(target_os = "android"))]
fn status_dto(status: &ncm_service::PluginHostStatus) -> PluginStatusDto {
    PluginStatusDto {
        supported: true,
        enabled: status.enabled,
        active: status.active,
        root: status.root.to_string_lossy().into_owned(),
        error: status.error.clone(),
        loaded: status.loaded.clone(),
        failed: count(status.failed),
    }
}

#[cfg(not(target_os = "android"))]
fn summary_dto(summary: &ncm_service::PluginSummary) -> PluginSummaryDto {
    PluginSummaryDto {
        id: summary.id.clone(),
        name: summary.name.clone(),
        version: summary.version.clone(),
        enabled: summary.enabled,
        request_domains: summary.request_domains.clone(),
        error: summary.error.clone(),
    }
}

/// `BTreeMap<id, detail>` -> 有序 `Vec`(BTreeMap 已是字典序, 顺序直接透传).
#[cfg(not(target_os = "android"))]
fn failures_dto(map: &std::collections::BTreeMap<String, String>) -> Vec<PluginFailureDto> {
    map.iter()
        .map(|(id, detail)| PluginFailureDto {
            id: id.clone(),
            detail: detail.clone(),
        })
        .collect()
}

/// `Vec<(键, 原因)>` -> `Vec<PluginFailureDto>`(重扫报表的 `failed` 是这种形状).
#[cfg(not(target_os = "android"))]
fn failed_pairs_dto(entries: &[(String, String)]) -> Vec<PluginFailureDto> {
    entries
        .iter()
        .map(|(id, detail)| PluginFailureDto {
            id: id.clone(),
            detail: detail.clone(),
        })
        .collect()
}

#[cfg(not(target_os = "android"))]
fn rejected_dto(entries: &[(String, String)]) -> Vec<PluginRejectedDto> {
    entries
        .iter()
        .map(|(entry, detail)| PluginRejectedDto {
            entry: entry.clone(),
            detail: detail.clone(),
        })
        .collect()
}

#[cfg(not(target_os = "android"))]
fn rescan_dto(report: &ncm_service::RegistryReport) -> PluginRescanDto {
    PluginRescanDto {
        scanned: report.scanned.clone(),
        loaded: report.loaded.clone(),
        skipped: report.skipped.clone(),
        failed: failed_pairs_dto(&report.failed),
    }
}

// ------------------------------- 导出 -------------------------------

/// 宿主状态(UI 用它解释"为什么列表是空的").
///
/// 读类: 总开关关闭时**不报错**, 返回 `enabled = false` 的空视图.
pub fn plugin_status() -> Result<PluginStatusDto, FfiError> {
    #[cfg(not(target_os = "android"))]
    {
        let guard = core()?.lock().map_err(FfiError::from)?;
        Ok(status_dto(&guard.plugin_status()))
    }
    #[cfg(target_os = "android")]
    {
        Ok(unsupported_status())
    }
}

/// 插件列表(含坏条目的 `error` 原因).
pub fn plugin_summaries() -> Result<Vec<PluginSummaryDto>, FfiError> {
    #[cfg(not(target_os = "android"))]
    {
        let guard = core()?.lock().map_err(FfiError::from)?;
        Ok(guard.plugin_summaries().iter().map(summary_dto).collect())
    }
    #[cfg(target_os = "android")]
    {
        Ok(Vec::new())
    }
}

/// 失败原因(清单坏/路径不安全/装载失败), 按 id 字典序.
pub fn plugin_failures() -> Result<Vec<PluginFailureDto>, FfiError> {
    #[cfg(not(target_os = "android"))]
    {
        let guard = core()?.lock().map_err(FfiError::from)?;
        Ok(failures_dto(&guard.plugin_failures()))
    }
    #[cfg(target_os = "android")]
    {
        Ok(Vec::new())
    }
}

/// 最近一次扫描被拒收的条目(跨目录同 id / 目录不可访问).
pub fn plugin_rejected() -> Result<Vec<PluginRejectedDto>, FfiError> {
    #[cfg(not(target_os = "android"))]
    {
        let guard = core()?.lock().map_err(FfiError::from)?;
        Ok(rejected_dto(&guard.plugin_rejected()))
    }
    #[cfg(target_os = "android")]
    {
        Ok(Vec::new())
    }
}

/// 启用单个插件并即时装载(宿主总开关没开 ⇒ `forbidden`, 不会隐式打开总开关).
pub fn plugin_enable(id: String) -> Result<(), FfiError> {
    #[cfg(not(target_os = "android"))]
    {
        let mut guard = core()?.lock().map_err(FfiError::from)?;
        guard.plugin_enable(&id).map_err(FfiError::from)
    }
    #[cfg(target_os = "android")]
    {
        let _ = id;
        Err(unsupported_error("plugin_enable"))
    }
}

/// 停用单个插件并摘掉内存里的 provider.
pub fn plugin_disable(id: String) -> Result<(), FfiError> {
    #[cfg(not(target_os = "android"))]
    {
        let mut guard = core()?.lock().map_err(FfiError::from)?;
        guard.plugin_disable(&id).map_err(FfiError::from)
    }
    #[cfg(target_os = "android")]
    {
        let _ = id;
        Err(unsupported_error("plugin_disable"))
    }
}

/// 重扫插件根目录(全量重建 provider 视图).
pub fn plugin_rescan() -> Result<PluginRescanDto, FfiError> {
    #[cfg(not(target_os = "android"))]
    {
        let mut guard = core()?.lock().map_err(FfiError::from)?;
        let report = guard.plugin_rescan().map_err(FfiError::from)?;
        Ok(rescan_dto(&report))
    }
    #[cfg(target_os = "android")]
    {
        Err(unsupported_error("plugin_rescan"))
    }
}

/// 宿主**总开关**(落盘 `<dataDir>/plugin_host.json`, 0600 原子写).
///
/// 打开 = 建注册表 + 首扫; 关闭 = 摘掉注册表(不删目录、不改单插件状态).
/// 这是"磁盘上多一个插件目录"变成"真的执行脚本"的唯一开关 ——
/// 打开失败时策略不落盘并回滚内存状态, 错误是 `internal`.
pub fn plugin_set_enabled(enabled: bool) -> Result<(), FfiError> {
    #[cfg(not(target_os = "android"))]
    {
        let mut guard = core()?.lock().map_err(FfiError::from)?;
        guard.plugin_set_enabled(enabled).map_err(FfiError::from)
    }
    #[cfg(target_os = "android")]
    {
        let _ = enabled;
        Err(unsupported_error("plugin_set_enabled"))
    }
}

// 用例用到 `ncm_service::plugins`(非 Android 才有), 所以测试模块也按平台 gate.
#[cfg(all(test, not(target_os = "android")))]
#[path = "plugin_tests.rs"]
mod tests;
