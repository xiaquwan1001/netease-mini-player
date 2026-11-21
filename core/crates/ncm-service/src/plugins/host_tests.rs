//! `PluginHost` 用例: 缺省不扫描 / 缺省停用 / 启停落盘 / 坏插件隔离 / 重扫 / 错误口径 /
//! `Core` 层端到端(临时目录 + 最小插件).
//!
//! 全部不联网: 宿主层用 `MockTransport`, `Core` 端到端用例用生产 `ReqwestTransport`
//! (最小插件只 `lx.on('musicUrl')` 返回常量, 不发请求 —— 构造客户端不产生任何流量).
//! 临时目录每个用例一份, 结束尽力清理.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use ncm_plugin::MockTransport;
use ncm_provider::ProviderErrorKind;

use super::super::manager::STATE_FILE;
use super::{PluginHost, PluginHostPolicy, DEFAULT_ROOT_DIR, POLICY_FILE};

static SEQ: AtomicUsize = AtomicUsize::new(0);

/// 每个用例一个独立临时目录(用完尽力删).
struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = SEQ.fetch_add(1, Ordering::SeqCst);
        let mut path = std::env::temp_dir();
        path.push(format!("ncm-plugin-host-{tag}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("建临时目录");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn transport() -> Arc<MockTransport> {
    Arc::new(MockTransport::new())
}

/// 最小可用插件清单(只声明 `musicUrl`, 不需要出站白名单).
fn manifest_json(id: &str, entry: &str) -> String {
    format!(
        r#"{{"id":"{id}","name":"{id} 插件","version":"1.0.0","entry":"{entry}","permissions":{{"lxEvents":["musicUrl"]}}}}"#
    )
}

/// 最小可用入口脚本: 不联网, 直接给一条常量直链.
const MIN_SCRIPT: &str =
    "lx.on('musicUrl', async (source, info, type) => 'https://cdn.test/a.mp3');";

/// 写一个插件目录(`<root>/<id>/{manifest.json,index.js}`).
fn write_plugin(root: &Path, id: &str) {
    let dir = root.join(id);
    std::fs::create_dir_all(&dir).expect("建插件目录");
    std::fs::write(dir.join("manifest.json"), manifest_json(id, "index.js")).expect("写清单");
    std::fs::write(dir.join("index.js"), MIN_SCRIPT).expect("写入口脚本");
}

/// 日志通道: 取走语义 + 按插件 id 分组(空组不进结果).
#[test]
fn take_logs_groups_by_plugin_and_drains() {
    let temp = TempDir::new("logs");
    let root = temp.path().join(DEFAULT_ROOT_DIR);
    write_plugin(&root, "demo");
    // 顶层 lx.log: 装载期就该进宿主日志缓冲(不是只有调用期才有).
    std::fs::write(
        root.join("demo").join("index.js"),
        "lx.log('boot', 1);\nlx.on('musicUrl', async () => 'https://cdn.test/a.mp3');",
    )
    .expect("写入口脚本");
    enable_policy(temp.path());

    let mut host = PluginHost::open_with_transport(temp.path(), transport());
    assert!(host.take_logs().is_empty(), "没启用就没有日志可拉");
    host.enable("demo").expect("启用");

    let batch = host.take_logs();
    assert_eq!(batch.len(), 1, "只有一个插件有日志: {batch:?}");
    assert_eq!(batch[0].0, "demo");
    assert!(
        batch[0].1.iter().any(|line| line.contains("boot")),
        "装载期 lx.log 要落进宿主缓冲: {:?}",
        batch[0].1
    );
    assert!(
        host.take_logs().is_empty(),
        "取走语义: 同一批日志不能交付两次"
    );
}
/// 平台自报: `sources()` 从脚本的 inited 握手读出来, 只做展示(路由不看它).
#[test]
fn sources_report_what_script_declared() {
    let temp = TempDir::new("sources");
    let root = temp.path().join(DEFAULT_ROOT_DIR);
    write_plugin(&root, "demo");
    std::fs::write(
        root.join("demo").join("index.js"),
        "lx.send(lx.EVENT_NAMES.inited, { sources: { wy: {}, kw: {} } });\nlx.on('musicUrl', async () => 'https://cdn.test/a.mp3');",
    )
    .expect("写入口脚本");
    enable_policy(temp.path());

    let mut host = PluginHost::open_with_transport(temp.path(), transport());
    assert!(host.sources().is_empty(), "没启用就没有 provider 可问");
    host.enable("demo").expect("启用");

    let sources = host.sources();
    assert_eq!(
        sources.get("demo"),
        Some(&vec!["kw".to_string(), "wy".to_string()]),
        "按字典序透出脚本声明的平台: {sources:?}"
    );
}
/// 打开总开关(写策略文件).
fn enable_policy(data_dir: &Path) {
    let policy = PluginHostPolicy {
        enabled: true,
        ..PluginHostPolicy::default()
    };
    policy.save(data_dir).expect("写策略文件");
}

fn count(entries: &[(String, String)]) -> usize {
    entries.len()
}

// ------------------------- 缺省值: 不扫描(安全默认) -------------------------

#[test]
fn default_policy_creates_no_plugin_dir() {
    let temp = TempDir::new("default");
    let host = PluginHost::open_with_transport(temp.path(), transport());

    assert!(!host.policy().enabled, "缺省必须关闭总开关");
    assert!(!host.is_active(), "缺省不建注册表");
    assert!(
        !temp.path().join(DEFAULT_ROOT_DIR).exists(),
        "缺省不扫描 ⇒ 不许在数据目录里创建 plugins/"
    );
    assert!(host.summaries().is_empty());
    assert!(host.provider("demo").is_none());
    assert!(host.failures().is_empty());
    assert!(count(&host.rejected()) == 0);
    assert_eq!(host.ids(), Vec::<String>::new());

    let status = host.status();
    assert!(!status.enabled);
    assert!(!status.active);
    assert!(
        status.error.is_none(),
        "没开不是错误: {}",
        status.error.unwrap_or_default()
    );
    assert_eq!(status.root, temp.path().join(DEFAULT_ROOT_DIR));
}

#[test]
fn enabled_state_on_disk_is_ignored_while_policy_is_off() {
    // 盘上放一个"看起来已经启用"的插件(含单插件状态文件): 策略关闭时一个都不许装载.
    let temp = TempDir::new("ignored");
    let root = temp.path().join(DEFAULT_ROOT_DIR);
    write_plugin(&root, "demo");
    std::fs::write(
        root.join(STATE_FILE),
        b"{\"version\":1,\"enabled\":{\"demo\":true}}",
    )
    .expect("写单插件状态");

    let host = PluginHost::open_with_transport(temp.path(), transport());
    assert!(!host.is_active());
    assert!(
        host.summaries().is_empty(),
        "总开关关闭 ⇒ 不扫盘, 列表必须为空"
    );
    assert!(
        host.provider("demo").is_none(),
        "磁盘文件不能单方面给出执行权"
    );
}

#[test]
fn write_ops_while_off_are_forbidden_not_panic() {
    let temp = TempDir::new("off-ops");
    let mut host = PluginHost::open_with_transport(temp.path(), transport());

    for err in [
        host.enable("demo").unwrap_err(),
        host.disable("demo").unwrap_err(),
        host.rescan().expect_err("rescan 在关闭态必须报错"),
    ] {
        assert_eq!(err.kind, ProviderErrorKind::Forbidden);
        assert!(!err.retryable);
        assert!(
            err.detail.contains(POLICY_FILE),
            "detail 要指出开关在哪: {err}"
        );
    }
}

// ------------------------- 打开后: 缺省停用 + 启停落盘 -------------------------

#[test]
fn enabled_policy_scans_and_plugin_defaults_to_disabled() {
    let temp = TempDir::new("scan");
    let root = temp.path().join(DEFAULT_ROOT_DIR);
    write_plugin(&root, "demo");
    enable_policy(temp.path());

    let mut host = PluginHost::open_with_transport(temp.path(), transport());
    assert!(host.is_active(), "总开关打开 ⇒ 注册表必须建起来");
    let rows = host.summaries();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].id, "demo");
    assert!(!rows[0].enabled, "缺省停用: 装进来不等于启用");
    assert!(host.provider("demo").is_none(), "没启用不装载");
    assert!(host.ids().is_empty());
    assert!(host.failures().is_empty(), "停用不是失败");

    // 启用 ⇒ 立即装载, 且状态落盘.
    host.enable("demo").expect("启用");
    assert!(host.provider("demo").is_some());
    assert_eq!(host.ids(), vec!["demo".to_string()]);
    assert!(host.summaries()[0].enabled);
    let state = std::fs::read_to_string(root.join(STATE_FILE)).expect("状态文件");
    assert!(state.contains("\"demo\": true"), "启停要落盘: {state}");

    // 重开一份(等价重启): 启停从盘上读回, provider 重新装载.
    let reopened = PluginHost::open_with_transport(temp.path(), transport());
    assert!(reopened.provider("demo").is_some(), "启用状态要跨进程保留");

    // 停用 ⇒ 摘掉 provider; 状态也落盘.
    host.disable("demo").expect("停用");
    assert!(host.provider("demo").is_none());
    assert!(!host.summaries()[0].enabled);
    let state = std::fs::read_to_string(root.join(STATE_FILE)).expect("状态文件");
    assert!(state.contains("\"demo\": false"), "停用要落盘: {state}");
}

