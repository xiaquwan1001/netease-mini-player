//! 插件导出层用例: 错误口径(未启用 ⇒ forbidden / 坏插件只记录不 panic) +
//! DTO 转换保真 + Android 空视图语义.
//!
//! 这里**不走全局 `CORE`**(`OnceLock<Mutex<Core>>` 一进程只能建一次, 多用例并行会互相污染),
//! 而是直接构造 `PluginHost` / 纯 DTO, 覆盖导出层真正的职责:
//! 1. 错误是不是只经 `ProviderError` 一条口径(不打第二套词表);
//! 2. 空视图/失败视图的语义是不是"不 panic、不静默".
//!
//! 全局单例那一层薄壳(取锁 + 转发)由 `cargo check`/`clippy` 与桥接 codegen 保证形状;
//! `Core` 端到端行为在 `ncm-service` 的 `plugins::host_tests` 里已经钉住.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use ncm_provider::{ProviderError, ProviderErrorKind};
use ncm_service::{PluginHost, PluginHostPolicy, PluginHostStatus, PluginSummary};

use super::{
    failures_dto, rejected_dto, rescan_dto, route_mode_dto, route_plan_dto, status_dto,
    summary_dto, unsupported_error, unsupported_route_mode, unsupported_route_plan,
    unsupported_status,
};

static SEQ: AtomicUsize = AtomicUsize::new(0);

/// 每个用例一个独立临时目录(用完尽力删).
struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = SEQ.fetch_add(1, Ordering::SeqCst);
        let mut path = std::env::temp_dir();
        path.push(format!("ncm-ffi-plugin-{tag}-{}-{n}", std::process::id()));
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

/// 打开宿主总开关(写策略文件) —— 等价于 `plugin_set_enabled(true)` 的落盘结果.
fn enable_policy(data_dir: &Path) {
    PluginHostPolicy {
        enabled: true,
        ..PluginHostPolicy::default()
    }
    .save(data_dir)
    .expect("写策略文件");
}

fn summary(id: &str, enabled: bool, error: Option<&str>) -> PluginSummary {
    PluginSummary {
        id: id.to_string(),
        name: format!("{id} 插件"),
        version: "1.0.0".to_string(),
        enabled,
        request_domains: vec!["music.163.com".to_string()],
        error: error.map(str::to_string),
    }
}

// ------------------------- 错误口径: 只有一条 -------------------------

/// 未启用总开关时的写操作必须是 `forbidden`(不是"静默 Ok", 也不是另一种错误类型).
#[test]
fn write_before_enabling_host_is_forbidden() {
    let dir = TempDir::new("disabled");
    let mut host = PluginHost::open(dir.path());
    assert!(!host.policy().enabled, "缺省策略必须是不扫描");
    assert!(!host.is_active(), "缺省不建注册表");

    let err = host.enable("demo").expect_err("未启用时启用插件必须失败");
    let ffi = super::FfiError::from(err);
    assert_eq!(ffi.kind, ProviderErrorKind::Forbidden.as_str());
    assert!(!ffi.retryable, "策略拒绝重试不会变");
    // detail 保留宿主层原文(细分原因不丢). 这里**只要求非空**, 不对文案措辞做断言 ——
    // 文案改了不该让"错误口径"用例假红.
    assert!(
        !ffi.detail.is_empty(),
        "detail 不能丢, 否则 UI 只剩一个 kind"
    );

    // 三个写操作同口径: 都走 registry_mut(), 不该有一个漏网
    let disable = host.disable("demo").expect_err("未启用时停用必须失败");
    let rescan = host.rescan().expect_err("未启用时重扫必须失败");
    for err in [disable, rescan] {
        let ffi = super::FfiError::from(err);
        assert_eq!(ffi.kind, ProviderErrorKind::Forbidden.as_str());
        assert!(!ffi.retryable);
        assert!(!ffi.detail.is_empty());
    }
}

/// `ProviderError -> FfiError` 只是搬运 kind/retryable/detail, 不新造词表.
#[test]
fn ffi_error_reuses_provider_kind_vocabulary() {
    for kind in [
        ProviderErrorKind::Forbidden,
        ProviderErrorKind::Unsupported,
        ProviderErrorKind::NotFound,
        ProviderErrorKind::Internal,
        ProviderErrorKind::Network,
    ] {
        let ffi = super::FfiError::from(ProviderError::new(kind, true, "detail"));
        assert_eq!(ffi.kind, kind.as_str());
        assert!(ffi.retryable);
        assert_eq!(ffi.detail, "detail");
        // Display 仍是跨桥文本协议 "[kind] detail"
        assert_eq!(ffi.to_string(), format!("[{}] detail", kind.as_str()));
    }
}

// ------------------------- 坏插件: 记录但不 panic -------------------------

