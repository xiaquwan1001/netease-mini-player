//! `PluginRegistry` 用例: 目录扫描 + 校验失败隔离 + 重扫刷新 + 同 id 冲突 + 空目录 +
//! 端到端(临时目录里的最小插件 -> 注册表能返回并真的能取链).
//!
//! 全部不联网: `Transport` 用 `MockTransport`, 目录是 `std::env::temp_dir()` 下的临时目录
//! (每个用例一份, 结束尽力清理). 复用 `manager_tests.rs` 的写法, 但**不**跨模块引用它的
//! helper(那份是 `#[path]` 私有模块), 这里各写一份最小的.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use ncm_domain::TrackId;
use ncm_plugin::{MockTransport, SandboxConfig};
// `dyn Provider` 的方法不经 trait 导入就能调(超 trait 方法在 trait object 上有),
// 所以这里只引参数类型与错误枚举.
use ncm_provider::{AudioLevel, ProviderErrorKind, SongUrlRequest};

use super::{PluginRegistry, MAX_CONSECUTIVE_FAILURES};

static SEQ: AtomicUsize = AtomicUsize::new(0);

/// 每个用例一个独立临时目录(用完尽力删).
struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = SEQ.fetch_add(1, Ordering::SeqCst);
        let mut path = std::env::temp_dir();
        path.push(format!("ncm-plugin-reg-{tag}-{}-{n}", std::process::id()));
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

fn manifest_json(id: &str, name: &str, entry: &str) -> String {
    format!(
        r#"{{"id":"{id}","name":"{name}","version":"1.0.0","entry":"{entry}","permissions":{{"lxEvents":["musicUrl"]}}}}"#
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

/// 装载期必然失败(语法错)的入口脚本: 用来喂"连续失败"计数.
const BROKEN_SOURCE: &str = "lx.on('musicUrl', () => { this is not js";

/// 写一个"装载必失败"的插件目录.
fn write_broken_plugin(root: &Path, dir: &str) -> PathBuf {
    write_plugin(
        root,
        dir,
        &manifest_json(dir, "Broken 插件", "index.js"),
        "index.js",
        BROKEN_SOURCE,
    )
}

fn song_request() -> SongUrlRequest {
    SongUrlRequest {
        track: TrackId(7),
        level: AudioLevel::Exhigh,
    }
}

/// 注册表 + MockTransport 句柄(需要查见到什么请求的用例用).
fn registry(root: &Path) -> PluginRegistry {
    PluginRegistry::open(root, transport()).expect("打开插件根目录")
}

// ---------- 端到端: 最小插件 -> 注册表 -> 真的取链 ----------

#[test]
fn minimal_plugin_round_trips_through_registry() {
    let tmp = TempDir::new("e2e");
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "Alpha 插件", "index.js"),
        "index.js",
        OK_SOURCE,
    );

    let mut reg = registry(tmp.path());
    let report = reg.scan();
    assert_eq!(report.scanned, vec!["alpha".to_string()]);
    assert!(report.is_clean(), "{report:?}");
    assert!(
        reg.get("alpha").is_none(),
        "缺省停用 ⇒ 扫描后不装载({report:?})"
    );
    assert_eq!(report.skipped, vec!["alpha".to_string()]);
    assert!(report.loaded.is_empty());

    reg.enable("alpha").expect("启用并装载");
    assert_eq!(reg.ids(), vec!["alpha"]);

    let provider = reg.get("alpha").expect("按插件 id 取到 provider");
    assert_eq!(provider.name(), "Alpha 插件");
    // 关键口径: provider 自身 id 恒为 "script"(trait 返回 &'static str),
    // 所以注册表必须按插件 id 索引 —— 这条断言是"不能直接用 ProviderRegistry"的证据.
    assert_eq!(provider.id(), "script");

    let url = futures::executor::block_on(provider.song_url(&song_request())).expect("取链");
    assert_eq!(url.url.as_deref(), Some("https://cdn.test/a.mp3"));
    assert!(!url.is_trial);

    // 条目/全量两个视图一致.
    let entries = reg.entries();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].0, "alpha");
    assert_eq!(reg.all().len(), 1);
    assert!(reg.failures().is_empty());
}

// ---------- 坏插件隔离 ----------

