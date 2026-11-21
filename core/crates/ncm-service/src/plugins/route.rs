//! 插件 provider 的**路由层**: 回答"这次调用走插件还是内置 provider", 并把插件侧的
//! 缺失/超时/报错收敛成"回落内置 + 可区分的诊断".
//!
//! # 为什么单开一层
//!
//! `ScriptProvider::id()` 恒为 `"script"`, 插件 provider 也就不进
//! `ncm_provider::ProviderRegistry`(那份表的键是 `Provider::id()`), 只能按**插件 id**
//! 取([`PluginHost::provider`](super::host::PluginHost::provider)). 产品路径上"取哪个
//! provider"因此不再是一行 `first_with(cap)`, 而是一次判定: 用户选了谁、谁启用着、
//! 谁支持这个能力、没人能担时怎么办. 把判定集中在这一点, 产品路径只调
//! [`Core::route_decision`](crate::Core::route_decision) + [`call_routed`].
//!
//! # 选择策略(唯一口径, 禁静默猜)
//!
//! | `plugin_route.json` 的 mode | 已装载插件 | 本次路由 |
//! |---|---|---|
//! | `auto`(缺省) | 0 个支持该能力 | 内置([`RouteReason::NoPluginLoaded`]) |
//! | `auto` | 恰好 1 个支持该能力 | **自动用**它([`RouteReason::AutoSingle`]) |
//! | `auto` | ≥2 个支持该能力 | 内置([`RouteReason::Ambiguous`]) —— **不按字典序/顺序猜** |
//! | `plugin:<id>` | 该 id 已装载且支持该能力 | 用它([`RouteReason::Selected`]) |
//! | `plugin:<id>` | 该 id 没装载(禁用/移除) | 内置([`RouteReason::SelectionMissing`]) |
//! | `plugin:<id>` | 该 id 支持不了这个能力 | 内置([`RouteReason::CapabilityMissing`]) |
//! | `builtin` | 任意 | 内置([`RouteReason::BuiltinSelected`]) |
//! | 任意 | 宿主总开关关着 | 内置([`RouteReason::HostInactive`]) |
//!
//! 三条硬纪律:
//!
//! 1. **不猜**: 多个候选而用户没选 ⇒ 一律走内置并记 `Ambiguous`, 不许"先到先用"/字典序;
//! 2. **禁用立刻回默认**: 选中的插件被停用 ⇒ 当次就回内置(`SelectionMissing`),
//!    但**不自动改选**另一个插件(选择是用户的, 我们只报告它此刻不生效);
//! 3. **回落可区分**: 判定原因(`reason`)与调用期回落(`RouteUsed::Fallback`)都进
//!    [`last_route_event`] 与日志, 排查时能分清"没启用"/"没选"/"插件自己报错".
//!
//! # 回落边界
//!
//! [`call_routed`] 只对**插件侧调用失败**回落(超时/脚本抛错/协议错, 在 `ncm-plugin` 里
//! 已经收口成 `ProviderError{kind,retryable,detail}`). 内置 provider 自身的失败**不再回落**
//! (没有第二个兜底, 直接上抛), 否则真错误会被吞成"看起来成功的空结果".

use std::path::Path;
use std::sync::{Mutex, MutexGuard};

use ncm_provider::{BoxFuture, Capability, Provider, ProviderError, ProviderResult};
use serde::{Deserialize, Serialize};

/// 路由偏好文件(与 `plugin_host.json` 同目录、同一落盘手法).
pub const ROUTE_FILE: &str = "plugin_route.json";

/// 用户对插件路由的显式选择(**偏好**, 不是启用状态: 启停仍由 `plugin_host.json` +
/// `plugins-state.json` 说了算).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "lowercase")]
pub enum RouteMode {
    /// 自动: 只有一个启用插件支持该能力时自动用, 多个时不猜(缺省).
    #[default]
    Auto,
    /// 显式只用内置 provider(多个插件都在时, 这是"谁都别用"的表达方式).
    Builtin,
    /// 显式指定插件 id.
    Plugin { id: String },
}

