//! `PluginManager` 用例: 安装/坏清单/重复 id/路径与符号链接逃逸/启停落盘/存储隔离/崩溃隔离.
//!
//! 全部不联网: `Transport` 用 `MockTransport`, 目录是 `std::env::temp_dir()` 下的临时目录
//! (每个用例一份, 结束尽力清理). "可能挂住"的用例沿用沙箱层的守护时限手法
//! (`recv_timeout` + 子线程), 预算没生效时用例失败而不是把 test 进程挂死.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ncm_domain::TrackId;
use ncm_plugin::{MockTransport, SandboxConfig, Storage, TransportResponse};
use ncm_provider::{AudioLevel, ProviderErrorKind, ReadProvider, SongUrlRequest};

use super::super::transport::SourceFetcher;
use super::{
    check_https_url, read_capped, ManagerError, ManagerErrorKind, PluginManager,
    MAX_CONSECUTIVE_FAILURES, MAX_SOURCE_BYTES, STATE_FILE,
};

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

/// 带 `permissions.requestDomains` 的清单.
fn manifest_json_with_domains(id: &str, entry: &str, domains: &[&str]) -> String {
    let declared: Vec<String> = domains
        .iter()
        .map(|domain| format!("\"{domain}\""))
        .collect();
    format!(
        r#"{{"id":"{id}","name":"{id} 插件","version":"1.0.0","entry":"{entry}","permissions":{{"lxEvents":["musicUrl"],"requestDomains":[{}]}}}}"#,
        declared.join(",")
    )
}

/// 打开 manager 并**留下** transport 句柄(白名单用例要查它到底收到了什么).
fn manager_with_transport(root: &Path) -> (PluginManager, Arc<MockTransport>) {
    let mock = transport();
    let mgr = PluginManager::open(root, mock.clone()).expect("打开插件根目录");
    (mgr, mock)
}

/// 取链时先 `lx.request(url)` 再返回直链的脚本(未捕获的拒绝会冒泡成取链失败).
fn request_script(url: &str) -> String {
    format!(
        "lx.on('musicUrl', async () => {{ await lx.request({{ url: '{url}' }}); return 'https://cdn.test/a.mp3'; }});"
    )
}

fn ok_body(body: &str) -> TransportResponse {
    TransportResponse {
        status: 200,
        headers: Vec::new(),
        body: body.to_string(),
    }
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
        meta: None,
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

// ---- 出站域名白名单(切片 2 第三步): 清单声明在装载时变成真判据 ----

#[test]
fn undeclared_domain_request_is_denied_before_transport() {
    let tmp = TempDir::new("policy-deny");
    let source = request_script("https://evil.test/steal");
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json_with_domains("alpha", "index.js", &["api.example.com"]),
        "index.js",
        &source,
    );

    let (mut mgr, mock) = manager_with_transport(tmp.path());
    mgr.install_from_dir(tmp.path());
    mgr.enable("alpha").expect("启用 alpha");
    let provider = mgr.load_provider("alpha").expect("装载 alpha");

    let err = futures::executor::block_on(provider.song_url(&song_request()))
        .expect_err("越界域名必须让取链失败");
    // 白名单拒绝 = 脚本侧未捕获的拒绝 ⇒ PluginErrorKind::Script ⇒ kind=Internal, retryable=false.
    // 分类收敛口径见 `ncm_plugin::error` 模块头(没有 RequestDenied/Transport 变体)。
    assert_eq!(
        err.kind,
        ProviderErrorKind::Internal,
        "产品链路落点必须是 Internal: {err:?}"
    );
    assert!(!err.retryable, "白名单拒绝不是重试类错误: {err:?}");
    assert!(
        err.detail.contains("出站被拒"),
        "错误文案要说明是白名单拒绝: {err:?}"
    );
    assert!(
        err.detail.contains("evil.test"),
        "错误文案必须点名被拒主机: {err:?}"
    );
    assert!(
        mock.requests().is_empty(),
        "被拒的请求不许真的发出去: {:?}",
        mock.requests()
    );
}