#[test]
fn bad_plugin_does_not_block_good_one() {
    let tmp = TempDir::new("isolate");
    write_plugin(
        tmp.path(),
        "good",
        &manifest_json("good", "Good 插件", "index.js"),
        "index.js",
        OK_SOURCE,
    );
    write_plugin(
        tmp.path(),
        "broken",
        "{ this is not json",
        "index.js",
        OK_SOURCE,
    );
    // 目录名不是合法 id: 连清单都不看.
    write_plugin(
        tmp.path(),
        "Bad_Name",
        &manifest_json("Bad_Name", "Bad", "index.js"),
        "index.js",
        OK_SOURCE,
    );

    let mut reg = registry(tmp.path());
    let report = reg.scan();
    assert_eq!(report.scanned, vec!["good".to_string()], "{report:?}");
    assert!(!report.is_clean());
    let keys: Vec<&str> = report.failed.iter().map(|(k, _)| k.as_str()).collect();
    assert!(keys.contains(&"broken"), "{report:?}");
    assert!(keys.contains(&"Bad_Name"), "{report:?}");

    reg.enable("good").expect("好插件照常启用");
    assert_eq!(reg.ids(), vec!["good"]);
    assert!(reg.get("broken").is_none());
    assert!(reg.get("Bad_Name").is_none());
    // 失败原因在注册表里可读(不会只留一个"未登记").
    assert!(reg.failures().contains_key("broken"));
    assert!(reg.failures().contains_key("Bad_Name"));

    // 管理视图里坏条目也占一行(UI 用这个).
    let rows = reg.summaries();
    assert_eq!(rows.len(), 3, "{rows:?}");
}

// ---------- 装载失败(脚本语法错)同样被隔离 ----------

#[test]
fn load_failure_is_recorded_and_isolated() {
    let tmp = TempDir::new("load-fail");
    write_plugin(
        tmp.path(),
        "syntax",
        &manifest_json("syntax", "Syntax", "index.js"),
        "index.js",
        "lx.on('musicUrl', () => { this is not js",
    );
    write_plugin(
        tmp.path(),
        "ok",
        &manifest_json("ok", "OK", "index.js"),
        "index.js",
        OK_SOURCE,
    );

    let mut reg = registry(tmp.path());
    assert!(reg.scan().is_clean(), "清单都好");
    reg.enable("ok").expect("启用 ok");
    let err = reg.enable("syntax").expect_err("语法错必须报装载失败");
    assert!(err.to_string().contains("syntax") || !err.detail.is_empty());

    assert_eq!(reg.ids(), vec!["ok"], "坏脚本不拖垮已装好的插件");
    assert!(
        reg.failures().contains_key("syntax"),
        "{:?}",
        reg.failures()
    );
    // 刷新后仍然是失败态(状态已落盘为启用), 而不是悄悄消失.
    let report = reg.scan();
    assert!(report.loaded.contains(&"ok".to_string()), "{report:?}");
    assert!(!report.loaded.contains(&"syntax".to_string()));
    assert!(
        report.failed.iter().any(|(k, _)| k == "syntax"),
        "{report:?}"
    );
}

// ---------- 重扫刷新(同目录覆盖) ----------

#[test]
fn rescan_refreshes_provider_from_same_dir() {
    let tmp = TempDir::new("refresh");
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "Alpha v1", "index.js"),
        "index.js",
        OK_SOURCE,
    );

    let mut reg = registry(tmp.path());
    reg.scan();
    reg.enable("alpha").expect("启用");
    assert_eq!(reg.get("alpha").expect("v1").name(), "Alpha v1");

    // 同目录改清单名 + 改脚本: 重扫必须是"覆盖", 不是"多一条".
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "Alpha v2", "main.js"),
        "main.js",
        "lx.on('musicUrl', () => ({ url: 'https://cdn.test/b.mp3', type: 'flac' }));",
    );
    let report = reg.scan();
    assert!(report.is_clean(), "{report:?}");
    assert_eq!(report.scanned, vec!["alpha".to_string()]);
    assert_eq!(reg.ids(), vec!["alpha"], "覆盖而不是追加");
    let provider = reg.get("alpha").expect("v2");
    assert_eq!(provider.name(), "Alpha v2");
    let url = futures::executor::block_on(provider.song_url(&song_request())).expect("取链");
    assert_eq!(url.url.as_deref(), Some("https://cdn.test/b.mp3"));

    // 再改坏清单: 旧 provider 必须摘掉(否则就是"改了没生效还看不出来").
    std::fs::write(tmp.path().join("alpha/manifest.json"), "{ broken").expect("写坏清单");
    let report = reg.scan();
    assert!(!report.is_clean(), "{report:?}");
    assert!(reg.get("alpha").is_none(), "坏掉的旧登记不能继续供源");
    assert!(reg.failures().contains_key("alpha"));
}

