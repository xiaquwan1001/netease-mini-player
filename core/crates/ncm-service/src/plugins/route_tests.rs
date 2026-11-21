//! 路由层用例: 自动/显式/禁用/多插件不猜 + 插件失败回落内置 + `Core` 端到端.
//!
//! 全部离线: 插件脚本只回常量直链(不发请求), 内置 provider 用本文件的 `FakeBuiltin`
//! —— 回落分支**绝不**碰真网易云(否则用例会变成联网测试).

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use ncm_domain::{SearchPage, StreamUrl};
use ncm_provider::{
    BoxFuture, Capability, Provider, ProviderError, ProviderErrorKind, ProviderResult,
    ReadProvider, SearchQuery, SongUrlRequest,
};

use crate::plugins::host::{PluginHostPolicy, DEFAULT_ROOT_DIR};
use crate::plugins::route::{self, RouteMode, RoutePlan, RouteReason, RouteTarget, RouteUsed};

// ------------------------------ 假 provider ------------------------------

/// 内置 provider 的替身: 取链/搜索都给固定值(回落分支就落到这里).
struct FakeBuiltin;

impl Provider for FakeBuiltin {
    fn id(&self) -> &'static str {
        "fake-builtin"
    }
    fn name(&self) -> &str {
        "FakeBuiltin"
    }
    fn capabilities(&self) -> &'static [Capability] {
        &[Capability::SongUrl, Capability::Search, Capability::Lyric]
    }
}

impl FakeBuiltin {
    /// 内置替身的返回值(用例用它断言"回落真的落到了内置").
    fn song_url_now(&self) -> StreamUrl {
        StreamUrl {
            url: Some("https://builtin.test/a.mp3".to_string()),
            ..StreamUrl::default()
        }
    }
}

impl ReadProvider for FakeBuiltin {
    fn search<'a>(&'a self, _q: &'a SearchQuery) -> BoxFuture<'a, ProviderResult<SearchPage>> {
        Box::pin(async { Ok(SearchPage::default()) })
    }
    fn song_url<'a>(&'a self, _r: &'a SongUrlRequest) -> BoxFuture<'a, ProviderResult<StreamUrl>> {
        let url = self.song_url_now();
        Box::pin(async move { Ok(url) })
    }
}

/// 只会失败的"插件 provider"(模拟脚本抛错/超时被收口成 ProviderError).
struct FakeBroken;

impl Provider for FakeBroken {
    fn id(&self) -> &'static str {
        "script"
    }
    fn name(&self) -> &str {
        "FakeBroken"
    }
    fn capabilities(&self) -> &'static [Capability] {
        &[Capability::SongUrl, Capability::Search]
    }
}

impl ReadProvider for FakeBroken {
    fn search<'a>(&'a self, _q: &'a SearchQuery) -> BoxFuture<'a, ProviderResult<SearchPage>> {
        Box::pin(async { Err(ProviderError::network("脚本抛错")) })
    }
    fn song_url<'a>(&'a self, _r: &'a SongUrlRequest) -> BoxFuture<'a, ProviderResult<StreamUrl>> {
        Box::pin(async { Err(ProviderError::network("脚本抛错")) })
    }
}

impl ncm_provider::LyricProvider for FakeBuiltin {
    fn lyric<'a>(
        &'a self,
        _track: ncm_domain::TrackId,
    ) -> BoxFuture<'a, ProviderResult<ncm_domain::Lyric>> {
        Box::pin(async {
            Ok(ncm_domain::Lyric {
                lrc: Some("[00:00.00]builtin".to_string()),
                ..ncm_domain::Lyric::default()
            })
        })
    }
}

impl ncm_provider::LyricProvider for FakeBroken {
    fn lyric<'a>(
        &'a self,
        _track: ncm_domain::TrackId,
    ) -> BoxFuture<'a, ProviderResult<ncm_domain::Lyric>> {
        Box::pin(async { Err(ProviderError::unsupported("fake broken 不带歌词")) })
    }
}

