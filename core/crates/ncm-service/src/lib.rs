//! 服务层: 会话/身份 + 内置 provider 实现.
//!
//! M0 只做两件事:
//! 1. 身份持久化(device_id 首启生成后永久复用, 设备 cookie 落盘)
//! 2. 把 vendor 的 ncm-api-rs 包成我们的 Provider

pub mod cache;
pub mod cloud_chunk;
pub mod credential_channel;
#[cfg(target_os = "linux")]
pub mod credential_keyring;
pub mod credential_store;
pub mod fsutil;
pub mod history;

pub use credential_store::{CredentialStatus, CredentialStore};
pub mod identity;
pub mod loudness_store;
pub mod netease;
// 插件宿主: 四端同一份实现(2026-11-21 起 Android 走构建期 bindgen,
// 见 docs/audit/2026-11-21-plugin-android-crosscompile.md)。
pub mod plugins;
pub mod read_cache;
pub mod ttml_source;

pub use history::HistoryStore;
pub use identity::{AccountBook, IdentityStore, StoredAccount};
pub use loudness_store::LoudnessStore;
pub use netease::{thread_id_for, NeteaseProvider};
pub use plugins::host::{PluginHostPolicy, PluginHostStatus};
pub use plugins::{
    PluginHost, PluginHostHandle, PluginSummary, RegistryReport, RouteDecision, RouteMode,
    RoutePlan, RouteReason, RouteTarget, RouteUsed, Routed,
};
pub use ttml_source::{
    fetch_ttml, word_lyric_with_fallback, LyricSource, TtmlDoc, WordLyricWithSource,
};

use ncm_provider::{Capability, ProviderRegistry};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, RwLock, RwLockReadGuard, RwLockWriteGuard};

/// 取 Mutex 锁并**忽略中毒**: 持锁线程 panic 后 `unwrap()` 会把整个进程再带崩一次,
/// 而我们持的这几把锁底下都是"可重建的状态"(凭据后端句柄、状态枚举、pending 队列),
/// 数据即使在 panic 中途被改也只会退化成"这次读到的旧值", 不会 UB.
///
/// 只用于 `std::sync::Mutex`; `tokio::sync::Mutex` 没有中毒概念, 不要套进来.
pub(crate) fn lock_ignore_poison<'a, T>(m: &'a Mutex<T>) -> MutexGuard<'a, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// 组装好的应用核心(不含 UI/播放)
pub struct Core {
    /// 身份/账号簿存储. 存**共享句柄**而不是拥有值: 它的写路径(`save` → 钥匙串
    /// `set_password`, 无超时)是阻塞外部 IO, FFI 入口要能绕开 `Core` 锁去做
    /// (锁审计 #1, 见 [`Core::store_handle`]).
    pub store: Arc<IdentityStore>,
    pub session: ncm_domain::Session,
    pub providers: ProviderRegistry,
    pub netease: Arc<NeteaseProvider>,
    /// 插件宿主: 缺省不扫描, 详见 `plugins::host` 头注释.
    ///
    /// 存**共享句柄**而不是裸 `PluginHost`: 装载/扫描很慢(单插件 8s), 而 `Core` 只有唯一一把锁,
    /// 插件 FFI 入口要能跳过 `Core` 锁直接拿这一把(锁序纪律见 `plugins::PluginHostHandle`).
    plugin_host: PluginHostHandle,
    /// 路由判定**快照**槽位(隔离二期切片 A2): 与 `plugin_host` 里那份是**同一个 `Arc`**
    /// (由 `PluginHost::open` 造、此处取走).
    ///
    /// 判定只读它: 短锁 clone `Arc` 后立刻释放, 于是重扫/导入(持插件句柄写锁, 8s × N)期间
    /// 取链/搜索/歌词的判定照跑. 快照的发布点全在插件宿主写路径末尾
    /// (见 `plugins::route::RouteSnapshot` 的注释), 这里只读不写.
    route_snapshot: plugins::RouteSnapshotHandle,
}

impl Core {
    /// 插件宿主的**共享句柄**(FFI 层用它绕开 `Core` 锁执行装载/扫描等慢操作).
    ///
    /// 拿到之后**不要再回头调 `core()`**(锁序纪律见 [`PluginHostHandle`]).
    pub fn plugin_host_handle(&self) -> PluginHostHandle {
        self.plugin_host.clone()
    }

