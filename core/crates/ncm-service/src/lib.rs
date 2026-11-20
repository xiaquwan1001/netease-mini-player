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
// 插件宿主接缝只在**非 Android** 目标编译: rquickjs-sys 0.12.2 没有 Android 的预生成
// bindings(cross 编译直接失败), 详见 Cargo.toml 里 [target.`cfg(not(target_os = "android"))`] 段。
#[cfg(not(target_os = "android"))]
pub mod plugins;
pub mod read_cache;
pub mod ttml_source;

pub use history::HistoryStore;
pub use identity::{AccountBook, IdentityStore, StoredAccount};
pub use loudness_store::LoudnessStore;
pub use netease::{thread_id_for, NeteaseProvider};
#[cfg(not(target_os = "android"))]
pub use plugins::host::{PluginHostPolicy, PluginHostStatus};
#[cfg(not(target_os = "android"))]
pub use plugins::{PluginHost, PluginSummary, RegistryReport};
pub use ttml_source::{
    fetch_ttml, word_lyric_with_fallback, LyricSource, TtmlDoc, WordLyricWithSource,
};

use ncm_provider::{Capability, ProviderRegistry};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

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
    pub store: IdentityStore,
    pub session: ncm_domain::Session,
    pub providers: ProviderRegistry,
    pub netease: Arc<NeteaseProvider>,
    /// 插件宿主(仅非 Android 目标): 缺省不扫描, 详见 `plugins::host` 头注释.
    #[cfg(not(target_os = "android"))]
    plugin_host: PluginHost,
}

impl Core {
    /// 打开数据目录, 加载或创建身份, 注册内置 provider.
    ///
    /// 凭据链: 选后端 → 旧明文迁移(best-effort, 失败保留明文并上报) → 加载会话.
    pub fn open(data_dir: &Path) -> std::io::Result<Self> {
        let store = IdentityStore::open(data_dir)?;
        let (creds, status) = credential_store::open_backend(data_dir);
        store.set_credential_backend(creds, status);
        let _ = store.migrate_legacy_cleartext();
        let session = store.load_or_create()?;
        let netease = Arc::new(NeteaseProvider::new(session.clone()));
        let mut providers = ProviderRegistry::new();
        providers.register(netease.clone());
        // 插件宿主:**不返回 Result** —— 插件侧的失败(坏清单/根目录建不出来)只降级成
        // "宿主不可用", 绝不影响 Core 启动(见 plugins/host.rs 头注释的缺省值一节).
        #[cfg(not(target_os = "android"))]
        let plugin_host = PluginHost::open(data_dir);
        Ok(Self {
            store,
            session,
            providers,
            netease,
            #[cfg(not(target_os = "android"))]
            plugin_host,
        })
    }

    /// 登录成功后调用: 持久化并热更新 provider
    pub fn apply_session(&mut self, session: ncm_domain::Session) -> std::io::Result<()> {
        self.store.save(&session)?;
        self.netease.update_session(session.clone());
        self.session = session;
        Ok(())
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
        let mut book = self.store.load_accounts()?;
        book.upsert(StoredAccount {
            user_id: profile.user_id,
            nickname: profile.nickname.clone(),
            avatar_url: profile.avatar_url.clone(),
            vip: profile.vip,
            cookie: identity::extract_login_cookie(&self.session.cookie),
        });
        self.store.save_accounts(&book)?;
        let mut next = self.session.clone();
        next.profile = Some(profile.clone());
        self.apply_session(next)?;
        Ok(book)
    }

    /// 直接切到已保存的账号(不用重新登录); 返回是否切换成功
    pub fn switch_account(&mut self, user_id: u64) -> std::io::Result<bool> {
        let mut book = self.store.load_accounts()?;
        let Some(account) = book.switch(user_id) else {
            return Ok(false);
        };
        // 设备指纹取自当前会话(与账号无关), 登录凭据换成目标账号的
        let device_only = identity::clear_login_cookie(&self.session.cookie);
        let cookie =
            identity::merge_device_cookie(&device_only, &account.cookie, &self.session.device_id);
        let mut next = self.session.clone();
        next.cookie = cookie;
        next.profile = Some(ncm_domain::Profile {
            user_id,
            nickname: account.nickname,
            avatar_url: account.avatar_url,
            vip: account.vip,
        });
        self.apply_session(next)?;
        self.store.save_accounts(&book).map(|_| true)
    }

