//! 插件宿主接线层(切片 2 第五步): `Core` 与 [`PluginRegistry`] 之间**唯一的一层**.
//!
//! # 这一层解决什么
//!
//! 前四步把"扫描/启停/装载/按插件 id 取 provider"做完了, 但没有**归属**: 没有东西决定
//! 插件根目录在哪、什么时候扫、谁来持有注册表. 本层把它接进 [`Core`](crate::Core),
//! **只做 Rust 侧** —— 没有 FFI 导出, 没有 UI, 产品默认路径的连接数/线程数/目录数一个都不多.
//!
//! | 动作 | 入口 | 落盘 |
//! |---|---|---|
//! | 读策略 + (开启时)建注册表并首扫 | [`PluginHost::open`] | 无 |
//! | 总开关 | [`PluginHost::set_enabled`] | `<data_dir>/plugin_host.json`(0600) |
//! | 根目录 | [`PluginHost::set_root`] | 同上 |
//! | 列表 | [`PluginHost::summaries`] | 无 |
//! | 单插件启停 | [`PluginHost::enable`] / [`PluginHost::disable`] | `<root>/plugins-state.json`(由 `PluginManager` 写) |
//! | 失败视图 | [`PluginHost::failures`] / [`PluginHost::rejected`] | 无 |
//! | 重扫 | [`PluginHost::rescan`] | 无 |
//! | 按插件 id 取 provider | [`PluginHost::provider`] | 无 |
//! | 状态上报 | [`PluginHost::status`] | 无 |
//!
//! # 缺省值: **不扫描**(安全默认, 理由写在下面)
//!
//! 策略文件 `<data_dir>/plugin_host.json`:
//!
//! ```json
//! { "version": 1, "enabled": false, "root": null }
//! ```
//!
//! 文件不存在 ⇒ 用 [`PluginHostPolicy::default`](`enabled = false`). 也就是:
//!
//! - **不创建** `<data_dir>/plugins/`(老用户盘上不会突然多一个目录);
//! - **不读**插件目录、**不建** QuickJS 实例、**不建** reqwest 客户端(零启动成本);
//! - 插件目录里就算有 `plugins-state.json` 声明了 `enabled: {demo: true}`, 也**不装载** ——
//!   单插件开关只在宿主总开关打开后才有意义.
//!
//! 为什么选"不扫描"而不是"扫描但全停用":
//!
//! 1. **产品还没有入口**: 插件管理页/导入都未做, 扫了也没人能启停, 只会在磁盘上留下
//!    `<root>/<id>/data/` 并让每个已启用插件在启动时起一条 QuickJS worker 线程;
//! 2. **执行权不该由磁盘文件单方面给出**: 单插件状态文件(`plugins-state.json`)是宿主自己写的,
//!    但它**可被任意复制/手改**(从别人机器拷一个插件目录过来). 若"扫描即尊重该文件",
//!    那么"拷贝一个目录到数据目录"就等于"远程代码在本机启动" —— 少了用户显式同意这一道门;
//! 3. **失败面**: 扫描要碰用户文件系统(坏清单/无权限/symlink 逃逸), 这些在缺省路径上
//!    一律不该发生. 现在 `Core::open` **永远不会**因插件失败(`PluginHost::open` 不返回
//!    `Result`; 任何构造失败都记进 [`PluginHostStatus::error`] 并降级成"宿主不可用").
//!
//! 判据用例(缺省策略被断言钉住): `host_tests::default_policy_creates_no_plugin_dir`、
//! `host_tests::enabled_state_on_disk_is_ignored_while_policy_is_off`、
//! `host_tests::core_default_opens_without_plugin_host`.
//!
//! # 错误口径: Core 边界只有 `ProviderError{kind,retryable,detail}`
//!
//! 本层**不新造错误类型**. 管理层的 [`ManagerError`](super::ManagerError)(带 `ManagerErrorKind`)
//! 在 [`to_provider_error`] **这一处**翻成产品统一的 `ProviderError`, 之后 Core 的所有可失败
//! 插件操作都返回 `ProviderResult<_>` —— 与 provider 方法调用期完全同一个口径, 调用方只按
//! `kind` 决策, 不需要认第二套错误枚举.
//!
//! | `ManagerErrorKind` | `ProviderErrorKind` | `retryable` | 理由 |
//! |---|---|---|---|
//! | `NotInstalled` | `NotFound` | false | 该 id 没登记(目录不存在/清单坏/没扫到), 重试不会变 |
//! | `Disabled` | `Forbidden` | false | 用户停用 = 策略拒绝 |
//! | `UnsafePath` | `Forbidden` | false | 本地安全拒绝(目录名/symlink 逃逸), 重试不会变 |
//! | `Manifest` | `Unsupported` | false | 清单/入口/来源文本形状不成立(含来源体积超限), 重试无用 |
//! | `Io` | `Internal` | false | 本地文件系统失败 |
//! | `Network` | `Network` | **true** | URL 导入的抓取失败(DNS/连接/超时/非 2xx), 瞬时且值得重试 |
//! | `Plugin` | `Internal` | false | 装载失败(语法错/初始化超时) |
//!
//! `detail` 保留管理层原文(`"[notInstalled] 插件 \`x\` 未登记..."`), 所以细分原因**不丢**,
//! 只是不再单开错误类型. `retryable` 在管理层**除了 `Network` 之外**均为 `false`: 调用期
//! (provider 方法)的 `retryable` 由 `PluginError::retryable` 决定, 那里才是"重试有没有意义"
//! 的唯一判据; URL 导入是本地人对网络的一次性动作, 与调用期无关, 所以单独一间.
//!
//! 宿主不可用(总开关关闭 / 构造失败)时: 读类接口返回空视图(`summaries()` 空、`provider()`
//! `None`), 写类接口(`enable`/`disable`/`rescan`)返回 `Forbidden`(关闭)或 `Internal`(构造失败)
//! 并把原因写进 `detail` —— 不 panic, 不静默吞掉.
//!
//! # 与 provider 路由的关系(不变的事实)
//!
//! `ScriptProvider::id()` 恒为 `"script"`, 所以路由**必须**认"插件 id -> provider"这张表
//! (见 [`PluginRegistry`] 头注释), `ncm_provider::ProviderRegistry` 不放插件 provider.
//!
//! # 路由判定快照(切片 A2: 判定不再进本宿主的锁)
//!
//! 判定读的是 [`RouteSnapshot`] 的共享槽位([`Self::snapshot_handle`]), **不读本宿主的
//! `RwLock`** —— 于是重扫/导入(持写锁, 单插件装载预算 8s × N)期间, 取链/搜索/歌词这些
//! "只要一次判定"的 FFI 照跑, 不会被排队.
//!
//! 快照在本层**所有**会改变判定输入的写路径末尾由 [`Self::publish_snapshot`] 原子替换
//! (`Arc` 换 `Arc`): [`Self::rebuild`](首扫/`set_enabled`/`set_root`) /
//! [`Self::rescan`] / [`Self::install_source`] / [`Self::install_with`] /
//! [`Self::uninstall`] / [`Self::enable`] / [`Self::disable`] /
//! [`Self::set_route_mode`]. **加新的写路径必须在那里也发布一次**, 否则判定会停在旧视图
//! (判据用例 `route_tests::route_snapshot_is_republished_by_rescan_and_policy_writes`).
//!
//! 锁序仍然只有一条: `Core 锁 -> 插件句柄`. 快照槽位是**叶子锁**(持它时不再取任何锁,
//! 读侧更是只 clone 一次 `Arc` 就放), 所以不引入新的死锁面.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use ncm_plugin::Transport;
use ncm_provider::{Provider, ProviderError, ProviderErrorKind, ProviderResult};
use serde::{Deserialize, Serialize};

