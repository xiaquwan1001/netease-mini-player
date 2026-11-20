//! 插件目录管理 + 启停状态(切片 2 第二步; **仍不接 FFI/UI**;
//! 装配 `Provider` 的是 [`PluginRegistry`](super::registry), 本层只管目录与启停状态).
//!
//! # 这一层负责什么
//!
//! | 动作 | 入口 | 落盘 |
//! |---|---|---|
//! | 扫描发现(`<root>/<plugin-id>/{manifest.json, *.js}`) | [`PluginManager::install_from_dir`] | 无 |
//! | 启停 | [`PluginManager::enable`] / [`PluginManager::disable`] | `<root>/plugins-state.json`(0600, 原子替换) |
//! | 连续失败计数 | [`PluginManager::record_load_failure`] / [`PluginManager::record_load_success`] | 同上 |
//! | 状态汇总 | [`PluginManager::list`] | 无 |
//! | 装载沙箱实例 | [`PluginManager::load_provider`] | 每插件 `<root>/<id>/data/` |
//!
//! # 目录形状
//!
//! ```text
//! <root>/
//!   plugins-state.json        # 只能由本模块写(0600)
//!   <plugin-id>/
//!     manifest.json           # 清单(见 ncm_plugin::manifest)
//!     index.js                # 入口脚本(名字由清单 entry 指定, 单层文件名)
//!     data/                   # 本模块创建: 该插件自己的 lx.storage 落盘目录
//!   <plugin-id>/ 的其它文件都是插件资产(不同插件之间互不可见)
//! ```
//!
//! # 安全判据(每条都有对应用例, 见 `manager_tests.rs`)
//!
//! | 判据 | 做法 | 失败表现 |
//! |---|---|---|
//! | 目录名必须是合法插件 id | `manifest::validate_id` | 单条记错误, 不影响其它插件 |
//! | 插件目录不许逃出扫描根 | `canonicalize(dir)` 后必须 `starts_with(canonicalize(扫描根))` | 拒绝(symlink 指向根外即命中) |
//! | 清单必须是插件目录内的普通文件 | `canonicalize(dir/manifest.json)` 必须落在 `canonicalize(dir)` 内 | 拒绝 |
//! | 清单 `id` 必须等于目录名 | 字符串比对 | 拒绝(防"同名 id 挂到别人目录") |
//! | 入口脚本只许读插件自己目录 | `canonicalize(dir/entry)` 必须是目录内的**文件** | 拒绝(`..` 与 symlink 逃逸都命中) |
//! | 清单不得异常巨大 | 单个 manifest 上限 [`MAX_MANIFEST_BYTES`] | 拒绝 |
//! | 坏插件不阻塞好插件 | 每个目录独立 `Result`, 错误进 `list()` 的 `error` 字段 | 好插件照常登记 |
//! | 同目录重扫 = 刷新 | 同一目录重复登记 ⇒ 先撤旧登记(按 `dir` 匹配)再重读清单, 清单坏掉就变成错误条目 | 覆盖原登记(`list()` 仍只一行) |
//! | 跨目录同 id 不抢已登记 | 同 id 已从**另一个目录**登记过 ⇒ 记 `InstallReport::failed`, 不覆盖原登记 | 只出现在报告里(`list()` 不会同 id 两行) |
//!
//! # 连续失败 3 次自动禁用(README §4 的最后一条缺口)
//!
//! 计数**落盘**(`plugins-state.json` 的 `failures` 段), 口径如下:
//!
//! | 事件 | 效果 |
//! |---|---|
//! | 装载/初始化失败一次([`PluginManager::record_load_failure`]) | `count += 1`, 记最近原因 + 时间 |
//! | 装载成功一次([`PluginManager::record_load_success`]) | 整条记录删掉(**连续**失败清零) |
//! | `count` 达 [`MAX_CONSECUTIVE_FAILURES`] | 自动 `disabled`: `enabled = false` + 记原因与时间(**同一份原子写**) |
//! | 重启([`PluginManager::open`]) | 从盘上读回 `enabled=false` 与失败记录 ⇒ 仍然禁用, 原因可查 |
//! | 用户手动 `enable` | **显式重置**: 整条失败记录被清掉, `enabled = true` |
//! | `rescan` / `install_from_dir` | **不清计数**(只重读目录, 不碰状态文件) |
//!
//! 只数**装载期**失败(语法错/初始化超时), 不数单次取链失败: 调用期错误已经是
//! `ProviderError{kind,retryable}` 交给上层按 `kind` 决策, 宿主不在调用路径上再判一次
//! (否则一次网络抖动就能把一个可用插件禁掉). 判据用例见 `manager_tests.rs` 与
//! `registry_tests.rs` 的 `failure_*` 组.
//!
//! # 预算不跨插件共享
//!
//! 每个插件装载时拿到的是 [`SandboxConfig`] 的一份 **clone**(默认 8s / 32MB 堆 / 512KB 栈 /
//! 单次 8 个请求 —— 与 `ncm_plugin::SandboxConfig::default()` 同一份口径), 以及自己的
//! [`FileStorage`](目录 `<root>/<id>/data`, namespace = 插件 id). 插件 A 的请求计数、
//! 存储键、堆上限都不会影响插件 B.
//!
//! # 明确未做
//!
//! - 没有"下载/解包插件"的能力(只从**已经在本机磁盘上**的目录登记);
//! - `permissions.requestDomains` **已强制**: 每个插件装载时把宿主 transport 包进
//!   [`GuardedTransport`](ncm_plugin::GuardedTransport)(每插件一份 [`DomainPolicy`](ncm_plugin::DomainPolicy)),
//!   不在清单白名单里的主机在发出去之前就被拒(未声明 = 不出站);
//! - 没有热重载: 改脚本要重新 `install_from_dir` + 重新 `load_provider`;
//! - 没有接 FFI/UI ⇒ **插件仍不可从产品触发**(装配在 `PluginRegistry`, 它也不进 `Core`).

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use ncm_plugin::{
    DomainPolicy, FileStorage, GuardedTransport, PluginError, PluginManifest, PluginSpec,
    SandboxConfig, ScriptProvider, Storage, Transport, MANIFEST_FILE,
};
use serde::{Deserialize, Serialize};