impl RouteMode {
    /// 落盘/诊断用的稳定标签(`auto` / `builtin` / `plugin:<id>`).
    pub fn label(&self) -> String {
        match self {
            Self::Auto => "auto".to_string(),
            Self::Builtin => "builtin".to_string(),
            Self::Plugin { id } => format!("plugin:{id}"),
        }
    }

    /// 从标签解析(FFI 入口只有字符串, 见 `ncm-ffi/api/plugin.rs`).
    ///
    /// 空串按 `auto`; `plugin:` 后面必须是合法 id(空 id 视为形状不成立 ⇒ `None`).
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim();
        match text {
            "" | "auto" => Some(Self::Auto),
            "builtin" => Some(Self::Builtin),
            _ => text
                .strip_prefix("plugin:")
                .map(str::trim)
                .filter(|id| !id.is_empty())
                .map(|id| Self::Plugin { id: id.to_string() }),
        }
    }

    /// 读偏好: 文件缺失/解析失败一律回落**安全缺省**(`auto` = 单插件才用), 不 panic.
    ///
    /// 解析失败额外打一行 stderr —— 静默回落会让人以为"我明明选了"却看它不动.
    pub fn load(data_dir: &Path) -> Self {
        let path = data_dir.join(ROUTE_FILE);
        match std::fs::read(&path) {
            Ok(bytes) => match serde_json::from_slice::<Self>(&bytes) {
                Ok(mode) => mode,
                Err(err) => {
                    eprintln!(
                        "[ncm-plugin] {ROUTE_FILE} 解析失败, 按缺省(auto)处理({}): {err}",
                        path.display()
                    );
                    Self::default()
                }
            },
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Self::default(),
            Err(err) => {
                eprintln!(
                    "[ncm-plugin] 读 {} 失败, 按缺省(auto)处理: {err}",
                    path.display()
                );
                Self::default()
            }
        }
    }

    /// 原子落盘(0600, 与 `plugin_host.json` 同一手法).
    pub fn save(&self, data_dir: &Path) -> std::io::Result<()> {
        let bytes = serde_json::to_vec_pretty(self)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        crate::fsutil::write_atomic_private(data_dir, ROUTE_FILE, &bytes)
    }
}

// ------------------------------- 判定 -------------------------------

/// 本次路由的**目标**.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RouteTarget {
    /// 内置 provider(`ncm_provider::ProviderRegistry` 里那份).
    Builtin,
    /// 指定插件 id 的 provider.
    Plugin(String),
}

impl RouteTarget {
    /// 诊断/FFI 用的稳定标签.
    pub fn label(&self) -> String {
        match self {
            Self::Builtin => "builtin".to_string(),
            Self::Plugin(id) => format!("plugin:{id}"),
        }
    }
}

/// 判定依据(**回落原因在这里可区分**).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RouteReason {
    /// 只有一个启用插件支持该能力 ⇒ 自动用.
    AutoSingle,
    /// 用户显式选择的插件命中.
    Selected,
    /// 用户显式选择只走内置.
    BuiltinSelected,
    /// 多个插件支持该能力而用户没选 ⇒ 不猜.
    Ambiguous,
    /// 选中的插件没装载(停用/移除/重扫后消失).
    SelectionMissing,
    /// 选中的插件不支持这次要用的能力.
    CapabilityMissing,
    /// 宿主总开关关着(或宿主构造失败).
    HostInactive,
    /// 宿主开着但没有插件支持该能力.
    NoPluginLoaded,
}

impl RouteReason {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::AutoSingle => "autoSingle",
            Self::Selected => "selected",
            Self::BuiltinSelected => "builtinSelected",
            Self::Ambiguous => "ambiguous",
            Self::SelectionMissing => "selectionMissing",
            Self::CapabilityMissing => "capabilityMissing",
            Self::HostInactive => "hostInactive",
            Self::NoPluginLoaded => "noPluginLoaded",
        }
    }

    /// 这个原因是否值得每次变化都提醒用户(配置错误类, 而不是"本来就没插件").
    fn is_misconfig(&self) -> bool {
        matches!(
            self,
            Self::Ambiguous | Self::SelectionMissing | Self::CapabilityMissing
        )
    }
}

