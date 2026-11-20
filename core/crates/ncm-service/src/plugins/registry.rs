//! 插件 provider 注册表(切片 2 第四步): 把"已登记 + 已启用"的插件装配成
//! 产品既有的 `Provider` 对象.
//!
//! **接线状态(切片 2 第五步)**: 已由 `super::host::PluginHost` 接进 `Core::open`(Rust 侧);
//! 仍**没有** FFI 导出/UI 入口, 且缺省不扫描(总开关在 `plugin_host.json`), 所以产品默认路径
//! 不受影响. 管理层错误(`ManagerError`)到 `ProviderError` 的**唯一**翻译点在
//! `host::to_provider_error`(映射表见 `host.rs` 头注释).
//!
//! # 这一层负责什么
//!
//! | 动作 | 入口 | 落盘 |
//! |---|---|---|
//! | 扫描根目录 + 装载 | [`PluginRegistry::scan`] | 无(启停状态归 `PluginManager`) |
//! | 扫描额外目录(跨根) | [`PluginRegistry::scan_dir`] | 无 |
//! | 启停 + 即时装载/卸载 | [`PluginRegistry::enable`] / [`PluginRegistry::disable`] | `<root>/plugins-state.json` |
//! | 按插件 id 取 provider | [`PluginRegistry::get`] / [`PluginRegistry::entries`] / [`PluginRegistry::all`] | 无 |
//! | 失败视图 | [`PluginRegistry::failures`](行级错误+装载失败) + [`PluginRegistry::rejected`](最近一次扫描被拒收的条目) | 无 |
//!
//! # 为什么不是 `ncm_provider::ProviderRegistry`
//!
//! `ncm-provider` 里那份注册表的键是 `Provider::id()`, 而 `ScriptProvider::id()` 是常量
//! `"script"`(trait 的返回类型是 `&'static str`, 脚本插件给不出动态 id). 直接 `register()`
//! 会让**第二个插件被静默丢弃**(先到先得), 所以本层**按插件 id(清单 id = 目录名)索引**,
//! [`Provider::id()`] 只作为 provider 自身标识透传.
//!
//! 产品接线时要二选一(见 README §4 第 7 项): 让路由层认"插件 id -> provider"这张表, 或者
//! 改 `Provider::id()` 为可拥有字符串. 本层只保证前者可用, 不动 trait 形状(FFI 依赖它).
//!
//! # 与既有 provider 抽象的语义对齐
//!
//! - 产出的对象就是 `ncm_provider::Provider` 的 `Arc<dyn Provider>`, **没有第二条错误口径**:
//!   脚本侧的失败在 `ncm_plugin` 里已经收口成 `ProviderError{kind,retryable,detail}`
//!   (映射表见 `ncm-plugin/src/error.rs`), 本层不做任何错误翻译;
//! - 装载/扫描失败的 `ManagerError` 只在**宿主管理层**使用(`enable` 的返回值、`failures()`),
//!   不会伪装成 provider 调用错误; 需要跨到 `Core` 边界时由 `super::host::to_provider_error`
//!   一处翻成 `ProviderError`(调用期与协调期同一口径, 不新增错误类型);
//! - `Capability` 由脚本实际注册的事件决定(`ScriptProvider` 内), 本层不猜、不覆盖.
//!
//! # 刷新与冲突口径(与 `PluginManager` 一致)
//!
//! | 场景 | 结果 |
//! |---|---|
//! | 同目录重扫 | 旧登记先撤, 重读清单/脚本 ⇒ 清单一变坏就变成错误条目(provider 随之摘掉) |
//! | 跨目录同 id | 先到先得: 后到的记 `RegistryReport::failed`, **不覆盖**已在装的那份 |
//! | 坏插件 | 单条进 `failed`, 其它插件照常装载(逐条 `Result`) |
//! | 未启用(缺省) | 进 `skipped`, 不算错误、不装载 —— 沿用 `PluginManager` 的"缺省停用"纪律 |
//! | 装载失败(语法错/初始化超时) | 进 `failed`, 该 id 的旧 provider 摘掉 |
//! | 空目录 | 0 provider / 0 失败, `RegistryReport::is_clean()` 为真 |
//!
//! 刷新是**全量重建**: 每次 `scan*` 都把仍处于启用态的插件重新 `ScriptProvider::load` 一遍
//! (老实例在 `Arc` 全部释放后由 `Drop` 通知 worker 线程退出 —— 不 join, 见 `ScriptProvider`)。
//! 没有热重载, 改脚本就得重扫, 与 `PluginManager` 的口径一致.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use ncm_plugin::{SandboxConfig, Transport};
use ncm_provider::Provider;