use super::manager::{ManagerError, ManagerErrorKind, PluginSummary};
use super::registry::{PluginRegistry, RegistryReport};
use super::route::{self, RouteMode, RoutePlan, RouteSnapshot};
use super::transport::ReqwestTransport;

/// 宿主策略文件名(与 `credential_policy.json` 同目录、同一落盘手法).
pub const POLICY_FILE: &str = "plugin_host.json";
/// 缺省插件根目录(相对数据目录); 只在总开关打开时才会被创建.
pub const DEFAULT_ROOT_DIR: &str = "plugins";
/// 策略文件版本(改形状才加, 读的时候不校验).
const POLICY_VERSION: u32 = 1;

// ------------------------------- 策略 -------------------------------

/// 宿主策略: 只回答"要不要扫、扫哪里", **不回答单插件是否启用**(那是 `plugins-state.json`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PluginHostPolicy {
    #[serde(default = "default_version")]
    pub version: u32,
    /// 宿主总开关. **缺省 false = 不扫描**(理由见模块头注释).
    #[serde(default)]
    pub enabled: bool,
    /// 插件根目录. `None` = `<data_dir>` + [`DEFAULT_ROOT_DIR`]; 相对路径按数据目录解析.
    #[serde(default)]
    pub root: Option<PathBuf>,
}