/// 一次路由判定: 目标 + 依据 + 可读原因.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoutePlan {
    pub target: RouteTarget,
    pub reason: RouteReason,
    /// 可读原因(日志/诊断原文), 形如 `选择的插件 \`x\` 未启用/未装载`.
    pub detail: String,
}

impl RoutePlan {
    fn builtin(reason: RouteReason, detail: impl Into<String>) -> Self {
        Self {
            target: RouteTarget::Builtin,
            reason,
            detail: detail.into(),
        }
    }

    fn plugin(id: &str, reason: RouteReason, detail: impl Into<String>) -> Self {
        Self {
            target: RouteTarget::Plugin(id.to_string()),
            reason,
            detail: detail.into(),
        }
    }

    /// 是否命中了插件(仅**判定**层面, 不代表这次调用成功).
    pub fn plugin_id(&self) -> Option<&str> {
        match &self.target {
            RouteTarget::Plugin(id) => Some(id),
            RouteTarget::Builtin => None,
        }
    }
}

/// 纯函数判定(无 IO / 无锁, 单测直接打这里).
///
/// - `mode`: 用户偏好;
/// - `host_active`: 宿主总开关开着且注册表建起来了;
/// - `loaded`: 已装载成 provider 的插件 id(字典序, 见 `PluginHost::ids`);
/// - `supports`: 该 id 的 provider 是否声明了 `cap`(能力是路由的唯一依据);
/// - `cap`: 本次调用的能力.
pub fn plan(
    mode: &RouteMode,
    host_active: bool,
    loaded: &[String],
    supports: impl Fn(&str) -> bool,
    cap: Capability,
) -> RoutePlan {
    let cap_name = cap.as_str();
    if !host_active {
        return RoutePlan::builtin(
            RouteReason::HostInactive,
            format!("插件宿主未启用/未就绪, {cap_name} 一律走内置 provider"),
        );
    }
    match mode {
        RouteMode::Builtin => RoutePlan::builtin(
            RouteReason::BuiltinSelected,
            format!("已显式选择内置 provider({cap_name})"),
        ),
        RouteMode::Plugin { id } => {
            if !loaded.iter().any(|x| x == id) {
                return RoutePlan::builtin(
                    RouteReason::SelectionMissing,
                    format!("选择的插件 `{id}` 未启用/未装载 ⇒ {cap_name} 回内置 provider"),
                );
            }
            if !supports(id) {
                return RoutePlan::builtin(
                    RouteReason::CapabilityMissing,
                    format!("选择的插件 `{id}` 未声明能力 {cap_name} ⇒ 回内置 provider"),
                );
            }
            RoutePlan::plugin(
                id,
                RouteReason::Selected,
                format!("显式选择插件 `{id}`({cap_name})"),
            )
        }
        RouteMode::Auto => {
            let candidates: Vec<&String> = loaded.iter().filter(|id| supports(id)).collect();
            match candidates.as_slice() {
                [] => RoutePlan::builtin(
                    RouteReason::NoPluginLoaded,
                    format!("没有已启用插件声明能力 {cap_name} ⇒ 走内置 provider"),
                ),
                [only] => RoutePlan::plugin(
                    only,
                    RouteReason::AutoSingle,
                    format!("只有插件 `{only}` 支持 {cap_name}, 自动选用"),
                ),
                many => RoutePlan::builtin(
                    RouteReason::Ambiguous,
                    format!(
                        "{} 个启用插件支持 {cap_name}({}), 未显式选择 ⇒ 走内置 provider",
                        many.len(),
                        many.iter()
                            .map(|id| format!("`{id}`"))
                            .collect::<Vec<_>>()
                            .join("/")
                    ),
                ),
            }
        }
    }
}

// ------------------------------- 快照 -------------------------------

