//! 服务层: 会话/身份 + 内置 provider 实现.
//!
//! M0 只做两件事:
//! 1. 身份持久化(device_id 首启生成后永久复用, 设备 cookie 落盘)
//! 2. 把 vendor 的 ncm-api-rs 包成我们的 Provider

pub mod cache;
pub mod credential_store;
pub mod history;
pub mod identity;
pub mod loudness_store;
pub mod netease;
pub mod ttml_source;

pub use history::HistoryStore;
pub use identity::{AccountBook, IdentityStore, StoredAccount};
pub use loudness_store::LoudnessStore;
pub use netease::{thread_id_for, NeteaseProvider};
pub use ttml_source::{fetch_ttml, word_lyric_with_fallback, LyricSource, TtmlDoc, WordLyricWithSource};

use ncm_provider::{Capability, ProviderRegistry};
use std::path::Path;
use std::sync::Arc;

pub const PROVIDER_NETEASE: &str = "netease";

/// 组装好的应用核心(不含 UI/播放)
pub struct Core {
    pub store: IdentityStore,
    pub session: ncm_domain::Session,
    pub providers: ProviderRegistry,
    pub netease: Arc<NeteaseProvider>,
}

impl Core {
    /// 打开数据目录, 加载或创建身份, 注册内置 provider.
    pub fn open(data_dir: &Path) -> std::io::Result<Self> {
        let store = IdentityStore::open(data_dir)?;
        let session = store.load_or_create()?;
        let netease = Arc::new(NeteaseProvider::new(session.clone()));
        let mut providers = ProviderRegistry::new();
        providers.register(netease.clone());
        Ok(Self { store, session, providers, netease })
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
    pub fn remember_account(&mut self, profile: &ncm_domain::Profile) -> std::io::Result<AccountBook> {
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
        let cookie = identity::merge_device_cookie(&device_only, &account.cookie, &self.session.device_id);
        let mut next = self.session.clone();
        next.cookie = cookie;
        next.profile = Some(ncm_domain::Profile {
            user_id,
            nickname: account.nickname,
            avatar_url: account.avatar_url,
            vip: account.vip,
        });
        self.apply_session(next)?;
        self.store.save_accounts(&book)
            .map(|_| true)
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
}