#[test]
fn declared_domain_request_reaches_transport() {
    let tmp = TempDir::new("policy-allow");
    let url = "https://api.example.com/url?id=7";
    let source = request_script(url);
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json_with_domains("alpha", "index.js", &["api.example.com"]),
        "index.js",
        &source,
    );

    let (mut mgr, mock) = manager_with_transport(tmp.path());
    mgr.install_from_dir(tmp.path());
    mgr.enable("alpha").expect("启用 alpha");
    mock.expect("api.example.com", Ok(ok_body(r#"{"data":"ok"}"#)));
    let provider = mgr.load_provider("alpha").expect("装载 alpha");

    let stream = futures::executor::block_on(provider.song_url(&song_request()))
        .expect("白名单内的域名应放行");
    assert_eq!(stream.url.as_deref(), Some("https://cdn.test/a.mp3"));

    let seen = mock.requests();
    assert_eq!(seen.len(), 1, "白名单内的请求必须真的发出去: {seen:?}");
    assert_eq!(seen[0].url, url);
    assert_eq!(seen[0].method, "GET");

    // 汇总里的可观测字段取自清单.
    let row = mgr
        .list()
        .into_iter()
        .find(|row| row.id == "alpha")
        .expect("alpha 行");
    assert_eq!(row.request_domains, vec!["api.example.com".to_string()]);
}

#[test]
fn plugin_without_request_domains_cannot_make_any_request() {
    let tmp = TempDir::new("policy-empty");
    let source = request_script("https://api.example.com/url?id=7");
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "index.js"),
        "index.js",
        &source,
    );

    let (mut mgr, mock) = manager_with_transport(tmp.path());
    mgr.install_from_dir(tmp.path());
    mgr.enable("alpha").expect("启用 alpha");
    mock.expect("api.example.com", Ok(ok_body("{}")));
    let provider = mgr.load_provider("alpha").expect("装载 alpha");

    let err = futures::executor::block_on(provider.song_url(&song_request()))
        .expect_err("未声明白名单 = 不出站");
    assert!(!err.retryable, "未声明拒绝不重试: {err:?}");
    assert!(
        err.detail.contains("未声明"),
        "错误文案要指出未声明 requestDomains: {err:?}"
    );
    assert!(
        mock.requests().is_empty(),
        "未声明插件的任何请求都不许发出去: {:?}",
        mock.requests()
    );

    let row = mgr
        .list()
        .into_iter()
        .find(|row| row.id == "alpha")
        .expect("alpha 行");
    assert!(row.request_domains.is_empty(), "{row:?}");
    assert!(row.error.is_none(), "{row:?}");
}

// ---- 连续失败计数: rescan 不清计数 + 跨实例保留(P3) ----

#[test]
fn failure_counts_survive_rescan_and_reopen() {
    let tmp = TempDir::new("fail-state");
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "index.js"),
        "index.js",
        OK_SOURCE,
    );

    {
        let mut mgr = manager(tmp.path());
        mgr.install_from_dir(tmp.path());
        mgr.enable("alpha").expect("启用");
        assert!(!mgr
            .record_load_failure("alpha", "模拟装载失败 1")
            .expect("计数"));
        // rescan / 重扫不清计数: 重新读目录与状态无关.
        assert!(mgr.rescan().is_clean());
        mgr.install_from_dir(tmp.path());
        assert_eq!(
            mgr.failure_record("alpha").map(|r| r.count),
            Some(1),
            "rescan 不清计数"
        );
        assert!(mgr.is_enabled("alpha"), "1 次失败不禁用");
        assert!(!mgr
            .record_load_failure("alpha", "模拟装载失败 2")
            .expect("计数"));
        assert_eq!(mgr.failure_record("alpha").map(|r| r.count), Some(2));

        // 未登记的 id 记账要报错(不写状态文件).
        assert_eq!(
            mgr.record_load_failure("ghost", "x")
                .expect_err("未登记")
                .kind,
            ManagerErrorKind::NotInstalled
        );
        assert_eq!(
            mgr.record_load_success("ghost").expect_err("未登记").kind,
            ManagerErrorKind::NotInstalled
        );
    }

    // 换一个实例(等价于重启): 计数与启用态都从盘上读回.
    let mut mgr = manager(tmp.path());
    mgr.install_from_dir(tmp.path());
    assert!(mgr.is_enabled("alpha"));
    let record = mgr.failure_record("alpha").expect("计数跨实例保留");
    assert_eq!(record.count, 2);
    assert!(!record.is_auto_disabled());
    assert!(record
        .last_reason
        .as_deref()
        .unwrap()
        .contains("模拟装载失败 2"));

    // 第 3 次: 达阈值 ⇒ 自动禁用(启用态同一次原子写里变 false).
    assert!(mgr
        .record_load_failure("alpha", "模拟装载失败 3")
        .expect("计数"));
    assert!(!mgr.is_enabled("alpha"), "3 次失败必须禁用");
    let record = mgr.failure_record("alpha").expect("记录").clone();
    assert_eq!(record.count, MAX_CONSECUTIVE_FAILURES);
    assert!(record.is_auto_disabled());
    assert!(record.disabled_at_ms.is_some());
    assert_eq!(
        mgr.load_provider("alpha").expect_err("已禁用").kind,
        ManagerErrorKind::Disabled
    );

    // 手动启用 = 显式重置.
    mgr.enable("alpha").expect("手动启用");
    assert!(mgr.is_enabled("alpha"));
    assert_eq!(
        mgr.failure_record("alpha"),
        None,
        "手动启用清掉计数与禁用原因"
    );
    assert!(mgr.load_provider("alpha").is_ok(), "重置后能重新装载");

    // 落盘文件里只剩 enabled 段(没有失败记录).
    let text = std::fs::read_to_string(tmp.path().join(STATE_FILE)).expect("读状态文件");
    assert!(text.contains("\"enabled\""), "{text}");
    assert!(!text.contains("disabledReason"), "{text}");
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&text).expect("状态文件应是合法 JSON")
            ["failures"],
        serde_json::json!({}),
        "没有失败记录的插件不该留在 failures 段: {text}"
    );
}