    /// 把外部拿到的登录凭据(网页/扫码登录)合并进会话并落盘: 设备指纹保留.
    pub fn apply_login_cookie(&mut self, incoming: &str) -> std::io::Result<()> {
        let merged =
            identity::merge_device_cookie(&self.session.cookie, incoming, &self.session.device_id);
        let mut next = self.session.clone();
        next.cookie = merged;
        self.apply_session(next)
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
        let mut next = self.session.clone();
        next.cookie = identity::clear_login_cookie(&next.cookie);
        next.profile = None;
        self.apply_session(next)?;
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
    pub fn set_plaintext_consent(&mut self, consent: bool) -> std::io::Result<()> {
        let dir = self.store_dir();
        let mut policy = credential_store::CredentialPolicy::load(&dir);
        policy.plaintext_consent = consent;
        policy.save(&dir)?;
        let (creds, status) = credential_store::open_backend(&dir);
        self.store.set_credential_backend(creds, status);
        let _ = self.store.migrate_legacy_cleartext();
        Ok(())
    }

    fn store_dir(&self) -> PathBuf {
        // IdentityStore 没暴露 dir; 借 path() 的 parent 足够(同一数据目录)
        self.store
            .path()
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default()
    }
}

/// 插件宿主的 Rust 侧 API(非 Android; FFI 出口在 `ncm-ffi` 的 `api/plugin.rs`).
///
/// 三条纪律(详见 `plugins/host.rs` 头注释):
/// 1. **缺省不扫描**: 总开关在 `<data_dir>/plugin_host.json` 的 `enabled`(缺省 false),
///    未打开时读类接口给空视图, 写类接口给 `Forbidden` —— 绝不因磁盘上有多一个目录就开始执行脚本;
/// 2. **按插件 id 路由**: `ScriptProvider::id()` 恒为 `"script"`, 所以插件 provider 不进
///    `self.providers`(`ncm_provider::ProviderRegistry`), 一律走 [`Core::plugin_provider`];
/// 3. **单一错误口径**: 可失败的插件操作都是 `ProviderResult<_>`, 不新增错误类型.
#[cfg(not(target_os = "android"))]
impl Core {
    /// 宿主状态(UI 用它解释"为什么列表是空的")
    pub fn plugin_status(&self) -> PluginHostStatus {
        self.plugin_host.status()
    }

    /// 插件列表(含坏条目的 `error` 原因)
    pub fn plugin_summaries(&self) -> Vec<PluginSummary> {
        self.plugin_host.summaries()
    }

    /// 失败原因(清单坏/路径不安全/装载失败)
    pub fn plugin_failures(&self) -> std::collections::BTreeMap<String, String> {
        self.plugin_host.failures()
    }

    /// 最近一次扫描被拒收的条目(跨目录同 id / 目录不可访问)
    pub fn plugin_rejected(&self) -> Vec<(String, String)> {
        self.plugin_host.rejected()
    }

    /// 已装载 provider 的插件 id(字典序)
    pub fn plugin_ids(&self) -> Vec<String> {
        self.plugin_host.ids()
    }

    /// 按**插件 id** 取 provider(未启用/未装载/不存在都是 `None`)
    pub fn plugin_provider(&self, id: &str) -> Option<Arc<dyn ncm_provider::Provider>> {
        self.plugin_host.provider(id)
    }

    /// 启用插件并即时装载
    pub fn plugin_enable(&mut self, id: &str) -> ncm_provider::ProviderResult<()> {
        self.plugin_host.enable(id)
    }

    /// 停用插件并摘掉 provider
    pub fn plugin_disable(&mut self, id: &str) -> ncm_provider::ProviderResult<()> {
        self.plugin_host.disable(id)
    }

    /// 重扫插件根目录(全量重建, 没有热重载)
    pub fn plugin_rescan(&mut self) -> ncm_provider::ProviderResult<RegistryReport> {
        self.plugin_host.rescan()
    }

    /// 宿主总开关(持久化到 `plugin_host.json`)
    pub fn plugin_set_enabled(&mut self, enabled: bool) -> ncm_provider::ProviderResult<()> {
        self.plugin_host.set_enabled(enabled)
    }

    /// 改插件根目录(`None` = 回到缺省 `<data_dir>/plugins`)
    pub fn plugin_set_root(&mut self, root: Option<PathBuf>) -> ncm_provider::ProviderResult<()> {
        self.plugin_host.set_root(root)
    }

    /// 宿主策略(只读: 总开关与根目录)
    pub fn plugin_policy(&self) -> &PluginHostPolicy {
        self.plugin_host.policy()
    }
}