use super::manager::{InstallReport, ManagerError, PluginManager, PluginSummary};

/// 一次装配的结果: 扫描到的 / 装上的 / 跳过的 / 失败的.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RegistryReport {
    /// 本次扫描新登记成功的插件 id(字典序).
    pub scanned: Vec<String>,
    /// 刷新后处于"已装载成 provider"的 id(字典序).
    pub loaded: Vec<String>,
    /// 已登记但未启用 ⇒ 不装载(**不是错误**, 缺省停用纪律).
    pub skipped: Vec<String>,
    /// 失败条目: (目录名或插件 id, 可读原因) —— 扫描/清单/路径错误 + 装载失败.
    pub failed: Vec<(String, String)>,
}

impl RegistryReport {
    pub fn is_clean(&self) -> bool {
        self.failed.is_empty()
    }

    fn from_scan(scan: InstallReport) -> Self {
        Self {
            scanned: scan.installed,
            loaded: Vec::new(),
            skipped: Vec::new(),
            failed: scan.failed,
        }
    }
}

/// 插件 provider 注册表: 插件 id -> `Arc<dyn Provider>`(只装**已启用**的插件).
pub struct PluginRegistry {
    manager: PluginManager,
    /// 键是**插件 id**(清单 id = 目录名), 不是 `Provider::id()`(后者恒为 `"script"`).
    providers: BTreeMap<String, Arc<dyn Provider>>,
    /// 行级错误(清单/路径) + 装载失败的可读原因(键 = 插件 id 或目录名).
    failures: BTreeMap<String, String>,
    /// 最近一次扫描被**拒收**的条目(跨目录同 id / 目录不可访问 / 未登记成功).
    ///
    /// 与 [`Self::failures`] 分开存: 重复 id 命中的是"某个目录被拒", 而该 id 本身可能
    /// 正由别的目录正常供源 —— 混在一起会读成"这个插件坏了".
    rejected: Vec<(String, String)>,
}

impl PluginRegistry {
    /// 打开(必要时创建)插件根目录; 不扫描 —— 首次装配要显式调 [`Self::scan`].
    pub fn open(
        root: impl Into<PathBuf>,
        transport: Arc<dyn Transport>,
    ) -> Result<Self, ManagerError> {
        let manager = PluginManager::open(root, transport)?;
        Ok(Self {
            manager,
            providers: BTreeMap::new(),
            failures: BTreeMap::new(),
            rejected: Vec::new(),
        })
    }

    /// 覆盖沙箱预算(默认值就是产品口径; 测试用短超时也走这里).
    pub fn with_sandbox_config(mut self, sandbox: SandboxConfig) -> Self {
        self.manager = self.manager.with_sandbox_config(sandbox);
        self
    }

    pub fn root(&self) -> &Path {
        self.manager.root()
    }

    pub fn sandbox_config(&self) -> &SandboxConfig {
        self.manager.sandbox_config()
    }

    /// 只读访问底层目录管理器(列表/清单字段仍在那边).
    pub fn manager(&self) -> &PluginManager {
        &self.manager
    }

    /// 重扫自己的根目录并重建 provider 视图.
    pub fn scan(&mut self) -> RegistryReport {
        let scan = self.manager.rescan();
        self.sync(scan)
    }

    /// 扫描一个额外目录(跨根装配)并重建视图. 同 id 冲突按 `PluginManager` 口径: 先到先得.
    pub fn scan_dir(&mut self, dir: &Path) -> RegistryReport {
        let scan = self.manager.install_from_dir(dir);
        self.sync(scan)
    }

    /// 启用并即时装载该插件.
    ///
    /// 启停状态由 `PluginManager` 落盘; 装载失败会记进 [`Self::failures`] 并作为 `Err` 返回
    /// (此刻状态已是"启用", 下次刷新会重试装载).
    pub fn enable(&mut self, id: &str) -> Result<(), ManagerError> {
        self.manager.enable(id)?;
        self.load_one(id)
    }

    /// 停用并摘掉内存里的 provider(老实例随 `Arc` 释放自然退出).
    pub fn disable(&mut self, id: &str) -> Result<(), ManagerError> {
        self.manager.disable(id)?;
        self.providers.remove(id);
        self.failures.remove(id);
        Ok(())
    }