    /// 插件宿主读锁(忽略中毒: 底下是"可重建的内存视图").
    fn plugin_host_read(&self) -> RwLockReadGuard<'_, PluginHost> {
        self.plugin_host.read().unwrap_or_else(|e| e.into_inner())
    }

    /// 插件宿主写锁(装载/扫描/落盘; 同类写操作之间串行).
    fn plugin_host_write(&self) -> RwLockWriteGuard<'_, PluginHost> {
        self.plugin_host.write().unwrap_or_else(|e| e.into_inner())
    }

    /// 路由判定快照(**只取一次短锁**, `Arc::clone` 后立刻释放).
    ///
    /// 之后判定/取 provider 全在快照里做, **不再进插件句柄锁** —— 这就是切片 A2 的解耦点.
    fn route_snapshot(&self) -> Arc<plugins::RouteSnapshot> {
        self.route_snapshot
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }
}

impl Core {
    /// 打开数据目录, 加载或创建身份, 注册内置 provider.
    ///
    /// 凭据链: 选后端 → 旧明文迁移(best-effort, 失败保留明文并上报) → 加载会话.
    pub fn open(data_dir: &Path) -> std::io::Result<Self> {
        let store = Arc::new(IdentityStore::open(data_dir)?);
        let (creds, status) = credential_store::open_backend(data_dir);
        store.set_credential_backend(creds, status);
        let _ = store.migrate_legacy_cleartext();
        let session = store.load_or_create()?;
        let netease = Arc::new(NeteaseProvider::new(session.clone()));
        let mut providers = ProviderRegistry::new();
        providers.register(netease.clone());
        // 插件宿主:**不返回 Result** —— 插件侧的失败(坏清单/根目录建不出来)只降级成
        // "宿主不可用", 绝不影响 Core 启动(见 plugins/host.rs 头注释的缺省值一节).
        let host = PluginHost::open(data_dir);
        // 快照槽位在宿主构造时就发布了"宿主没开/首扫后"的那份, 这里只是取走同一个 `Arc`.
        let route_snapshot = host.snapshot_handle();
        let plugin_host = Arc::new(RwLock::new(host));
        Ok(Self {
            store,
            session,
            providers,
            netease,
            plugin_host,
            route_snapshot,
        })
    }

    /// 登录成功后调用: 持久化并热更新 provider
    pub fn apply_session(&mut self, session: ncm_domain::Session) -> std::io::Result<()> {
        self.store.save(&session)?;
        self.commit_session(session);
        Ok(())
    }

    /// store 的**共享句柄**(FFI 层用它绕开 `Core` 锁做阻塞外部 IO).
    ///
    /// 拿到之后**不要再回头调 `core()`**: 钥匙串 `set_password`(zbus 阻塞, 无超时)与
    /// `fsutil` 的 fsync 一律在锁外做, 见 [`persist_session`] 与 `ncm-ffi` 的账号入口.
    pub fn store_handle(&self) -> Arc<IdentityStore> {
        Arc::clone(&self.store)
    }

    /// 只改内存态 + 热更新 provider, **不碰磁盘**.
    ///
    /// 锁外的落盘成功后再调它: 失败时内存态就不前进(错返给 UI, 下次调用可重试).
    pub fn commit_session(&mut self, session: ncm_domain::Session) {
        self.netease.update_session(session.clone());
        self.session = session;
    }

    // ---------------- 多账号 ----------------

    pub fn accounts(&self) -> std::io::Result<AccountBook> {
        self.store.load_accounts()
    }

    /// 登录成功后记住这个账号(只存登录凭据, 指纹共享), 并设为当前账号
    pub fn remember_account(
        &mut self,
        profile: &ncm_domain::Profile,
    ) -> std::io::Result<AccountBook> {
        let (book, next) =
            identity::prepare_remember(&self.session, self.store.load_accounts()?, profile);
        self.store.save_accounts(&book)?;
        self.apply_session(next)?;
        Ok(book)
    }