#[test]
fn set_enabled_round_trip_persists_policy() {
    let temp = TempDir::new("toggle");
    write_plugin(&temp.path().join(DEFAULT_ROOT_DIR), "demo");
    let mut host = PluginHost::open_with_transport(temp.path(), transport());
    assert!(!host.is_active());

    host.set_enabled(true).expect("打开总开关");
    assert!(host.is_active());
    assert_eq!(host.summaries().len(), 1);
    let saved = PluginHostPolicy::load(temp.path());
    assert!(saved.enabled, "总开关要落盘");

    host.set_enabled(false).expect("关闭总开关");
    assert!(!host.is_active());
    assert!(host.summaries().is_empty());
    assert!(!PluginHostPolicy::load(temp.path()).enabled, "关闭也要落盘");
    assert!(
        temp.path().join(DEFAULT_ROOT_DIR).exists(),
        "关闭不删用户目录(插件与 data/ 都是用户资产)"
    );
}

#[test]
fn custom_root_is_resolved_and_relative_paths_hang_off_data_dir() {
    let temp = TempDir::new("root");
    let abs = temp.path().join("custom-plugins");
    write_plugin(&abs, "demo");

    // 绝对路径原样用.
    let mut policy = PluginHostPolicy {
        enabled: true,
        root: Some(abs.clone()),
        ..PluginHostPolicy::default()
    };
    policy.save(temp.path()).expect("写策略");
    let host = PluginHost::open_with_transport(temp.path(), transport());
    assert_eq!(host.root(), abs);
    assert_eq!(host.summaries().len(), 1);

    // 相对路径挂到数据目录下(纯函数口径).
    policy.root = Some(PathBuf::from("rel-plugins"));
    assert_eq!(
        policy.resolve_root(temp.path()),
        temp.path().join("rel-plugins")
    );
    policy.root = None;
    assert_eq!(
        policy.resolve_root(temp.path()),
        temp.path().join(DEFAULT_ROOT_DIR)
    );
}