    /// 按插件 id 取 provider.
    pub fn get(&self, id: &str) -> Option<Arc<dyn Provider>> {
        self.providers.get(id).cloned()
    }

    /// 全部已装载 provider, 按插件 id 字典序(键随值一起给, 因为 `Provider::id()` 不唯一).
    pub fn entries(&self) -> Vec<(String, Arc<dyn Provider>)> {
        self.providers
            .iter()
            .map(|(id, provider)| (id.clone(), provider.clone()))
            .collect()
    }

    /// 全部已装载 provider(顺序同 [`Self::entries`]).
    pub fn all(&self) -> Vec<Arc<dyn Provider>> {
        self.providers.values().cloned().collect()
    }

    /// 已装载的插件 id(字典序).
    pub fn ids(&self) -> Vec<&str> {
        self.providers.keys().map(String::as_str).collect()
    }

    /// 管理视图(启停 + 清单字段 + 扫描错误), 直接转发 `PluginManager::list`.
    pub fn summaries(&self) -> Vec<PluginSummary> {
        self.manager.list()
    }

    /// 行级错误(清单坏/路径不安全) + 装载失败(键 = 插件 id 或目录名).
    ///
    /// **不含**调用期错误(那是 `ProviderError`, 在 provider 方法返回值里), 也**不含跨目录
    /// 同 id 冲突**(那条只说明"某个目录被拒收", 该 id 可能正由别的目录供源 —— 看
    /// [`Self::rejected`]). 行级错误(坏清单/坏目录名/路径逃逸)两边都有, 可对照读.
    pub fn failures(&self) -> &BTreeMap<String, String> {
        &self.failures
    }

    /// 最近一次扫描被拒收的条目(跨目录同 id / 目录不可访问 / 单条登记失败).
    ///
    /// 是**那次扫描的快照**, 不是状态派生视图: 每次 `scan`/`scan_dir` 整体替换,
    /// 只扫根目录的 `scan()` 会把上一次 `scan_dir(别处)` 的冲突条目清掉(盘上状态没变,
    /// 所以别拿它当持久状态). `enable`/`disable` 不动它.
    pub fn rejected(&self) -> &[(String, String)] {
        &self.rejected
    }

    /// 重建视图: 逐条独立 `Result` ⇒ 坏插件不拖垮整体.
    fn sync(&mut self, scan: InstallReport) -> RegistryReport {
        let scan_failed = scan.failed.clone();
        let mut report = RegistryReport::from_scan(scan);
        let mut providers: BTreeMap<String, Arc<dyn Provider>> = BTreeMap::new();
        let mut failures: BTreeMap<String, String> = BTreeMap::new();

        for row in self.manager.list() {
            if let Some(reason) = row.error {
                failures.insert(row.id, reason);
                continue;
            }
            if !row.enabled {
                report.skipped.push(row.id);
                continue;
            }
            match self.manager.load_provider(&row.id) {
                Ok(provider) => {
                    report.loaded.push(row.id.clone());
                    providers.insert(row.id, Arc::new(provider) as Arc<dyn Provider>);
                }
                Err(err) => {
                    // 装载失败也要在报告里出现, 否则"启用了但没 provider"查不到原因.
                    failures.insert(row.id, err.to_string());
                }
            }
        }

        // 扫描报告里的失败条目(目录级)与状态视图可能重叠, 以状态视图为准再合并.
        for (key, reason) in &failures {
            if !report.failed.iter().any(|(k, _)| k == key) {
                report.failed.push((key.clone(), reason.clone()));
            }
        }
        report.failed.sort();

        self.providers = providers;
        self.failures = failures;
        self.rejected = scan_failed;
        report
    }

    /// 装载单个插件(enable 用): 成功就替换旧实例, 失败摘掉旧实例并记原因.
    fn load_one(&mut self, id: &str) -> Result<(), ManagerError> {
        match self.manager.load_provider(id) {
            Ok(provider) => {
                self.providers
                    .insert(id.to_string(), Arc::new(provider) as Arc<dyn Provider>);
                self.failures.remove(id);
                Ok(())
            }
            Err(err) => {
                self.providers.remove(id);
                self.failures.insert(id.to_string(), err.to_string());
                Err(err)
            }
        }
    }
}

impl std::fmt::Debug for PluginRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PluginRegistry")
            .field("root", &self.root())
            .field("providers", &self.providers.keys().collect::<Vec<_>>())
            .field("failures", &self.failures)
            .field("rejected", &self.rejected)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
#[path = "registry_tests.rs"]
mod tests;
