//! 插件目录管理 + 启停状态(切片 2 第二步; **仍不接 FFI/UI, 不注册进 ProviderRegistry**).
//!
//! # 这一层负责什么
//!
//! | 动作 | 入口 | 落盘 |
//! |---|---|---|
//! | 扫描发现(`<root>/<plugin-id>/{manifest.json, *.js}`) | [`PluginManager::install_from_dir`] | 无 |
//! | 启停 | [`PluginManager::enable`] / [`PluginManager::disable`] | `<root>/plugins-state.json`(0600, 原子替换) |
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
//! | 同 id 不抢已登记 | 目录已登记过同一 id ⇒ 记 `InstallReport::failed`, 不覆盖原登记 | 只出现在报告里(`list()` 不会同 id 两行) |
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
//! - `permissions.requestDomains` 目前只是清单数据, 出站不按域过滤(接线切片再做);
//! - 没有热重载: 改脚本要重新 `install_from_dir` + 重新 `load_provider`;
//! - 没有接 `ProviderRegistry`/FFI/UI ⇒ **插件仍不可从产品触发**.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use ncm_plugin::{
    FileStorage, PluginError, PluginManifest, PluginSpec, SandboxConfig, ScriptProvider, Storage,
    Transport, MANIFEST_FILE,
};
use serde::{Deserialize, Serialize};

use crate::fsutil;

/// 启停状态文件名(`<root>/plugins-state.json`).
pub const STATE_FILE: &str = "plugins-state.json";
/// 单个清单文件的大小上限(正常清单是几百字节; 超了就是坏文件或攻击).
pub const MAX_MANIFEST_BYTES: u64 = 64 * 1024;
/// 状态文件格式版本(改形状才加, 读的时候不校验).
const STATE_VERSION: u32 = 1;
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

/// 状态文件形状.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
struct StateFile {
    #[serde(default)]
    version: u32,
    /// 显式声明过的启停(缺省 = 停用, 见 [`PluginManager::is_enabled`]).
    #[serde(default)]
    enabled: BTreeMap<String, bool>,
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
        let enabled = load_state(&root)?;
        Ok(Self {
            root,
            transport,
            sandbox: SandboxConfig::default(),
            plugins: BTreeMap::new(),
            errors: BTreeMap::new(),
            enabled,
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
    /// - 重复调用是"刷新"(同一 id 重新读清单/路径), 清单坏掉的旧登记会被撤掉并转成错误条目;
    /// - 不同扫描根之间出现同一个 id ⇒ 后者记"重复 id"错误(不抢已有登记).
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
                    error: None,
                },
                None => PluginSummary {
                    id: id.clone(),
                    name: String::new(),
                    version: String::new(),
                    enabled: false,
                    error: self.errors.get(id).cloned(),
                },
            })
            .collect()
    }

    /// 已登记插件的清单(只读; UI 将来用它画列表, 现在没人调).
    pub fn manifest(&self, id: &str) -> Option<&PluginManifest> {
        self.plugins.get(id).map(|plugin| &plugin.manifest)
    }

    /// 启用并落盘.
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
        let previous = self.enabled.insert(id.to_string(), value);
        if let Err(err) = self.save_state() {
            // 落盘失败要回滚内存视图, 否则"这次运行启用了、下次启动又没了"更难查.
            match previous {
                Some(old) => {
                    self.enabled.insert(id.to_string(), old);
                }
                None => {
                    self.enabled.remove(id);
                }
            }
            return Err(err);
        }
        Ok(())
    }

    /// 原子落盘启停状态(0600).
    fn save_state(&self) -> Result<(), ManagerError> {
        let state = StateFile {
            version: STATE_VERSION,
            enabled: self.enabled.clone(),
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
        let spec = PluginSpec::new(
            plugin.manifest.name.clone(),
            source,
            self.transport.clone(),
            storage,
        )
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
            .finish_non_exhaustive()
    }
}

/// 读启停状态; 文件缺失/损坏一律当"没有声明"(全部停用), 不 panic.
fn load_state(root: &Path) -> Result<BTreeMap<String, bool>, ManagerError> {
    let path = root.join(STATE_FILE);
    match std::fs::read(&path) {
        Ok(bytes) => match serde_json::from_slice::<StateFile>(&bytes) {
            Ok(state) => Ok(state.enabled),
            Err(err) => {
                eprintln!(
                    "[ncm-plugin] {STATE_FILE} 解析失败, 按全部停用处理({}): {err}",
                    path.display()
                );
                Ok(BTreeMap::new())
            }
        },
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(BTreeMap::new()),
        Err(err) => Err(ManagerError::io(&format!("读 {STATE_FILE}"), &err)),
    }
}

#[cfg(test)]
#[path = "manager_tests.rs"]
mod tests;
