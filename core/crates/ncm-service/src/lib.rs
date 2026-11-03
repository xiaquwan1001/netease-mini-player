//! 服务层: 会话/身份 + 内置 provider 实现.
//!
//! M0 只做两件事:
//! 1. 身份持久化(device_id 首启生成后永久复用, 设备 cookie 落盘)
//! 2. 把 vendor 的 ncm-api-rs 包成我们的 Provider

pub mod identity;
pub mod netease;

pub use identity::IdentityStore;
pub use netease::NeteaseProvider;

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

    pub fn capabilities(&self, provider_id: &str) -> Option<&'static [Capability]> {
        self.providers.get(provider_id).map(|p| p.capabilities())
    }
}