use crate::fsutil;

/// 启停状态文件名(`<root>/plugins-state.json`).
pub const STATE_FILE: &str = "plugins-state.json";
/// 单个清单文件的大小上限(正常清单是几百字节; 超了就是坏文件或攻击).
pub const MAX_MANIFEST_BYTES: u64 = 64 * 1024;
/// 状态文件格式版本(改形状才加, 读的时候不校验).
///
/// v2 起多出 `failures` 段(连续失败计数 + 自动禁用原因); 读 v1 文件时该段缺省为空,
/// 不需要迁移.
const STATE_VERSION: u32 = 2;
/// 连续装载失败达到这个次数 ⇒ 自动禁用(README §4: "连续失败 3 次自动禁用").
pub const MAX_CONSECUTIVE_FAILURES: u32 = 3;
/// 每插件的存储子目录名.
const DATA_DIR: &str = "data";

/// 管理层的错误分类(比 `PluginError` 粗一档, 便于日志与用例断言).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ManagerErrorKind {
    /// 没登记过这个 id(目录不存在/清单坏/没扫描过).
    NotInstalled,
    /// 插件存在但处于停用态.
    Disabled,
    /// 路径/符号链接越界, 或目录名不是合法 id.
    UnsafePath,
    /// 清单本身不合法.
    Manifest,
    /// 文件系统失败(建目录/读写/落盘).
    Io,
    /// 装载沙箱失败(语法错误/初始化超时).
    Plugin,
}

impl ManagerErrorKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ManagerErrorKind::NotInstalled => "notInstalled",
            ManagerErrorKind::Disabled => "disabled",
            ManagerErrorKind::UnsafePath => "unsafePath",
            ManagerErrorKind::Manifest => "manifest",
            ManagerErrorKind::Io => "io",
            ManagerErrorKind::Plugin => "plugin",
        }
    }
}