ncm_provider::impl_default_caps!(
    FakeBuiltin,
    RecommendProvider,
    PlaylistReadProvider,
    PlaylistWriteProvider,
    CommentProvider,
    AccountProvider,
    ArtistAlbumProvider,
    RadioProvider,
    CommunityProvider,
    VipProvider,
    CloudProvider,
    MessageProvider
);
ncm_provider::impl_default_caps!(
    FakeBroken,
    RecommendProvider,
    PlaylistReadProvider,
    PlaylistWriteProvider,
    CommentProvider,
    AccountProvider,
    ArtistAlbumProvider,
    RadioProvider,
    CommunityProvider,
    VipProvider,
    CloudProvider,
    MessageProvider
);

fn loaded(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|s| s.to_string()).collect()
}

fn request() -> SongUrlRequest {
    SongUrlRequest::new(ncm_domain::TrackId::new(1))
}

/// 判定: 只有一个插件支持该能力 ⇒ 自动用(① 判定层).
#[test]
fn auto_uses_the_only_plugin() {
    let plan = route::plan(
        &RouteMode::Auto,
        true,
        &loaded(&["only"]),
        |_| true,
        Capability::SongUrl,
    );
    assert_eq!(plan.target, RouteTarget::Plugin("only".into()));
    assert_eq!(plan.reason, RouteReason::AutoSingle);
    assert_eq!(plan.plugin_id(), Some("only"));
}

/// ④ 多插件未选择 ⇒ 不猜(禁字典序/先到先用), 走内置并给可区分的原因.
#[test]
fn auto_with_several_plugins_does_not_guess() {
    let plan = route::plan(
        &RouteMode::Auto,
        true,
        &loaded(&["alpha", "beta"]),
        |_| true,
        Capability::SongUrl,
    );
    assert_eq!(plan.target, RouteTarget::Builtin);
    assert_eq!(plan.reason, RouteReason::Ambiguous);
    assert!(
        plan.detail.contains("`alpha`") && plan.detail.contains("`beta`"),
        "原因要列出候选: {}",
        plan.detail
    );
}

/// 多插件但只有一个支持该能力 ⇒ 仍算"唯一候选", 不因别人的存在而退化.
#[test]
fn auto_ignores_plugins_without_the_capability() {
    let plan = route::plan(
        &RouteMode::Auto,
        true,
        &loaded(&["alpha", "beta"]),
        |id| id == "beta",
        Capability::SongUrl,
    );
    assert_eq!(plan.target, RouteTarget::Plugin("beta".into()));
    assert_eq!(plan.reason, RouteReason::AutoSingle);
}

/// 显式选择命中(① 判定层).
#[test]
fn explicit_selection_hits() {
    let plan = route::plan(
        &RouteMode::Plugin { id: "beta".into() },
        true,
        &loaded(&["alpha", "beta"]),
        |_| true,
        Capability::SongUrl,
    );
    assert_eq!(plan.target, RouteTarget::Plugin("beta".into()));
    assert_eq!(plan.reason, RouteReason::Selected);
}

/// ③ 选中的插件被停用 ⇒ 当次回内置, 且**不自动改选**另一个插件.
#[test]
fn disabled_selection_falls_back_to_builtin() {
    let plan = route::plan(
        &RouteMode::Plugin { id: "beta".into() },
        true,
        &loaded(&["alpha"]),
        |_| true,
        Capability::SongUrl,
    );
    assert_eq!(plan.target, RouteTarget::Builtin);
    assert_eq!(plan.reason, RouteReason::SelectionMissing);
    assert!(
        plan.detail.contains("beta"),
        "原因要点名失效的 id: {}",
        plan.detail
    );
    assert_eq!(plan.plugin_id(), None);
}

/// 选中的插件活着但没声明这个能力 ⇒ 回内置, 不硬调(能力是唯一路由依据).
#[test]
fn capability_missing_falls_back_to_builtin() {
    let plan = route::plan(
        &RouteMode::Plugin { id: "beta".into() },
        true,
        &loaded(&["beta"]),
        |_| false,
        Capability::Search,
    );
    assert_eq!(plan.target, RouteTarget::Builtin);
    assert_eq!(plan.reason, RouteReason::CapabilityMissing);
}