fn default_version() -> u32 {
    POLICY_VERSION
}

impl Default for PluginHostPolicy {
    fn default() -> Self {
        Self {
            version: POLICY_VERSION,
            enabled: false,
            root: None,
        }
    }
}

impl PluginHostPolicy {
    pub fn path(data_dir: &Path) -> PathBuf {
        data_dir.join(POLICY_FILE)
    }

    /// 读策略: 文件缺失/解析失败一律回落**安全缺省**(不扫描), 不 panic.
    ///
    /// 解析失败额外打一行 stderr —— 静默回落会让人以为"我明明开了"却又看它不动.
    pub fn load(data_dir: &Path) -> Self {
        let path = Self::path(data_dir);
        match std::fs::read(&path) {
            Ok(bytes) => match serde_json::from_slice::<Self>(&bytes) {
                Ok(policy) => policy,
                Err(err) => {
                    eprintln!(
                        "[ncm-plugin] {POLICY_FILE} 解析失败, 按缺省(不扫描)处理({}): {err}",
                        path.display()
                    );
                    Self::default()
                }
            },
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Self::default(),
            Err(err) => {
                eprintln!(
                    "[ncm-plugin] 读 {} 失败, 按缺省(不扫描)处理: {err}",
                    path.display()
                );
                Self::default()
            }
        }
    }

    /// 原子落盘(0600, 与凭据策略同一手法).
    pub fn save(&self, data_dir: &Path) -> std::io::Result<()> {
        let bytes = serde_json::to_vec_pretty(self)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        crate::fsutil::write_atomic_private(data_dir, POLICY_FILE, &bytes)
    }

    /// 实际生效的插件根目录(纯函数, 不碰盘).
    pub fn resolve_root(&self, data_dir: &Path) -> PathBuf {
        match &self.root {
            Some(root) if root.is_absolute() => root.clone(),
            Some(root) => data_dir.join(root),
            None => data_dir.join(DEFAULT_ROOT_DIR),
        }
    }
}

// ------------------------------- 状态 -------------------------------

/// 宿主状态(给 FFI/UI 上报): 一句话回答"插件现在能不能用、为什么不能用".
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PluginHostStatus {
    /// 策略文件里的总开关.
    pub enabled: bool,
    /// 生效的插件根目录(**未启用时也给**, 就是"开了之后会用的那个").
    pub root: PathBuf,
    /// 注册表真的建起来了(总开关打开且构造成功).
    pub active: bool,
    /// 构造/重扫失败的可读原因(`active == false` 且有值 ⇒ 是失败而非"没开").
    pub error: Option<String>,
    /// 已装载成 provider 的插件 id(字典序), 未启用时为空.
    pub loaded: Vec<String>,
    /// 失败条目数(扫描/清单/装载失败, 不含"停用").
    pub failed: usize,
}

// ------------------------------- 宿主 -------------------------------

/// 插件宿主: 策略 + 注册表 + 状态. `Core` 持有它, 唯一入口.
pub struct PluginHost {
    data_dir: PathBuf,
    policy: PluginHostPolicy,
    /// 出站实现(生产 = [`ReqwestTransport`], 测试可注入); 只有需要时才会被造出来.
    transport: Option<Arc<dyn Transport>>,
    registry: Option<PluginRegistry>,
    error: Option<String>,
    /// 路由偏好(用户的显式选择; 落盘 [`ROUTE_FILE`](super::route::ROUTE_FILE)).
    mode: RouteMode,
    /// 路由判定快照的共享槽位(切片 A2). 与 `Core` 共用**同一个 `Arc`**, 读路径
    /// (`Core::route_decision`)只 clone 快照, 不取本宿主锁 —— 所以重扫/导入持写锁期间
    /// 判定照跑. 快照在下面每个写路径末尾由 [`Self::publish_snapshot`] 原子替换.
    snapshot: super::RouteSnapshotHandle,
}

impl PluginHost {
    /// 生产构造: 读策略, 只有总开关打开时才建注册表(⇒ 缺省路径零成本、零目录).
    ///
    /// **不返回 `Result`**: 插件宿主的任何失败都不能拖垮 `Core::open`, 失败原因进
    /// [`PluginHostStatus::error`].
    pub fn open(data_dir: &Path) -> Self {
        let mut host = Self {
            data_dir: data_dir.to_path_buf(),
            policy: PluginHostPolicy::load(data_dir),
            transport: None,
            registry: None,
            error: None,
            mode: RouteMode::load(data_dir),
            snapshot: std::sync::Arc::new(std::sync::RwLock::new(std::sync::Arc::new(
                RouteSnapshot::inactive(),
            ))),
        };
        // 缺省(不扫描)时不建 reqwest 客户端: 少一个后台 runtime 线程、少一次 DNS/UA 初始化.
        if let Err(err) = host.rebuild() {
            eprintln!("[ncm-plugin] 插件宿主未就绪(不影响 Core 启动): {err}");
        }
        host
    }