#[test]
fn load_success_without_record_does_not_rewrite_state() {
    let tmp = TempDir::new("fail-noop");
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
    let path = tmp.path().join(STATE_FILE);
    let before = std::fs::metadata(&path)
        .expect("stat")
        .modified()
        .expect("mtime");
    std::thread::sleep(Duration::from_millis(20));
    // 没有失败记录时"成功一次"不写盘(否则每次重扫都落一次盘).
    mgr.record_load_success("alpha").expect("清零");
    let after = std::fs::metadata(&path)
        .expect("stat")
        .modified()
        .expect("mtime");
    assert_eq!(before, after, "无记录的成功不该重写状态文件");
}

// ---- 文件导入 / URL 导入 / 卸载(P4 插件导入补全) ----

/// URL 抓取替身: 不发网络, 记录被调用的 URL, 按预设返回(超限/非 2xx 的裁决在抓取器里,
/// 这里直接给结果就是为了只测"管理器怎么用抓取结果").
struct FakeFetcher {
    outcome: Result<String, ManagerError>,
    calls: Mutex<Vec<String>>,
}

impl FakeFetcher {
    fn ok(body: &str) -> Arc<Self> {
        Arc::new(Self {
            outcome: Ok(body.to_string()),
            calls: Mutex::new(Vec::new()),
        })
    }

    fn fail(err: ManagerError) -> Arc<Self> {
        Arc::new(Self {
            outcome: Err(err),
            calls: Mutex::new(Vec::new()),
        })
    }

    fn calls(&self) -> Vec<String> {
        self.calls.lock().expect("lock").clone()
    }
}

impl SourceFetcher for FakeFetcher {
    fn fetch(&self, url: &str) -> Result<String, ManagerError> {
        self.calls.lock().expect("lock").push(url.to_string());
        self.outcome.clone()
    }
}

/// 注入抓取器的 manager(URL 用例专用).
fn manager_with_fetcher(root: &Path, fetcher: Arc<FakeFetcher>) -> PluginManager {
    PluginManager::open(root, transport())
        .expect("打开插件根目录")
        .with_source_fetcher(fetcher)
}

fn events(names: &[&str]) -> Vec<String> {
    names.iter().map(|name| name.to_string()).collect()
}