/// 宿主没开 ⇒ 任何选择都不生效(不报错, 就是没插件可用).
#[test]
fn inactive_host_always_uses_builtin() {
    for mode in [
        RouteMode::Auto,
        RouteMode::Builtin,
        RouteMode::Plugin { id: "x".into() },
    ] {
        let plan = route::plan(&mode, false, &[], |_| true, Capability::SongUrl);
        assert_eq!(plan.target, RouteTarget::Builtin);
        assert_eq!(plan.reason, RouteReason::HostInactive);
    }
}

/// 显式"只用内置"(多插件都在时的表达方式).
#[test]
fn builtin_selection_is_honoured() {
    let plan = route::plan(
        &RouteMode::Builtin,
        true,
        &loaded(&["alpha"]),
        |_| true,
        Capability::SongUrl,
    );
    assert_eq!(plan.target, RouteTarget::Builtin);
    assert_eq!(plan.reason, RouteReason::BuiltinSelected);
}

/// 偏好的标签/解析往返 + 落盘读取(损坏文件回落 auto, 不 panic).
#[test]
fn mode_labels_roundtrip_and_persist() {
    for mode in [
        RouteMode::Auto,
        RouteMode::Builtin,
        RouteMode::Plugin { id: "demo".into() },
    ] {
        let label = mode.label();
        assert_eq!(
            RouteMode::parse(&label),
            Some(mode.clone()),
            "标签: {label}"
        );
    }
    assert_eq!(RouteMode::parse(""), Some(RouteMode::Auto));
    assert_eq!(RouteMode::parse("plugin:  "), None);

    let temp = TempDir::new("mode-persist");
    assert_eq!(
        RouteMode::load(temp.path()),
        RouteMode::Auto,
        "缺文件 = 缺省"
    );
    let mode = RouteMode::Plugin { id: "demo".into() };
    mode.save(temp.path()).expect("落盘");
    assert_eq!(RouteMode::load(temp.path()), mode);
    std::fs::write(temp.path().join(route::ROUTE_FILE), b"{not json").expect("写坏");
    assert_eq!(
        RouteMode::load(temp.path()),
        RouteMode::Auto,
        "坏文件回落缺省"
    );
}

// ------------------------------ 调用 + 回落 ------------------------------

fn decision(
    plan: RoutePlan,
    plugin: Option<Arc<dyn Provider>>,
    builtin: bool,
) -> route::RouteDecision {
    route::RouteDecision {
        capability: Capability::SongUrl,
        plan,
        plugin,
        builtin: builtin.then(|| Arc::new(FakeBuiltin) as Arc<dyn Provider>),
    }
}

/// ① 插件命中: 调用走插件, 内置一次都没被碰(它返回的值不一样, 可以断言).
#[test]
fn plugin_hit_is_used() {
    // FakeBroken 会失败, 所以这里用一个"成功"的插件替身: 复用 FakeBuiltin 但换 id 无意义,
    // 直接让插件本身就是 FakeBuiltin(值相同也足以断言 used; 差别在 RouteUsed).
    let plugin: Arc<dyn Provider> = Arc::new(FakeBuiltin);
    let plan = RoutePlan {
        target: RouteTarget::Plugin("demo".into()),
        reason: RouteReason::AutoSingle,
        detail: String::new(),
    };
    let req = request();
    let req = &req;
    let routed = futures::executor::block_on(route::call_routed(
        decision(plan, Some(plugin), true),
        |p| Box::pin(async move { p.song_url(req).await }),
    ))
    .expect("插件命中不该失败");
    assert_eq!(routed.used, RouteUsed::Plugin("demo".into()));
    assert!(!routed.fell_back());
}