/// 管理层错误: kind + 可读 detail(不 panic, 不外泄 JS 栈).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManagerError {
    pub kind: ManagerErrorKind,
    pub detail: String,
}

impl ManagerError {
    pub fn new(kind: ManagerErrorKind, detail: impl Into<String>) -> Self {
        Self {
            kind,
            detail: detail.into(),
        }
    }

    fn not_installed(id: &str) -> Self {
        Self::new(
            ManagerErrorKind::NotInstalled,
            format!("插件 `{id}` 未登记(目录不存在 / 清单无效 / 还没扫描)"),
        )
    }

    fn disabled(id: &str) -> Self {
        Self::new(ManagerErrorKind::Disabled, format!("插件 `{id}` 已停用"))
    }

    fn io(context: &str, err: &std::io::Error) -> Self {
        Self::new(ManagerErrorKind::Io, format!("{context}: {err}"))
    }
}

impl std::fmt::Display for ManagerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.kind.as_str(), self.detail)
    }
}

impl std::error::Error for ManagerError {}

impl From<PluginError> for ManagerError {
    fn from(value: PluginError) -> Self {
        Self::new(ManagerErrorKind::Plugin, value.to_string())
    }
}

/// 一次扫描的结果(登记成功的 id + 失败条目).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct InstallReport {
    /// 登记成功的插件 id(按目录名字典序).
    pub installed: Vec<String>,
    /// 失败条目: (目录名或 id, 可读原因).
    pub failed: Vec<(String, String)>,
}

impl InstallReport {
    pub fn is_clean(&self) -> bool {
        self.failed.is_empty()
    }
}

/// `list()` 的一行: 好插件给清单字段, 坏插件给 `error`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PluginSummary {
    pub id: String,
    pub name: String,
    pub version: String,
    pub enabled: bool,
    /// 清单声明的出站白名单(`permissions.requestDomains` 原样, 装载时**强制生效**).
    /// 空 = 该插件出站全拒; 坏条目拿不到清单 ⇒ 也是空.
    pub request_domains: Vec<String>,
    /// `Some(reason)` = 这个目录没装上(清单坏/路径不安全/重复 id ...).
    pub error: Option<String>,
}

/// 已登记插件(路径都已 canonicalize, 后续读脚本不再信任清单).
#[derive(Debug, Clone)]
struct InstalledPlugin {
    manifest: PluginManifest,
    /// 插件目录(canonical).
    dir: PathBuf,
    /// 入口脚本(canonical, 已确认是插件目录内的文件).
    entry_path: PathBuf,
}

/// 从盘上读回的状态(启停 + 连续失败计数), 与 `StateFile` 分开只为让读函数的返回类型可读.
struct LoadedState {
    enabled: BTreeMap<String, bool>,
    failures: BTreeMap<String, PluginFailureRecord>,
}

/// 状态文件形状.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
struct StateFile {
    #[serde(default)]
    version: u32,
    /// 显式声明过的启停(缺省 = 停用, 见 [`PluginManager::is_enabled`]).
    #[serde(default)]
    enabled: BTreeMap<String, bool>,
    /// 每插件连续装载失败计数(键 = 插件 id; 成功一次整条删掉).
    #[serde(default)]
    failures: BTreeMap<String, PluginFailureRecord>,
}

/// 一个插件的连续失败记录(落 `plugins-state.json` 的 `failures.<id>`, 0600 原子写).
///
/// 字段全部 `camelCase`(与清单/策略文件的跨语言口径一致), 缺省字段不写出,
/// 所以"没失败过"的插件在盘上不占字节.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginFailureRecord {
    /// 连续失败次数(成功一次就整条记录消失, 所以它天然只表示"连续").
    pub count: u32,
    /// 最近一次失败的可读原因(管理层原文).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_reason: Option<String>,
    /// 最近一次失败时间(Unix 毫秒).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_at_ms: Option<u64>,
    /// `Some` = 已达阈值被**自动禁用**, 内容是给用户看的完整原因.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disabled_reason: Option<String>,
    /// 自动禁用时间(Unix 毫秒).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disabled_at_ms: Option<u64>,
}