#[test]
fn install_file_reads_local_script_and_writes_plugin() {
    // 来源文件放在**插件根目录之外**(放根里会被当插件目录扫, 干扰断言).
    let outside = TempDir::new("source-file");
    let src = outside.path().join("chain.js");
    std::fs::write(&src, OK_SOURCE).expect("写来源文件");

    let tmp = TempDir::new("install-file");
    let mut mgr = manager(tmp.path());
    let report = mgr
        .install_file(
            "fromfile",
            "文件插件",
            "2.0.0",
            &src,
            &events(&["musicUrl"]),
            &events(&["api.example.com"]),
        )
        .expect("文件导入应成功");
    assert_eq!(report.installed, vec!["fromfile".to_string()]);
    assert!(report.is_clean(), "{report:?}");

    let dir = tmp.path().join("fromfile");
    assert_eq!(
        std::fs::read_to_string(dir.join("index.js")).expect("入口脚本要写出来"),
        OK_SOURCE,
        "文件内容原样落盘"
    );
    let manifest = std::fs::read_to_string(dir.join("manifest.json")).expect("清单要写出来");
    assert!(manifest.contains("\"entry\":\"index.js\""), "{manifest}");
    assert!(manifest.contains("api.example.com"), "{manifest}");

    let row = mgr
        .list()
        .into_iter()
        .find(|row| row.id == "fromfile")
        .expect("应登记");
    assert_eq!(row.name, "文件插件");
    assert_eq!(row.version, "2.0.0");
    assert!(!row.enabled, "导入不等于启用");
    assert!(row.error.is_none(), "{row:?}");
}

#[test]
fn install_file_rejects_bad_source_without_touching_disk() {
    let outside = TempDir::new("source-bad");
    let tmp = TempDir::new("install-file-bad");
    let mut mgr = manager(tmp.path());

    // 1) 不存在
    let missing = outside.path().join("nope.js");
    let err = mgr
        .install_file("f1", "x", "1.0.0", &missing, &events(&["musicUrl"]), &[])
        .expect_err("不存在必须拒绝");
    assert_eq!(err.kind, ManagerErrorKind::Io, "{err}");

    // 2) 是目录不是文件
    let err = mgr
        .install_file(
            "f2",
            "x",
            "1.0.0",
            outside.path(),
            &events(&["musicUrl"]),
            &[],
        )
        .expect_err("目录必须拒绝");
    assert_eq!(err.kind, ManagerErrorKind::Io, "{err}");

    // 3) 非 UTF-8 文本
    let binary = outside.path().join("binary.js");
    std::fs::write(&binary, [0xff, 0xfe, 0x00]).expect("写非 UTF-8");
    let err = mgr
        .install_file("f3", "x", "1.0.0", &binary, &events(&["musicUrl"]), &[])
        .expect_err("非 UTF-8 必须拒绝");
    assert_eq!(err.kind, ManagerErrorKind::Manifest, "{err}");

    // 4) 超过 2 MiB(清单类错误)
    let huge = outside.path().join("huge.js");
    let mut bytes = vec![b'/'; MAX_SOURCE_BYTES + 1];
    std::fs::write(&huge, &mut bytes).expect("写超大来源");
    let err = mgr
        .install_file("f4", "x", "1.0.0", &huge, &events(&["musicUrl"]), &[])
        .expect_err("超限必须拒绝");
    assert_eq!(err.kind, ManagerErrorKind::Manifest, "{err}");
    assert!(err.detail.contains("超过上限"), "{err}");

    for id in ["f1", "f2", "f3", "f4"] {
        assert!(
            !tmp.path().join(id).exists(),
            "来源被拒后不能在盘上留下 {id}"
        );
    }
    assert!(mgr.list().is_empty(), "一条都不该登记: {:?}", mgr.list());
}

#[test]
fn install_url_only_accepts_https_and_never_fetches_otherwise() {
    let tmp = TempDir::new("install-url-bad");
    let fetcher = FakeFetcher::ok(OK_SOURCE);
    let mut mgr = manager_with_fetcher(tmp.path(), fetcher.clone());

    for url in [
        "http://cdn.test/plugin.js",
        "ftp://cdn.test/plugin.js",
        "file:///etc/passwd",
        "cdn.test/plugin.js",
        "https://",
        "",
    ] {
        let err = mgr
            .install_url("u1", "x", "1.0.0", url, &events(&["musicUrl"]), &[])
            .expect_err("非 https 必须拒绝");
        assert_eq!(err.kind, ManagerErrorKind::UnsafePath, "{url}: {err}");
    }
    assert!(
        fetcher.calls().is_empty(),
        "形态裁决在抓取之前, 不该发任何请求: {:?}",
        fetcher.calls()
    );
    assert!(!tmp.path().join("u1").exists(), "被拒后不落任何文件");
    assert!(mgr.list().is_empty());
}