    /// 注入 transport(测试/headless): **仍受策略总开关约束**, 只是换掉出站实现.
    pub fn open_with_transport(data_dir: &Path, transport: Arc<dyn Transport>) -> Self {
        let mut host = Self {
            data_dir: data_dir.to_path_buf(),
            policy: PluginHostPolicy::load(data_dir),
            transport: Some(transport),
            registry: None,
            error: None,
            mode: RouteMode::load(data_dir),
            snapshot: std::sync::Arc::new(std::sync::RwLock::new(std::sync::Arc::new(
                RouteSnapshot::inactive(),
            ))),
        };
        if let Err(err) = host.rebuild() {
            eprintln!("[ncm-plugin] 插件宿主未就绪(不影响 Core 启动): {err}");
        }
        host
    }

    pub fn policy(&self) -> &PluginHostPolicy {
        &self.policy
    }

    /// 注册表是否可用(总开关打开 + 构造成功).
    pub fn is_active(&self) -> bool {
        self.registry.is_some()
    }

    /// 生效的插件根目录.
    pub fn root(&self) -> PathBuf {
        self.policy.resolve_root(&self.data_dir)
    }

    // ---------------- 路由快照(切片 A2) ----------------

    /// 路由判定快照的共享槽位. `Core` 在 `open` 时拿走同一个 `Arc`, 读路径靠它绕开本宿主锁.
    ///
    /// **只有一处发布点**: [`Self::publish_snapshot`](Self::publish_snapshot)(所有写路径末尾).
    pub fn snapshot_handle(&self) -> super::RouteSnapshotHandle {
        self.snapshot.clone()
    }

    /// 当前快照(短锁 + `Arc::clone`; 之后判定完全不再进锁).
    ///
    /// 缺快照(理论上不会发生: 构造期就发布了"宿主没开"的那份)时给
    /// [`RouteSnapshot::inactive`] 的语义 —— 一律内置, 不 panic.
    pub fn route_snapshot(&self) -> std::sync::Arc<RouteSnapshot> {
        let slot = self.snapshot.read().unwrap_or_else(|e| e.into_inner());
        slot.clone()
    }

    /// 按当前注册表 + 路由偏好拍一份快照(纯内存, 不碰盘/不碰网络).
    fn build_snapshot(&self) -> RouteSnapshot {
        let loaded = match self.registry.as_ref() {
            Some(registry) => registry.entries(),
            None => Vec::new(),
        };
        RouteSnapshot::new(self.is_active(), self.mode.clone(), loaded)
    }

    /// **原子替换**快照(`Arc` 换 `Arc`; 读路径永远看到完整的旧值或完整的新值).
    ///
    /// 发布纪律: 任何会改变判定输入的写路径(重扫/导入/卸载/启停/`set_root`/
    /// `set_route_mode`/首扫)末尾都必须调它, 否则判定会停在旧视图.
    fn publish_snapshot(&self) {
        let fresh = std::sync::Arc::new(self.build_snapshot());
        let mut slot = self.snapshot.write().unwrap_or_else(|e| e.into_inner());
        *slot = fresh;
    }

    /// 状态上报(UI 用来解释"为什么列表是空的").
    pub fn status(&self) -> PluginHostStatus {
        PluginHostStatus {
            enabled: self.policy.enabled,
            root: self.root(),
            active: self.is_active(),
            error: self.error.clone(),
            loaded: self.ids(),
            failed: self.failures().len(),
        }
    }

    // ---------------- 读 ----------------

    /// 插件列表(未启用 ⇒ 空: 没扫描就没有"已登记"这回事).
    pub fn summaries(&self) -> Vec<PluginSummary> {
        self.registry
            .as_ref()
            .map(PluginRegistry::summaries)
            .unwrap_or_default()
    }

    /// 失败原因(清单坏/路径不安全/装载失败; 未启用 ⇒ 空).
    pub fn failures(&self) -> BTreeMap<String, String> {
        self.registry
            .as_ref()
            .map(|r| r.failures().clone())
            .unwrap_or_default()
    }

