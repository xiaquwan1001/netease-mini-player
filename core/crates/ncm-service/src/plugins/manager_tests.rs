//! `PluginManager` 用例: 安装/坏清单/重复 id/路径与符号链接逃逸/启停落盘/存储隔离/崩溃隔离.
//!
//! 全部不联网: `Transport` 用 `MockTransport`, 目录是 `std::env::temp_dir()` 下的临时目录
//! (每个用例一份, 结束尽力清理). "可能挂住"的用例沿用沙箱层的守护时限手法
//! (`recv_timeout` + 子线程), 预算没生效时用例失败而不是把 test 进程挂死.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

use ncm_domain::TrackId;
use ncm_plugin::{MockTransport, SandboxConfig, Storage};
use ncm_provider::{AudioLevel, ProviderErrorKind, ReadProvider, SongUrlRequest};

use super::{ManagerErrorKind, PluginManager, STATE_FILE};

static SEQ: AtomicUsize = AtomicUsize::new(0);

/// 每个用例一个独立临时目录(用完尽力删).
struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = SEQ.fetch_add(1, Ordering::SeqCst);
        let mut path = std::env::temp_dir();
        path.push(format!("ncm-plugin-mgr-{tag}-{}-{n}", std::process::id()));
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

fn manager(root: &Path) -> PluginManager {
    PluginManager::open(root, transport()).expect("打开插件根目录")
}

fn manifest_json(id: &str, entry: &str) -> String {
    format!(
        r#"{{"id":"{id}","name":"{id} 插件","version":"1.0.0","entry":"{entry}","permissions":{{"lxEvents":["musicUrl"]}}}}"#
    )
}

/// 写一个插件目录: `<root>/<dir>/{manifest.json, <entry>}`.
fn write_plugin(root: &Path, dir: &str, manifest: &str, entry: &str, source: &str) -> PathBuf {
    let plugin_dir = root.join(dir);
    std::fs::create_dir_all(&plugin_dir).expect("建插件目录");
    std::fs::write(plugin_dir.join("manifest.json"), manifest).expect("写清单");
    std::fs::write(plugin_dir.join(entry), source).expect("写入口脚本");
    plugin_dir
}

const OK_SOURCE: &str =
    "lx.on('musicUrl', () => ({ url: 'https://cdn.test/a.mp3', type: 'mp3' }));";

fn song_request() -> SongUrlRequest {
    SongUrlRequest {
        track: TrackId(7),
        level: AudioLevel::Exhigh,
    }
}

#[test]
fn installs_valid_plugins_and_lists_fields() {
    let tmp = TempDir::new("install");
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "index.js"),
        "index.js",
        OK_SOURCE,
    );
    write_plugin(
        tmp.path(),
        "beta",
        &manifest_json("beta", "main.js"),
        "main.js",
        OK_SOURCE,
    );

    let mut mgr = manager(tmp.path());
    let report = mgr.install_from_dir(tmp.path());
    assert_eq!(
        report.installed,
        vec!["alpha".to_string(), "beta".to_string()]
    );
    assert!(report.is_clean(), "无坏条目: {report:?}");

    let list = mgr.list();
    assert_eq!(list.len(), 2);
    let alpha = &list[0];
    assert_eq!(alpha.id, "alpha");
    assert_eq!(alpha.name, "alpha 插件");
    assert_eq!(alpha.version, "1.0.0");
    assert!(!alpha.enabled, "缺省停用(要显式 enable)");
    assert!(alpha.error.is_none());
    // 清单字段可读(将来 UI 直接用).
    assert_eq!(
        mgr.manifest("beta").map(|m| m.entry.as_str()),
        Some("main.js")
    );
}