/// ② 插件抛错 ⇒ 回落内置, 原因可区分(`Fallback{kind,detail}` + 诊断槽).
#[test]
fn plugin_error_falls_back_to_builtin() {
    let plugin: Arc<dyn Provider> = Arc::new(FakeBroken);
    let plan = RoutePlan {
        target: RouteTarget::Plugin("demo".into()),
        reason: RouteReason::AutoSingle,
        detail: String::new(),
    };
    let req = request();
    let req = &req;
    let routed = futures::executor::block_on(route::call_routed(
        decision(plan, Some(plugin), true),
        |p| Box::pin(async move { p.song_url(req).await }),
    ))
    .expect("插件失败要回落内置, 不是整次失败");
    assert!(routed.fell_back(), "回落要能看出来: {:?}", routed.used);
    match &routed.used {
        RouteUsed::Fallback {
            plugin,
            kind,
            detail,
        } => {
            assert_eq!(plugin, "demo");
            assert_eq!(kind, "network");
            assert!(detail.contains("脚本抛错"), "detail 要保留原文: {detail}");
        }
        other => panic!("期望 Fallback, 实际 {other:?}"),
    }
    // 落点是内置 provider 的返回值(FakeBuiltin 给带 url 的直链), 不是插件错误.
    assert_eq!(
        routed.value.url.as_deref(),
        Some("https://builtin.test/a.mp3"),
        "落点必须是内置 provider 的返回值"
    );
}

/// 歌词能力: 插件声明 Lyric ⇒ auto 命中; 插件失败 ⇒ 回落内置(歌词是"有则更好"的数据).
#[test]
fn lyric_capability_routes_to_plugin_and_falls_back_on_error() {
    let plan = route::plan(
        &RouteMode::Auto,
        true,
        &loaded(&["lyric-only"]),
        |_| true,
        Capability::Lyric,
    );
    assert_eq!(plan.target, RouteTarget::Plugin("lyric-only".into()));
    assert_eq!(plan.reason, RouteReason::AutoSingle);

    let plugin: Arc<dyn Provider> = Arc::new(FakeBroken);
    let track = ncm_domain::TrackId::new(5);
    let routed = futures::executor::block_on(route::call_routed(
        route::RouteDecision {
            capability: Capability::Lyric,
            plan: RoutePlan {
                target: RouteTarget::Plugin("demo".into()),
                reason: RouteReason::AutoSingle,
                detail: String::new(),
            },
            plugin: Some(plugin),
            builtin: Some(Arc::new(FakeBuiltin) as Arc<dyn Provider>),
        },
        |p| Box::pin(async move { p.lyric(track).await }),
    ))
    .expect("插件歌词失败要回落内置, 不是整次失败");
    assert!(routed.fell_back(), "回落要能看出来: {:?}", routed.used);
    assert_eq!(routed.value.lrc.as_deref(), Some("[00:00.00]builtin"));
}

/// 没有内置 provider 可回落 ⇒ 插件错误原样上抛(不假装成功).
#[test]
fn plugin_error_without_builtin_surfaces_original_error() {
    let plugin: Arc<dyn Provider> = Arc::new(FakeBroken);
    let plan = RoutePlan {
        target: RouteTarget::Plugin("demo".into()),
        reason: RouteReason::AutoSingle,
        detail: String::new(),
    };
    let req = request();
    let req = &req;
    let err = futures::executor::block_on(route::call_routed(
        decision(plan, Some(plugin), false),
        |p| Box::pin(async move { p.song_url(req).await }),
    ))
    .unwrap_err();
    assert_eq!(err.kind, ProviderErrorKind::Network);
    assert!(err.retryable, "插件的可重试性要保留");
}

/// 内置目标不反向回落: 内置自己的错误直接上抛(避免把真错误吞成空结果).
#[test]
fn builtin_error_is_not_swallowed() {
    let plan = RoutePlan {
        target: RouteTarget::Builtin,
        reason: RouteReason::HostInactive,
        detail: String::new(),
    };
    // 内置位置放一个只会失败的 provider.
    let decision = route::RouteDecision {
        capability: Capability::SongUrl,
        plan,
        plugin: None,
        builtin: Some(Arc::new(FakeBroken)),
    };
    let req = request();
    let req = &req;
    let err = futures::executor::block_on(route::call_routed(decision, |p| {
        Box::pin(async move { p.song_url(req).await })
    }))
    .unwrap_err();
    assert_eq!(err.kind, ProviderErrorKind::Network);
}

// ------------------------------ Core 端到端 ------------------------------

static SEQ: AtomicUsize = AtomicUsize::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = SEQ.fetch_add(1, Ordering::SeqCst);
        let mut path = std::env::temp_dir();
        path.push(format!("ncm-plugin-route-{tag}-{}-{n}", std::process::id()));
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