    /// 最近一次扫描被拒收的条目(跨目录同 id / 目录不可访问).
    pub fn rejected(&self) -> Vec<(String, String)> {
        self.registry
            .as_ref()
            .map(|r| r.rejected().to_vec())
            .unwrap_or_default()
    }

    /// 已装载 provider 的插件 id(字典序; 未启用 ⇒ 空).
    pub fn ids(&self) -> Vec<String> {
        self.registry
            .as_ref()
            .map(|r| r.ids().into_iter().map(str::to_string).collect())
            .unwrap_or_default()
    }

    /// 各已装载插件**自报**的平台代号(`send('inited', {sources})` 的 key).
    ///
    /// 只用于 UI 展示与诊断; 路由判定不看它(能力面看 `capabilities`)。
    pub fn sources(&self) -> std::collections::BTreeMap<String, Vec<String>> {
        let Some(registry) = self.registry.as_ref() else {
            return std::collections::BTreeMap::new();
        };
        registry
            .entries()
            .into_iter()
            .map(|(id, provider)| (id, provider.declared_sources()))
            .collect()
    }

    /// 拉走所有已装载插件累计的诊断日志(按插件 id 分组, 空组丢弃).
    ///
    /// **取走语义**: 同一批日志只交付一次; UI 按需拉取(不做后台轮询 —— 拉取本身
    /// 不碰网络, 但要拿 `Core` 的唯一一把锁, 轮询会拖慢别的域调用).
    pub fn take_logs(&self) -> Vec<(String, Vec<String>)> {
        let Some(registry) = self.registry.as_ref() else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for (id, provider) in registry.entries() {
            let lines = provider.take_logs();
            if !lines.is_empty() {
                out.push((id, lines));
            }
        }
        out
    }

    /// 按**插件 id** 取 provider(不是 `Provider::id()`, 后者恒为 `"script"`).
    ///
    /// 未启用/未装载/不存在都返回 `None` —— 这是查询不是操作, 不制造错误;
    /// 想区分原因请看 [`Self::failures`] / [`Self::summaries`] 的 `error` 字段.
    pub fn provider(&self, id: &str) -> Option<Arc<dyn Provider>> {
        self.registry.as_ref().and_then(|r| r.get(id))
    }

    /// 路由偏好(用户的显式选择; `auto` = 单插件自动、多插件不猜).
    pub fn route_mode(&self) -> &RouteMode {
        &self.mode
    }

    /// 改路由偏好并落盘(`plugin_route.json`, 0600 原子写).
    ///
    /// **不校验 id 是否存在**: 偏好是"我想用谁", 插件可能稍后才启用; 失效的选择在
    /// [`Self::route_plan`] 里报 `selectionMissing` 并回内置, 不在这里制造错误.
    /// 写盘失败 ⇒ 内存回滚, 返回 `internal`(与 `set_enabled` 同一手法).
    pub fn set_route_mode(&mut self, mode: RouteMode) -> ProviderResult<()> {
        let previous = std::mem::replace(&mut self.mode, mode);
        let result = match self.mode.save(&self.data_dir) {
            Ok(()) => Ok(()),
            Err(io) => {
                self.mode = previous;
                Err(ProviderError::internal(format!(
                    "写 {} 失败: {io}",
                    route::ROUTE_FILE
                )))
            }
        };
        // 判定输入变了(失败时已回滚 ⇒ 发布的是回滚后的值, 同样一致) ⇒ 立刻换快照.
        self.publish_snapshot();
        result
    }

    /// 本次调用该走谁(纯判定, 不碰 provider 调用).
    ///
    /// 能力是唯一路由依据: 插件没声明 `cap` 就不算候选(见 [`super::route::plan`]).
    pub fn route_plan(&self, cap: ncm_provider::Capability) -> RoutePlan {
        let loaded = self.ids();
        route::plan(
            &self.mode,
            self.is_active(),
            &loaded,
            |id| self.provider(id).is_some_and(|p| p.supports(cap)),
            cap,
        )
    }

    // ---------------- 写 ----------------

    /// 宿主总开关: 打开 = 建注册表 + 首扫; 关闭 = 摘掉注册表(**不删目录、不改单插件状态**).
    ///
    /// 打开失败(根目录建不出来/出站客户端建不出来)时**不落盘**并回滚内存策略 ——
    /// 否则"这次开了、下次启动才发现开不起来"更难查.
    pub fn set_enabled(&mut self, enabled: bool) -> ProviderResult<()> {
        if self.policy.enabled == enabled && (self.registry.is_some() || !enabled) {
            return Ok(());
        }
        let previous = self.policy.clone();
        self.policy.enabled = enabled;
        if let Err(err) = self.rebuild() {
            self.policy = previous;
            let _ = self.rebuild();
            return Err(err);
        }
        if let Err(io) = self.policy.save(&self.data_dir) {
            self.policy = previous;
            let _ = self.rebuild();
            return Err(ProviderError::internal(format!(
                "写 {POLICY_FILE} 失败: {io}"
            )));
        }
        Ok(())
    }