#[test]
fn bad_manifest_does_not_block_other_plugins() {
    let tmp = TempDir::new("bad-manifest");
    write_plugin(
        tmp.path(),
        "good",
        &manifest_json("good", "index.js"),
        "index.js",
        OK_SOURCE,
    );
    // 坏 JSON.
    write_plugin(tmp.path(), "broken", "{ \"id\": ", "index.js", OK_SOURCE);
    // 清单合法但 id 与目录名不一致.
    write_plugin(
        tmp.path(),
        "mismatch",
        &manifest_json("other", "index.js"),
        "index.js",
        OK_SOURCE,
    );
    // 清单声明了路径穿越的入口.
    write_plugin(
        tmp.path(),
        "escape",
        &manifest_json("escape", "../evil.js"),
        "index.js",
        OK_SOURCE,
    );
    // 目录名本身不是合法 id.
    write_plugin(
        tmp.path(),
        "Bad Name",
        &manifest_json("bad name", "index.js"),
        "index.js",
        OK_SOURCE,
    );

    let mut mgr = manager(tmp.path());
    let report = mgr.install_from_dir(tmp.path());
    assert_eq!(report.installed, vec!["good".to_string()]);
    assert_eq!(report.failed.len(), 4, "{report:?}");

    let list = mgr.list();
    assert_eq!(list.len(), 5, "好插件 + 4 个错误条目都要出现: {list:?}");
    let bad = list.iter().find(|row| row.id == "broken").expect("坏条目");
    assert!(bad.error.as_ref().unwrap().contains("第 1 行"), "{bad:?}");
    let mismatch = list
        .iter()
        .find(|row| row.id == "mismatch")
        .expect("id 不一致");
    assert!(
        mismatch.error.as_ref().unwrap().contains("不一致"),
        "{mismatch:?}"
    );
    let escape = list
        .iter()
        .find(|row| row.id == "escape")
        .expect("入口穿越");
    assert!(
        escape.error.as_ref().unwrap().contains("entry"),
        "错误要指向 entry 字段: {escape:?}"
    );
    // 好插件照常可用.
    mgr.enable("good").expect("启用");
    assert!(mgr.load_provider("good").is_ok());
    // 坏条目不能启用, 且原因带出来.
    let err = mgr.enable("broken").expect_err("坏条目不能启用");
    assert_eq!(err.kind, ManagerErrorKind::NotInstalled);
    assert!(err.detail.contains("登记失败"), "{err}");
}

#[test]
fn duplicate_id_across_roots_is_rejected() {
    let tmp_a = TempDir::new("dup-a");
    let tmp_b = TempDir::new("dup-b");
    write_plugin(
        tmp_a.path(),
        "dup",
        &manifest_json("dup", "index.js"),
        "index.js",
        OK_SOURCE,
    );
    write_plugin(
        tmp_b.path(),
        "dup",
        &manifest_json("dup", "index.js"),
        "index.js",
        OK_SOURCE,
    );

    let mut mgr = manager(tmp_a.path());
    assert!(mgr.install_from_dir(tmp_a.path()).is_clean());
    let report = mgr.install_from_dir(tmp_b.path());
    assert!(report.installed.is_empty(), "{report:?}");
    let (key, detail) = &report.failed[0];
    assert_eq!(key, "dup");
    assert!(detail.contains("重复 id"), "{detail}");
    // 原登记仍在(先到先得), 且 list() 不会出现同 id 两行.
    assert_eq!(
        mgr.manifest("dup").map(|m| m.name.clone()),
        Some("dup 插件".to_string())
    );
    let list = mgr.list();
    assert_eq!(list.len(), 1, "{list:?}");
    assert!(
        list[0].error.is_none(),
        "已登记的插件不该被错误行顶掉: {list:?}"
    );
    // 再扫一次自己的根: 重复扫描不等于重复 id(同一目录是刷新, 不该报错).
    assert!(mgr.install_from_dir(tmp_a.path()).is_clean());
}

