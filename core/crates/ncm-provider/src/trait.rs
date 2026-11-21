//! `Provider` trait 本体: 能力 trait 的组合面(不再是 131 方法的 god trait)。
//!
//! 方法按语义域拆到 `crate::caps` 的 13 个能力 trait 里, 本文件只留
//! 身份 + 能力声明这 4 个核心方法, 再用超 trait 组合回来:
//!
//! ```text
//! pub trait Provider: ReadProvider + LyricProvider + ... {}
//! ```
//!
//! 所以 `dyn Provider` / `P: Provider` 上的调用点、方法签名、FFI 导出**全部不变**
//! (超 trait 的方法在 trait object 与泛型约束上都可直接调用);
//! 能力声明(`Capability`)仍是路由的唯一依据, 与 trait 形状无关 —— trait 拆分只是为了让
//! 实现侧与消费侧能只依赖自己需要的那一组方法。
//!
//! 入参类型(`SearchQuery`/`SongUrlRequest`/`RankingPeriod`/`BoxFuture`)在 `params` 模块。

use crate::capability::Capability;
use crate::caps::{
    AccountProvider, ArtistAlbumProvider, CloudProvider, CommentProvider, CommunityProvider,
    LyricProvider, MessageProvider, PlaylistReadProvider, PlaylistWriteProvider, RadioProvider,
    ReadProvider, RecommendProvider, VipProvider,
};

/// 音源 provider: 身份 + 能力声明 + 13 个能力域(`caps`)的超 trait 组合。
pub trait Provider:
    Send
    + Sync
    + ReadProvider
    + LyricProvider
    + RecommendProvider
    + PlaylistReadProvider
    + PlaylistWriteProvider
    + CommentProvider
    + AccountProvider
    + ArtistAlbumProvider
    + RadioProvider
    + CommunityProvider
    + VipProvider
    + CloudProvider
    + MessageProvider
{
    fn id(&self) -> &'static str;
    fn name(&self) -> &str;
    fn capabilities(&self) -> &'static [Capability];

    fn supports(&self, cap: Capability) -> bool {
        self.capabilities().contains(&cap)
    }

    /// 取走 provider 侧累计的诊断日志(插件脚本的 `lx.log` / `console.*`)。
    ///
    /// 缺省是空(内置 provider 不攒日志); 有日志通道的实现自己覆盖。
    /// **取走语义**: 同一批日志不会交付两次 —— 调用方是「按需拉取」而不是后台轮询。
    fn take_logs(&self) -> Vec<String> {
        Vec::new()
    }
}