    /// 直接切到已保存的账号(不用重新登录); 返回是否切换成功
    pub fn switch_account(&mut self, user_id: u64) -> std::io::Result<bool> {
        let Some((book, next)) =
            identity::prepare_switch(&self.session, self.store.load_accounts()?, user_id)
        else {
            return Ok(false);
        };
        self.apply_session(next)?;
        self.store.save_accounts(&book).map(|_| true)
    }

    /// 把外部拿到的登录凭据(网页/扫码登录)合并进会话并落盘: 设备指纹保留.
    pub fn apply_login_cookie(&mut self, incoming: &str) -> std::io::Result<()> {
        self.apply_session(identity::login_session(&self.session, incoming))
    }

    /// 从账号簿移除(不改变当前登录态, 只是忘掉这个账号的凭据)
    pub fn forget_account(&mut self, user_id: u64) -> std::io::Result<AccountBook> {
        let mut book = self.store.load_accounts()?;
        book.remove(user_id);
        // 凭据后端里的副本一并清掉(失败不阻塞, 下次迁移不会找回它)
        if let Some(creds) = self.store.credential_backend() {
            let _ = creds.remove(credential_store::CredentialKey::Account(user_id));
        }
        self.store.save_accounts(&book)?;
        Ok(book)
    }

    /// 退出登录: 清凭据(账号仍留在账号簿里, 下次可一键切回)
    pub fn logout(&mut self) -> std::io::Result<AccountBook> {
        self.apply_session(identity::logout_session(&self.session))?;
        let mut book = self.store.load_accounts()?;
        book.clear_active();
        self.store.save_accounts(&book)?;
        Ok(book)
    }

    pub fn capabilities(&self, provider_id: &str) -> Option<&'static [Capability]> {
        self.providers.get(provider_id).map(|p| p.capabilities())
    }

    /// 凭据后端状态(给 FFI/UI 上报: 是否安全后端 / 明文回退原因)
    pub fn credential_status(&self) -> CredentialStatus {
        self.store.credential_status()
    }

    /// 用户明确同意/撤销"0600 明文回退"(设置页入口). 同意后立即重建后端并
    /// 补跑一次迁移(把仍在明文里的凭据搬走); 撤销只写标记, 不删已有明文.
    ///
    /// 阻塞(后端探测 2s + 钥匙串写) ⇒ FFI 走 [`Core::store_handle`] 在锁外调
    /// [`IdentityStore::set_plaintext_consent`](identity::IdentityStore::set_plaintext_consent).
    pub fn set_plaintext_consent(&mut self, consent: bool) -> std::io::Result<()> {
        self.store.set_plaintext_consent(consent)
    }
}

/// 会话落盘的**两段式**序列: 短锁取 store 句柄 → 锁外 `save`(钥匙串 put 可能
/// 无界阻塞) → 短锁只提交内存态.
///
/// `ncm-ffi` 的登录入口(扫码/短信/cookie)都走它, 单测
/// `slow_credential_put_does_not_block_readers` 用同一条路径验证锁不被 IO 占住.
pub fn persist_session(core: &Mutex<Core>, session: ncm_domain::Session) -> std::io::Result<()> {
    let store = lock_ignore_poison(core).store_handle();
    store.save(&session)?;
    lock_ignore_poison(core).commit_session(session);
    Ok(())
}

/// 插件宿主的 Rust 侧 API(非 Android; FFI 出口在 `ncm-ffi` 的 `api/plugin.rs`).
///
/// 三条纪律(详见 `plugins/host.rs` 头注释):
/// 1. **缺省不扫描**: 总开关在 `<data_dir>/plugin_host.json` 的 `enabled`(缺省 false),
///    未打开时读类接口给空视图, 写类接口给 `Forbidden` —— 绝不因磁盘上有多一个目录就开始执行脚本;
/// 2. **按插件 id 路由**: `ScriptProvider::id()` 恒为 `"script"`, 所以插件 provider 不进
///    `self.providers`(`ncm_provider::ProviderRegistry`), 一律走 [`Core::plugin_provider`];
/// 3. **单一错误口径**: 可失败的插件操作都是 `ProviderResult<_>`, 不新增错误类型.
impl Core {
    /// 宿主状态(UI 用它解释"为什么列表是空的")
    pub fn plugin_status(&self) -> PluginHostStatus {
        self.plugin_host_read().status()
    }

