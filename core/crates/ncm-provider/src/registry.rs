//! provider 注册表: 按 id 索引 + 按能力挑选。

use crate::capability::Capability;
use crate::r#trait::Provider;
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Default, Clone)]
pub struct ProviderRegistry {
    providers: Vec<Arc<dyn Provider>>,
    by_id: HashMap<&'static str, usize>,
}

impl ProviderRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, provider: Arc<dyn Provider>) -> &mut Self {
        let id = provider.id();
        if self.by_id.contains_key(id) {
            return self;
        }
        self.by_id.insert(id, self.providers.len());
        self.providers.push(provider);
        self
    }

    pub fn get(&self, id: &str) -> Option<Arc<dyn Provider>> {
        self.by_id
            .get(id)
            .and_then(|i| self.providers.get(*i))
            .cloned()
    }

    pub fn all(&self) -> &[Arc<dyn Provider>] {
        &self.providers
    }

    /// 按注册顺序找第一个支持该能力的 provider
    pub fn first_with(&self, cap: Capability) -> Option<Arc<dyn Provider>> {
        self.providers.iter().find(|p| p.supports(cap)).cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::capability::AudioLevel;
    use crate::caps::{LyricProvider, ReadProvider};
    use crate::error::{ProviderError, ProviderResult};
    use crate::params::{BoxFuture, SearchQuery, SongUrlRequest};
    use ncm_domain::{Lyric, SearchPage, StreamUrl, TrackId};

    struct Dummy;

    impl Provider for Dummy {
        fn id(&self) -> &'static str {
            "dummy"
        }
        fn name(&self) -> &str {
            "Dummy"
        }
        fn capabilities(&self) -> &'static [Capability] {
            &[Capability::Search]
        }
    }

    // 只实现它真正提供的两组能力(搜索/取链 + 歌词), 其余 11 个能力域一行宏补齐默认 impl ——
    // 拆分前这里必须在一个 impl 块里把 god trait 的必填方法都写一遍。
    impl ReadProvider for Dummy {
        fn search<'a>(&'a self, _q: &'a SearchQuery) -> BoxFuture<'a, ProviderResult<SearchPage>> {
            Box::pin(async { Ok(SearchPage::default()) })
        }
        fn song_url<'a>(
            &'a self,
            _r: &'a SongUrlRequest,
        ) -> BoxFuture<'a, ProviderResult<StreamUrl>> {
            Box::pin(async { Err(ProviderError::unsupported("no songUrl")) })
        }
    }

    impl LyricProvider for Dummy {
        fn lyric<'a>(&'a self, _t: TrackId) -> BoxFuture<'a, ProviderResult<Lyric>> {
            Box::pin(async { Err(ProviderError::unsupported("no lyric")) })
        }
    }

    crate::impl_default_caps!(
        Dummy,
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

    #[test]
    fn registry_and_capabilities() {
        let mut reg = ProviderRegistry::new();
        reg.register(Arc::new(Dummy));
        assert!(reg.get("dummy").is_some());
        assert!(reg.first_with(Capability::Search).is_some());
        assert!(reg.first_with(Capability::Lyric).is_none());
        assert_eq!(AudioLevel::parse("hires"), Some(AudioLevel::Hires));
    }
}