    /// 改插件根目录(`None` = 回到缺省 `<data_dir>/plugins`). 未启用时只落盘不扫描.
    pub fn set_root(&mut self, root: Option<PathBuf>) -> ProviderResult<()> {
        let previous = self.policy.clone();
        self.policy.root = root;
        if let Err(err) = self.rebuild() {
            self.policy = previous;
            let _ = self.rebuild();
            return Err(err);
        }
        if let Err(io) = self.policy.save(&self.data_dir) {
            self.policy = previous;
            let _ = self.rebuild();
            return Err(ProviderError::internal(format!(
                "写 {POLICY_FILE} 失败: {io}"
            )));
        }
        Ok(())
    }

    /// 重扫根目录并重建 provider 视图(全量重建, 没有热重载).
    /// 从**脚本文本**导入一个插件(写盘 + 立即重扫装载).
    ///
    /// 口径:
    /// - 宿主总开关没开 ⇒ `forbidden`(与其它写操作一致, 不隐式打开总开关);
    /// - 清单/入口文件名不合法 ⇒ `unsupported`(Manifest), **不落任何文件**;
    /// - 文件系统失败 ⇒ `internal`;
    /// - 覆盖同名插件是允许的(用户显式提交), 该插件的 `data/` 存储保留;
    /// - 成功后按 `plugins-state.json` 决定是否装载 —— 导入**不**自动启用(与目录导入一致)。
    #[allow(clippy::too_many_arguments)]
    pub fn install_source(
        &mut self,
        id: &str,
        name: &str,
        version: &str,
        entry: &str,
        source: &str,
        lx_events: &[String],
        request_domains: &[String],
    ) -> ProviderResult<RegistryReport> {
        let result = self.install_source_report(
            id,
            name,
            version,
            entry,
            source,
            lx_events,
            request_domains,
        );
        self.publish_snapshot();
        result
    }

    /// [`Self::install_source`] 的本体(发布快照由外层统一做).
    #[allow(clippy::too_many_arguments)]
    fn install_source_report(
        &mut self,
        id: &str,
        name: &str,
        version: &str,
        entry: &str,
        source: &str,
        lx_events: &[String],
        request_domains: &[String],
    ) -> ProviderResult<RegistryReport> {
        let Some(registry) = self.registry.as_mut() else {
            return Err(ProviderError::forbidden(
                "插件宿主未启用: 先打开总开关再导入",
            ));
        };
        let report = registry
            .manager_mut()
            .install_source(id, name, version, entry, source, lx_events, request_domains)
            .map_err(|err| to_provider_error(&err))?;
        // 写盘后必须让注册表重新扫一遍, 否则 provider 视图还是旧的(与 rescan 同口径).
        let refreshed = registry.scan();
        self.error = None;
        Ok(RegistryReport {
            scanned: report.installed.clone(),
            loaded: refreshed.loaded.clone(),
            skipped: refreshed.skipped.clone(),
            failed: refreshed.failed.clone(),
        })
    }

    /// 从**本机文件**导入一个插件(读文件 → 写盘 → 重扫装载).
    ///
    /// 口径与 [`Self::install_source`] 一致: 未启用总开关 ⇒ `forbidden`; 来源文件读不了/不是
    /// UTF-8/超过 2 MiB ⇒ `internal`(`Io`)或 `unsupported`(`Manifest`); 任何失败**不落文件**.
    #[allow(clippy::too_many_arguments)]
    pub fn install_file(
        &mut self,
        id: &str,
        name: &str,
        version: &str,
        path: &Path,
        lx_events: &[String],
        request_domains: &[String],
    ) -> ProviderResult<RegistryReport> {
        self.install_with(|manager| {
            manager.install_file(id, name, version, path, lx_events, request_domains)
        })
    }

    /// 从 **URL** 导入一个插件(只允许 https).
    ///
    /// 三条硬约束全在落盘之前: `https://` 形态、重定向上限、响应体 ≤ 2 MiB; 失败不落任何文件.
    /// 抓取失败是**唯一**可重试的插件错误(`network` + `retryable = true`).
    #[allow(clippy::too_many_arguments)]
    pub fn install_url(
        &mut self,
        id: &str,
        name: &str,
        version: &str,
        url: &str,
        lx_events: &[String],
        request_domains: &[String],
    ) -> ProviderResult<RegistryReport> {
        self.install_with(|manager| {
            manager.install_url(id, name, version, url, lx_events, request_domains)
        })
    }