    /// 插件列表(含坏条目的 `error` 原因)
    pub fn plugin_summaries(&self) -> Vec<PluginSummary> {
        self.plugin_host_read().summaries()
    }

    /// 失败原因(清单坏/路径不安全/装载失败)
    pub fn plugin_failures(&self) -> std::collections::BTreeMap<String, String> {
        self.plugin_host_read().failures()
    }

    /// 最近一次扫描被拒收的条目(跨目录同 id / 目录不可访问)
    pub fn plugin_rejected(&self) -> Vec<(String, String)> {
        self.plugin_host_read().rejected()
    }

    /// 各插件自报的平台代号(展示/诊断用, 不参与路由)
    pub fn plugin_sources(&self) -> std::collections::BTreeMap<String, Vec<String>> {
        self.plugin_host_read().sources()
    }

    /// 拉走所有插件累计的诊断日志(按插件 id 分组, 取走语义)
    pub fn plugin_take_logs(&self) -> Vec<(String, Vec<String>)> {
        self.plugin_host_read().take_logs()
    }

    /// 已装载 provider 的插件 id(字典序)
    pub fn plugin_ids(&self) -> Vec<String> {
        self.plugin_host_read().ids()
    }

    /// 按**插件 id** 取 provider(未启用/未装载/不存在都是 `None`)
    pub fn plugin_provider(&self, id: &str) -> Option<Arc<dyn ncm_provider::Provider>> {
        self.plugin_host_read().provider(id)
    }

    /// 启用插件并即时装载
    pub fn plugin_enable(&mut self, id: &str) -> ncm_provider::ProviderResult<()> {
        self.plugin_host_write().enable(id)
    }

    /// 停用插件并摘掉 provider
    pub fn plugin_disable(&mut self, id: &str) -> ncm_provider::ProviderResult<()> {
        self.plugin_host_write().disable(id)
    }

    /// 从脚本文本导入一个插件(写盘 + 立即重扫)
    #[allow(clippy::too_many_arguments)]
    pub fn plugin_install_script(
        &mut self,
        id: &str,
        name: &str,
        version: &str,
        entry: &str,
        source: &str,
        lx_events: &[String],
        request_domains: &[String],
    ) -> ncm_provider::ProviderResult<RegistryReport> {
        self.plugin_host_write().install_source(
            id,
            name,
            version,
            entry,
            source,
            lx_events,
            request_domains,
        )
    }

    /// 从**本机文件**导入一个插件(读文件 → 写盘 → 立即重扫)
    #[allow(clippy::too_many_arguments)]
    pub fn plugin_install_file(
        &mut self,
        id: &str,
        name: &str,
        version: &str,
        path: &std::path::Path,
        lx_events: &[String],
        request_domains: &[String],
    ) -> ncm_provider::ProviderResult<RegistryReport> {
        self.plugin_host_write()
            .install_file(id, name, version, path, lx_events, request_domains)
    }

    /// 从 **URL** 导入一个插件(只允许 https; 抓取失败是唯一可重试的一类错误)
    #[allow(clippy::too_many_arguments)]
    pub fn plugin_install_url(
        &mut self,
        id: &str,
        name: &str,
        version: &str,
        url: &str,
        lx_events: &[String],
        request_domains: &[String],
    ) -> ncm_provider::ProviderResult<RegistryReport> {
        self.plugin_host_write()
            .install_url(id, name, version, url, lx_events, request_domains)
    }

    /// 卸载一个插件(停用 → 删目录含 `data/` → 清状态 → 重扫; 路由选择回 `auto`)
    pub fn plugin_uninstall(&mut self, id: &str) -> ncm_provider::ProviderResult<RegistryReport> {
        self.plugin_host_write().uninstall(id)
    }

    /// 重扫插件根目录(全量重建, 没有热重载)
    pub fn plugin_rescan(&mut self) -> ncm_provider::ProviderResult<RegistryReport> {
        self.plugin_host_write().rescan()
    }

    /// 宿主总开关(持久化到 `plugin_host.json`)
    pub fn plugin_set_enabled(&mut self, enabled: bool) -> ncm_provider::ProviderResult<()> {
        self.plugin_host_write().set_enabled(enabled)
    }