#[test]
fn set_root_switches_scan_target() {
    let temp = TempDir::new("setroot");
    enable_policy(temp.path());
    let other = temp.path().join("other");
    write_plugin(&other, "demo");

    let mut host = PluginHost::open_with_transport(temp.path(), transport());
    assert!(host.summaries().is_empty(), "缺省根目录是空的");

    host.set_root(Some(other.clone())).expect("换根目录");
    assert_eq!(host.root(), other);
    assert_eq!(host.summaries().len(), 1);
    assert_eq!(
        PluginHostPolicy::load(temp.path()).root,
        Some(other),
        "根目录要落盘"
    );
}

// ------------------------- 坏插件 / 重扫 -------------------------

#[test]
fn bad_plugin_is_isolated_and_visible() {
    let temp = TempDir::new("bad");
    let root = temp.path().join(DEFAULT_ROOT_DIR);
    write_plugin(&root, "demo");
    let broken = root.join("broken");
    std::fs::create_dir_all(&broken).expect("建坏插件目录");
    std::fs::write(broken.join("manifest.json"), b"{not json").expect("写坏清单");
    std::fs::write(broken.join("index.js"), MIN_SCRIPT).expect("写脚本");
    enable_policy(temp.path());

    let host = PluginHost::open_with_transport(temp.path(), transport());
    assert!(host.is_active(), "坏插件不许把宿主带崩");
    let ids: Vec<String> = host.summaries().into_iter().map(|row| row.id).collect();
    assert_eq!(ids, vec!["broken".to_string(), "demo".to_string()]);
    let failures = host.failures();
    assert!(
        failures.contains_key("broken"),
        "坏插件要在 failures 里: {failures:?}"
    );
    assert!(!failures.contains_key("demo"));
    let status = host.status();
    assert!(status.error.is_none(), "行级失败不算宿主失败");
    assert_eq!(status.failed, 1);
}