impl PluginFailureRecord {
    /// 是否因连续失败被自动禁用(**手动**停用不算, 那种情况没有记录或没有 `disabled_reason`).
    pub fn is_auto_disabled(&self) -> bool {
        self.disabled_reason.is_some()
    }
}

/// 当前时间(Unix 毫秒); 只用于状态文件里的时间戳, 取不到就记 0(不 panic).
fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 插件目录管理: 扫描/启停/列表/装载. **不接 FFI/UI, 不注册进 ProviderRegistry**.
pub struct PluginManager {
    root: PathBuf,
    transport: Arc<dyn Transport>,
    sandbox: SandboxConfig,
    plugins: BTreeMap<String, InstalledPlugin>,
    /// 坏条目的可读原因(键 = 目录名或清单 id).
    errors: BTreeMap<String, String>,
    enabled: BTreeMap<String, bool>,
    /// 连续装载失败计数(键 = 插件 id); 与 `enabled` 同一份状态文件.
    failures: BTreeMap<String, PluginFailureRecord>,
}

impl PluginManager {
    /// 打开(必要时创建)插件根目录并读回启停状态. 扫描要另外调 [`Self::install_from_dir`].
    pub fn open(
        root: impl Into<PathBuf>,
        transport: Arc<dyn Transport>,
    ) -> Result<Self, ManagerError> {
        let root = root.into();
        std::fs::create_dir_all(&root)
            .map_err(|e| ManagerError::io(&format!("创建插件根目录 {}", root.display()), &e))?;
        let LoadedState { enabled, failures } = load_state(&root)?;
        Ok(Self {
            root,
            transport,
            sandbox: SandboxConfig::default(),
            plugins: BTreeMap::new(),
            errors: BTreeMap::new(),
            enabled,
            failures,
        })
    }