    /// 改插件根目录(`None` = 回到缺省 `<data_dir>/plugins`)
    pub fn plugin_set_root(&mut self, root: Option<PathBuf>) -> ncm_provider::ProviderResult<()> {
        self.plugin_host_write().set_root(root)
    }

    /// 宿主策略(只读: 总开关与根目录).
    ///
    /// 返回**拥有值**(策略是小结构体): 句柄锁是局部的, 给不出借用的生命周期.
    pub fn plugin_policy(&self) -> PluginHostPolicy {
        self.plugin_host_read().policy().clone()
    }

    // ---------------- 路由(产品路径: 取链 / 搜索) ----------------

    /// 当前路由偏好(`auto` 单插件自动 / `builtin` 只用内置 / `plugin:<id>` 显式选).
    ///
    /// 返回**拥有值**(理由同 [`Core::plugin_policy`]: 句柄锁是局部的).
    pub fn plugin_route_mode(&self) -> RouteMode {
        self.plugin_host_read().route_mode().clone()
    }

    /// 改路由偏好并落盘(`plugin_route.json`). 失效的 id 不在这里报错, 见
    /// [`Core::plugin_route_plan`](Self::plugin_route_plan) 的 `selectionMissing`.
    pub fn plugin_set_route_mode(&mut self, mode: RouteMode) -> ncm_provider::ProviderResult<()> {
        self.plugin_host_write().set_route_mode(mode)
    }

    /// 本次调用该走谁(纯判定; 判定依据见 [`RouteReason`]).
    ///
    /// 读**快照**(切片 A2): 重扫/导入持插件句柄写锁期间照样立刻返回.
    pub fn plugin_route_plan(&self, cap: Capability) -> RoutePlan {
        self.route_snapshot().plan(cap)
    }

    /// 产品路径的**唯一路由入口**: 判定 + 取到两边 provider(`Arc`), 之后调用方不持锁.
    ///
    /// 插件命中失败(超时/脚本错/协议错)的回落由 [`plugins::route::call_routed`] 做,
    /// 判定原因(`RouteReason`)与回落(`RouteUsed`)都进日志 + [`plugins::last_route_event`].
    pub fn route_decision(&self, cap: Capability) -> RouteDecision {
        // 判定 + 插件 provider 全部来自**快照**(一次短锁 clone, 之后不再碰插件句柄锁).
        let snapshot = self.route_snapshot();
        let plan = snapshot.plan(cap);
        plugins::route::warn_plan(cap, &plan);
        let plugin = plan.plugin_id().and_then(|id| snapshot.provider(id));
        RouteDecision {
            capability: cap,
            plan,
            plugin,
            builtin: self.providers.first_with(cap),
        }
    }
}

#[cfg(test)]
mod lock_scope_tests {
    //! 锁审计 #1: 凭据落盘(钥匙串 `put`, **无超时**)与后端探测必须在 `Core` 锁外做.
    //!
    //! 现状根因: FFI 入口持全局 `Core` 锁调 `IdentityStore::save` → `CredentialStore::put`
    //! (secret-service/zbus 阻塞) → `fsutil` 的 fsync. 钥匙串被锁时这一条不返回 ⇒
    //! 全进程所有 FFI 入口(含 init/poll)一起挂. 这里用"put 睡 1s"的假后端把那种
    //! 无界阻塞缩短成可测的 1s, 断言只读路径的**锁等待**不被它带走.

    use super::*;
    use crate::credential_store::{
        CredentialError, CredentialKey, CredentialStatus, CredentialStore,
    };
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    /// 假钥匙串: `put` 阻塞 1s(置 `in_put` 供测试确认"IO 正在进行").
    struct SlowPutStore {
        in_put: Arc<AtomicBool>,
        puts: AtomicUsize,
    }

    impl CredentialStore for SlowPutStore {
        fn put(&self, _key: CredentialKey, _secret: &str) -> Result<(), CredentialError> {
            self.puts.fetch_add(1, Ordering::SeqCst);
            self.in_put.store(true, Ordering::SeqCst);
            std::thread::sleep(Duration::from_secs(1));
            Ok(())
        }
        fn get(&self, _key: CredentialKey) -> Result<Option<String>, CredentialError> {
            Ok(None)
        }
        fn remove(&self, _key: CredentialKey) -> Result<(), CredentialError> {
            Ok(())
        }
        fn available(&self) -> Result<(), CredentialError> {
            Ok(())
        }
    }

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("ncm-lock-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("临时目录");
        dir
    }