#[cfg(unix)]
#[test]
fn symlinked_entry_escaping_plugin_dir_is_rejected() {
    let tmp = TempDir::new("symlink-entry");
    // 插件目录外的"受害者"脚本: 目录内的 index.js 是指向它的符号链接.
    let victim = tmp.path().join("victim.js");
    std::fs::write(&victim, OK_SOURCE).expect("写受害者脚本");
    let plugin_dir = write_plugin(
        tmp.path(),
        "peek",
        &manifest_json("peek", "index.js"),
        "index.js",
        OK_SOURCE,
    );
    std::fs::remove_file(plugin_dir.join("index.js")).expect("删真入口");
    std::os::unix::fs::symlink(&victim, plugin_dir.join("index.js")).expect("建符号链接");

    let mut mgr = manager(tmp.path());
    let report = mgr.install_from_dir(tmp.path());
    assert!(report.installed.is_empty(), "{report:?}");
    let (_, detail) = &report.failed[0];
    assert!(
        detail.contains("插件目录之外"),
        "判据必须点名逃逸: {detail}"
    );

    // 指向目录内其它文件的符号链接则**允许**(没逃出插件自己的目录).
    let plugin2 = write_plugin(
        tmp.path(),
        "inner",
        &manifest_json("inner", "shared.js"),
        "shared.js",
        OK_SOURCE,
    );
    std::fs::write(plugin2.join("real.js"), OK_SOURCE).expect("写同一目录内的真脚本");
    std::fs::remove_file(plugin2.join("shared.js")).expect("删");
    std::os::unix::fs::symlink(plugin2.join("real.js"), plugin2.join("shared.js")).expect("建内链");
    let report = mgr.install_from_dir(tmp.path());
    assert_eq!(report.installed, vec!["inner".to_string()], "{report:?}");
}

#[cfg(unix)]
#[test]
fn symlinked_plugin_dir_escaping_root_is_rejected() {
    let tmp = TempDir::new("symlink-dir");
    let outside = TempDir::new("symlink-dir-outside");
    write_plugin(
        outside.path(),
        "outside",
        &manifest_json("outside", "index.js"),
        "index.js",
        OK_SOURCE,
    );
    let link = tmp.path().join("outside");
    std::os::unix::fs::symlink(outside.path().join("outside"), &link).expect("建目录符号链接");

    let mut mgr = manager(tmp.path());
    let report = mgr.install_from_dir(tmp.path());
    assert!(report.installed.is_empty(), "{report:?}");
    let (key, detail) = &report.failed[0];
    assert_eq!(key, "outside");
    assert!(detail.contains("扫描根"), "{detail}");
    assert!(mgr.list().iter().all(|row| row.error.is_some()));
}

#[test]
fn enable_disable_roundtrip_persists_0600() {
    let tmp = TempDir::new("state");
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "index.js"),
        "index.js",
        OK_SOURCE,
    );
    write_plugin(
        tmp.path(),
        "beta",
        &manifest_json("beta", "index.js"),
        "index.js",
        OK_SOURCE,
    );

    {
        let mut mgr = manager(tmp.path());
        mgr.install_from_dir(tmp.path());
        mgr.enable("alpha").expect("启用 alpha");
        assert!(mgr.is_enabled("alpha"));
        assert!(!mgr.is_enabled("beta"));
    }

    let state_path = tmp.path().join(STATE_FILE);
    assert!(state_path.is_file(), "状态文件必须落盘");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&state_path)
            .expect("stat")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "状态文件必须是 0600, 实际 {mode:o}");
    }
    assert!(
        !std::fs::read_dir(tmp.path())
            .expect("列目录")
            .filter_map(|e| e.ok())
            .any(|e| e.file_name().to_string_lossy().contains(".tmp")),
        "原子写不许留下 tmp 文件"
    );

    // 重开: 状态读回.
    {
        let mut mgr = manager(tmp.path());
        mgr.install_from_dir(tmp.path());
        assert!(mgr.is_enabled("alpha"), "启用态要跨进程/跨实例保留");
        assert!(!mgr.is_enabled("beta"));
        // 停用再重开: 也要读回.
        mgr.disable("alpha").expect("停用 alpha");
        assert!(!mgr.is_enabled("alpha"));
    }
    let mut mgr = manager(tmp.path());
    mgr.install_from_dir(tmp.path());
    assert!(!mgr.is_enabled("alpha"));
    // 未登记的 id 直接报错, 不写状态文件.
    let err = mgr.enable("nobody").expect_err("未登记不能启用");
    assert_eq!(err.kind, ManagerErrorKind::NotInstalled);
}

