//! 插件管理导出层: 宿主状态 / 列表 / 失败视图 / 单插件启停 / 重扫 / 总开关.
//!
//! 这是 `ncm-service::plugins::host` 的**唯一 FFI 出口**(切片 2 第六步; 没有 UI 页面).
//! 本文件只做两件事: 取**插件宿主句柄的锁**、把 DTO 摊平成桥接类型. 所有决策(缺省不扫描、
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
//! | 总开关没开就 `plugin_enable/disable/rescan/install_*/uninstall` | `forbidden` | false |
//! | 卸载/文件导入的路径不安全(id 非法) | `forbidden` | false |
//! | URL 导入只收 `https://`(形态不成立) | `forbidden` | false |
//! | URL 导入抓取失败(DNS/连接/超时/非 2xx) | `network` | **true** |
//! | 宿主构造失败(根目录/出站客户端建不出来) | `internal` | false |
//! | 插件 id 没登记(目录不存在/清单坏) | `notFound` | false |
//! | 清单形状不成立 | `unsupported` | false |
//! | 当前平台不带插件宿主(Android) | `unsupported` | false |
//!
//! 读类接口(`plugin_status/summaries/failures/rejected`)在总开关关闭时**不报错**,
//! 给空视图 + `status.enabled == false`(UI 靠它解释"为什么列表是空的").
//! 这与 `Core` 侧语义逐字一致, 本层没有额外规则.
//!
//! # 并发: 拿的是**插件宿主自己的锁**, 不再是 `Core` 的唯一一把锁(隔离二期切片 A, v0.36.0)
//!
//! 导出函数是同步实现(`frb` 给 Dart 生成 `Future`, 但 Rust 侧不 await). 入口统一走
//! `super::plugin_host()` 拿 `Arc<RwLock<PluginHost>>`(与 `CORE` 里那份**同一个** `Arc`):
//! - 读类(`status/summaries/failures/logs/rejected/route_mode/route_plan`)取**读锁**, 多个读并发;
//! - 写类(`rescan/set_enabled/install_*/enable/disable/uninstall/set_route_mode`)取**写锁**,
//!   彼此串行 —— 它们会真的扫盘并装载 QuickJS(单插件预算 8s).
//!
//! 关键收益: 装载期间**其它域的 FFI(`song_url`/`search`/账号…)完全不受影响**, 因为它们只碰
//! `Core` 锁. UI 侧仍建议给个 loading 态(同类写操作之间还是会排队), 但不必再怕"重扫时整机卡".
//!
//! 锁序纪律: 允许 `Core 锁 -> 插件句柄`, **禁止**反过来(插件侧代码绝不回头拿 `Core` 锁);
//! 判据用例 `ncm-service` `plugins::route_tests::plugin_handle_does_not_hold_the_core_lock_while_loading`.
//!
//! # 平台覆盖: 四端同一份实现(2026-11-21 起 Android 也带插件宿主)
//!
//! 历史上 `ncm-plugin` 只在非 Android 目标编译(`rquickjs-sys` 无 `*-linux-android`
//! 预生成 bindings)。2026-11-21 起 Android 走**构建期 bindgen**(见
//! `docs/audit/2026-11-21-plugin-android-crosscompile.md` §3 推荐路径 b 与
//! `ncm-plugin/Cargo.toml` 的 target 段), 于是:
//!
//! - 本文件**没有**平台分支: 读类/写类在 Linux/Windows/Android 上是同一段代码;
//! - 构建 Android 时必须经 `tools/android-bindgen-env.sh`(或 `tools/build-android.sh`
//!   自动套的那层)启动, 否则 bindgen 拿不到 NDK sysroot, 构建期直接失败;
//! - `PluginStatusDto.supported` 现在两端都恒为 `true`(保留字段是为了桥接兼容).

pub(crate) use super::*;

// ------------------------------- DTO -------------------------------

/// 宿主状态: 一句话回答"插件现在能不能用、为什么不能用".
pub struct PluginStatusDto {
    /// 本平台是否带插件宿主(实现细节见「平台覆盖」; 现在两端都是 true).
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
    /// 脚本自报的平台代号(`send('inited', {sources})` 的 key); 空 = 未声明/没装载.
    ///
    /// 只用于展示与诊断, **不参与路由判定**(能力面看 `capabilities`).
    pub sources: Vec<String>,
}