#[test]
fn rescan_drops_provider_when_script_breaks() {
    let temp = TempDir::new("rescan");
    let root = temp.path().join(DEFAULT_ROOT_DIR);
    write_plugin(&root, "demo");
    enable_policy(temp.path());

    let mut host = PluginHost::open_with_transport(temp.path(), transport());
    host.enable("demo").expect("启用");
    assert!(host.provider("demo").is_some());

    // 脚本改坏(语法错误) ⇒ 重扫后 provider 摘掉, 原因进 failures, 报告里也有一条.
    std::fs::write(root.join("demo").join("index.js"), "lx.on(").expect("写坏脚本");
    let report = host.rescan().expect("重扫");
    assert!(!report.is_clean(), "装载失败要进报告: {report:?}");
    assert!(host.provider("demo").is_none(), "坏了的插件不许继续供源");
    assert!(host.failures().contains_key("demo"));

    // 修回去再扫: provider 回来(重扫是真修复路径, 没有热重载).
    std::fs::write(root.join("demo").join("index.js"), MIN_SCRIPT).expect("写回脚本");
    host.rescan().expect("重扫");
    assert!(host.provider("demo").is_some());
    assert!(host.failures().is_empty());
}

// ------------------------- 错误口径: 唯一且可判 -------------------------

#[test]
fn manager_errors_flatten_into_one_provider_error_caliber() {
    let temp = TempDir::new("errors");
    write_plugin(&temp.path().join(DEFAULT_ROOT_DIR), "demo");
    enable_policy(temp.path());
    let mut host = PluginHost::open_with_transport(temp.path(), transport());

    // 未登记 id ⇒ NotFound(不可重试), detail 保留管理层原文.
    let err = host.enable("nope").unwrap_err();
    assert_eq!(err.kind, ProviderErrorKind::NotFound);
    assert!(!err.retryable);
    assert!(
        err.detail.starts_with("[notInstalled]"),
        "detail 要保留管理层分类: {err}"
    );
    assert_eq!(err.to_string(), format!("[notFound] {}", err.detail));
}

// ------------------------- Core 层端到端 -------------------------