/// 路由判定的**只读快照**(隔离二期切片 A2): 判定所需的全部输入, 纯内存、无锁、可克隆.
///
/// # 为什么要有快照
///
/// 判定原本直接问插件宿主([`PluginHost`](super::host::PluginHost)), 也就是取
/// [`PluginHostHandle`](super::PluginHostHandle) 的**读锁**; 而重扫/导入/启停拿的是
/// **写锁**(单插件装载预算 8s, N 个插件可能更久). 两者一撞, 取链/搜索/歌词这些
/// "只要一次判定"的 FFI 就跟着排队 —— 这就是残留 A2.
///
/// 现在判定输入在**写路径末尾**被拍成一份快照并原子替换(`Arc` 换 `Arc`), 读路径只
/// clone 一次 `Arc` 就走, 与插件句柄锁彻底解耦. 发布点全部在
/// [`PluginHost`](super::host::PluginHost) 的写路径末尾: 首扫/[`set_enabled`]/
/// [`set_root`]/[`rescan`]/[`install_*`]/[`uninstall`]/[`enable`]/[`disable`]/
/// [`set_route_mode`]. 加新的写路径**必须**在那里也发布一次, 否则判定会停在旧视图.
///
/// # 为什么快照里带 `Arc<dyn Provider>`
///
/// 判定命中插件后,**调用期**要的就是这个 `Arc`; 不带它就得回宿主再取一次(又进锁).
/// 代价: 重扫/停用后旧 provider 会活到下一次发布为止 —— 这恰好是期望语义, 已经在跑的
/// 那次调用不该被中途换掉.
///
/// # 缺快照(宿主未初始化)
///
/// [`RouteSnapshot::inactive`] 给出"宿主没开"的语义: 判定一律回内置, 不 panic、不报错
/// (与 [`Core::route_decision`](crate::Core::route_decision) 改造前的缺省一致).
///
/// 判据用例: `route_tests::route_decision_does_not_wait_for_plugin_handle_lock`(写锁
/// 300ms 期间判定 <200ms 返回)、`route_tests::slow_plugin_call_does_not_block_route_decisions`.
#[derive(Clone)]
pub struct RouteSnapshot {
    /// 宿主总开关开着且注册表建起来了(等价 [`PluginHost::is_active`]).
    host_active: bool,
    /// 用户的显式路由偏好(快照那一时刻的值).
    mode: RouteMode,
    /// 已装载插件 id, **字典序**(`plugins` 的键), 判定时直接借用, 不再每次排序.
    ids: Vec<String>,
    /// 已装载插件: id -> 能力声明 + 调用期 provider.
    plugins: std::collections::BTreeMap<String, RouteSnapshotPlugin>,
}

/// 快照里的单个插件: 装载那一刻声明的能力 + 调用期要用的 provider.
#[derive(Clone)]
pub struct RouteSnapshotPlugin {
    provider: std::sync::Arc<dyn Provider>,
    /// 能力声明在 `Provider::capabilities()` 里恒为 `&'static`, 照抄引用即可.
    capabilities: &'static [Capability],
}

impl std::fmt::Debug for RouteSnapshot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RouteSnapshot")
            .field("host_active", &self.host_active)
            .field("mode", &self.mode)
            .field("ids", &self.ids)
            .finish_non_exhaustive()
    }
}

impl RouteSnapshot {
    /// 宿主未初始化/不可用的快照: 判定恒为 [`RouteReason::HostInactive`] ⇒ 走内置.
    pub fn inactive() -> Self {
        Self::new(false, RouteMode::default(), Vec::new())
    }

    /// 组装快照(只由插件宿主的写路径调用, 见类型注释的发布点清单).
    pub fn new(
        host_active: bool,
        mode: RouteMode,
        loaded: Vec<(String, std::sync::Arc<dyn Provider>)>,
    ) -> Self {
        let mut plugins = std::collections::BTreeMap::new();
        let mut ids = Vec::with_capacity(loaded.len());
        for (id, provider) in loaded {
            ids.push(id.clone());
            plugins.insert(
                id,
                RouteSnapshotPlugin {
                    capabilities: provider.capabilities(),
                    provider,
                },
            );
        }
        // 已装载 id 是 BTreeMap 的键 ⇒ 天然字典序; 与 [`PluginHost::ids`] 的口径一致.
        ids.sort_unstable();
        Self {
            host_active,
            mode,
            ids,
            plugins,
        }
    }