/// 最小插件: 只注册 `musicUrl`, 回常量直链(不发请求).
fn write_plugin(root: &Path, id: &str) {
    let dir = root.join(id);
    std::fs::create_dir_all(&dir).expect("建插件目录");
    std::fs::write(
        dir.join("manifest.json"),
        format!(
            r#"{{"id":"{id}","name":"{id} 插件","version":"1.0.0","entry":"index.js","permissions":{{"lxEvents":["musicUrl"]}}}}"#
        ),
    )
    .expect("写清单");
    std::fs::write(
        dir.join("index.js"),
        "lx.on('musicUrl', async () => 'https://cdn.test/a.mp3');",
    )
    .expect("写脚本");
}

fn enable_policy(data_dir: &Path) {
    let policy = PluginHostPolicy {
        enabled: true,
        ..PluginHostPolicy::default()
    };
    policy.save(data_dir).expect("写策略文件");
}

/// ① + ③ Core 层: 单插件自动命中; 停用后立刻回内置并给 `selectionMissing`.
#[test]
fn core_routes_to_single_plugin_then_back_after_disable() {
    let temp = TempDir::new("core-single");
    write_plugin(&temp.path().join(DEFAULT_ROOT_DIR), "demo");
    enable_policy(temp.path());

    let mut core = crate::Core::open(temp.path()).expect("Core 打开");
    core.plugin_enable("demo").expect("启用插件");

    // ① 命中: 只有一个启用插件 ⇒ auto 自动用.
    let decision = core.route_decision(Capability::SongUrl);
    assert_eq!(decision.plan.plugin_id(), Some("demo"));
    assert_eq!(decision.plan.reason, RouteReason::AutoSingle);
    let plugin = decision
        .plugin
        .clone()
        .expect("判定命中就要拿到插件 provider");
    assert_eq!(plugin.id(), "script", "插件 provider 的 id 恒为 script");
    let url = futures::executor::block_on(route::call_routed(decision, |p| {
        Box::pin(async move { p.song_url(&request()).await })
    }))
    .expect("插件取链");
    assert_eq!(url.used, RouteUsed::Plugin("demo".into()));
    assert_eq!(url.value.url.as_deref(), Some("https://cdn.test/a.mp3"));

    // 显式选择落盘.
    core.plugin_set_route_mode(RouteMode::Plugin { id: "demo".into() })
        .expect("写路由偏好");
    assert_eq!(
        core.plugin_route_mode(),
        RouteMode::Plugin { id: "demo".into() }
    );

    // ③ 停用 ⇒ 当次回内置(`selectionMissing`), 偏好本身不被偷偷改掉.
    core.plugin_disable("demo").expect("停用插件");
    let plan = core.plugin_route_plan(Capability::SongUrl);
    assert_eq!(plan.target, RouteTarget::Builtin);
    assert_eq!(plan.reason, RouteReason::SelectionMissing);
    let decision = core.route_decision(Capability::SongUrl);
    assert!(decision.plugin.is_none());
    assert!(
        decision.builtin.is_some(),
        "内置 provider 必须在场(回落目标)"
    );
    assert_eq!(
        core.plugin_route_mode(),
        RouteMode::Plugin { id: "demo".into() },
        "停用插件 ≠ 改用户选择"
    );
}

/// Core 重启后路由偏好仍在(落盘生效), 且缺省是 auto.
#[test]
fn core_route_preference_survives_reopen() {
    let temp = TempDir::new("core-persist");
    // 宿主总开关开着, 才能把"显式内置"的判定原因与"宿主没开"区分开.
    enable_policy(temp.path());
    {
        let mut core = crate::Core::open(temp.path()).expect("Core 打开");
        assert_eq!(core.plugin_route_mode(), RouteMode::Auto);
        core.plugin_set_route_mode(RouteMode::Builtin)
            .expect("写路由偏好");
    }
    let core = crate::Core::open(temp.path()).expect("Core 再打开");
    assert_eq!(core.plugin_route_mode(), RouteMode::Builtin);
    // 显式内置 ⇒ 判定恒为内置(即使有插件可用).
    let plan = core.plugin_route_plan(Capability::SongUrl);
    assert_eq!(plan.target, RouteTarget::Builtin);
    assert_eq!(plan.reason, RouteReason::BuiltinSelected);
}