/// 坏插件目录: 只有 failures/summaries 里的一行原因, 导出层照常返回(`Ok`), 不 panic.
#[test]
fn broken_plugin_is_recorded_not_panicked() {
    let dir = TempDir::new("broken");
    enable_policy(dir.path());
    let bad = dir.path().join("plugins").join("demo");
    std::fs::create_dir_all(&bad).expect("建插件目录");
    std::fs::write(bad.join("manifest.json"), b"{ not json").expect("写坏清单");

    let host = PluginHost::open(dir.path());
    assert!(host.is_active(), "总开关打开后应建起注册表");

    // 读类: 空视图以外还要有原因
    let status = status_dto(&host.status());
    assert!(status.supported);
    assert!(status.enabled && status.active);
    assert!(status.loaded.is_empty(), "坏插件不该被装载");
    assert_eq!(status.failed, 1, "坏条目要计入 failed");
    assert!(status.error.is_none(), "单个坏插件不算宿主失败");
    assert!(!status.root.is_empty(), "未启用也要给出根目录用于展示");

    let failures = failures_dto(&host.failures());
    assert_eq!(failures.len(), 1);
    assert_eq!(failures[0].id, "demo");
    assert!(!failures[0].detail.is_empty(), "失败原因不能为空");

    let summaries: Vec<_> = host.summaries().iter().map(summary_dto).collect();
    // 坏目录未必进 summaries(扫描阶段就被拒), 但一定有 error 或进 failures —— 两者至少一处
    assert!(
        summaries.iter().any(|s| s.error.is_some()) || !failures.is_empty(),
        "坏插件必须被记录"
    );

    // 写类: 坏插件启不来, 但错误仍是同一口径(notFound/unsupported), 且不 panic
    let mut host = host;
    let err = host.enable("demo").expect_err("坏插件不能启用");
    let ffi = super::FfiError::from(err);
    assert!(
        ffi.kind == ProviderErrorKind::NotFound.as_str()
            || ffi.kind == ProviderErrorKind::Unsupported.as_str(),
        "坏插件错误应落在已有词表里, 实际: {ffi}"
    );
    assert!(!ffi.retryable);
}

// ------------------------- DTO 保真 -------------------------

#[test]
fn summary_dto_preserves_every_field() {
    let dto = summary_dto(&summary("demo", true, Some("装载失败")));
    assert_eq!(dto.id, "demo");
    assert_eq!(dto.name, "demo 插件");
    assert_eq!(dto.version, "1.0.0");
    assert!(dto.enabled);
    assert_eq!(dto.request_domains, vec!["music.163.com".to_string()]);
    assert_eq!(dto.error.as_deref(), Some("装载失败"));

    let clean = summary_dto(&summary("ok", false, None));
    assert_eq!(clean.error, None, "干净条目 error 必须是 None");
    assert!(!clean.enabled, "缺省停用要原样透出");
}

#[test]
fn status_dto_maps_failure_count_and_root() {
    let status = PluginHostStatus {
        enabled: false,
        root: PathBuf::from("/data/plugins"),
        active: false,
        error: Some("根目录建不出来".to_string()),
        loaded: vec!["a".to_string(), "b".to_string()],
        failed: 3,
    };
    let dto = status_dto(&status);
    assert!(dto.supported, "非 Android 一律 supported");
    assert!(!dto.enabled && !dto.active);
    assert_eq!(dto.root, "/data/plugins");
    assert_eq!(dto.error.as_deref(), Some("根目录建不出来"));
    assert_eq!(dto.loaded, vec!["a".to_string(), "b".to_string()]);
    assert_eq!(dto.failed, 3);
}

#[test]
fn failure_and_rejected_views_keep_order_and_detail() {
    let map = std::collections::BTreeMap::from([
        ("b".to_string(), "清单坏".to_string()),
        ("a".to_string(), "路径不安全".to_string()),
    ]);
    let failures = failures_dto(&map);
    assert_eq!(
        failures.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(),
        vec!["a", "b"],
        "BTreeMap 字典序直接透传, 导出层不重排"
    );

    let rejected = rejected_dto(&[("dup".to_string(), "跨目录同 id".to_string())]);
    assert_eq!(rejected[0].entry, "dup");
    assert_eq!(rejected[0].detail, "跨目录同 id");
}

#[test]
fn rescan_dto_maps_all_four_buckets() {
    let report = ncm_service::RegistryReport {
        scanned: vec!["a".to_string()],
        loaded: vec!["a".to_string()],
        skipped: vec!["b".to_string()],
        failed: vec![("c".to_string(), "装载失败".to_string())],
    };
    let dto = rescan_dto(&report);
    assert_eq!(dto.scanned, vec!["a".to_string()]);
    assert_eq!(dto.loaded, vec!["a".to_string()]);
    assert_eq!(dto.skipped, vec!["b".to_string()], "停用不是错误, 单独一桶");
    assert_eq!(dto.failed.len(), 1);
    assert_eq!(dto.failed[0].id, "c");
}