// ---------- 跨目录同 id: 先到先得 ----------

#[test]
fn same_id_from_another_dir_does_not_take_over() {
    let first = TempDir::new("dup-first");
    let second = TempDir::new("dup-second");
    write_plugin(
        first.path(),
        "shared",
        &manifest_json("shared", "First 插件", "index.js"),
        "index.js",
        OK_SOURCE,
    );
    write_plugin(
        second.path(),
        "shared",
        &manifest_json("shared", "Second 插件", "index.js"),
        "index.js",
        "lx.on('musicUrl', () => ({ url: 'https://cdn.test/other.mp3', type: 'mp3' }));",
    );

    // 注册表根 = first, 再扫 second 这个额外目录.
    let mut reg = registry(first.path());
    assert!(reg.scan().is_clean());
    reg.enable("shared").expect("启用 first 的 shared");

    let report = reg.scan_dir(second.path());
    assert!(!report.is_clean(), "重复 id 必须进报告: {report:?}");
    assert!(
        report.failed.iter().any(|(k, _)| k == "shared"),
        "{report:?}"
    );
    assert_eq!(reg.ids(), vec!["shared"], "同 id 不会出现两份");
    // 冲突是"某个目录被拒", 不能写进 failures()(那会读成"这个插件坏了, 但它正在供源").
    assert!(reg.failures().is_empty(), "{:?}", reg.failures());
    assert!(
        reg.rejected().iter().any(|(k, _)| k == "shared"),
        "被拒收的目录要能跨调用追溯: {:?}",
        reg.rejected()
    );
    let provider = reg.get("shared").expect("第一份仍在");
    assert_eq!(provider.name(), "First 插件", "先到先得: 不被后登记者覆盖");
    let url = futures::executor::block_on(provider.song_url(&song_request())).expect("取链");
    assert_eq!(url.url.as_deref(), Some("https://cdn.test/a.mp3"));

    // 反方向再验证一次: 先扫 second 的注册表, 第一份也在(独立实例, 不共享状态).
    let mut other = registry(second.path());
    other.scan();
    other.enable("shared").expect("启用 second 的 shared");
    assert_eq!(
        other.get("shared").expect("second").name(),
        "Second 插件",
        "各自根目录里都是自己那份"
    );
}

// ---------- 空目录 ----------

#[test]
fn empty_dir_scans_clean() {
    let tmp = TempDir::new("empty");
    let mut reg = registry(tmp.path());
    let report = reg.scan();
    assert_eq!(report, super::RegistryReport::default());
    assert!(report.is_clean());
    assert!(reg.ids().is_empty());
    assert!(reg.entries().is_empty());
    assert!(reg.failures().is_empty());
    assert!(reg.summaries().is_empty());

    // 隐藏项 / 状态文件本身不算插件.
    std::fs::write(tmp.path().join(".tmp"), "x").expect("写隐藏文件");
    let report = reg.scan();
    assert!(report.is_clean(), "隐藏项必须被忽略: {report:?}");
    assert!(report.scanned.is_empty());
}

// ---------- 错误口径: 注册表不新造错误类型 ----------

#[test]
fn provider_errors_keep_provider_error_shape() {
    let tmp = TempDir::new("err-shape");
    write_plugin(
        tmp.path(),
        "boom",
        &manifest_json("boom", "Boom", "index.js"),
        "index.js",
        "lx.on('musicUrl', () => { throw new Error('boom from plugin'); });",
    );

    let mut reg = registry(tmp.path()).with_sandbox_config(SandboxConfig {
        call_timeout: Duration::from_secs(5),
        ..SandboxConfig::default()
    });
    reg.scan();
    reg.enable("boom").expect("脚本能装载(抛错发生在调用期)");
    let provider = reg.get("boom").expect("取到 provider");

    let err = futures::executor::block_on(provider.song_url(&song_request()))
        .expect_err("脚本抛错必须变成 ProviderError");
    // 形状: ncm_provider::ProviderError{kind,retryable,detail}; 脚本未捕获异常 -> Internal.
    assert_eq!(err.kind, ProviderErrorKind::Internal, "{err:?}");
    assert!(!err.retryable);
    assert!(!err.detail.is_empty(), "detail 要有可读原因");
    assert_eq!(err.to_string(), format!("[internal] {}", err.detail));

    // 注册表本身没有第二条错误口径: `failures()` 里不该出现调用期错误(它只管装载/扫描).
    assert!(!reg.failures().contains_key("boom"), "{:?}", reg.failures());
}

