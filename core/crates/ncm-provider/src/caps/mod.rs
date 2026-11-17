//! 能力 trait 集合: 原 131 方法的 god trait `Provider` 按**方法语义域**拆成的 13 个能力 trait。
//!
//! 组合面见 `crate::r#trait::Provider`: `pub trait Provider: ReadProvider + LyricProvider + ...`,
//! 因此 `dyn Provider` / `P: Provider` 上的调用点、签名与 FFI 导出全部不变, 收益在两侧:
//!
//! - **实现侧**: 只需 `impl` 自己需要的能力域(其余能力域补空默认 impl 即可, 方法默认返回 `Unsupported`);
//! - **消费侧**: 只用到某域的函数可把参数收窄成 `&dyn LyricProvider` 这类窄 trait object(接口隔离),
//!   例如 `ncm-service::ttml_source` 的歌词聚合只要求 `&dyn LyricProvider`。
//!
//! | 模块 | trait | 能力域 | 方法数 |
//! |---|---|---|---|
//! | `read` | `ReadProvider` | 读取核心: 搜索/取链/歌曲详情/热搜/搜索建议/百科/喜欢状态 | 12 |
//! | `lyric` | `LyricProvider` | 歌词(逐行 LRC / 逐字 YRC) | 2 |
//! | `recommend` | `RecommendProvider` | 推荐与发现: 日推/私人FM/新歌新碟/相似/曲风/榜单/历史推荐 | 26 |
//! | `playlist_read` | `PlaylistReadProvider` | 歌单/喜欢列表/听歌排行 只读 | 11 |
//! | `playlist_write` | `PlaylistWriteProvider` | 歌单/喜欢 写操作 | 9 |
//! | `comment` | `CommentProvider` | 评论与分享 | 8 |
//! | `account` | `AccountProvider` | 登录/账号资料/关注关系 | 12 |
//! | `artist_album` | `ArtistAlbumProvider` | 歌手/专辑/MV/收藏 | 11 |
//! | `radio` | `RadioProvider` | 播客/电台 | 9 |
//! | `community` | `CommunityProvider` | 动态/社区 | 6 |
//! | `vip` | `VipProvider` | 黑胶会员/云贝签到/数字专辑 | 9 |
//! | `cloud` | `CloudProvider` | 音乐云盘 | 4 |
//! | `message` | `MessageProvider` | 消息中心 | 8 |

mod account;
mod artist_album;
mod cloud;
mod comment;
mod community;
mod lyric;
mod message;
mod playlist_read;
mod playlist_write;
mod radio;
mod read;
mod recommend;
mod vip;

pub use account::AccountProvider;
pub use artist_album::ArtistAlbumProvider;
pub use cloud::CloudProvider;
pub use comment::CommentProvider;
pub use community::CommunityProvider;
pub use lyric::LyricProvider;
pub use message::MessageProvider;
pub use playlist_read::PlaylistReadProvider;
pub use playlist_write::PlaylistWriteProvider;
pub use radio::RadioProvider;
pub use read::ReadProvider;
pub use recommend::RecommendProvider;
pub use vip::VipProvider;

/// 给"只实现少数能力域"的实现者, 有成列地生成其余能力域的**默认(空)impl**。
///
/// 每个能力域 trait 的方法都带默认实现(默认返回 `ProviderError::unsupported`), 所以空 impl 就够:
///
/// ```ignore
/// impl Provider for Minimal { /* id / name / capabilities */ }
/// impl ReadProvider for Minimal { /* search / song_url: 唯一的必填项 */ }
/// impl LyricProvider for Minimal { /* lyric */ }
/// ncm_provider::impl_default_caps!(
///     Minimal,
///     RecommendProvider, PlaylistReadProvider, /* ...其余 11 个能力域 */
/// );
/// ```
///
/// 不带能力域列表的写法 = 补齐**全部 13 个**能力域(适合什么都不支持的占位实现)。
#[macro_export]
macro_rules! impl_default_caps {
    ($ty:ty $(,)?) => {
        $crate::impl_default_caps!(
            $ty,
            ReadProvider,
            LyricProvider,
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
    };
    ($ty:ty, $($cap:ident),+ $(,)?) => {
        $( impl $crate::$cap for $ty {} )+
    };
}