#[test]
fn corrupt_state_file_means_all_disabled() {
    let tmp = TempDir::new("state-corrupt");
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "index.js"),
        "index.js",
        OK_SOURCE,
    );
    let mut mgr = manager(tmp.path());
    mgr.install_from_dir(tmp.path());
    mgr.enable("alpha").expect("启用");
    std::fs::write(tmp.path().join(STATE_FILE), b"{ not json").expect("写坏状态");

    let mut reopened = manager(tmp.path());
    let report = reopened.install_from_dir(tmp.path());
    assert!(report.is_clean(), "{report:?}");
    assert!(!reopened.is_enabled("alpha"), "坏状态文件按全部停用处理");
}

#[test]
fn storage_and_budget_are_per_plugin() {
    let tmp = TempDir::new("storage");
    let source_a =
        "lx.on('musicUrl', () => { lx.storage.set('k', 'A'); return 'https://cdn.test/a.mp3'; });";
    let source_b =
        "lx.on('musicUrl', () => { lx.storage.set('k', 'B'); return 'https://cdn.test/b.mp3'; });";
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "index.js"),
        "index.js",
        source_a,
    );
    write_plugin(
        tmp.path(),
        "beta",
        &manifest_json("beta", "index.js"),
        "index.js",
        source_b,
    );

    let mut mgr = manager(tmp.path());
    mgr.install_from_dir(tmp.path());
    mgr.enable("alpha").expect("启用 alpha");
    mgr.enable("beta").expect("启用 beta");

    // 预算口径: 默认 8s / 32MB / 512KB / 单次 8 请求(与 SandboxConfig::default 同源).
    let sandbox = mgr.sandbox_config();
    assert_eq!(sandbox.call_timeout, Duration::from_secs(8));
    assert_eq!(sandbox.memory_limit_bytes, 32 * 1024 * 1024);
    assert_eq!(sandbox.max_stack_bytes, 512 * 1024);
    assert_eq!(sandbox.max_requests_per_call, 8);

    let provider_a = mgr.load_provider("alpha").expect("装载 alpha");
    let provider_b = mgr.load_provider("beta").expect("装载 beta");
    let request = song_request();
    let url_a = futures::executor::block_on(provider_a.song_url(&request)).expect("alpha 取链");
    let url_b = futures::executor::block_on(provider_b.song_url(&request)).expect("beta 取链");
    assert_eq!(url_a.url.as_deref(), Some("https://cdn.test/a.mp3"));
    assert_eq!(url_b.url.as_deref(), Some("https://cdn.test/b.mp3"));

    // 各自的落盘文件不同, 键值互不可见.
    let storage_a = mgr.storage_for("alpha").expect("alpha 存储");
    let storage_b = mgr.storage_for("beta").expect("beta 存储");
    assert_ne!(storage_a.dir(), storage_b.dir(), "每插件一个 data 目录");
    assert_eq!(storage_a.get("alpha", "k").as_deref(), Some("\"A\""));
    assert_eq!(storage_b.get("beta", "k").as_deref(), Some("\"B\""));
    assert_eq!(
        storage_a.get("beta", "k"),
        None,
        "跨插件 namespace 必须隔离"
    );
    assert!(
        storage_a.dir().ends_with("alpha/data"),
        "{:?}",
        storage_a.dir()
    );
    assert!(
        std::fs::read_dir(storage_a.dir()).expect("列目录").count() >= 1,
        "启用的插件写过 lx.storage ⇒ data 目录里应有文件"
    );
}