// ---------- 停用: 摘 provider, 且刷新不复活 ----------

#[test]
fn disable_drops_provider_and_rescan_does_not_resurrect() {
    let tmp = TempDir::new("disable");
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "Alpha", "index.js"),
        "index.js",
        OK_SOURCE,
    );

    let mut reg = registry(tmp.path());
    reg.scan();
    reg.enable("alpha").expect("启用");
    assert!(reg.get("alpha").is_some());

    reg.disable("alpha").expect("停用");
    assert!(reg.get("alpha").is_none(), "停用后不能再供源");
    assert!(reg.ids().is_empty());
    assert!(reg.failures().is_empty());
    assert!(!reg.manager().is_enabled("alpha"), "状态已落盘为停用");

    // 重扫不能把它复活: 启用态归 PluginManager, 刷新只装载"已启用"的插件.
    let report = reg.scan();
    assert!(report.is_clean(), "{report:?}");
    assert_eq!(report.skipped, vec!["alpha".to_string()]);
    assert!(report.loaded.is_empty());
    assert!(reg.get("alpha").is_none());

    // 未登记 id 的 enable/disable 仍然报 NotInstalled(不静默成功).
    assert_eq!(
        reg.enable("ghost").expect_err("未登记").kind,
        super::super::ManagerErrorKind::NotInstalled
    );
}

// ---------- 扫描根不可访问: 进 rejected, 不动已有 provider ----------

#[test]
fn unreachable_dir_is_rejected_without_touching_loaded_providers() {
    let tmp = TempDir::new("unreachable");
    write_plugin(
        tmp.path(),
        "alpha",
        &manifest_json("alpha", "Alpha", "index.js"),
        "index.js",
        OK_SOURCE,
    );

    let mut reg = registry(tmp.path());
    reg.scan();
    reg.enable("alpha").expect("启用");

    let missing = tmp.path().join("does-not-exist");
    let report = reg.scan_dir(&missing);
    assert!(!report.is_clean(), "{report:?}");
    assert_eq!(reg.ids(), vec!["alpha"], "坏扫描根不影响已装载的 provider");
    assert!(reg.get("alpha").is_some());
    assert!(
        reg.rejected()
            .iter()
            .any(|(k, _)| k.contains("does-not-exist")),
        "{:?}",
        reg.rejected()
    );
}

// ---------- 连续装载失败 3 次自动禁用(P3) ----------