#[test]
fn core_default_opens_without_plugin_host() {
    // 盘上预置一个"已启用"的插件: 缺省策略下 Core 不许装载它, 也不许多建目录.
    let temp = TempDir::new("core-default");
    let root = temp.path().join(DEFAULT_ROOT_DIR);
    write_plugin(&root, "demo");
    std::fs::write(
        root.join(STATE_FILE),
        b"{\"version\":1,\"enabled\":{\"demo\":true}}",
    )
    .expect("写单插件状态");

    let core = crate::Core::open(temp.path()).expect("Core 打开");
    let status = core.plugin_status();
    assert!(!status.enabled, "缺省总开关必须关闭");
    assert!(!status.active);
    assert!(core.plugin_summaries().is_empty());
    assert!(core.plugin_summaries().is_empty() && core.plugin_failures().is_empty());
    assert!(core.plugin_rejected().is_empty());
    assert!(core.plugin_provider("demo").is_none());
    assert!(core.plugin_ids().is_empty());
    // 内置 provider 不受影响.
    assert!(core.capabilities("netease").is_some());
}

#[test]
fn core_default_does_not_create_plugin_dir() {
    let temp = TempDir::new("core-nodir");
    let core = crate::Core::open(temp.path()).expect("Core 打开");
    assert!(!core.plugin_status().active);
    assert!(
        !temp.path().join(DEFAULT_ROOT_DIR).exists(),
        "缺省路径上 Core 不许创建 plugins/"
    );
}

#[test]
fn core_end_to_end_enable_disable_rescan_and_routing() {
    let temp = TempDir::new("core-e2e");
    let root = temp.path().join(DEFAULT_ROOT_DIR);
    write_plugin(&root, "demo");
    enable_policy(temp.path());

    let mut core = crate::Core::open(temp.path()).expect("Core 打开");
    let status = core.plugin_status();
    assert!(status.enabled && status.active, "开了总开关就该有注册表");
    assert_eq!(status.root, root);
    assert_eq!(core.plugin_summaries().len(), 1);
    assert!(!core.plugin_summaries()[0].enabled, "缺省停用被断言钉住");
    assert!(core.plugin_provider("demo").is_none());

    // 启用 ⇒ 按插件 id 路由拿到 provider; `Provider::id()` 仍是常量 "script".
    core.plugin_enable("demo").expect("启用");
    let provider = core.plugin_provider("demo").expect("按插件 id 取 provider");
    assert_eq!(
        provider.id(),
        "script",
        "trait 的 id 恒为 script, 不能拿来当键"
    );
    assert!(
        !provider.capabilities().is_empty(),
        "能力由脚本注册的事件决定"
    );
    assert_eq!(core.plugin_ids(), vec!["demo".to_string()]);

    // 重扫是可重复的幂等操作(全量重建).
    let report = core.plugin_rescan().expect("重扫");
    assert!(report.failed.is_empty(), "重扫报告: {report:?}");
    assert!(core.plugin_provider("demo").is_some());

    // 停用 ⇒ 路由失效; 未知 id ⇒ NotFound(不是 panic, 也不是新错误类型).
    core.plugin_disable("demo").expect("停用");
    assert!(core.plugin_provider("demo").is_none());
    let err = core.plugin_enable("nope").unwrap_err();
    assert_eq!(err.kind, ProviderErrorKind::NotFound);
}

#[test]
fn core_starts_even_with_broken_plugin() {
    let temp = TempDir::new("core-bad");
    let root = temp.path().join(DEFAULT_ROOT_DIR);
    write_plugin(&root, "demo");
    let broken = root.join("broken");
    std::fs::create_dir_all(&broken).expect("建坏插件目录");
    std::fs::write(broken.join("manifest.json"), b"{not json").expect("写坏清单");
    enable_policy(temp.path());

    let mut core = crate::Core::open(temp.path()).expect("坏插件不许影响 Core 启动");
    assert!(core.plugin_status().active);
    assert!(core.plugin_failures().contains_key("broken"));
    // 好插件照常可启用.
    core.plugin_enable("demo").expect("好插件照常启用");
    assert!(core.plugin_provider("demo").is_some());
}