#[test]
fn install_url_writes_fetched_script() {
    let tmp = TempDir::new("install-url");
    let fetcher = FakeFetcher::ok(OK_SOURCE);
    let mut mgr = manager_with_fetcher(tmp.path(), fetcher.clone());

    let report = mgr
        .install_url(
            "fromurl",
            "URL 插件",
            "3.1.4",
            "https://cdn.test/plugin.js",
            &events(&["musicUrl", "search"]),
            &events(&["*.cdn.test"]),
        )
        .expect("URL 导入应成功");
    assert_eq!(report.installed, vec!["fromurl".to_string()]);
    assert_eq!(
        fetcher.calls(),
        vec!["https://cdn.test/plugin.js".to_string()],
        "抓取只发生一次, 且 URL 原样传下去"
    );
    let dir = tmp.path().join("fromurl");
    assert_eq!(
        std::fs::read_to_string(dir.join("index.js")).expect("入口脚本"),
        OK_SOURCE
    );
    let row = mgr
        .list()
        .into_iter()
        .find(|row| row.id == "fromurl")
        .expect("应登记");
    assert_eq!(row.version, "3.1.4");
    assert_eq!(row.request_domains, vec!["*.cdn.test".to_string()]);
    assert!(!row.enabled);
}

#[test]
fn install_url_rejects_oversized_body_and_fetch_errors() {
    let tmp = TempDir::new("install-url-limits");

    // 1) 抓取器给了超限内容(对注入实现的兜底) ⇒ 清单类错误, 不落盘.
    let big = "x".repeat(MAX_SOURCE_BYTES + 1);
    let fetcher = FakeFetcher::ok(&big);
    let mut mgr = manager_with_fetcher(tmp.path(), fetcher);
    let err = mgr
        .install_url(
            "u2",
            "x",
            "1.0.0",
            "https://cdn.test/big.js",
            &events(&["musicUrl"]),
            &[],
        )
        .expect_err("超限必须拒绝");
    assert_eq!(err.kind, ManagerErrorKind::Manifest, "{err}");
    assert!(!tmp.path().join("u2").exists(), "超限不能落盘");

    // 2) 抓取器报网络错(非 2xx/超时/DNS) ⇒ 原样透出 Network, 且**不落盘**.
    let fetcher = FakeFetcher::fail(ManagerError::new(
        ManagerErrorKind::Network,
        "抓取 https://cdn.test/x.js 返回 http 404(只接受 2xx)",
    ));
    let mut mgr = manager_with_fetcher(tmp.path(), fetcher);
    let err = mgr
        .install_url(
            "u3",
            "x",
            "1.0.0",
            "https://cdn.test/x.js",
            &events(&["musicUrl"]),
            &[],
        )
        .expect_err("抓取失败必须报错");
    assert_eq!(err.kind, ManagerErrorKind::Network, "{err}");
    assert!(err.detail.contains("404"), "{err}");
    assert!(!tmp.path().join("u3").exists(), "抓取失败不能落盘");
    assert!(mgr.list().is_empty());
}

#[test]
fn uninstall_removes_dir_state_and_data_then_disappears_after_rescan() {
    let tmp = TempDir::new("uninstall");
    let dir = write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "index.js"),
        "index.js",
        OK_SOURCE,
    );
    // 插件自己的存储目录(卸载一并删掉).
    let data = dir.join("data");
    std::fs::create_dir_all(&data).expect("建 data");
    std::fs::write(data.join("kv.json"), b"{}").expect("写存储");

    let mut mgr = manager(tmp.path());
    mgr.install_from_dir(tmp.path());
    mgr.enable("alpha").expect("启用");
    assert!(mgr.load_provider("alpha").is_ok(), "启用后可装载");
    // 顺手留一条失败计数, 验证卸载会把它一起清掉.
    mgr.record_load_failure("alpha", "模拟一次失败")
        .expect("计数");

    mgr.uninstall("alpha").expect("卸载应成功");

    assert!(!dir.exists(), "插件目录(含 data/)必须删掉");
    assert!(mgr.list().is_empty(), "卸载后列表不该再有它");
    assert!(mgr.manifest("alpha").is_none());
    assert!(!mgr.is_enabled("alpha"));
    assert!(mgr.failure_record("alpha").is_none(), "失败计数要清掉");
    assert_eq!(
        mgr.load_provider("alpha").expect_err("已删").kind,
        ManagerErrorKind::NotInstalled
    );

    // 状态文件里不残留该 id(否则会在盘上留一条指向不存在插件的记录).
    let text = std::fs::read_to_string(tmp.path().join(STATE_FILE)).expect("读状态文件");
    assert!(!text.contains("alpha"), "状态文件不该残留: {text}");

    // 重扫(等价于重启后首扫)不会让它回来.
    let report = mgr.rescan();
    assert!(report.is_clean(), "{report:?}");
    assert!(mgr.list().is_empty(), "重扫后仍不该出现");
}

