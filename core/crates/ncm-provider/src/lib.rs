//! 音源插件边界: Provider trait + 能力声明 + 注册表.
//!
//! 首版不实现脚本宿主, 但边界从第一天就固定:
//! - 出入参全是可序列化 DTO (见 ncm-domain)
//! - 错误统一成 ProviderError, UI 只按 kind 决策
//! - 未来加 QuickJS 时, 只需新增一个 ScriptProvider 实现本 trait
//!
//! ## 文件分工
//!
//! | 模块 | 内容 |
//! |---|---|
//! | capability | `Capability`(路由依据) + `AudioLevel`(音质档位) |
//! | error | `ProviderError{kind,retryable,detail}` / `ProviderErrorKind` / `ProviderResult` |
//! | params | `BoxFuture` + 入参类型(`SearchQuery`/`SongUrlRequest`/`RankingPeriod`) |
//! | `trait` | `Provider` trait 本体: 身份 4 方法 + 13 个能力 trait 的超 trait 组合 |
//! | caps | 13 个能力 trait(`ReadProvider`/`LyricProvider`/…)—— 按方法语义域拆开 |
//! | registry | `ProviderRegistry`(按 id 索引 + 按能力挑选) |
//!
//! 对外路径保持不变: 下面全部 `pub use`, 调用方继续写 `ncm_provider::ProviderError` 等.

mod capability;
mod caps;
mod error;
mod params;
mod registry;
mod r#trait;

pub use capability::{AudioLevel, Capability};
pub use caps::{
    AccountProvider, ArtistAlbumProvider, CloudProvider, CommentProvider, CommunityProvider,
    LyricProvider, MessageProvider, PlaylistReadProvider, PlaylistWriteProvider, RadioProvider,
    ReadProvider, RecommendProvider, VipProvider,
};
pub use error::{ProviderError, ProviderErrorKind, ProviderResult};
pub use params::{BoxFuture, RankingPeriod, SearchQuery, SongUrlRequest};
pub use r#trait::Provider;
pub use registry::ProviderRegistry;