    /// 卸载一个插件: 停用 → 删目录(含该插件的 `data/`) → 清状态 → 重扫; 指向它的路由选择回 `Auto`.
    ///
    /// 未启用总开关 ⇒ `forbidden`; 非法 id(symlink/`..`/绝对路径) ⇒ `forbidden`;
    /// 目录删不掉 ⇒ `internal` 且插件**保持停用**(不留下"启用但删了一半"的状态).
    /// 路由偏好回 `Auto` 写盘失败时返回 `internal`, 但目录已经删了(不可回滚) —— 下次
    /// 判定会自己报 `selectionMissing` 并回内置.
    pub fn uninstall(&mut self, id: &str) -> ProviderResult<RegistryReport> {
        let result = self.uninstall_inner(id);
        // 目录已删/可能已回 `auto` ⇒ 无论成功失败都要让判定看到新视图.
        self.publish_snapshot();
        result
    }

    /// [`Self::uninstall`] 的本体(发布快照由外层统一做).
    fn uninstall_inner(&mut self, id: &str) -> ProviderResult<RegistryReport> {
        // 借用分两段: 删目录/清状态只需注册表, 改路由偏好要 &mut self(它落自己的盘).
        {
            let Some(registry) = self.registry.as_mut() else {
                return Err(self.inactive_error());
            };
            registry
                .manager_mut()
                .uninstall(id)
                .map_err(|err| to_provider_error(&err))?;
        }
        // 路由选择指向被卸载的 id ⇒ 回 auto, 否则判定永远停在 selectionMissing.
        let selected = matches!(&self.mode, RouteMode::Plugin { id: current } if current == id);
        if selected {
            self.set_route_mode(RouteMode::Auto)?;
        }
        let Some(registry) = self.registry.as_mut() else {
            return Err(self.inactive_error());
        };
        let refreshed = registry.scan();
        self.error = None;
        Ok(RegistryReport {
            // 卸载不"新登记"任何插件, 所以 `scanned` 恒为空; 结果看 loaded/skipped/failed.
            scanned: Vec::new(),
            loaded: refreshed.loaded,
            skipped: refreshed.skipped,
            failed: refreshed.failed,
        })
    }

    /// 导入类操作的公共壳: 取注册表 → 交给目录管理器 → 重扫刷新 provider 视图.
    fn install_with(
        &mut self,
        run: impl FnOnce(
            &mut super::manager::PluginManager,
        ) -> Result<super::manager::InstallReport, ManagerError>,
    ) -> ProviderResult<RegistryReport> {
        let result = self.install_report(run);
        self.publish_snapshot();
        result
    }

    /// [`Self::install_with`] 的本体(发布快照由外层统一做).
    fn install_report(
        &mut self,
        run: impl FnOnce(
            &mut super::manager::PluginManager,
        ) -> Result<super::manager::InstallReport, ManagerError>,
    ) -> ProviderResult<RegistryReport> {
        let Some(registry) = self.registry.as_mut() else {
            return Err(self.inactive_error());
        };
        let report = run(registry.manager_mut()).map_err(|err| to_provider_error(&err))?;
        let refreshed = registry.scan();
        self.error = None;
        Ok(RegistryReport {
            scanned: report.installed.clone(),
            loaded: refreshed.loaded.clone(),
            skipped: refreshed.skipped.clone(),
            failed: refreshed.failed.clone(),
        })
    }

    /// 写类操作在"宿主不可用"时的统一错误(关闭 ⇒ forbidden / 构造失败 ⇒ internal).
    fn inactive_error(&self) -> ProviderError {
        match &self.error {
            Some(reason) => ProviderError::internal(format!("插件宿主未就绪: {reason}")),
            None => ProviderError::forbidden(format!(
                "插件宿主未启用({POLICY_FILE} 的 enabled 缺省 false): 先打开总开关再操作插件"
            )),
        }
    }

    /// 重扫插件根目录(全量重建, 没有热重载)
    pub fn rescan(&mut self) -> ProviderResult<RegistryReport> {
        let result = self.registry_mut().map(|registry| registry.scan());
        self.publish_snapshot();
        result
    }