    /// 打开一个 `Core` 并把凭据后端换成"put 睡 1s"的假实现.
    fn open_core(tag: &str) -> (PathBuf, Arc<SlowPutStore>, Mutex<Core>) {
        let dir = temp_dir(tag);
        let core = Core::open(&dir).expect("Core 打开");
        let slow = Arc::new(SlowPutStore {
            in_put: Arc::new(AtomicBool::new(false)),
            puts: AtomicUsize::new(0),
        });
        core.store.set_credential_backend(
            Some(slow.clone()),
            CredentialStatus::Secure {
                backend: "slow-test",
                migrated: false,
            },
        );
        (dir, slow, Mutex::new(core))
    }

    /// 带 MUSIC_U 的会话: `IdentityStore::save` 会走 `creds.put(Session)`(即那条阻塞链).
    fn logged_in_session(core: &Mutex<Core>) -> ncm_domain::Session {
        let guard = lock_ignore_poison(core);
        crate::identity::login_session(&guard.session, "MUSIC_U=u; __csrf=1")
    }

    /// 线程 A 走生产的两段式落盘([`persist_session`]), 其间线程 B 反复走只读路径;
    /// B 每次**取锁**的等待必须远小于 A 的阻塞 IO(1s). 现状(持锁落盘)会等于 1s.
    #[test]
    fn slow_credential_put_does_not_block_readers() {
        let (_dir, slow, core) = open_core("slow-put");
        let session = logged_in_session(&core);
        let in_put = slow.in_put.clone();

        std::thread::scope(|scope| {
            let writer = scope.spawn(|| {
                let started = Instant::now();
                persist_session(&core, session).expect("会话落盘");
                started.elapsed()
            });

            // 先确认阻塞 IO 真的进来了(save 走了凭据后端), 再开始测读方等待
            let wait_until = Instant::now() + Duration::from_secs(5);
            while !in_put.load(Ordering::SeqCst) {
                assert!(
                    Instant::now() < wait_until,
                    "put 没被调用: 会话落盘没走凭据后端, 这个用例就失去意义"
                );
                std::thread::yield_now();
            }

            // 采样窗口必须**包含第一次取锁**: 持锁落盘时那一次就会被阻塞 IO 拖住,
            // 预热(skip 掉首次)会把回归掩盖掉(实测踩过).
            let mut worst = Duration::ZERO;
            let mut reads = 0usize;
            let sample_until = Instant::now() + Duration::from_millis(250);
            while Instant::now() < sample_until {
                let t = Instant::now();
                let guard = lock_ignore_poison(&core);
                worst = worst.max(t.elapsed());
                // 只读路径: 凭据状态 + 账号簿
                let _ = guard.credential_status();
                guard.accounts().expect("账号簿可读");
                drop(guard);
                reads += 1;
            }

            let blocking = writer.join().expect("写线程");
            assert!(
                blocking >= Duration::from_millis(900),
                "假后端没真阻塞住, 用例无效: {blocking:?}"
            );
            assert!(
                worst < Duration::from_millis(200),
                "锁外落盘期间读方的取锁最坏等待 {worst:?} ≥ 200ms: \
                 阻塞 IO 又回到 Core 锁内了"
            );
            assert!(reads > 10, "读方采样太少({reads} 次), 用例无效");
        });
    }

    /// [`Core::commit_session`] 只改内存态: 不碰磁盘/钥匙串.
    #[test]
    fn commit_session_does_not_touch_disk() {
        let (_dir, slow, core) = open_core("commit-only");
        let next = logged_in_session(&core);
        let before = lock_ignore_poison(&core).session.cookie.clone();
        assert_ne!(before, next.cookie);

        lock_ignore_poison(&core).commit_session(next.clone());

        assert_eq!(lock_ignore_poison(&core).session.cookie, next.cookie);
        assert_eq!(slow.puts.load(Ordering::SeqCst), 0, "commit 不该写凭据后端");
    }
}