#[test]
fn three_consecutive_load_failures_auto_disable() {
    let tmp = TempDir::new("fail3");
    write_broken_plugin(tmp.path(), "brk");

    let mut reg = registry(tmp.path());
    assert!(reg.scan().is_clean(), "清单一律合法, 失败只发生在装载");

    // 第 1 次: enable 即装载 ⇒ 失败但不禁用.
    reg.enable("brk").expect_err("语法错必须报装载失败");
    assert_eq!(
        reg.manager().failure_record("brk").map(|r| r.count),
        Some(1),
        "enable 的装载失败要计一次"
    );
    assert!(reg.manager().is_enabled("brk"), "1 次失败还不该禁用");

    // 第 2 次: 重扫重试装载.
    let report = reg.scan();
    assert!(report.failed.iter().any(|(k, _)| k == "brk"), "{report:?}");
    assert_eq!(
        reg.manager().failure_record("brk").map(|r| r.count),
        Some(2)
    );
    assert!(reg.manager().is_enabled("brk"), "2 次失败还不该禁用");

    // 第 3 次: 达阈值 ⇒ 自动禁用(同一份原子写里改 enabled + 记原因).
    let report = reg.scan();
    assert!(
        !reg.manager().is_enabled("brk"),
        "连续 {MAX_CONSECUTIVE_FAILURES} 次失败必须自动禁用"
    );
    let record = reg
        .manager()
        .failure_record("brk")
        .expect("失败记录")
        .clone();
    assert_eq!(record.count, MAX_CONSECUTIVE_FAILURES);
    assert!(record.is_auto_disabled());
    let reason = record.disabled_reason.as_deref().expect("自动禁用原因");
    assert!(reason.contains("自动禁用"), "{reason}");
    assert!(reason.contains("连续 3 次"), "原因要带次数: {reason}");
    assert!(record.disabled_at_ms.is_some(), "要记禁用时间");
    assert!(record.last_reason.is_some() && record.last_at_ms.is_some());

    // 报告文案必须说"被禁用了", 不能只说最近一次语法错.
    let (_, detail) = report
        .failed
        .iter()
        .find(|(k, _)| k == "brk")
        .expect("失败行");
    assert!(detail.contains("自动禁用"), "{detail}");

    // 状态落盘: failures 段与禁用原因都在盘上.
    let text = std::fs::read_to_string(tmp.path().join("plugins-state.json")).expect("读状态文件");
    assert!(text.contains("\"failures\""), "{text}");
    assert!(text.contains("\"disabledReason\""), "{text}");
    assert!(text.contains("\"disabledAtMs\""), "{text}");

    // 已禁用 ⇒ 后续重扫进 skipped, 不再尝试装载, 计数也不再涨.
    let report = reg.scan();
    assert!(report.skipped.contains(&"brk".to_string()), "{report:?}");
    assert_eq!(
        reg.manager().failure_record("brk").map(|r| r.count),
        Some(MAX_CONSECUTIVE_FAILURES)
    );
}

#[test]
fn two_failures_then_success_clears_the_count() {
    let tmp = TempDir::new("fail-reset");
    write_broken_plugin(tmp.path(), "flaky");

    let mut reg = registry(tmp.path());
    reg.scan();
    reg.enable("flaky").expect_err("第 1 次失败");
    let report = reg.scan();
    assert!(report.failed.iter().any(|(k, _)| k == "flaky"));
    assert_eq!(
        reg.manager().failure_record("flaky").map(|r| r.count),
        Some(2)
    );

    // 修好脚本 ⇒ 下一次装载成功: 计数清零(整条记录消失).
    std::fs::write(tmp.path().join("flaky/index.js"), OK_SOURCE).expect("修脚本");
    let report = reg.scan();
    assert!(report.loaded.contains(&"flaky".to_string()), "{report:?}");
    assert_eq!(
        reg.manager().failure_record("flaky"),
        None,
        "成功一次必须把连续失败清零"
    );
    assert!(reg.manager().is_enabled("flaky"), "清零不是禁用");
    let state: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(tmp.path().join("plugins-state.json")).expect("读状态文件"),
    )
    .expect("状态文件应是合法 JSON");
    assert_eq!(
        state["failures"],
        serde_json::json!({}),
        "清零后不该在 failures 段留条目: {state}"
    );
    assert_eq!(state["enabled"]["flaky"], serde_json::json!(true));

    // 再弄坏一次: 计数从 1 重新开始(不是接着数到 3 ⇒ 也就不会立刻被禁).
    std::fs::write(tmp.path().join("flaky/index.js"), BROKEN_SOURCE).expect("再弄坏");
    let report = reg.scan();
    assert!(!report.loaded.contains(&"flaky".to_string()), "{report:?}");
    let record = reg.manager().failure_record("flaky").expect("新记录");
    assert_eq!(record.count, 1, "清零后重新计数");
    assert!(!record.is_auto_disabled());
    assert!(
        reg.manager().is_enabled("flaky"),
        "重新计数的第 1 次不该禁用"
    );
}