    /// 宿主总开关是否真的生效(等价 [`PluginHost::is_active`]).
    pub fn is_active(&self) -> bool {
        self.host_active
    }

    /// 快照里已装载插件的 id(字典序).
    pub fn ids(&self) -> &[String] {
        &self.ids
    }

    /// 已装载插件数.
    pub fn len(&self) -> usize {
        self.ids.len()
    }

    /// 没有任何已装载插件(含宿主没开).
    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    /// 按插件 id 取调用期 provider(判定命中后直接用它, 不再回宿主).
    pub fn provider(&self, id: &str) -> Option<std::sync::Arc<dyn Provider>> {
        self.plugins.get(id).map(|entry| entry.provider.clone())
    }

    /// 该 id 是否声明了能力 `cap`(能力是路由的唯一依据).
    pub fn supports(&self, id: &str, cap: Capability) -> bool {
        self.plugins
            .get(id)
            .is_some_and(|entry| entry.capabilities.contains(&cap))
    }

    /// 本次调用该走谁(纯判定: 与 [`plan`] 同一口径, 输入全部来自本快照).
    pub fn plan(&self, cap: Capability) -> RoutePlan {
        plan(
            &self.mode,
            self.host_active,
            &self.ids,
            |id| self.supports(id, cap),
            cap,
        )
    }
}

// ------------------------------- 诊断 -------------------------------

/// 一次**真实调用**的路由结果(诊断用; 判定见 [`RoutePlan`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RouteUsed {
    /// 走内置 provider.
    Builtin,
    /// 走插件, 调用成功.
    Plugin(String),
    /// 插件调用失败 ⇒ 已回落内置(`kind`/`detail` 来自 `ProviderError`).
    Fallback {
        plugin: String,
        kind: String,
        detail: String,
    },
}

impl RouteUsed {
    pub fn label(&self) -> String {
        match self {
            Self::Builtin => "builtin".to_string(),
            Self::Plugin(id) => format!("plugin:{id}"),
            Self::Fallback { plugin, .. } => format!("fallback:{plugin}"),
        }
    }

    /// 这次调用是否回落了(诊断页/日志用它区分"用了插件"与"插件坏了换的").
    pub fn fell_back(&self) -> bool {
        matches!(self, Self::Fallback { .. })
    }
}

/// 最近一次路由调用的结果(进程内一槽, 够诊断用; 不落盘).
static LAST_EVENT: Mutex<Option<RouteUsed>> = Mutex::new(None);
/// 最近一次**打过**的配置类告警(去重, 免得每次取链刷一行日志).
static LAST_WARN: Mutex<Option<String>> = Mutex::new(None);

fn lock_slot<'a, T>(slot: &'a Mutex<T>) -> MutexGuard<'a, T> {
    slot.lock().unwrap_or_else(|e| e.into_inner())
}

fn record(used: &RouteUsed) {
    *lock_slot(&LAST_EVENT) = Some(used.clone());
}

/// 最近一次路由调用结果(`None` = 本进程还没走过路由).
pub fn last_route_event() -> Option<RouteUsed> {
    lock_slot(&LAST_EVENT).clone()
}

/// 记一条**配置类**判定告警(多插件未选/选择失效/能力不支持), 同一个 key 只打一次.
///
/// "本来就没插件"/"开关没开"这类不算错, 不打日志: 产品默认路径就是那样, 刷屏没意义.
pub fn warn_plan(cap: Capability, plan: &RoutePlan) {
    if !plan.reason.is_misconfig() {
        return;
    }
    let key = format!("{}:{}", cap.as_str(), plan.reason.as_str());
    let mut last = lock_slot(&LAST_WARN);
    if last.as_deref() == Some(key.as_str()) {
        return;
    }
    *last = Some(key);
    eprintln!(
        "[ncm-plugin] 路由提示({}): {}",
        plan.reason.as_str(),
        plan.detail
    );
}

