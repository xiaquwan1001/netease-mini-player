# D7 · frb 直接透传 ncm-domain 类型(删除重复 `*Dto`)

> 车道: **唯一 cargo/codegen 车道**(其余批次已收口)。范围: `core/crates/ncm-ffi/src/api.rs`、
> `core/crates/ncm-domain`(只读, 不改语义)、`ui/lib/src/rust/*`(只由 codegen 重写)、Dart 调用点。
> 本文件**增量写**: 每完成一步/一批就追加。

## 0. 结论速览(每次更新)

| 项 | 状态 |
|---|---|
| 策略 spike(方案 A mirror / 方案 B domain 注注解) | ✅ 方案 A 可行(见 §1) |
| Dart 类名是否零改动 | ❌ 不可能(**frb 2.13 不支持给 struct 改名**, 见 §1.3); 采用脚本化 `rust.XDto`→`rust.X` 重命名, 逐批用 `dart analyze` + `flutter test` 兜底 |
| 迁移批次 | 批1–批5 已收口(38/57, 见 §3) |

## 3. 批次日志(增量)

### 批1(2026-11-09)—— 11 个类型, 已提交

**迁移范围**(分类表 §2.2 的 #1/2/3/4/5/6/7/8/9/10/51):

`StyleTag` / `ProfileDetail` / `Playlist` / `PlaylistDetail` / `Artist` / `UserItem` /
`FollowCount` / `HotArtist` / `AlbumItem` / `SuggestItem` / `UserLevel`

做法(全部按 §1.2 三条件):

1. `api.rs` 顶部一次性 `pub use ncm_domain::{...}`(裸标识符 + pub use)。
2. 每个类型留一个 `#[frb(mirror(X))] pub struct _X { ... }`, 字段与 domain 完全一致。
3. 转换函数就地删除, 导出签名改为 domain 类型, 函数体统一走 `ffi_forward!`。
4. `ffi_forward!` 宏原本定义在首次使用点之后(macro_rules 按源码顺序解析), 已上移到
   `data_dir_default` 之前, 否则 `cannot find macro`。
5. `core/crates/ncm-ffi/Cargo.toml` 加 `[lints.rust] unexpected_cfgs`, 消掉 `frb_expand` 的 10 条警告。
6. Dart 侧机械重命名(脚本, 仅 `ui/lib` + `ui/test`, 排除生成目录):
   `s/rust\.(StyleTag|AlbumItem|Artist|FollowCount|HotArtist|Playlist|PlaylistDetail|ProfileDetail|SuggestItem|UserItem)Dto\b/rust.\1/g`
   —— 30 个文件命中。**必须带 `rust.` 前缀 + 单词边界**, 否则会误伤未迁移的 `SearchArtistDto`/`AlbumDetailDto` 等。

**门禁(编排者独立重跑)**

| 命令 | 结果 |
|---|---|
| `flutter_rust_bridge_codegen generate ...` | Done(rc=0) |
| `cargo build --offline --workspace --all-targets` | Finished, 0 warning |
| `cargo test -p ncm-domain -p ncm-service` | 22 + 97 = **119 passed** |
| `cd ui && dart analyze` | 39 issues, **全部 info**(0 error / 0 warning) |
| `cd ui && flutter test` | **309 passed + 1 skip** |

**坑**: 改完 `api.rs` 如果只跑 `cargo build` 而没重跑 codegen, 会看到
`Vec<ncm_domain::Playlist>: IntoIntoDart` 之类 106 个错误 —— 那是 `frb_generated.rs` 过期, 不是签名写错;
正确顺序永远是 **api.rs → codegen → cargo build → dart rename → analyze → test**。

### 批2(2026-11-09)—— 评论/签到 5 个类型, 已提交

`Comment` / `CommentPage` / `CommentStats` / `SigninDay` / `SigninStatus`

- 删掉 `comment_page_dto` 与 `signin_status_dto` 两个转换函数, 4 个评论导出(comments/hot_comments/
  event_comments/comment_replies)统一改 `ffi_forward!`, 签名直接 `Result<CommentPage, String>`。
- Dart 侧 7 个文件机械重命名(`comment_thread.dart` / `detail_page.dart` / 测试等)。
- 门禁同上, 全绿(cargo build 0 warning, analyze 39 info, flutter test 309+1skip)。

**坑(第二次踩)**: codegen 会先按**旧的 `frb_generated.rs`** 试编译, 因此删类型后第一次
`generate` 会刷一屏 `cannot find type XxxDto in module crate::api` —— 但它仍会把新生成物写好,
紧接着 `cargo build` 是通过的。判断标准是看 `ui/lib/src/rust/api.dart` 里是否已有新类名, 而不是看那屏报错。

### 批3(2026-11-09)—— 榜单/分类/百科 5 个类型, 已提交

`ChartSummary` / `ToplistCatalogItem` / `ToplistCatalogGroup` / `PlaylistCategory` / `WikiFact`

- 4 个导出(chart_list/toplist_catalog/playlist_categories/song_wiki)改 `ffi_forward!`, 转换函数全删。
- Dart 侧 9 个文件重命名。门禁全绿。

### 批4+批5(2026-11-09)—— 搜索/播客/电台 17 个类型, 已提交

批4(8 个): `SearchArtist` `SearchAlbum` `SearchPlaylistItem` `SearchPodcast` `AlbumBrief`
`HotSearchTerm` `HotSearchDetailItem` `DefaultSearch`

- `SearchBundleDto` 保留(字段含 `SongDto`), 但 `artists/albums/playlists/podcasts` 四组改成 domain 类型,
  `search_all` 里四段手写转换全删;
- `ArtistDetailDto.albums` 改 `Vec<AlbumBrief>`。

批5(9 个): `PodcastRadio` `RadioCategory` `RadioPick` `RadioExploreHome` `RadioRankedRadio`
`RadioRankedDj` `RadioSubscriber` `RadioSubscriberPage` + `SearchExact`

- 删 `radio_dto`; 7 个导出改 `ffi_forward!`;
- `PodcastRadio` 迁完后 `SearchExact` 变成纯镜像(字段全对得上), `SearchExactDto` 一并删除。

### 待办(批6 起)

按 §2.2 表里剩下的 46 个 (a) 类型分批迁移, 建议按模块成簇(每批 8–12 个), 每批一套完整门禁:

| 批 | 簇 | 类型 |
|---|---|---|
| ~~2~~ | ~~评论/签到~~ | ✅ 已做(批2) |
| ~~3~~ | ~~榜单/分类/百科~~ | ✅ 已做(批3) |
| 4 | 搜索(带 (c) 连带改动) | `SearchArtist` `SearchAlbum` `SearchPlaylistItem` `SearchPodcast` `AlbumBrief` `SearchExact` `HotSearchTerm` `HotSearchDetailItem` `DefaultSearch`(需同时把 `SearchBundleDto`/`ArtistDetailDto` 的字段改成 domain 类型) |
| 5 | 电台 | `PodcastRadio` `RadioCategory` `RadioPick` `RadioExploreHome` `RadioRankedRadio` `RadioRankedDj` `RadioSubscriber` `RadioSubscriberPage` |
| 6 | 数字专辑/VIP/私信 | `DigitalAlbumPurchasedEntry` `DigitalAlbumPurchased` `PurchasedSongEntry` `SongPurchasedPage` `DigitalAlbumDetail` `DigitalAlbumSalesEntry` `VipMembership` `VipGrowth` `VipSignDay` `VipSign` `VipTask` `VipOverview` `UserMedal` `PrivateSession` `PrivateMessage` `InboxItem` `ForwardItem` `RecentContact` |
| 7 | 流地址 | `StreamUrl`(`StreamDto` 是 (a+) 超集: domain 多 `size`, Dart 只是多拿一个字段) |

**注意**: `SearchArtist`/`SearchAlbum`/`SearchPlaylistItem`/`SearchPodcast`/`AlbumBrief` 虽然自身可迁,
但仍被 `SearchBundleDto`/`ArtistDetailDto`(含 `SongDto`)引用 —— 迁移后要把这些 (c) 类型的字段改成 domain 类型,
属于同一批的连带改动, 别单独提交。

## 1. 第 0 步: 策略 spike

### 1.1 环境与版本

- `flutter_rust_bridge_codegen 2.13.0`(与 `core/crates/ncm-ffi/Cargo.toml` 的 `flutter_rust_bridge = "=2.13.0"` 对齐)。
- codegen 命令(本车道独占, 与 §9 文档一致):
  ```bash
  cd /home/xuqianhui/netease-mini-player
  flutter_rust_bridge_codegen generate --rust-input crate::api --rust-root core/crates/ncm-ffi --dart-output ui/lib/src/rust
  ```

### 1.2 方案 A(mirror)实测可行 —— 三件必备条件

先用最小类型 `StyleTag`(domain `ncm_domain::StyleTag`, 字段完全一致)做 spike, 三轮失败后定位到三个必要条件:

| # | 条件 | 反证(踩过的坑) |
|---|---|---|
| A1 | `api.rs` 里必须有 `use flutter_rust_bridge::frb;` | 否则 `error: cannot find attribute \`frb\` in this scope` |
| A2 | 被镜像的 domain 类型必须以**裸标识符**出现在签名里, 且通过 **`pub use ncm_domain::X;`** 引入 | ①写 `ncm_domain::StyleTag` 全路径 → frb 认不出去重表, 直接降级成 **opaque 句柄**(生成 `abstract class StyleTag implements RustOpaqueInterface`); ②只写 `use`(私有导入) → `error[E0603]: struct import StyleTag is private`(生成的 `crate::frb_generated` 要访问 `crate::api::StyleTag`) |
| A3 | mirror dummy struct 字段必须与 domain 完全一致(名字+类型), 名称随意(用 `_X` 前缀) | 字段不一致会生成错的编解码代码(编译期就会炸) |

最终形态(spike 落地版, 已在首批里保留):

```rust
use flutter_rust_bridge::frb;
pub use ncm_domain::StyleTag;   // A2: 必须是 pub use

/// 曲风标签: 直接镜像 domain 类型. Dart 类名 = StyleTag(原 StyleTagDto).
#[frb(mirror(StyleTag))]
pub struct _StyleTag {
    pub id: String,
    pub name: String,
    pub cover_url: Option<String>,
    pub song_count: Option<u64>,
}

pub async fn style_preference() -> Result<Vec<StyleTag>, String> {
    ffi_forward!(Capability::StyleRecommend, provider.style_preference())  // 转换函数直接消失
}
```

验证命令与结果(spike, 单类型):
```
flutter_rust_bridge_codegen generate → rc=0 (无 error)
cd core && cargo build --offline --workspace --all-targets → 0 error
cd ui && dart analyze → 0 error / 0 warning (39 条历史 info)
ui/lib/src/rust/api.dart → class StyleTag { ... } (不再是 StyleTagDto)
```
附带产物: `#[frb]` 会触发 rustc `unexpected cfg condition name: frb_expand` 警告, 在
`core/crates/ncm-ffi/Cargo.toml` 加 `[lints.rust] unexpected_cfgs = { level = "allow", check-cfg = ['cfg(frb_expand)'] }` 消掉(不动 build 语义)。

### 1.3 ❌ Dart 类名无法保持不变(frb 2.13 硬限制)

结论来自**读 codegen 源码 + 实测**两路互证:

1. struct 的 Dart 类名 = `MirStruct.name` = 被镜像类型的 ident(`compute_name_and_wrapper_name`)。
   `#[frb(name = "...")]` 在 codegen 里**只作用于函数名与字段名**
   (`parser/mir/parser/function/real/mod.rs: parse_dart_name`、`parser/mir/parser/ty/structure.rs: MirField.name`),
   对 struct 类型名无效。
2. 试过用 `#[frb(dart_code = "typedef StyleTagDto = StyleTag;")]` 保留旧名: 注入点在建出来的**类体内部**
   (`generator/api_dart/spec_generator/class/misc.rs: generate_class_extra_body`), Dart 直接报
   `Typedefs can't be declared inside classes` → 整份 `api.dart` 连 `dart format` 都过不去, 文件不可解析, 已放弃。
3. 方案 B(给 `ncm-domain` 注 frb 注解 + 多 `--rust-input`)同样只是把类名变成 domain ident, 对"保名"零帮助,
   还要让 domain 依赖 flutter_rust_bridge(违反 §9.1 前置③"domain 仍是纯数据 crate"), 因此**不采用**。

**由此的策略**: 类名统一改为 domain 名(`SongDto`→... 见下), Dart 调用点用脚本做
`rust.XDto` → `rust.X` 的**机械重命名**(全部 rust 导入都带 `as rust;` 前缀, 不存在命名冲突;
`ui/lib/src/rust/*` 生成物不计入), 每批都过 `dart analyze`(0 error/warning) + 全量 `flutter test`。
**注意**: `SongDto` 保留(见 §2 分类), 所以 Dart 侧仍然是 `rust.SongDto`, 歌曲链不动。

## 2. 第 1 步: 73 个 Dto 分类

见下节(逐条比对 `api.rs` Dto 字段 与 `ncm-domain/src/lib.rs` 同名/近名 struct 的字段名+类型)。

### 2.1 分类口径

逐条比较 `api.rs` 的 Dto 字段(**名字+类型**)与 `ncm-domain/src/lib.rs` 对应 struct:

- **(a) 纯镜像**: 字段集完全一致(嵌套字段只是 `XDto` → `X` 的差异也算), 删 Dto → mirror。
- **(a+) 超集镜像**: Dto 是 domain 的子集(domain 多字段), Dart 只是多拿到一个字段, 不破坏调用点(本仓只有 `StreamDto`)。
- **(b) FFI 变形**: 有 Dto 独有字段(计算字段/汇总字段)或根本没有 domain 对应物 → **保留**。
- **(c) 被 (b) 卡住**: 字段里含 `SongDto` 等 (b) 类型 → 保留(mirror 要求字段类型与 domain 完全一致)。

### 2.2 分类结果(73 个 Dto)

**(a)/(a+) 可迁移: 57 个**

| # | Dto | → domain | 备注 |
|---|---|---|---|
| 1 | `StyleTagDto` | `StyleTag` | ✅ 首批已迁(spike) |
| 2 | `ProfileDetailDto` | `ProfileDetail` | 字段一致 |
| 3 | `PlaylistDto` | `Playlist` | 字段一致 |
| 4 | `PlaylistDetailDto` | `PlaylistDetail` | 字段一致 |
| 5 | `ArtistDto` | `Artist` | 字段一致 |
| 6 | `UserItemDto` | `UserItem` | 字段一致 |
| 7 | `FollowCountDto` | `FollowCount` | 字段一致 |
| 8 | `HotArtistDto` | `HotArtist` | 字段一致 |
| 9 | `AlbumItemDto` | `AlbumItem` | 字段一致 |
| 10 | `SuggestItemDto` | `SuggestItem` | 字段一致 |
| 11 | `CommentDto` | `Comment` | 字段一致 |
| 12 | `CommentPageDto` | `CommentPage` | 仅嵌套 `Vec<CommentDto>`→`Vec<Comment>` |
| 13 | `CommentStatsDto` | `CommentStats` | 字段一致 |
| 14 | `SigninDayDto` | `SigninDay` | 字段一致 |
| 15 | `SigninStatusDto` | `SigninStatus` | 仅嵌套 |
| 16 | `SearchArtistDto` | `SearchArtist` | 字段一致(仍被保留的 `SearchBundleDto` 引用) |
| 17 | `SearchAlbumDto` | `SearchAlbum` | 同上 |
| 18 | `SearchPlaylistDto` | `SearchPlaylistItem` | 同上(domain 叫 ...Item) |
| 19 | `SearchPodcastDto` | `SearchPodcast` | 同上 |
| 20 | `AlbumBriefDto` | `AlbumBrief` | 仍被保留的 `ArtistDetailDto` 引用 |
| 21 | `PodcastRadioDto` | `PodcastRadio` | 字段一致 |
| 22 | `RadioCategoryDto` | `RadioCategory` | 字段一致 |
| 23 | `RadioPickDto` | `RadioPick` | 仅嵌套 |
| 24 | `RadioExploreHomeDto` | `RadioExploreHome` | 仅嵌套 |
| 25 | `RadioRankedRadioDto` | `RadioRankedRadio` | 字段一致 |
| 26 | `RadioRankedDjDto` | `RadioRankedDj` | 字段一致 |
| 27 | `RadioSubscriberDto` | `RadioSubscriber` | 字段一致 |
| 28 | `RadioSubscriberPageDto` | `RadioSubscriberPage` | 仅嵌套 |
| 29 | `SearchExactDto` | `SearchExact` | 仅嵌套 |
| 30 | `HotSearchTermDto` | `HotSearchTerm` | 字段一致 |
| 31 | `HotSearchDetailItemDto` | `HotSearchDetailItem` | 字段一致 |
| 32 | `DefaultSearchDto` | `DefaultSearch` | 字段一致 |
| 33 | `ChartSummaryDto` | `ChartSummary` | 字段一致 |
| 34 | `ToplistCatalogItemDto` | `ToplistCatalogItem` | 字段一致 |
| 35 | `ToplistCatalogGroupDto` | `ToplistCatalogGroup` | 仅嵌套 |
| 36 | `PlaylistCategoryDto` | `PlaylistCategory` | 字段一致 |
| 37 | `WikiFactDto` | `WikiFact` | 字段一致 |
| 38 | `StreamDto` | `StreamUrl` | (a+) domain 多一个 `size`(Dart 多一个字段, 无破坏) |
| 39 | `DigitalAlbumEntryDto` | `DigitalAlbumPurchasedEntry` | 字段一致 |
| 40 | `DigitalAlbumPurchasedDto` | `DigitalAlbumPurchased` | 仅嵌套 |
| 41 | `PurchasedSongDto` | `PurchasedSongEntry` | 字段一致 |
| 42 | `SongPurchasedDto` | `SongPurchasedPage` | 仅嵌套 |
| 43 | `DigitalAlbumDetailDto` | `DigitalAlbumDetail` | 字段一致 |
| 44 | `DigitalAlbumSalesDto` | `DigitalAlbumSalesEntry` | 字段一致 |
| 45 | `VipMembershipDto` | `VipMembership` | 字段一致 |
| 46 | `VipGrowthDto` | `VipGrowth` | 字段一致 |
| 47 | `VipSignDayDto` | `VipSignDay` | 字段一致 |
| 48 | `VipSignDto` | `VipSign` | 仅嵌套 |
| 49 | `VipTaskDto` | `VipTask` | 字段一致 |
| 50 | `VipOverviewDto` | `VipOverview` | 仅嵌套 |
| 51 | `UserLevelDto` | `UserLevel` | 字段一致 |
| 52 | `UserMedalDto` | `UserMedal` | 字段一致 |
| 53 | `PrivateSessionDto` | `PrivateSession` | 字段一致 |
| 54 | `PrivateMessageDto` | `PrivateMessage` | 字段一致 |
| 55 | `InboxItemDto` | `InboxItem` | 字段一致 |
| 56 | `ForwardItemDto` | `ForwardItem` | 字段一致 |
| 57 | `RecentContactDto` | `RecentContact` | 字段一致 |

**(b) FFI 变形 / (c) 被卡住: 16 个(保留, 不为删而删)**

| Dto | 归属 | 原因 |
|---|---|---|
| `SongDto` | (b) | UI 投影: `artist`/`album` 拼成字符串、`artist_id`/`album_id`/`cover_url` 摊平、`vip`/`paid` 由 `fee` 算、`id`/`fee` 去 Option/newtype。domain `Song` 是 `Vec<Artist>`+`Option<Album>`+`TrackId` |
| `SearchBundleDto` | (c) | 字段含 `songs: Vec<SongDto>` |
| `ArtistDetailDto` | (c) | `songs: Vec<SongDto>` |
| `AlbumDetailDto` | (c) | `songs: Vec<SongDto>` |
| `PodcastProgramDto` | (c) | `song: Option<SongDto>` |
| `FeedEventDto` | (c) | `song: Option<SongDto>` |
| `PlayRankEntryDto` | (c) | `song: SongDto` |
| `RadioRankedProgramDto` | (c) | `program: PodcastProgramDto`(而 PodcastProgramDto 被 Song 卡住) |
| `RadioToplistDto` | (b) | 独有 `kind`(入参回显), 且缺 domain 的 `has_more` |
| `AccountDto` | (b) | 独有 `active`(账号簿当前项), domain `Profile` 没有 |
| `MessageCountsDto` | (b) | 独有 `total`(四项之和, 角标用) |
| `PlayerStateDto` | (b) | 播放器状态快照, 无 domain 对应物 |
| `LyricLineDto` | (b) | `parse_lrc_with_translation` 的解析产物, 无 domain struct |
| `WordItemDto` / `WordLyricLineDto` / `WordLyricDto` | (b) | YRC 解析产物(在 `ncm-domain::word_lyric` 里是内部类型), 无 domain DTO |