    /// 启用插件并即时装载(失败 ⇒ `Err`, 但"启用"状态已经落盘, 下次重扫会重试装载).
    pub fn enable(&mut self, id: &str) -> ProviderResult<()> {
        let result = self
            .registry_mut()
            .and_then(|registry| registry.enable(id).map_err(|err| to_provider_error(&err)));
        // 即使失败, 边界状态也可能变了(启用已落盘) ⇒ 照发一次快照.
        self.publish_snapshot();
        result
    }

    /// 停用插件并摘掉内存里的 provider.
    pub fn disable(&mut self, id: &str) -> ProviderResult<()> {
        let result = self
            .registry_mut()
            .and_then(|registry| registry.disable(id).map_err(|err| to_provider_error(&err)));
        self.publish_snapshot();
        result
    }

    // ---------------- 内部 ----------------

    /// 取可用的注册表: 总开关关闭 ⇒ `Forbidden`; 开着但构造失败 ⇒ `Internal`; 都带原因.
    ///
    /// 写类操作共用这一处判断 —— 未启用时**不**静默 `Ok`/`None`, 也不 panic.
    fn registry_mut(&mut self) -> ProviderResult<&mut PluginRegistry> {
        if self.registry.is_none() {
            return Err(self.inactive_error());
        }
        self.registry
            .as_mut()
            .ok_or_else(|| ProviderError::internal("插件宿主内部状态不一致: registry 缺失"))
    }

    /// 按当前策略重建注册表(不落盘: 落盘归调用方), 结束时发布一次快照.
    fn rebuild(&mut self) -> ProviderResult<()> {
        let result = self.rebuild_registry();
        // 首扫/开关/换根都会改判定输入; 失败时注册表已被摘掉(⇒ 宿主不可用), 同样要发布.
        self.publish_snapshot();
        result
    }

    /// [`Self::rebuild`] 的本体(发布快照由外层统一做).
    fn rebuild_registry(&mut self) -> ProviderResult<()> {
        self.registry = None;
        self.error = None;
        if !self.policy.enabled {
            // 关闭: 不建目录、不扫盘、不建客户端.
            return Ok(());
        }
        let root = self.policy.resolve_root(&self.data_dir);
        let transport = match self.ensure_transport() {
            Ok(transport) => transport,
            Err(err) => {
                self.error = Some(err.detail.clone());
                return Err(err);
            }
        };
        match PluginRegistry::open(root, transport) {
            Ok(mut registry) => {
                // 首扫: 坏插件只进 failures, 不影响其它插件, 也不影响 Core.
                registry.scan();
                self.registry = Some(registry);
                Ok(())
            }
            Err(err) => {
                let err = to_provider_error(&err);
                self.error = Some(err.detail.clone());
                Err(err)
            }
        }
    }

    /// 出站客户端: 建一次复用(重开/重扫不重复建连接池).
    fn ensure_transport(&mut self) -> ProviderResult<Arc<dyn Transport>> {
        if let Some(transport) = &self.transport {
            return Ok(transport.clone());
        }
        let transport: Arc<dyn Transport> = Arc::new(ReqwestTransport::new()?);
        self.transport = Some(transport.clone());
        Ok(transport)
    }
}

impl std::fmt::Debug for PluginHost {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PluginHost")
            .field("policy", &self.policy)
            .field("active", &self.is_active())
            .field("loaded", &self.ids())
            .field("failed", &self.failures().len())
            .field("error", &self.error)
            .finish_non_exhaustive()
    }
}

/// `ManagerError` -> `ProviderError`: **全仓唯一的插件管理层错误翻译点**.
///
/// 映射表与 `retryable` 口径见模块头注释; `detail` 用管理层原文(`"[kind] detail"`),
/// 细分原因不丢, 也不新造错误类型.
fn to_provider_error(err: &ManagerError) -> ProviderError {
    let (kind, retryable) = match err.kind {
        ManagerErrorKind::NotInstalled => (ProviderErrorKind::NotFound, false),
        ManagerErrorKind::Disabled => (ProviderErrorKind::Forbidden, false),
        ManagerErrorKind::UnsafePath => (ProviderErrorKind::Forbidden, false),
        ManagerErrorKind::Manifest => (ProviderErrorKind::Unsupported, false),
        ManagerErrorKind::Io => (ProviderErrorKind::Internal, false),
        // 唯一可重试的管理层错误: URL 导入时 DNS/连接/超时/非 2xx 都是瞬时的.
        ManagerErrorKind::Network => (ProviderErrorKind::Network, true),
        ManagerErrorKind::Plugin => (ProviderErrorKind::Internal, false),
    };
    ProviderError::new(kind, retryable, err.to_string())
}

#[cfg(test)]
#[path = "host_tests.rs"]
mod tests;