    /// 覆盖沙箱预算(默认值就是产品口径; 测试用短超时也走这里).
    pub fn with_sandbox_config(mut self, sandbox: SandboxConfig) -> Self {
        self.sandbox = sandbox;
        self
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// 当前生效的沙箱预算(每个插件装载时拿一份 clone).
    pub fn sandbox_config(&self) -> &SandboxConfig {
        &self.sandbox
    }

    /// 扫描 `dir` 下的每个 `<plugin-id>/`, 逐条校验并登记.
    ///
    /// 语义:
    /// - 返回 [`InstallReport`] 而不是整体失败 —— **坏插件不阻塞好插件**;
    /// - 重复调用同一个目录是"刷新": 先按 `dir` 撤掉该目录的旧登记, 再重读清单/路径;
    ///   清单坏掉的旧登记就此变成错误条目(这条与顶部表格「同目录重扫 = 刷新」一致);
    /// - 不同目录(含不同扫描根)出现同一个 id ⇒ 先到先得, 后者记"重复 id"错误, 不覆盖
    ///   (顶部表格「跨目录同 id 不抢已登记」).
    pub fn install_from_dir(&mut self, dir: &Path) -> InstallReport {
        let mut report = InstallReport::default();
        let scan_root = match std::fs::canonicalize(dir) {
            Ok(path) => path,
            Err(err) => {
                report.failed.push((
                    dir.display().to_string(),
                    format!("插件目录不可访问: {err}"),
                ));
                return report;
            }
        };
        let entries = match std::fs::read_dir(&scan_root) {
            Ok(entries) => entries,
            Err(err) => {
                report.failed.push((
                    scan_root.display().to_string(),
                    format!("列目录失败: {err}"),
                ));
                return report;
            }
        };
        let mut names: Vec<String> = entries
            .filter_map(|entry| entry.ok())
            .filter_map(|entry| entry.file_name().to_str().map(str::to_string))
            .collect();
        // 跳过隐藏项(.tmp/状态文件之类): 状态文件本身就在根目录里.
        names.retain(|name| !name.starts_with('.') && name != STATE_FILE);
        names.sort();

        for name in names {
            let path = scan_root.join(&name);
            // 刷新同一个目录时先撤旧登记: 否则旧登记会盖住"清单一变坏就该报错"的事实.
            if let Ok(canonical) = std::fs::canonicalize(&path) {
                let stale: Vec<String> = self
                    .plugins
                    .iter()
                    .filter(|(_, plugin)| plugin.dir == canonical)
                    .map(|(id, _)| id.clone())
                    .collect();
                for id in stale {
                    self.plugins.remove(&id);
                }
            }
            match self.install_one(&scan_root, &path, &name) {
                Ok(id) => {
                    self.errors.remove(&id);
                    report.installed.push(id);
                }
                Err((key, detail)) => {
                    if self.plugins.contains_key(&key) {
                        // 同名 id 已从别的扫描根登记: 不覆盖、也不占错误行(否则 list() 会同 id 两行),
                        // 只在这份报告里体现 —— 失败方拿不到登记是最要紧的信息.
                    } else {
                        self.errors.insert(key.clone(), detail.clone());
                    }
                    report.failed.push((key, detail));
                }
            }
        }
        report
    }

    /// 重新扫描自己的根目录.
    pub fn rescan(&mut self) -> InstallReport {
        let root = self.root.clone();
        self.install_from_dir(&root)
    }

    /// 登记一个插件目录(失败返回 (键, 可读原因)).
    fn install_one(
        &mut self,
        scan_root: &Path,
        dir: &Path,
        dir_name: &str,
    ) -> Result<String, (String, String)> {
        let key = dir_name.to_string();
        // 1) 目录名就是插件 id: 先按清单规则校验, 名字不安全就不再看里面的东西.
        if let Err(err) = ncm_plugin::manifest::validate_id(dir_name) {
            return Err((key, format!("目录名不是合法的插件 id: {err}")));
        }
        // 2) 目录本身必须落在扫描根内(symlink 指向根外即在这里被拒).
        let canonical_dir = std::fs::canonicalize(dir)
            .map_err(|e| (key.clone(), format!("插件目录不可访问: {e}")))?;
        if !canonical_dir.starts_with(scan_root) {
            return Err((
                key,
                format!(
                    "插件目录 {} 指向扫描根 {} 之外(符号链接逃逸)",
                    canonical_dir.display(),
                    scan_root.display()
                ),
            ));
        }
        let meta = std::fs::metadata(&canonical_dir)
            .map_err(|e| (key.clone(), format!("读取插件目录属性失败: {e}")))?;
        if !meta.is_dir() {
            return Err((key, "插件条目不是目录".to_string()));
        }
        // 3) 清单必须是插件目录内的普通文件.
        let manifest_path = canonical_dir.join(MANIFEST_FILE);
        let canonical_manifest = std::fs::canonicalize(&manifest_path)
            .map_err(|e| (key.clone(), format!("缺少 {MANIFEST_FILE} 或不可读: {e}")))?;
        if !canonical_manifest.starts_with(&canonical_dir) {
            return Err((
                key,
                format!("{MANIFEST_FILE} 指向插件目录之外(符号链接逃逸)"),
            ));
        }
        let manifest_meta = std::fs::metadata(&canonical_manifest)
            .map_err(|e| (key.clone(), format!("读取 {MANIFEST_FILE} 属性失败: {e}")))?;
        if !manifest_meta.is_file() {
            return Err((key, format!("{MANIFEST_FILE} 不是普通文件")));
        }
        if manifest_meta.len() > MAX_MANIFEST_BYTES {
            return Err((
                key,
                format!(
                    "{MANIFEST_FILE} 有 {} 字节, 超过上限 {MAX_MANIFEST_BYTES}",
                    manifest_meta.len()
                ),
            ));
        }
        let text = std::fs::read_to_string(&canonical_manifest)
            .map_err(|e| (key.clone(), format!("读取 {MANIFEST_FILE} 失败: {e}")))?;
        let manifest = PluginManifest::parse(&text).map_err(|e| (key.clone(), e.to_string()))?;
        // 4) 清单 id 必须等于目录名: 否则一份清单就能"借用"别人的目录身份.
        if manifest.id != dir_name {
            return Err((
                key,
                format!("清单 id `{}` 与目录名 `{dir_name}` 不一致", manifest.id),
            ));
        }
        // 5) 入口脚本只许读插件自己的目录(canonical 后必须仍在目录内, 且是文件).
        let entry_path = canonical_dir.join(&manifest.entry);
        let canonical_entry = std::fs::canonicalize(&entry_path).map_err(|e| {
            (
                key.clone(),
                format!("入口脚本 {} 不可读: {e}", manifest.entry),
            )
        })?;
        if !canonical_entry.starts_with(&canonical_dir) {
            return Err((
                key,
                format!("入口脚本 {} 指向插件目录之外(符号链接逃逸)", manifest.entry),
            ));
        }
        let entry_meta = std::fs::metadata(&canonical_entry)
            .map_err(|e| (key.clone(), format!("读入口脚本属性失败: {e}")))?;
        if !entry_meta.is_file() {
            return Err((key, format!("入口脚本 {} 不是普通文件", manifest.entry)));
        }
        // 6) 登记; 同 id 已在别的扫描根登记过 ⇒ 记"重复 id"(先到先得).
        if let Some(existing) = self.plugins.get(&manifest.id) {
            if existing.dir != canonical_dir {
                return Err((
                    key,
                    format!(
                        "重复 id `{}`: 已从 {} 登记, 忽略 {}",
                        manifest.id,
                        existing.dir.display(),
                        canonical_dir.display()
                    ),
                ));
            }
        }
        let id = manifest.id.clone();
        self.plugins.insert(
            id.clone(),
            InstalledPlugin {
                manifest,
                dir: canonical_dir,
                entry_path: canonical_entry,
            },
        );
        Ok(id)
    }

    /// 是否启用. **缺省是停用**(装进来的插件要显式 enable 才会被装载).
    pub fn is_enabled(&self, id: &str) -> bool {
        self.enabled.get(id).copied().unwrap_or(false)
    }

    /// 启停状态 + 错误态的汇总(按 id 字典序; 坏条目也占一行).
    pub fn list(&self) -> Vec<PluginSummary> {
        let ids: BTreeSet<&String> = self.plugins.keys().chain(self.errors.keys()).collect();
        ids.into_iter()
            .map(|id| match self.plugins.get(id) {
                Some(plugin) => PluginSummary {
                    id: id.clone(),
                    name: plugin.manifest.name.clone(),
                    version: plugin.manifest.version.clone(),
                    enabled: self.is_enabled(id),
                    request_domains: plugin.manifest.permissions.request_domains.clone(),
                    error: None,
                },
                None => PluginSummary {
                    id: id.clone(),
                    name: String::new(),
                    version: String::new(),
                    enabled: false,
                    request_domains: Vec::new(),
                    error: self.errors.get(id).cloned(),
                },
            })
            .collect()
    }

    /// 已登记插件的清单(只读; UI 将来用它画列表, 现在没人调).
    pub fn manifest(&self, id: &str) -> Option<&PluginManifest> {
        self.plugins.get(id).map(|plugin| &plugin.manifest)
    }

    /// 启用并落盘. **用户手动启用 = 显式重置**: 该插件的连续失败记录(含自动禁用原因)被清掉.
    pub fn enable(&mut self, id: &str) -> Result<(), ManagerError> {
        self.set_enabled(id, true)
    }

    /// 停用并落盘(停用不卸载任何东西, 只是 `load_provider` 会拒).
    pub fn disable(&mut self, id: &str) -> Result<(), ManagerError> {
        self.set_enabled(id, false)
    }

    fn set_enabled(&mut self, id: &str, value: bool) -> Result<(), ManagerError> {
        if !self.plugins.contains_key(id) {
            // 坏条目要把原因带出来, 否则调用方只看到"未登记".
            if let Some(reason) = self.errors.get(id) {
                return Err(ManagerError::new(
                    ManagerErrorKind::NotInstalled,
                    format!("插件 `{id}` 登记失败: {reason}"),
                ));
            }
            return Err(ManagerError::not_installed(id));
        }
        let id_owned = id.to_string();
        self.mutate_state(|manager| {
            manager.enabled.insert(id_owned.clone(), value);
            if value {
                // 手动启用是**显式重置**: 自动禁用的原因与计数都作废, 否则下一次单次失败
                // 就会立刻再禁一次(用户"手动启用"等于什么都没做).
                manager.failures.remove(&id_owned);
            }
        })
    }

    /// 记一次**装载期**失败(键 = 插件 id); 返回是否在本步触发了自动禁用.
    ///
    /// 达 [`MAX_CONSECUTIVE_FAILURES`] 次 ⇒ 同一份原子写里把 `enabled` 置 false 并写明原因与
    /// 时间, 所以"计数到 3" 与"禁用生效" 不可能只落一半.
    pub fn record_load_failure(&mut self, id: &str, reason: &str) -> Result<bool, ManagerError> {
        if !self.plugins.contains_key(id) {
            return Err(ManagerError::not_installed(id));
        }
        let id_owned = id.to_string();
        let reason_owned = reason.to_string();
        self.mutate_state(move |manager| {
            let now = now_ms();
            let record = manager
                .failures
                .entry(id_owned.clone())
                .or_insert_with(PluginFailureRecord::default);
            record.count = record.count.saturating_add(1);
            record.last_reason = Some(reason_owned.clone());
            record.last_at_ms = Some(now);
            if record.count < MAX_CONSECUTIVE_FAILURES {
                return false;
            }
            let disabled_reason = format!(
                "连续 {} 次装载失败, 已自动禁用(需要用户手动启用才能恢复); 最近一次: {}",
                record.count, reason_owned
            );
            record.disabled_reason = Some(disabled_reason);
            record.disabled_at_ms = Some(now);
            manager.enabled.insert(id_owned.clone(), false);
            true
        })
    }

    /// 记一次装载成功: 连续失败清零(整条记录删掉). 本来就没记录 ⇒ 不写盘.
    pub fn record_load_success(&mut self, id: &str) -> Result<(), ManagerError> {
        if !self.plugins.contains_key(id) {
            return Err(ManagerError::not_installed(id));
        }
        if self.failures.contains_key(id) {
            let id_owned = id.to_string();
            self.mutate_state(move |manager| {
                manager.failures.remove(&id_owned);
            })?;
        }
        Ok(())
    }

    /// 某插件的连续失败记录(磁盘视图, 只读). `None` = 没有连续失败/已被重置.
    pub fn failure_record(&self, id: &str) -> Option<&PluginFailureRecord> {
        self.failures.get(id)
    }

    /// 改内存状态后立刻落盘; 落盘失败把 `enabled` 与 `failures` 一起回滚.
    ///
    /// 回滚是"这次没改成", 不是"下次启动再说": 少回滚一半会造出"内存里启用了、盘上没启用"
    /// 这种重启后才暴露的不一致.
    fn mutate_state<T>(&mut self, update: impl FnOnce(&mut Self) -> T) -> Result<T, ManagerError> {
        let enabled_before = self.enabled.clone();
        let failures_before = self.failures.clone();
        let out = update(self);
        if let Err(err) = self.save_state() {
            self.enabled = enabled_before;
            self.failures = failures_before;
            return Err(err);
        }
        Ok(out)
    }

    /// 原子落盘启停状态 + 失败计数(0600).
    fn save_state(&self) -> Result<(), ManagerError> {
        let state = StateFile {
            version: STATE_VERSION,
            enabled: self.enabled.clone(),
            failures: self.failures.clone(),
        };
        let bytes = serde_json::to_vec_pretty(&state)
            .map_err(|e| ManagerError::new(ManagerErrorKind::Io, format!("状态序列化失败: {e}")))?;
        fsutil::write_atomic_private(&self.root, STATE_FILE, &bytes)
            .map_err(|e| ManagerError::io(&format!("写 {STATE_FILE}"), &e))
    }

    /// 该插件的存储: 目录 `<root>/<id>/data`, namespace = 插件 id.
    ///
    /// 每插件一份 `FileStorage`(目录不同)+ 独立 namespace ⇒ 键空间与文件都不共享.
    pub fn storage_for(&self, id: &str) -> Result<FileStorage, ManagerError> {
        let plugin = self
            .plugins
            .get(id)
            .ok_or_else(|| ManagerError::not_installed(id))?;
        let dir = plugin.dir.join(DATA_DIR);
        FileStorage::open(dir).map_err(|e| ManagerError::io("打开插件存储目录", &e))
    }

    /// 装载一个**已启用**插件的沙箱实例(不注册进任何 registry, 调用方自己持有).
    pub fn load_provider(&self, id: &str) -> Result<ScriptProvider, ManagerError> {
        let plugin = self
            .plugins
            .get(id)
            .ok_or_else(|| ManagerError::not_installed(id))?;
        if !self.is_enabled(id) {
            return Err(ManagerError::disabled(id));
        }
        let source = std::fs::read_to_string(&plugin.entry_path).map_err(|e| {
            ManagerError::io(&format!("读取入口脚本 {}", plugin.entry_path.display()), &e)
        })?;
        let storage: Arc<dyn Storage> = Arc::new(self.storage_for(id)?);
        // 出站白名单: 每插件一份(不共享), 宿主 HTTP 栈原样复用, 只在通道口裁决.
        let policy = DomainPolicy::from_permissions(&plugin.manifest.permissions);
        let transport: Arc<dyn Transport> =
            Arc::new(GuardedTransport::new(self.transport.clone(), policy));
        let spec = PluginSpec::new(plugin.manifest.name.clone(), source, transport, storage)
            .with_config(self.sandbox.clone())
            .with_namespace(id.to_string());
        ScriptProvider::load(spec).map_err(ManagerError::from)
    }
}

impl std::fmt::Debug for PluginManager {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PluginManager")
            .field("root", &self.root)
            .field("installed", &self.plugins.keys().collect::<Vec<_>>())
            .field("errors", &self.errors)
            .field("failures", &self.failures)
            .finish_non_exhaustive()
    }
}

/// 读启停状态 + 连续失败计数; 文件缺失/损坏一律当"没有声明"(全部停用, 无失败记录), 不 panic.
///
/// 状态文件坏掉时**不**保留旧计数: 读不出来就无从判断"连续", 宁可从头数(下一个装载失败
/// 记 1), 也不要凭一半数据把插件禁掉.
fn load_state(root: &Path) -> Result<LoadedState, ManagerError> {
    let empty = || LoadedState {
        enabled: BTreeMap::new(),
        failures: BTreeMap::new(),
    };
    let path = root.join(STATE_FILE);
    match std::fs::read(&path) {
        Ok(bytes) => match serde_json::from_slice::<StateFile>(&bytes) {
            Ok(state) => Ok(LoadedState {
                enabled: state.enabled,
                failures: state.failures,
            }),
            Err(err) => {
                eprintln!(
                    "[ncm-plugin] {STATE_FILE} 解析失败, 按全部停用处理({}): {err}",
                    path.display()
                );
                Ok(empty())
            }
        },
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(empty()),
        Err(err) => Err(ManagerError::io(&format!("读 {STATE_FILE}"), &err)),
    }
}

#[cfg(test)]
#[path = "manager_tests.rs"]
mod tests;