#[test]
fn crashed_plugin_does_not_break_others() {
    let tmp = TempDir::new("crash");
    let hang = "lx.on('musicUrl', () => { while (true) {} });";
    write_plugin(
        tmp.path(),
        "hang",
        &manifest_json("hang", "index.js"),
        "index.js",
        hang,
    );
    write_plugin(
        tmp.path(),
        "ok",
        &manifest_json("ok", "index.js"),
        "index.js",
        OK_SOURCE,
    );

    let mut mgr = PluginManager::open(tmp.path(), transport())
        .expect("打开")
        .with_sandbox_config(SandboxConfig {
            call_timeout: Duration::from_millis(300),
            ..SandboxConfig::default()
        });
    mgr.install_from_dir(tmp.path());
    mgr.enable("hang").expect("启用 hang");
    mgr.enable("ok").expect("启用 ok");

    let provider_hang = mgr.load_provider("hang").expect("装载 hang");
    let provider_ok = mgr.load_provider("ok").expect("装载 ok");

    // 守护时限: 时间预算没生效时用例失败而不是把 test 进程挂死.
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let err = futures::executor::block_on(provider_hang.song_url(&song_request()))
            .expect_err("死循环必须被时间预算打断");
        let _ = tx.send(err);
    });
    let err = rx
        .recv_timeout(Duration::from_secs(15))
        .expect("插件超时预算未生效(红相)");
    assert_eq!(
        err.kind,
        ProviderErrorKind::Network,
        "超时映射 network: {err:?}"
    );
    assert!(err.retryable, "超时可重试");

    // 另一个插件完全不受影响.
    let url = futures::executor::block_on(provider_ok.song_url(&song_request()))
        .expect("另一个插件照常工作");
    assert_eq!(url.url.as_deref(), Some("https://cdn.test/a.mp3"));
    // 管理状态也没被带坏.
    let list = mgr.list();
    assert_eq!(list.len(), 2);
    assert!(list.iter().all(|row| row.error.is_none()));
    assert!(list.iter().all(|row| row.enabled));
}

#[test]
fn disabled_or_unknown_plugin_cannot_be_loaded() {
    let tmp = TempDir::new("disabled");
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "index.js"),
        "index.js",
        OK_SOURCE,
    );
    let mut mgr = manager(tmp.path());
    mgr.install_from_dir(tmp.path());

    let err = mgr.load_provider("alpha").expect_err("缺省停用");
    assert_eq!(err.kind, ManagerErrorKind::Disabled);
    let err = mgr.load_provider("ghost").expect_err("未登记");
    assert_eq!(err.kind, ManagerErrorKind::NotInstalled);

    mgr.enable("alpha").expect("启用");
    assert!(mgr.load_provider("alpha").is_ok());
    mgr.disable("alpha").expect("停用");
    assert_eq!(
        mgr.load_provider("alpha").expect_err("停用后不能装载").kind,
        ManagerErrorKind::Disabled
    );
}

#[test]
fn rescan_drops_plugin_whose_manifest_broke() {
    let tmp = TempDir::new("rescan");
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "index.js"),
        "index.js",
        OK_SOURCE,
    );
    let mut mgr = manager(tmp.path());
    assert!(mgr.install_from_dir(tmp.path()).is_clean());
    assert!(mgr.manifest("alpha").is_some());

    std::fs::write(tmp.path().join("alpha/manifest.json"), "{ broken").expect("写坏清单");
    let report = mgr.rescan();
    assert!(report.installed.is_empty(), "{report:?}");
    assert!(mgr.manifest("alpha").is_none(), "坏掉的旧登记必须撤掉");
    let row = mgr
        .list()
        .into_iter()
        .find(|row| row.id == "alpha")
        .expect("错误行");
    assert!(row.error.is_some(), "{row:?}");
}