// ------------------------- 路由视图(取链/搜索的判定) -------------------------

/// 路由偏好视图: 标签可原样回传(`label` / `parse` 往返), id 只从 `plugin:<id>` 来.
#[test]
fn route_mode_dto_roundtrips_labels() {
    use ncm_service::RouteMode;
    for mode in [
        RouteMode::Auto,
        RouteMode::Builtin,
        RouteMode::Plugin { id: "demo".into() },
    ] {
        let dto = route_mode_dto(&mode);
        assert!(dto.supported, "非 Android 一律 supported");
        assert_eq!(dto.mode, mode.label());
        assert_eq!(
            dto.plugin_id,
            match &mode {
                RouteMode::Plugin { id } => Some(id.clone()),
                _ => None,
            }
        );
        // 回传等价: 桥接层把 `mode` 原样喂回 plugin_set_route_mode 不应变成别的模式
        assert_eq!(RouteMode::parse(&dto.mode), Some(mode));
    }
}

/// 判定视图: 目标/原因/插件 id 三个字段直接来自 `RoutePlan`, 不重新解释.
#[test]
fn route_plan_dto_mirrors_plan() {
    use ncm_service::{RoutePlan, RouteReason, RouteTarget};
    let plan = RoutePlan {
        target: RouteTarget::Plugin("demo".into()),
        reason: RouteReason::AutoSingle,
        detail: "只有插件 `demo` 支持 songUrl, 自动选用".to_string(),
    };
    let dto = route_plan_dto(&plan);
    assert!(dto.supported);
    assert_eq!(dto.target, "plugin:demo");
    assert_eq!(dto.plugin_id.as_deref(), Some("demo"));
    assert_eq!(dto.reason, "autoSingle");
    assert_eq!(dto.detail, plan.detail);

    let builtin = route_plan_dto(&RoutePlan {
        target: RouteTarget::Builtin,
        reason: RouteReason::Ambiguous,
        detail: "2 个启用插件支持 songUrl".to_string(),
    });
    assert_eq!(builtin.target, "builtin");
    assert_eq!(builtin.plugin_id, None, "内置目标没有插件 id");
    assert_eq!(builtin.reason, "ambiguous");
}

/// Android: 读类给"恒内置"的空视图(supported=false + 原因), 与"宿主没开"区分得开.
#[test]
fn android_route_view_is_builtin_and_explicit() {
    let mode = unsupported_route_mode();
    assert!(!mode.supported);
    assert_eq!(mode.mode, "auto", "缺省偏好就是 auto(行为同没插件)");
    assert_eq!(mode.plugin_id, None);

    let plan = unsupported_route_plan("songUrl");
    assert!(!plan.supported);
    assert_eq!(plan.target, "builtin");
    assert_eq!(plan.plugin_id, None);
    assert_eq!(plan.reason, "unsupported");
    assert!(plan.detail.starts_with("songUrl"), "detail 要点名能力");
}

// ------------------------- Android 空视图语义 -------------------------

/// Android 分支的返回值(与真实 Android 分支**共用**同一对构造函数):
/// 读 = 空视图 + `supported = false` + 非空 error; 写 = `Err(unsupported)`.
#[test]
fn android_view_is_empty_and_explicit() {
    let status = unsupported_status();
    assert!(
        !status.supported,
        "Android 必须自报不支持, 不能假装'只是没开'"
    );
    assert!(!status.enabled && !status.active);
    assert!(status.loaded.is_empty());
    assert_eq!(status.failed, 0);
    // 未启用时也要给 root; Android 没有 root 概念, 空串是唯一诚实的值
    assert!(status.root.is_empty());
    let detail = status.error.as_deref().unwrap_or_default();
    assert!(!detail.is_empty(), "空视图必须带原因, 否则 UI 只能瞎猜");
    // 语义要求: 与"总开关没开"区分得开 —— 那一条是 `forbidden`, 这一条是 `unsupported`
    // (见下面的写类断言). 文案措辞不断言, 只要求非空.
    assert!(!detail.is_empty());

    // 写类: 同词表(unsupported) + 不可重试 + detail 带操作名
    for op in [
        "plugin_enable",
        "plugin_disable",
        "plugin_rescan",
        "plugin_set_enabled",
    ] {
        let err = unsupported_error(op);
        assert_eq!(err.kind, ProviderErrorKind::Unsupported.as_str());
        assert!(!err.retryable, "重试变不出 bindings");
        assert!(err.detail.starts_with(op), "detail 要指明是哪个操作: {err}");
    }
}