#[test]
fn auto_disabled_plugin_stays_disabled_across_restart() {
    let tmp = TempDir::new("fail-restart");
    write_broken_plugin(tmp.path(), "brk");
    {
        let mut reg = registry(tmp.path());
        reg.scan();
        reg.enable("brk").expect_err("装载失败");
        reg.scan();
        reg.scan();
        assert!(!reg.manager().is_enabled("brk"), "三次失败已禁用");
    } // 掉电/重启: 注册表整个丢掉

    let mut reg = registry(tmp.path());
    let report = reg.scan();
    assert!(
        report.skipped.contains(&"brk".to_string()),
        "重启后仍然禁用(进 skipped): {report:?}"
    );
    assert!(report.loaded.is_empty(), "{report:?}");
    assert!(!reg.manager().is_enabled("brk"));
    let record = reg
        .manager()
        .failure_record("brk")
        .expect("禁用原因跨重启保留");
    assert!(record.is_auto_disabled());
    assert_eq!(record.count, MAX_CONSECUTIVE_FAILURES);
    let reason = record.disabled_reason.clone().expect("原因");
    assert!(reason.contains("连续 3 次"), "{reason}");
}

#[test]
fn manual_enable_after_auto_disable_is_an_explicit_reset() {
    let tmp = TempDir::new("fail-manual");
    write_broken_plugin(tmp.path(), "brk");
    let mut reg = registry(tmp.path());
    reg.scan();
    reg.enable("brk").expect_err("装载失败");
    reg.scan();
    reg.scan();
    assert!(reg
        .manager()
        .failure_record("brk")
        .expect("记录")
        .is_auto_disabled());

    // 用户修好脚本后手动启用: 视为显式重置(计数与禁用原因一起清掉).
    std::fs::write(tmp.path().join("brk/index.js"), OK_SOURCE).expect("修脚本");
    reg.enable("brk").expect("手动启用后应能装载");
    assert!(reg.manager().is_enabled("brk"));
    assert_eq!(
        reg.manager().failure_record("brk"),
        None,
        "手动启用必须清掉禁用记录"
    );
    assert_eq!(
        reg.get("brk").map(|p| p.name().to_string()).as_deref(),
        Some("Broken 插件"),
        "重置后应真的装上"
    );
    let text = std::fs::read_to_string(tmp.path().join("plugins-state.json")).expect("读状态文件");
    assert!(
        !text.contains("disabledReason"),
        "盘上的禁用原因也要清掉: {text}"
    );

    // 重置后计数从 0 开始: 弄坏一次只是 1, 不是接着 3 立刻再禁.
    std::fs::write(tmp.path().join("brk/index.js"), BROKEN_SOURCE).expect("再弄坏");
    reg.scan();
    let record = reg.manager().failure_record("brk").expect("记录");
    assert_eq!(record.count, 1);
    assert!(!record.is_auto_disabled());
    assert!(reg.manager().is_enabled("brk"));
}

// ---------- 版本协商: 不兼容 ⇒ 拒绝装载 + 文案带区间(P3) ----------

#[test]
fn incompatible_api_version_is_rejected_with_required_range() {
    let tmp = TempDir::new("api-version");
    let too_new = r#"{"id":"future","name":"Future 插件","version":"1.0.0","apiVersion":2,"entry":"index.js"}"#;
    let too_old = r#"{"id":"ancient","name":"Ancient 插件","version":"1.0.0","apiVersion":0,"entry":"index.js"}"#;
    write_plugin(tmp.path(), "future", too_new, "index.js", OK_SOURCE);
    write_plugin(tmp.path(), "ancient", too_old, "index.js", OK_SOURCE);

    let mut reg = registry(tmp.path());
    let report = reg.scan();
    assert!(report.scanned.is_empty(), "版本不兼容不许登记: {report:?}");
    assert_eq!(report.failed.len(), 2, "{report:?}");
    for (key, detail) in &report.failed {
        assert!(detail.contains("apiVersion"), "{key}: {detail}");
        assert!(
            detail.contains("1..=1"),
            "文案必须含所需区间({key}): {detail}"
        );
    }

    // 不静默跳过: 两个目录都占一行错误, 且原因可读(UI 直接展示).
    let rows = reg.summaries();
    assert_eq!(rows.len(), 2, "{rows:?}");
    for row in &rows {
        let error = row.error.as_ref().expect("必须带原因");
        assert!(error.contains("1..=1"), "{row:?}");
    }
    assert!(reg.ids().is_empty(), "不兼容版本不许建沙箱/装上 provider");
    assert!(reg.get("future").is_none());
    assert!(reg.get("ancient").is_none());

    // 也不能"先启用再装载": 启用本身就报带区间的错.
    let err = reg.enable("future").expect_err("不兼容版本不能启用");
    assert!(err.to_string().contains("1..=1"), "{err}");
}