#[test]
fn uninstall_rejects_unsafe_ids_and_unknown_plugins() {
    let tmp = TempDir::new("uninstall-unsafe");
    let dir = write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "index.js"),
        "index.js",
        OK_SOURCE,
    );
    let mut mgr = manager(tmp.path());
    mgr.install_from_dir(tmp.path());

    // 路径安全: `..` / 分隔符 / 绝对路径 / 大写 / 点号 / 空串一律 UnsafePath.
    for bad in [
        "../alpha",
        "alpha/../alpha",
        "/etc/alpha",
        "Alpha",
        "al.pha",
        "",
        ".",
        "..",
    ] {
        let err = mgr.uninstall(bad).expect_err("非法 id 必须拒绝");
        assert_eq!(err.kind, ManagerErrorKind::UnsafePath, "{bad}: {err}");
    }
    assert!(dir.exists(), "非法 id 不能删掉任何东西");
    assert_eq!(mgr.list().len(), 1, "登记要原样留着");

    // 未登记(且目录不存在) ⇒ notInstalled, 不 panic.
    let err = mgr.uninstall("ghost").expect_err("未登记必须拒绝");
    assert_eq!(err.kind, ManagerErrorKind::NotInstalled, "{err}");
}

#[test]
fn uninstall_removes_broken_plugin_dir() {
    let tmp = TempDir::new("uninstall-broken");
    let dir = tmp.path().join("broken");
    std::fs::create_dir_all(&dir).expect("建目录");
    std::fs::write(dir.join("manifest.json"), b"{ not json").expect("写坏清单");

    let mut mgr = manager(tmp.path());
    let report = mgr.install_from_dir(tmp.path());
    assert!(!report.is_clean(), "坏清单应该进报告: {report:?}");

    // 坏条目虽未登记, 但目录存在 ⇒ 必须能删掉(这是清垃圾的唯一入口).
    mgr.uninstall("broken").expect("坏插件目录也要能删");
    assert!(!dir.exists(), "坏插件目录应被删除");
    assert!(
        mgr.list().is_empty(),
        "卸载后不该再有错误行: {:?}",
        mgr.list()
    );
}

#[test]
fn https_url_shape_helper_is_strict() {
    for ok in [
        "https://cdn.test/a.js",
        "HTTPS://cdn.test/a.js",
        "https://cdn.test:8443/x?a=1#f",
    ] {
        check_https_url(ok).unwrap_or_else(|err| panic!("{ok} 应通过: {err}"));
    }
    for bad in [
        "http://cdn.test/a.js",
        "ftp://cdn.test/a.js",
        "file:///etc/passwd",
        "cdn.test/a.js",
        "https://",
        "https:///a.js",
        "   ",
    ] {
        let err = check_https_url(bad).expect_err("应被拒绝");
        assert_eq!(err.kind, ManagerErrorKind::UnsafePath, "{bad}: {err}");
        assert!(!err.detail.is_empty());
    }
}

#[test]
fn read_capped_stops_at_the_limit() {
    let ok = read_capped(std::io::Cursor::new(b"abc".to_vec()), 3).expect("恰好到上限可以");
    assert_eq!(ok, b"abc");

    let err = read_capped(std::io::Cursor::new(vec![b'x'; 4]), 3).expect_err("超限必须拒绝");
    assert_eq!(err.kind, ManagerErrorKind::Manifest, "{err}");
    assert!(err.detail.contains("超过上限"), "{err}");
}