/// 一个插件的诊断日志批次(`lx.log` / `console.*`)。
///
/// **取走语义**: 拉一次就清一次, 同一批日志不会重复交付(见 `PluginHost::take_logs`)。
pub struct PluginLogDto {
    pub id: String,
    pub lines: Vec<String>,
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
fn count(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

// ---------------------- 非 Android 的 DTO 转换 ----------------------

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

fn summary_dto(
    summary: &ncm_service::PluginSummary,
    sources: &std::collections::BTreeMap<String, Vec<String>>,
) -> PluginSummaryDto {
    PluginSummaryDto {
        id: summary.id.clone(),
        name: summary.name.clone(),
        version: summary.version.clone(),
        enabled: summary.enabled,
        request_domains: summary.request_domains.clone(),
        error: summary.error.clone(),
        sources: sources.get(&summary.id).cloned().unwrap_or_default(),
    }
}

/// `BTreeMap<id, detail>` -> 有序 `Vec`(BTreeMap 已是字典序, 顺序直接透传).
fn failures_dto(map: &std::collections::BTreeMap<String, String>) -> Vec<PluginFailureDto> {
    map.iter()
        .map(|(id, detail)| PluginFailureDto {
            id: id.clone(),
            detail: detail.clone(),
        })
        .collect()
}

/// `Vec<(键, 原因)>` -> `Vec<PluginFailureDto>`(重扫报表的 `failed` 是这种形状).
fn failed_pairs_dto(entries: &[(String, String)]) -> Vec<PluginFailureDto> {
    entries
        .iter()
        .map(|(id, detail)| PluginFailureDto {
            id: id.clone(),
            detail: detail.clone(),
        })
        .collect()
}

fn rejected_dto(entries: &[(String, String)]) -> Vec<PluginRejectedDto> {
    entries
        .iter()
        .map(|(entry, detail)| PluginRejectedDto {
            entry: entry.clone(),
            detail: detail.clone(),
        })
        .collect()
}

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
    let host = plugin_host()?;
    let guard = host.read().unwrap_or_else(|e| e.into_inner());
    Ok(status_dto(&guard.status()))
}

/// 插件列表(含坏条目的 `error` 原因).
pub fn plugin_summaries() -> Result<Vec<PluginSummaryDto>, FfiError> {
    let host = plugin_host()?;
    let guard = host.read().unwrap_or_else(|e| e.into_inner());
    let sources = guard.sources();
    Ok(guard
        .summaries()
        .iter()
        .map(|summary| summary_dto(summary, &sources))
        .collect())
}

/// 失败原因(清单坏/路径不安全/装载失败), 按 id 字典序.
pub fn plugin_failures() -> Result<Vec<PluginFailureDto>, FfiError> {
    let host = plugin_host()?;
    let guard = host.read().unwrap_or_else(|e| e.into_inner());
    Ok(failures_dto(&guard.failures()))
}

/// 拉走所有插件累计的诊断日志(按插件 id 分组, 空组丢弃)。
///
/// 读类接口, 总开关关闭/宿主未激活时给空视图, 不报错。UI 侧按需点「拉取日志」,
/// **不做后台轮询**(拉取要拿 `Core` 的唯一一把锁, 轮询会拖慢别的域调用)。
pub fn plugin_logs() -> Result<Vec<PluginLogDto>, FfiError> {
    let host = plugin_host()?;
    let guard = host.read().unwrap_or_else(|e| e.into_inner());
    Ok(guard
        .take_logs()
        .into_iter()
        .map(|(id, lines)| PluginLogDto { id, lines })
        .collect())
}

/// 最近一次扫描被拒收的条目(跨目录同 id / 目录不可访问).
pub fn plugin_rejected() -> Result<Vec<PluginRejectedDto>, FfiError> {
    let host = plugin_host()?;
    let guard = host.read().unwrap_or_else(|e| e.into_inner());
    Ok(rejected_dto(&guard.rejected()))
}

/// 启用单个插件并即时装载(宿主总开关没开 ⇒ `forbidden`, 不会隐式打开总开关).
pub fn plugin_enable(id: String) -> Result<(), FfiError> {
    let host = plugin_host()?;
    let mut guard = host.write().unwrap_or_else(|e| e.into_inner());
    guard.enable(&id).map_err(FfiError::from)
}

/// 停用单个插件并摘掉内存里的 provider.
pub fn plugin_disable(id: String) -> Result<(), FfiError> {
    let host = plugin_host()?;
    let mut guard = host.write().unwrap_or_else(|e| e.into_inner());
    guard.disable(&id).map_err(FfiError::from)
}

/// 重扫插件根目录(全量重建 provider 视图).
pub fn plugin_rescan() -> Result<PluginRescanDto, FfiError> {
    let host = plugin_host()?;
    let mut guard = host.write().unwrap_or_else(|e| e.into_inner());
    let report = guard.rescan().map_err(FfiError::from)?;
    Ok(rescan_dto(&report))
}

/// 从**脚本文本**导入一个插件(写 `<root>/<id>/{manifest.json,index.js}` 后立即重扫).
///
/// 口径(与其它写类一致): 总开关没开 ⇒ `forbidden`; 清单字段不合法 ⇒ `unsupported`(不落文件);
/// 文件系统失败 ⇒ `internal`. 导入**不**自动启用插件(与目录导入一致, 仍由用户决定)。
/// 覆盖同名插件允许(用户显式提交), 该插件的 `data/` 存储保留。
#[allow(clippy::too_many_arguments)]
pub fn plugin_install_script(
    id: String,
    name: String,
    version: String,
    source: String,
    lx_events: Vec<String>,
    request_domains: Vec<String>,
) -> Result<PluginRescanDto, FfiError> {
    let host = plugin_host()?;
    let mut guard = host.write().unwrap_or_else(|e| e.into_inner());
    let report = guard
        .install_source(
            &id,
            &name,
            &version,
            "index.js",
            &source,
            &lx_events,
            &request_domains,
        )
        .map_err(FfiError::from)?;
    Ok(rescan_dto(&report))
}

/// 从**本机文件**导入一个插件(读文件 → 写 `<root>/<id>/{manifest.json,index.js}` 后立即重扫).
///
/// `path` 是**绝对路径**(UI 侧只收绝对路径; 也可以用文本输入, 不引文件选择器依赖)。
/// 口径与 [`plugin_install_script`] 一致: 总开关没开 ⇒ `forbidden`; 文件读不了/不是
/// UTF-8/超过 2 MiB ⇒ `internal`(`Io`)或 `unsupported`(`Manifest`); 失败**不落任何文件**。
/// 导入**不**自动启用插件。
pub fn plugin_install_file(
    id: String,
    name: String,
    version: String,
    path: String,
    lx_events: Vec<String>,
    request_domains: Vec<String>,
) -> Result<PluginRescanDto, FfiError> {
    let host = plugin_host()?;
    let mut guard = host.write().unwrap_or_else(|e| e.into_inner());
    let report = guard
        .install_file(
            &id,
            &name,
            &version,
            std::path::Path::new(&path),
            &lx_events,
            &request_domains,
        )
        .map_err(FfiError::from)?;
    Ok(rescan_dto(&report))
}

/// 从 **URL** 导入一个插件(只允许 `https://`)。
///
/// 三条硬约束全在落盘之前: `https://` 形态、重定向上限(3 跳)、响应体 ≤ 2 MiB; 任一不满足
/// **不落任何文件**。抓取失败是全仓**唯一**可重试的插件错误(`network` + `retryable = true`),
/// UI 侧可提示“稍后重试”。导入**不**自动启用插件。
pub fn plugin_install_url(
    id: String,
    name: String,
    version: String,
    url: String,
    lx_events: Vec<String>,
    request_domains: Vec<String>,
) -> Result<PluginRescanDto, FfiError> {
    let host = plugin_host()?;
    let mut guard = host.write().unwrap_or_else(|e| e.into_inner());
    let report = guard
        .install_url(&id, &name, &version, &url, &lx_events, &request_domains)
        .map_err(FfiError::from)?;
    Ok(rescan_dto(&report))
}

/// 卸载一个插件: 停用 → **删掉 `<root>/<id>`(含该插件的 `data/`)** → 清状态 → 重扫。
///
/// - 总开关没开 ⇒ `forbidden`; 非法 id(`..`/`/`/绝对路径/大写) ⇒ `forbidden`;
/// - 未登记且目录不存在 ⇒ `notFound`; 目录删不掉 ⇒ `internal` 且插件**保持停用**;
/// - 指向它的路由选择会自动回 `auto`(否则判定永远停在 `selectionMissing`)。
///
/// 返回的 `scanned` 恒为空(卸载不“新登记”任何插件), 结果看 `loaded/skipped/failed`。
pub fn plugin_uninstall(id: String) -> Result<PluginRescanDto, FfiError> {
    let host = plugin_host()?;
    let mut guard = host.write().unwrap_or_else(|e| e.into_inner());
    let report = guard.uninstall(&id).map_err(FfiError::from)?;
    Ok(rescan_dto(&report))
}

/// 宿主**总开关**(落盘 `<dataDir>/plugin_host.json`, 0600 原子写).
///
/// 打开 = 建注册表 + 首扫; 关闭 = 摘掉注册表(不删目录、不改单插件状态).
/// 这是"磁盘上多一个插件目录"变成"真的执行脚本"的唯一开关 ——
/// 打开失败时策略不落盘并回滚内存状态, 错误是 `internal`.
pub fn plugin_set_enabled(enabled: bool) -> Result<(), FfiError> {
    let host = plugin_host()?;
    let mut guard = host.write().unwrap_or_else(|e| e.into_inner());
    guard.set_enabled(enabled).map_err(FfiError::from)
}

// ---------------------------- 路由(取链/搜索的判定视图) ----------------------------

/// 路由偏好视图(`<dataDir>/plugin_route.json`): 用户选的是"自动/只用内置/指定插件".
///
/// 与宿主状态分开: 宿主开不开(`PluginStatusDto.enabled`)决定"有没有插件可用",
/// 这里决定"可用的时候优先用谁". 两者都缺省(不扫描 + auto)时产品行为不变.
pub struct PluginRouteModeDto {
    /// 本平台是否带插件宿主(现在两端都是 true).
    pub supported: bool,
    /// 稳定标签: `auto` / `builtin` / `plugin:<id>`(可原样回传给 [`plugin_set_route_mode`]).
    pub mode: String,
    /// 显式选中的插件 id(`mode` 不是 `plugin:<id>` 形态时为 None).
    pub plugin_id: Option<String>,
}

/// 一次路由**判定**的诊断视图(纯判定, 不发请求、不改状态).
pub struct PluginRoutePlanDto {
    pub supported: bool,
    /// 这次会用的目标: `builtin` / `plugin:<id>`.
    pub target: String,
    /// 命中的插件 id(None = 内置).
    pub plugin_id: Option<String>,
    /// 判定依据的稳定标签(`autoSingle` / `selected` / `builtinSelected` / `ambiguous` /
    /// `selectionMissing` / `capabilityMissing` / `hostInactive` / `noPluginLoaded`;
    /// Android 恒为 `unsupported`).
    pub reason: String,
    /// 可读原因(与日志同一份原文).
    pub detail: String,
}

fn route_mode_dto(mode: &ncm_service::RouteMode) -> PluginRouteModeDto {
    PluginRouteModeDto {
        supported: true,
        mode: mode.label(),
        plugin_id: match mode {
            ncm_service::RouteMode::Plugin { id } => Some(id.clone()),
            _ => None,
        },
    }
}

fn route_plan_dto(plan: &ncm_service::RoutePlan) -> PluginRoutePlanDto {
    PluginRoutePlanDto {
        supported: true,
        target: plan.target.label(),
        plugin_id: plan.plugin_id().map(str::to_string),
        reason: plan.reason.as_str().to_string(),
        detail: plan.detail.clone(),
    }
}

/// 当前路由偏好.
pub fn plugin_route_mode() -> Result<PluginRouteModeDto, FfiError> {
    let host = plugin_host()?;
    let guard = host.read().unwrap_or_else(|e| e.into_inner());
    Ok(route_mode_dto(guard.route_mode()))
}

/// 改路由偏好(落盘 `plugin_route.json`, 0600 原子写)并回读生效值.
///
/// 入口只有字符串(桥接层不传枚举): `auto` / `builtin` / `plugin:<id>`;
/// 空串按 `auto`. 形状不成立(如 `plugin:` 后面为空) ⇒ `unsupported`, 不改盘.
/// id 不存在**不算错误**: 判定时按 `selectionMissing` 回内置, 见 [`plugin_route_plan`].
pub fn plugin_set_route_mode(mode: String) -> Result<PluginRouteModeDto, FfiError> {
    let parsed = ncm_service::RouteMode::parse(&mode).ok_or_else(|| {
        FfiError::unsupported(format!(
            "plugin_set_route_mode: 不认识的模式 `{mode}`, 只接受 auto / builtin / plugin:<id>"
        ))
    })?;
    let host = plugin_host()?;
    let mut guard = host.write().unwrap_or_else(|e| e.into_inner());
    guard.set_route_mode(parsed).map_err(FfiError::from)?;
    Ok(route_mode_dto(guard.route_mode()))
}

/// 这个能力这次会走谁(纯判定; 想要"实际走了谁"看日志/诊断, 那是调用期的事).
///
/// `cap` 用 [`Capability::as_str`](ncm_provider::Capability::as_str) 的标签
/// (`songUrl` / `search` / `searchAll` ...), 未知标签 ⇒ `unsupported`.
pub fn plugin_route_plan(cap: String) -> Result<PluginRoutePlanDto, FfiError> {
    let capability = ncm_provider::Capability::parse(&cap)
        .ok_or_else(|| FfiError::unsupported(format!("plugin_route_plan: 未知能力 `{cap}`")))?;
    let host = plugin_host()?;
    let guard = host.read().unwrap_or_else(|e| e.into_inner());
    Ok(route_plan_dto(&guard.route_plan(capability)))
}

// 用例用到 `ncm_service::plugins`(非 Android 才有), 所以测试模块也按平台 gate.
#[cfg(test)]
#[path = "plugin_tests.rs"]
mod tests;