/// 隔离二期切片 A 的判据: 插件宿主句柄与 `Core` 锁**解耦** —— 装载(持有句柄写锁)期间,
/// `Core` 锁本身仍能拿到, 也就是其它域的 FFI 不会被 `rescan`/`install_*` 挡住.
///
/// 反例(改造前): 插件操作走 `MUTEX<Core>`, 而装载在锁内跑(单插件预算 8s) ⇒ 该断言会红.
#[test]
fn plugin_handle_does_not_hold_the_core_lock_while_loading() {
    let temp = TempDir::new("core-plugin-lock");
    enable_policy(temp.path());
    let core = Arc::new(std::sync::Mutex::new(
        crate::Core::open(temp.path()).expect("Core 打开"),
    ));
    let handle = core
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .plugin_host_handle();
    // 每次拿到的都是同一个 `Arc`(FFI 层那份 `PLUGIN` 与 `CORE` 里那份必须同源).
    assert!(Arc::ptr_eq(
        &handle,
        &core
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .plugin_host_handle()
    ));

    // ① 直接操作句柄不需要 `Core` 锁(空目录 ⇒ 没有已装载插件).
    {
        let host = handle.read().unwrap_or_else(|e| e.into_inner());
        assert!(host.ids().is_empty(), "空白插件目录不应装载出 provider");
    }

    // ② 另一个线程持**写锁**模拟「正在 rescan/装载 QuickJS」(真实装载预算 8s),
    //    主线程此时必须还能拿到 `Core` 锁去做别的域的事.
    let loader = {
        let handle = handle.clone();
        std::thread::spawn(move || {
            let _write = handle.write().unwrap_or_else(|e| e.into_inner());
            std::thread::sleep(std::time::Duration::from_millis(300));
        })
    };
    std::thread::sleep(std::time::Duration::from_millis(50));

    let started = std::time::Instant::now();
    {
        let guard = core.lock().unwrap_or_else(|e| e.into_inner());
        // 代表「其它域 FFI」: 只读会话字段, 完全不碰插件.
        assert!(!guard.session.device_id.is_empty());
    }
    let elapsed = started.elapsed();

    loader.join().expect("装载线程不应 panic");
    assert!(
        elapsed < std::time::Duration::from_millis(200),
        "插件装载期间其它域不应排队等 Core 锁, 实际等了 {elapsed:?}"
    );
}

/// ④ Core 层: 两个插件都启用而用户没选 ⇒ 走内置(不误用任何一个).
#[test]
fn core_two_plugins_without_selection_stay_on_builtin() {
    let temp = TempDir::new("core-two");
    let root = temp.path().join(DEFAULT_ROOT_DIR);
    write_plugin(&root, "alpha");
    write_plugin(&root, "beta");
    enable_policy(temp.path());

    let mut core = crate::Core::open(temp.path()).expect("Core 打开");
    core.plugin_enable("alpha").expect("启用 alpha");
    core.plugin_enable("beta").expect("启用 beta");
    assert_eq!(
        core.plugin_ids(),
        vec!["alpha".to_string(), "beta".to_string()]
    );

    let plan = core.plugin_route_plan(Capability::SongUrl);
    assert_eq!(plan.target, RouteTarget::Builtin);
    assert_eq!(plan.reason, RouteReason::Ambiguous);
    let decision = core.route_decision(Capability::SongUrl);
    assert!(decision.plugin.is_none(), "多插件未选择时不许挑一个用");

    // 显式选了谁就用谁(选择是唯一的出路).
    core.plugin_set_route_mode(RouteMode::Plugin { id: "beta".into() })
        .expect("写路由偏好");
    let plan = core.plugin_route_plan(Capability::SongUrl);
    assert_eq!(plan.target, RouteTarget::Plugin("beta".into()));
    assert_eq!(plan.reason, RouteReason::Selected);
}