// ------------------------------- 调用 -------------------------------

/// 一次路由可用的 provider 集合: 判定结果 + 实际能拿到的 provider.
///
/// 由 `Core::route_decision` 组装(拿锁期间一次性取好 `Arc`, 之后调用方**不必**持锁).
pub struct RouteDecision {
    /// 本次要用的能力(日志/诊断用).
    pub capability: Capability,
    pub plan: RoutePlan,
    /// 判定命中插件时 Some.
    pub plugin: Option<std::sync::Arc<dyn Provider>>,
    /// 内置 provider(回落目标; 注册表里没有支持该能力的 provider 时 None).
    pub builtin: Option<std::sync::Arc<dyn Provider>>,
}

/// 路由调用结果: 值 + 这次到底走了谁.
#[derive(Debug)]
pub struct Routed<T> {
    pub value: T,
    pub used: RouteUsed,
}

impl<T> Routed<T> {
    pub fn fell_back(&self) -> bool {
        self.used.fell_back()
    }
}

/// 按判定执行一次调用: 命中插件先试插件, **失败(超时/脚本错/协议错)才回落内置**.
///
/// `call` 只借用 provider(`Arc`), 所以两条分支共用同一份调用代码 —— 调用点不会为
/// "插件版"和"内置版"写两遍参数拼装.
///
/// 回落条件: 插件侧返回 `Err` 且内置 provider 存在. 内置 provider 缺席时**原错误上抛**
/// (没有兜底就别假装成功), 内置 provider 自己的失败也不回落(见模块头注释).
///
/// 闭包拿的是 provider 的 `Arc`(**按值**)而不是 `&Arc`: 这样 future 自己持有 provider,
/// 生命周期只剩调用点借来的请求参数(`&SongUrlRequest` / `&SearchQuery`, 即 `'p`),
/// 不会被 `for<'a>` HRTB 逼成 `'static`(`&self` 形态实际写不出来). 调用点写成
/// `|p| Box::pin(async move { p.song_url(&req).await })`.
pub async fn call_routed<'p, T, F>(decision: RouteDecision, call: F) -> ProviderResult<Routed<T>>
where
    F: Fn(std::sync::Arc<dyn Provider>) -> BoxFuture<'p, ProviderResult<T>>,
{
    let RouteDecision {
        capability,
        plan,
        plugin,
        builtin,
    } = decision;
    let cap_name = capability.as_str();

    // 命中插件: 先插件, 失败回落内置.
    if let (RouteTarget::Plugin(id), Some(plugin)) = (&plan.target, plugin) {
        let attempted = call(plugin).await;
        match attempted {
            Ok(value) => {
                let used = RouteUsed::Plugin(id.clone());
                record(&used);
                return Ok(Routed { value, used });
            }
            Err(err) => {
                let Some(builtin) = builtin else {
                    // 没有内置 provider ⇒ 插件错误原样上抛(不退化成 unsupported 掩盖真因).
                    record(&RouteUsed::Fallback {
                        plugin: id.clone(),
                        kind: err.kind.as_str().to_string(),
                        detail: err.detail.clone(),
                    });
                    return Err(err);
                };
                eprintln!(
                    "[ncm-plugin] 路由回落: 插件 `{id}` 的 {cap_name} 调用失败({}), 改用内置 provider",
                    err
                );
                let used = RouteUsed::Fallback {
                    plugin: id.clone(),
                    kind: err.kind.as_str().to_string(),
                    detail: err.detail.clone(),
                };
                let value = call(builtin).await?;
                record(&used);
                return Ok(Routed { value, used });
            }
        }
    }

    // 其余情况(内置目标): 直接内置, 不回落.
    let builtin = builtin.ok_or_else(|| {
        ProviderError::unsupported(format!(
            "no provider supports {cap_name}({} : {})",
            plan.reason.as_str(),
            plan.detail
        ))
    })?;
    let value = call(builtin).await?;
    let used = RouteUsed::Builtin;
    record(&used);
    Ok(Routed { value, used })
}

#[cfg(test)]
#[path = "route_tests.rs"]
mod tests;
