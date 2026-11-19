# 前端 (Flutter, ui/) 架构可维护性审计 — 2026-11-15

> 只读审计，不改代码。基线：`ui/lib` 105 个 dart 文件 / 59,387 行；`ui/test` 140 个测试文件 / 27,506 行。
> 方法：`rg`/`wc -l`/`git log` 静态分析 + 少量文件定点精读，未跑全量 test。

## 状态：已完成（6/6 节）

> 完成顺序：§1 拆壳可行性 → §2 大文件 → §3 状态管理 → §4 规则层 → §5 测试基建 → §6 排序与前 5 建议

## 目录
- [1. main.dart 拆壳可行性](#1-maindart-3877-行拆壳可行性)
- [2. src/ 大文件与职责重叠](#2-src-大文件与职责重叠)
- [3. 状态管理现状](#3-状态管理现状)
- [4. UI 规则层覆盖度](#4-ui-规则层覆盖度)
- [5. 测试基建](#5-测试基建)
- [6. 收益/风险/工作量排序 + 前 5 建议](#6-排序与前-5-建议)

## 1. main.dart (3877 行) 拆壳可行性

### 1.1 现在这 3877 行承担的角色

按"块"切片（行号为当前 HEAD 738fc27）：

| # | 行区间 | 行数 | 承担的角色 | 依赖 |
|---|---|---|---|---|
| A | 74–330 | ~257 | **逐字歌词三来源解析 + 打分择优**：`LyricSourceLoaders` / `ResolvedLyric` / `yrcWordGoodEnough` / `scoreWordLyric` / `resolveLyricSource`；纯函数 + rust DTO，零 Widget 依赖 | rust/api |
| B | 331–361 | ~31 | `main()` 入口 + 通知栏模式纯函数（`nextNotificationMode` / `notificationModeIcon`） | rust 初始化 |
| C | 362–440 | ~79 | **全局投递槽位**：`_actionsHost` / `_pageDepth` + `_PageDepthObserver` / `playerBarSlot` / `playerBarData` / `playerBarActions` / `_publishBottomBar`（帧后投递约定） | Flutter |
| D | 441–537 | ~97 | **底部条宿主**：`PlayerBarHost` / `_PlayerBarChrome`——Navigator 之外的 Overlay，键盘让位、安全区夹取逻辑 | 上表 C |
| E | 539–583 | ~45 | **应用外壳**：`MiniNcmApp`（主题/字号/OLED/MediaQuery 注入） | app_settings、theme |
| F | 584–625 | ~42 | **返回键策略**：`HomeBackAction` / `resolveHomeBackAction` / `HomeBackGuard` | Flutter |
| G | 626–3877 | **~3252** | `HomePage` + `_HomePageState`（下面再切） | 全仓 src/** |

`_HomePageState` 内部再切（行号为近似边界）：

| # | 行区间 | 行数 | 角色 | 说明 |
|---|---|---|---|---|
| G1 | 634–785 | ~152 | 字段/控制器声明 | `_playback`/`_auth`/`_queue`/`_player` + 歌词/搜索/库 三套状态散放在一起 |
| G2 | 786–962 | ~177 | 生命周期接线（initState/dispose） | 13 条全局静态钩子在这里注册，见 1.3 风险 2 |
| G3 | 964–1136 | ~173 | 启动编排 + 设置同步 + 播放轮询 | `_bootstrap`/`_onAudioSettingsChanged`/`_persistPlayback`/`_pollPlayer`/`_onTrackEnded` |
| G4 | 1137–1401 | ~265 | **搜索状态机** | `_search`/`_loadSearchLanding`/`_loadExact`/`_onQueryChanged`(防抖)/`_openExact*`/`_searchKeyword` |
| G5 | 1402–1799 | ~398 | **播放协调** | `_playSongsList`/`_heartMode`/`_playSong`/`_resolveAndPlay`/预取/通知封面缓存 |
| G6 | 1800–2078 | ~279 | **歌词状态机** | `_loadLyric`/`_loadRawLyric`/`_syncLyricIndex`/`_scrollLyricTo`/跟随暂停/多选/翻译切换/分享歌词 |
| G7 | 2079–2229 | ~151 | 登录与账号 | `_login`/`_switchAccount`/`_syncAccount`/`_logout`/`_loadLiked` |
| G8 | 2230–2637 | ~408 | **歌曲动作宿主装配** | `_buildActionsHost` + 喜欢/加入歌单/分享/评论/下载/不感兴趣/艺人/专辑跳转 |
| G9 | 2638–2795 | ~158 | 库浏览态 | `_openPlaylist`/`_openLikedDetail`/`_closeLibrary` |
| G10 | 2796–3102 | ~307 | **播放队列面板** | 打开/拖动重排/清空/存为歌单/追加到歌单/停止续播/模式轮转/`_toastTop` |
| G11 | 3103–3175 | ~73 | 封面取色 + 动作状态同步 + seek | `_syncCoverPalette`/`_syncActionState`/`_seekTo` |
| G12 | 3176–3877 | ~702 | **页面装配**（唯一该留在 HomePage 的部分） | `build`/`_buildPage`/`_buildTopBar`/`_buildTabPages`/`_buildSearchBar`/`_buildList`/`_buildLyrics`/`_publishPlayerBar`/`_buildBottomBar` |

结论：**G4+G5+G6+G8+G10 ≈ 1657 行是可整体外移的业务协调层**，G12 的 702 行才是真正的"页面"。拆完 HomePage 只剩 ~900–1100 行（字段 + 装配 + 少量胶水），可维护性回到可控区间。

### 1.2 拆分目标文件与依赖顺序

顺序原则：**先纯逻辑（零 Flutter 状态）→ 再全局槽位/外壳 → 最后逐个 controller 迁移**。每一步都可独立编译 + 全量测试通过后再进下一步。

| 步 | 目标文件 | 搬什么 | 行数变化 | 前置 |
|---|---|---|---|---|
| **S0** | `src/lyric_source.dart` | A（解析 + 打分）+ B 两个通知栏纯函数分到 `src/notification_mode.dart` + F 到 `src/back_policy.dart` | main 3877→~3480 | 无（纯函数，测试已覆盖 `resolveLyricSource`/`scoreWordLyric`/`nextNotificationMode`/`resolveHomeBackAction`） |
| **S1** | `src/app_shell.dart` | C + D + E（槽位、PlayerBarHost、MiniNcmApp）| →~3300 | S0 |
| **S2** | `src/home/lyric_controller.dart` | G6 + G1 里的歌词字段（`_lyricLines`/`_lyricTimes`/`_lyricIndex`/`_wordLines`/`_selectedLyricLines`/`_wordPositionMs`/`_playing`/`_lyricTicker`/`_autoFollowLyric`） | →~3000 | S1；先抽"数据 + 索引计算"，UI 部分（`_buildLyrics`）留到最后一步 |
| **S3** | `src/home/search_controller.dart` | G4 + 搜索字段（`_bundle`/`_suggestions`/`_exact`/`_searchHistory`/`_hotTerms`/`_searchToken`/`_suggestDebounce`） | →~2700 | S2（同款 ChangeNotifier 范式先跑通一遍） |
| **S4** | `src/home/playback_coordinator.dart` | G5 + G3 的轮询/续播/现场恢复（`_pollPlayer`/`_onTrackEnded`/`_restorePlayback`/`_persistPlayback`/预取） | →~2200 | S3；**最重一步**，见 1.3 风险 1/3 |
| **S5** | `src/home/song_action_wiring.dart` | G8（`_buildActionsHost` 与所有动作闭包） | →~1800 | S4 |
| **S6** | `src/home/queue_sheet_controller.dart` | G10 + `_queueSheetOpen` | →~1500 | S5 |
| **S7** | `src/home/account_actions.dart` | G7 + G9 | →~1300 | S6 |
| **S8** | 收尾：`main.dart` 只剩 `main()` + `HomePage`（G1 剩余字段 + G2 + G3 剩余 + G11 + G12），并把 `src/home/home_page.dart` 放主体、`main.dart` 保留为 `export` 门面 | | →~700–1100 | S0–S7 全绿 |

**为什么 "`main.dart` 保留为 export 门面"**：9 个测试文件直接 `import 'package:minincm/main.dart'`（`bottom_chrome_padding` / `lyric_source_fallback` / `lyric_source_preference` / `notification_actions` / `player_bar_host` / `player_bar_narrow` / `top_bar_no_duplicate` / `ui_batch_a_back_nav` / `widget`），用到 `HomePage`/`PlayerBarHost`/`playerBarSlot`/`playerBarData`/`playerBarActions`/`resolveLyricSource`/`scoreWordLyric`/`nextNotificationMode`/`notificationModeIcon`/`resolveHomeBackAction`/`HomeBackAction` 共 11 个公开符号。拆文件时把这些 `export` 出去，测试零改动；否则一次性 9 个测试文件全红。

### 1.3 风险点（按严重度）

1. **状态所有权交叉**（高）：`_playSong` 一次调用同时改 `_queue`/`_player`/`_libraryTitle`/`_queuePlaylistId`/`_coverPaletteUrl`/`_showLyrics`；`_toggleLyrics` 同时改 `_showLyrics`/`_autoFollowLyric`/`_lyricScroll`。`setState` 有 79 处。抽 controller 时必须先定"谁持有真相"，否则会出现两处状态不同步（这类 bug 在本仓历史上就出现过：`src/now_playing.dart` 的头注释记录的"正在播放高亮漏接一处就不亮"）。
   缓解：S2–S7 每步只搬一个 controller，且 controller 用 `ChangeNotifier` + 页面 `AnimatedBuilder`/`ListenableBuilder` 订阅，**不**把 `setState` 语义打散——迁移前后跑 `flutter test`（只跑相关子集，见 §5）。
2. **initState 里的 13 条全局静态钩子**（高）：`Playback.setSkipHandlers` / `Playback.setActionHandlers` / `UserNav.onPlaySongs` / `ArtistNav.onPlaySongs` / `ArtistNav.onOpenAlbum` / `UpdateCheckHost.pendingPrompt.addListener` / `_pageDepth.addListener` / `_actionsHost.value` / `playerBarActions.value` …全是**进程级单例写入**。测试里 `pumpHomePage` 会建多个 HomePage 实例，后建的覆盖先建的；拆壳时若把注册挪到新文件却漏了 dispose 成对移除，测试之间会串味（本仓已有 `UserNav.clearCache()` 这类为测试擦屁股的接口）。
   缓解：S1 抽槽位时同时把这批注册收进一个 `HomeWiring.attach()/detach()` 成对函数。
3. **帧后投递契约**（中高）：`_publishBottomBar` 必须在 `addPostFrameCallback` 里写 `playerBarSlot`，否则 `setState() called during build`（注释里写明踩过）。S1 搬家时容易顺手写成同步赋值。
4. **歌词打分与 Rust 是"同口径镜像"**（中）：`kYrcWordCoverageThreshold`/`kScoreWeights` 注释明写"与 Rust `ncm_service::ttml_source` 同一口径"。S0 搬家时**不要顺手改权重或阈值**，否则两侧择优行为分叉。
5. **build 结构是踩坑史**（中）：`Offstage` 保 tab 树、`CoverBackdrop` 叠层、suggest 面板 `Positioned.fill` + 不透明底色、`topBar == null` 时手动吃 `MediaQuery.paddingOf(context).top`——每条都对应一个已修 bug。S8 整理 `_buildPage` 时保持结构不动，只做"函数搬家"。
6. **`_publishPlayerBar` 在 build 期间调用**（低）：它写的是 `playerBarData`（帧后），但同帧还调 `_publishBottomBar`。两步顺序在 S1 里要保留。
7. **悬空私有引用**（低）：大量 `_` 私有方法被闭包捕获（`PlayerBarActions(onSeekStart: (v) => setState(...))` 等）。用 `flutter analyze`（本机走 `dart analyze`，见 `tools/ci.sh`）兜底，别靠肉眼。

### 1.4 拆壳该守的验收线

- 每步提交后：`cd ui && dart analyze` 0 error + `cargo build -p ncm_ffi` 不变 + 相关测试子集绿（`flutter test test/player_bar_host_test.dart test/ui_batch_a_back_nav_test.dart ...`）。
- 拆壳期间 `tools/check-tokens.sh --strict` 必须始终 OK（当前基线 0 越界，见 §4）。
- 最终 `main.dart` ≤ 400 行（只留 `main()` + export 门面 + `HomePage` 主体或 `export 'src/home/home_page.dart'`）。

## 2. src/ 大文件与职责重叠

### 2.1 top-15（`find ui/lib -name '*.dart' | xargs wc -l`）

`ui/lib` 共 **105 个 dart 文件 / 59,387 行**，其中 **23,425 行（39%）是 flutter_rust_bridge codegen**（`src/rust/frb_generated*.dart` 4 个 + `api.dart`），手写代码实际 **约 35,962 行**。

| # | 文件 | 行数 | 性质 |
|---|---|---|---|
| 1 | `src/rust/frb_generated.dart` | 12,358 | **生成**，勿手改 |
| 2 | `src/rust/api.dart` | 4,668 | **生成**（DTO/FFI 声明） |
| 3 | `main.dart` | 3,877 | 手写，见 §1 |
| 4 | `src/rust/frb_generated.web.dart` | 2,133 | **生成** |
| 5 | `src/rust/frb_generated.io.dart` | 2,133 | **生成** |
| 6 | `src/comment_thread.dart` | 1,662 | 手写 |
| 7 | `src/detail_page.dart` | 1,558 | 手写 |
| 8 | `src/mine_view.dart` | 1,216 | 手写 |
| 9 | `src/feed_view.dart` | 1,176 | 手写 |
| 10 | `src/artist_page.dart` | 1,073 | 手写 |
| 11 | `src/feed_share.dart` | 937 | 手写 |
| 12 | `src/settings_view.dart` | 887 | 手写 |
| 13 | `src/messages_page.dart` | 886 | 手写 |
| 14 | `src/discover.dart` | 882 | 手写 |
| 15 | `src/user_page.dart` | 875 | 手写 |

紧随其后（手写第 16–22）：`word_lyric_view.dart` 852、`recommend_view.dart` 809、`eq_curve_chart.dart` 768、`cover_art.dart` 698、`vip_page.dart` 692、`app_settings.dart` 676、`login_sheet.dart` 636、`medal_wall.dart` 632。

> 只看手写代码的 top-10 合计 **14,163 行（占手写 39%）**，其中 4 个文件（`main.dart` / `comment_thread` / `detail_page` / `messages_page`）就是"一个文件里塞了 3–5 个页面级 widget"的模式。

### 2.2 ≥300 行且职责混杂的拆分建议

判定标准：一个文件里出现**两个以上互不依赖的页面/面板级 StatefulWidget**，或**数据映射层与 Widget 同文件**。

| 文件 | 行数 | 现状（同文件里的东西） | 拆分建议 | 优先级 |
|---|---|---|---|---|
| `detail_page.dart` | 1558 | `_PlaylistDetailPage`(714) + `_PodcastDetailPage`(301) + `_SongRow`(162) + `_ProgramRow`(93) + `_showResourceShareSheet` + `_SkeletonList` + `showCommentsSheet`/`showPlaylistDetail`/`showPodcastDetail` 三个入口 | `detail/playlist_detail_page.dart` / `detail/podcast_detail_page.dart` / `detail/comments_sheet.dart`；`_SongRow`→复用 `song_tile.dart`（见 2.3） | **P0** |
| `messages_page.dart` | 886 | `MessagesPage`(89) + `_SessionsTab`(108) + `_ContactsStrip` + `_ChatBody`(228) + `_InboxTab`(108) + `_ForwardsTab`(78) + `relativeTime` + 7 个 loader typedef | `messages/sessions_tab.dart` / `messages/chat_body.dart` / `messages/inbox_tab.dart` / `messages/forwards_tab.dart`；`relativeTime` 与 `format.dart` 合并 | **P0** |
| `discover.dart` | 882 | `DailyRecommendPage` + `RecentPlayedPage` **两个独立页面** + 各自的 3 个 tab + `_SongRow` + 6 个 loader typedef | `discover/daily_recommend_page.dart` / `discover/recent_played_page.dart`；`_SongRow`→`song_tile.dart` | **P0** |
| `comment_thread.dart` | 1662 | `CommentThreadState`(775，分页/排序/点赞/回复挂载) + `_CommentTileState`(362) + `_RepliesSheet`(171) + `_ComposerBar` + `_ComposeSheet` + 6 个 typedef | `comment/comment_thread.dart`（状态机）+ `comment/comment_tile.dart` + `comment/replies_sheet.dart` + `comment/composer.dart` | **P1** |
| `feed_view.dart` | 1176 | `_FeedViewState`(390) + `_Author`(51, 数据类) + `_ArtistFilterBar`/`_AuthorChip`(152) + `_FeedCard`(285) + `_AllArtistsSheet` + `_LoadOlderFooter` | `feed/feed_card.dart` + `feed/artist_filter_bar.dart` + `feed/all_artists_sheet.dart` | **P1** |
| `artist_page.dart` | 1073 | `_ArtistDetailPageState`(376) + `_DynamicsTab`(101) + `_AllSongsTab`(190) + `_AlbumsTab`(94) + `_MvsTab`(64) + `_ArtistSongRow`(88) + 7 个注入 loader 参数 | `artist/artist_tabs.dart`（4 个 tab 一个文件即可）+ `_ArtistSongRow`→`song_tile.dart` | P1 |
| `feed_share.dart` | 937 | 3 个分享卡（`FeedShareCard` 222 / `CommentShareCard` 130）+ 3 个 sheet（`FeedShareSheet`/`FeedForwardSheet`/`CommentShareSheet`）+ 3 个 `show*` 入口 + 纯函数 | `feed/share_cards.dart` + `feed/share_sheets.dart` | P2 |
| `settings_view.dart` | 887 | 设置首页 + 5 个独立 tile（字号/日推缓存/凭据存储/检查更新/主题色）+ 2 个 sheet + 4 个主题纯函数 | 纯函数进 `settings_view_helpers.dart` 或 `theme.dart`；tile 各拆一文件（与已存在的 `settings_account_page`/`settings_audio_page` 对齐） | P2 |
| `mine_view.dart` | 1216 | `_MineViewState`(325, 依赖注入 9 个 loader) + 9 个 section（Liked/Playlists/Podcasts/Albums/AlbumPodcast/Ranking/Recent）+ `MessageEntryCard` + `SigninCard` + 编辑简介弹窗 | 已经是"一个文件一组 section"，建议整体移到 `mine/` 目录按 section 分文件；**状态机不用动**（AsyncView 已收口 11 处） | P3 |
| `vip_page.dart` | 692 | **DTO 映射层**（`VipProfileView`/`VipTaskView`/`mapVipOverview`/`loadVipPageData`）+ 页面 + 12 个小组件 | 映射层拆到 `vip/vip_mapping.dart`（有测试 `vip_mapping_test.dart` 已单独覆盖，纯搬运） | P2 |
| `medal_wall.dart` | 632 | 同款：`mapMedalWall` + `loadMedalWallData` + `LevelBadge` + 页面 + 网格 | `medal/medal_mapping.dart` + `medal/medal_wall_page.dart` | P2 |
| `cover_art.dart` | 698 | 纯函数（`neteaseSizedUrl`/`imageCandidates`/`coverRequestPx`）+ 自定义 `ImageProvider<_UaNetworkImage>` + `_FallbackImage` 状态机 + `NetImage`/`CircleCover`/`CoverArt` + 全屏查看器 | `image/url_rewrite.dart`（纯函数，好测）+ `image/ua_image_provider.dart` + `image/viewer.dart` | P2 |
| `login_sheet.dart` | 636 | `LoginSheetState`(497) 一个类里塞二维码轮询 + 手机号/验证码两条链路 + 平台分支 | 拆 `login/qr_flow.dart` + `login/phone_flow.dart`，主 sheet 只做选择与状态转发 | P2 |
| `word_lyric_view.dart` | 852 | 纯逻辑（`wordStylesAt`/`karaokeClipRects`/`_mergeAdjacent`）+ `KaraokeLine`(168) + `KaraokePainter`(132) + `_StaticWordLine` | 纯函数拆 `lyric/karaoke_geometry.dart`（已被 `karaoke_clip_rects_test` 覆盖）；Widget 部分保持一文件即可 | P3 |

**判定为"虽然大但职责单一、不建议拆"**：`recommend_view.dart`（809，12 个 section widget，无状态机，AsyncView 收口 7 处）、`eq_curve_chart.dart`（768，DSP 纯函数 + 2 个 painter，数学与绘制本来就是一体）、`app_settings.dart`（676，单一 ChangeNotifier，4 个 enum 属配置词表）、`playback.dart`/`queue.dart`/`playback_state.dart`（267/188/176，纯逻辑，单测齐全）。**这些拆了只会增加 import 噪音。**

### 2.3 职责重叠（真实重复实现）

这些不是"文件太大"，而是"同一件事有 N 份实现"：

1. **歌曲行 5 份**：`detail_page._SongRow`(162) / `discover._SongRow`(61) / `artist_page._ArtistSongRow`(88) / `user_page._LikedRow`(67) / `detail_page._ProgramRow`(93)。四份都自己算"正在播放高亮 + 序号列 + VIP 徽标 + 时长/歌手副标题"，差异只在要不要 like 按钮。而 `song_tile.dart`（300 行，已有 `SongTile`/`SongTitleWithBadges`/`SongFeeBadges`/`VipBadge`/`PaidBadge`/`UnplayableBadge` 六个件）本来就是为此存在。
   → **收口成一个 `SongRow`（在 song_tile.dart 里，参数控制 like/序号/菜单）**，预期删 ~450 行重复，且"正在播放高亮"这类全局口径只需改一处。
2. **底部面板 20 处 `showModalBottomSheet`**，其中 19 处用了 `SheetHeader`/`_ShareSheetFrame` 但**并不统一**（3 份 frame：`sheet_header.dart`、`feed_share.dart` 的 `_ShareSheetFrame`、各页面内联）。建议统一成 `showAppSheet(...)` 一个入口。
3. **`relativeTime`** 在 `messages_page.dart` 里私人实现（另有 `format.dart` 的时间函数），消息页外来一处就再写一份。
4. **骨架屏**：`detail_page._SkeletonList`（46 行）与 `search_loading.dart`（25 行）各一份，`state_views.dart` 里的 `LoadingView` 是第三份。
5. **DTO 映射散落在 UI 层**：`vip_page.mapVipOverview` / `medal_wall.mapMedalWall` / 各页 `_map*`，本该在 `src/**/mapping.dart` 或 Rust 侧 DTO 直接给出可渲染形态（有测试但放错了层）。

### 2.4 改动churn 佐证（最近 200 次提交涉及 ui/lib）

```
85  ui/lib/main.dart          ← 唯一热点，占 42%
36  src/mine_view.dart
30  src/recommend_view.dart
30  src/detail_page.dart
27  src/settings_view.dart
23  src/artist_page.dart
21  src/feed_view.dart
20  src/comment_thread.dart
19  src/discover.dart
18  src/app_settings.dart
```

> `main.dart` 的 churn 是第二名的 2.4 倍，且**每条 churn 都要在 3877 行里定位**——这是拆壳收益的最直接量化依据。§2.2 里 P0 的三个文件（detail/messages/discover）同时也是 churn 榜前 10。

## 3. 状态管理现状

### 3.1 事实清单（静态统计，排除 `src/rust/**` codegen）

| 机制 | 规模 | 用途 |
|---|---|---|
| `setState` | **366 处**，分布在 **49 个 StatefulWidget** | 页面级一切局部状态 |
| `ValueNotifier` | **20 个** | 跨路由广播 / 高频翻帧跳过 setState |
| `ChangeNotifier` | **1 个**（`AppSettings`） | 全局偏好（主题/字号/音质/播放参数） |
| `InheritedWidget` | **1 个**（`AppActions`，`song_actions.dart:107`） | 给任意子树里的歌曲"..."菜单拿动作宿主 |
| 全局静态可变单例 | **5 类**：`AppSettings.instance`(83 处引用)、`UserNav.*`、`ArtistNav.*`、`UpdateCheckHost.*`、`Playback.setSkipHandlers/setActionHandlers` | 隐式注入 |
| 全局顶层 `ValueNotifier` | `playerBarSlot`/`playerBarData`/`playerBarActions`/`_actionsHost`/`_pageDepth`/`nowPlayingSongId`/`pendingUpdate`/`pendingPrompt` | 同上 |
| `StreamController` | **0** | — |
| provider / riverpod / bloc / get_it | **0**（`pubspec.yaml` 依赖只有 `cupertino_icons`/`flutter_rust_bridge`/`qr_flutter`） | — |

**结论：没有第三方状态管理框架，这是刻意的（依赖面极小），但"自研三套通道并存"是主要的不一致来源。**

### 3.2 实际的三套通道

**通道 A：顶层 `ValueNotifier` + 帧后投递（跨路由广播）**
用于"任何页面、任何深度都要看到同一个值"：
- `playerBarSlot/Data/Actions`（`main.dart:414-427`）——底部播放条在 Navigator 之外，HomePage 每帧帧后写入；
- `nowPlayingSongId`（`src/now_playing.dart:42`）——所有列表行的高亮来源；
- `_pageDepth`（`main.dart:372`）——底部 tab 让位判定；
- `pendingUpdate/pendingPrompt`（`update_checker.dart`）。
写法一致、有明确"为什么不用构造透传"的注释，**这是本仓最健康的一层**。

**通道 B：全局静态可变单例（隐式注入）**
`UserNav.onPlaySongs` / `ArtistNav.onPlaySongs` / `ArtistNav.onOpenAlbum` / `UpdateCheckHost` / `Playback.setSkipHandlers`——由 `_HomePageState.initState` 一次性赋值（`main.dart:815-843`）。理由写在 `user_nav.dart` 头注释里（"逐层透传 onOpenUser 会污染一堆构造函数"），但代价是：
- 它们的生命周期绑定在"第一个 HomePage 实例"上，测试里多实例会互相覆盖；
- 需要一个 `HomePage` 才能工作——单独 pump 一个 `UserPage` 时播放回调为空。

**通道 C：构造注入 + `show*Page` 参数（正式 API 面）**
38 个 `show*Page` 入口，195 个具名参数，其中 **46 个 `on*` 生产回调 + 72 个测试注入 loader/hook**（如 `loadSongs`/`toggleFollow`/`like`），剩下约 77 个是数据/开关（id、name、coverUrl、loggedIn）。平均 5.1 个参数/入口，最多 12 个（`showArtistDetail` / `showUserPage`）。

### 3.3 prop drilling 到底有多深

**深度不深（≤3 层），但宽度很宽**——问题不是"透传链长"，而是"同一个回调在 20 个文件里各写一遍"：

`onPlaySongs`（签名 `void Function(List<SongDto>, int index)`）在 **20 个文件、160 处**出现（`main.dart` 15、`user_page` 23、`recommend_view` 17、`artist_page` 16、`detail_page` 12、`mine_view` 11 …）。每个二级页面都：接收 `onPlaySongs` → 存字段 → 传给它内部 3–6 个 section → section 传给行。

同理 `onLikeChanged` / `onAppendSong` / `onOpenPlaylist` / `onOpenAlbum` / `onOpenArtist` / `onOpenRadio` 各有一套。

> 也就是说：**这里已经有一套"播放能力"的三个通道同时存在**（A 的 `nowPlayingSongId` 只解决"谁在播"、B 的 `UserNav.onPlaySongs` 解决"从头像进的主页怎么播"、C 的 `onPlaySongs` 参数解决"从 main 进的主页怎么播"）。新增一个页面时，作者必须同时记住这三条，这正是历史上"某处点了没反应"类 bug 的根源。

### 3.4 一致性打分

| 维度 | 评价 | 证据 |
|---|---|---|
| 跨页广播 | **好** | 统一 ValueNotifier + 帧后投递，且有踩坑注释 |
| 页面局部状态 | **可接受** | 49 个 StatefulWidget / 366 setState，无超长状态机（除 `_HomePageState`） |
| 依赖注入（可测性） | **好** | `typedef XXXLoader` + 默认值回落到 `rust.*`，是全仓统一范式（`async_view.dart` 头注释、`cloud_page.dart` 头注释） |
| 播放能力入口 | **差** | 三条通道并存（见 3.3） |
| 高频翻帧状态 | **不一致** | `_playing`/`_wordPositionMs` 用页面内 ValueNotifier 绕开 setState，同一个页面的其他播放信息却走 setState |
| 全局单例清理 | **勉强** | 靠 `UserNav.clearCache()` 之类测试钩子擦屁股；`AppSettings.instance` 无 dispose 语义 |
| 数据映射层位置 | **差** | `mapVipOverview`/`mapMedalWall` 等 DTO 转换写在 UI 文件里（见 §2.3） |

### 3.5 建议（按投入产出）

1. **只做一件事就能消掉 160 处透传**：把"播放能力"收成通道 A 的一个 `PlaybackBridge` 顶层单例（`playSongs(List<SongDto>, int)` + `appendNext` + `openPlaylist` …），保留 `onPlaySongs` 参数**仅为测试注入**（或者干脆保留但不再新增）。收益大、风险中（需一次全量测试回归）。
2. **不加框架**：现状（无 provider）与四端一致性目标不冲突，引入框架的迁移成本远大于收益；缺的是"命名一致的通道"，不是"能力更强的库"。
3. **把 `UserNav`/`ArtistNav` 的静态回调改为读同一个 `PlaybackBridge`**，即可删掉 3 个静态可变字段与 `initState` 里的 3 行赋值。
4. **页面内高频状态统一用 ValueNotifier**（当前只有歌词逐字位置这么干），并在 `notes-ui-rules.md` 里写一句口径，避免下一个页面再自选范式。

## 4. UI 规则层覆盖度

### 4.1 规则层由什么组成（实测）

| 层 | 文件 | 行数 | 实例化数 |
|---|---|---|---|
| 设计令牌 | `src/layout.dart` | 297 | `kPagePadding`/`kCardRowPadding`/`kSectionTitlePadding`/`kRowExtent`/`rowExtentFor()`/`CoverGrid` 等 20+ 常量 + 2 个响应式函数 |
| 四态容器（一次性取数） | `src/async_view.dart` | 166 | **19 处**，8 个文件（recommend 6、mine 5、style 2、user 2、ranking/mv/chart/cloud 各 1） |
| 四态容器（分页列表） | `src/paged_list_view.dart` | 331 | **10 个文件**（playlist_square、all_charts、new_release、my_collections、radio_subscribers、ranking、user_list、digital_album、messages、artist） |
| 四态原子视图 | `state_views.dart`(162) + `error_views.dart`(54) | 216 | `LoadingView`/`LoadingView.inline`/`EmptyView`/`InlineError`/`FullError` |
| 区块 / 小组标题 | `section_header.dart`(150) | 150 | `SectionHeader` **15 处**、`SectionTitle` **20 处**，共 8 个文件 |
| 长文本 / 徽标 | `adaptive_text.dart`(228) + `adaptive_text_row.dart` | ~300 | `AdaptiveText`/`AdaptiveTextRow` **24 处**，19 个文件 |
| 门禁 | `tools/check-tokens.sh` | — | `--strict` 在 `tools/ci.sh` 里**必过** |

**当前 token 门禁实测：`bash tools/check-tokens.sh` → `OK（没有集合外的间距/圆角/字号）`。** 这是 2026-11-13 清零后的基线，是全仓质量最好的一个维度——间距/圆角/字号已经被锁进有限集合，改坏会直接 CI 红。

### 4.2 覆盖度实况（页面文件 × 规则件）

按 `class *Page` / `class *View` / `Future<void> show*` 识别出 **32 个页面级文件**：
- **19 个已用规则件**（其中 `settings_audio_page` 6 处 SectionTitle、`new_release_page` 3+4、`artist_page` 2+3、`style_page` 5 是标杆）；
- **13 个完全没用任何规则件**：`vip_page`(797) / `feed_share`(937) / `cover_art`(698) / `medal_wall`(632) / `album_preview`(416) / `feed_detail_page`(409) / `song_share`(395) / `song_actions`(358) / `similar_sheet`(226) / `song_wiki`(162) / `cover_quality_sheet`(102) / `update_dialog`(50) / `comment_page`(43)；
- `main.dart`(HomePage) 也不用——但它是外壳，行/标题都来自 `src/**`，属正常。

**仍然手写四态（`_error` + 手写"重试"按钮 + 各自 skeleton/spinner）的 17 个文件**，按混乱程度排：

| 文件 | `_error` 处数 | 备注 |
|---|---|---|
| `discover.dart` | 25 | 2 个页面 × 5 个 tab，各自一套 `_songs`/`_error`/`_retry` |
| `comment_thread.dart` | 17 | 分页 + 回复两层，错误态文案手写 |
| `messages_page.dart` | 16 | 4 个 tab 各一套 |
| `feed_view.dart` | 10 | 首屏 + 加载更多两套（`_error` / `_olderError`） |
| `artist_page.dart` | 6 | 虽有 PagedListView，动态 tab 仍手写 |
| `user_page.dart` | 7 | 已有 2 处 AsyncView，另 2 处手写 |
| `vip_page.dart` | 4 | 整页手写四态 |
| `medal_wall.dart` | 7 | 整页手写四态 |
| `radio_explore_page` / `song_wiki` / `similar_sheet` / `album_preview` / `login_sheet` / `podcast` / `digital_album_page` | 4–5 | 小组件手写 |
| `paged_list_view.dart` | 5 | **合理**（它就是四态实现本体） |

### 4.3 逐步收口方案（不改行为，按"风险/收益"升序）

**阶段 0（已完成，守成）**：`check-tokens.sh --strict` 保持 0 越界；新增 UI 一律先找规则件再写。

**阶段 1：把"整页手写四态"接到 `AsyncView`（收益高、风险低）**
- 目标：`vip_page`、`medal_wall`、`album_preview`，以及 `user_page`/`artist_page` 里剩余的手写块。
- 做法：把 `initState` 里的 `_load()` 改成 `AsyncView(load: ..., builder: ...)`；自定义空态用 `emptyBuilder`，整页错误用 `errorBuilder: FullError`。
- 验收：`dart analyze` + 该页现有测试（`vip_page_test`/`medal_wall_mapping_test`/`artist_page_tabs_test`）不动即绿。

**阶段 2：把"多 tab 页面各自的四态"抽成一层（收益中、风险中）**
- 目标：`discover`（5 tab）、`messages_page`（4 tab）、`feed_view`、`comment_thread`。
- 做法：先把 `_songs/_error/_retry` 三件套换成 `AsyncView`（不改 tab 结构），再谈 §2.2 的文件拆分。**顺序必须是"先收口四态，再拆文件"**，否则拆完还要再改一遍。
- 验收：`discover_test`/`messages_page_test`/`feed_pagination_test`/`comment_*_test`。

**阶段 3：区块标题全收口（收益低、风险低）**
- `feed_share`/`song_share`/`cover_quality_sheet` 的标题当前是手写 `Text + titleMedium`；改成 `SectionTitle`。
- 全仓 `titleMedium|titleSmall` 的直接使用只剩 ~25 行（多数已经在规则件内部），所以这步很轻。

**阶段 4：行组件收口（收益最高，但要连带 §2.3）**
- 5 份歌曲行（§2.3）合成一个走 `AdaptiveText` + `SongFeeBadges` 的 `SongRow`；这一步同时消掉"正在播放高亮漏接一处就不亮"的整类 bug。
- 因为要动 `detail_page`/`discover`/`artist_page`/`user_page` 四个页面，**排在 §2.2 P0 拆文件之后做**（在 1558 行的文件里冒出 5 个调用点不好 review）。

**阶段 5（可选）：把 `check-tokens.sh` 的白名单再收紧**
- 当前间距集合有 29 个值（`0,1,2,3,4,6,8,10,12,16,20,24,32,40,48,56,64,72,80,88,96,108,118,120,160,180,220,240`），字号集合 16 个值。收口后（阶段 1–4 落地）可以用实测统计把长尾（108/118/160/180/220/240）逐个要求写 `// token-ok: 理由`。**这一步没收益前不要做**，白名单宽是有意的。

### 4.4 一句话结论

**令牌层（layout + token 门禁）已经到位且 CI 强制；四态层有两个容器，但还有 17 个文件手写；标题/长文本层的覆盖率约 50%（19/38 页面文件）。** 收口的正确顺序是"先接容器（阶段 1–2）→ 再拆文件（§2.2）→ 最后合并行组件（阶段 4）"，反过来做会重复劳动。

## 5. 测试基建

### 5.1 规模与分布

| 指标 | 数值 |
|---|---|
| 测试文件 | **140 个**（全部在 `ui/test/`，无子目录、无 `dart_test.yaml`） |
| 测试代码 | **27,506 行**（≈ 手写 lib 代码 35,962 行的 **76%**） |
| 用例数 | **923**（`testWidgets` 647 + `test` 276），65 个 `group` |
| lib 文件被测试 import | **92 / 105（88%）** |
| 未被任何测试 import 的 lib 文件 | **13 个**：`frb_generated.io/web`(4,220 行 codegen)、`async_view`(166)、`error_views`(54)、`sheet_header`(91)、`cover_row`(118)、`expandable_text`(61)、`platform`(80)、`file_pick`(54)、`image_io`(39)、`auth`(48)、`comment_page`(43)、`update_dialog`(50) —— **非 codegen 的真空白只有约 804 行** |
| 被最多测试 import 的 lib | `app_settings`(20)、`comment_thread`(11)、`main.dart`(**9**)、`song_tile`(8)、`settings_view`/`recommend_view`/`cover_art`(8) |
| 网络用例 | 仅 `frb_smoke_test.dart`，`@Tags(['network'])`，CI 排除 |
| 视觉基准 | `@Tags(['golden'])`，**GitHub ci.yml / release.yml / GitLab 三处都 `--exclude-tags 'network || golden'` 排除**；只有本机 `tools/ci.sh` 的裸 `flutter test` 会跑（没有 CJK 字体时自动 skip） |

### 5.2 主要覆盖什么（按测试文件主题归类）

- **纯逻辑/映射**（`test` 用例为主，最健康）：`lyric`/`word_lyric`/`karaoke_clip_rects`/`lyric_source_*`/`queue`/`playback_url`/`playback_state`/`playback_tuning`/`eq_curve_chart`/`vip_mapping`/`medal_wall_mapping`/`layout_metrics`/`row_extent`/`theme_accent`/`cover_quality`/`friendly_error`/`skip_vip_songs`/`song_action_source`/`version_consistency`。
- **单组件 widget 测试**：`song_tile`/`adaptive_text_row`/`marquee_*`/`profile_banner_viewer`/`profile_identity`/`signin_card`/`message_entry_card`/`category_bar_layout`/`style_tiles`/`grid_columns_layout`/`search_grid_sections`/`row_extent`/`top_bar_no_duplicate`。
- **整页 widget 测试**（假 loader，0 网络）：`mine_view`/`recommend_view`/`discover`/`settings_*`/`vip_page`/`messages_page`/`user_page`/`artist_page_tabs`/`feed_pagination`/`comment_*`/`queue_sheet`/`play_queue_sheet`/`mv_page_comments`/`login_sheet_*`/`medal_wall`。
- **排版回归专项**：`narrow_width_audit_test.dart`（463 行，**逻辑宽 {300,320,360} × textScale {1.0,1.25,1.3,1.625} = 12 组矩阵**，断言无 overflow / 关键文本单行 / 右边界不出屏）+ `settings_narrow_overflow`/`detail_song_row_narrow`/`player_bar_narrow`/`s1_two_row_overflow`/`ui_batch_d_narrow`。
- **历史批次命名**（技术债）：11 个文件按反馈批次而不是行为命名 —— `ui_batch_a_back_nav`/`ui_batch_a_search_landing`/`ui_batch_a_song_tile`/`ui_batch_b2_keyboard`/`ui_batch_c_ia`/`ui_batch_d_narrow`/`c2_clear_history_confirm`/`r6_oled_theme`/`s1_two_row_overflow`/`s2_about_page`/`s5_audio_settings_page`。

### 5.3 Golden 测试：12 张图的位置与维护成本

**位置**：`ui/test/goldens/`（12 张 png），生成逻辑全在 `ui/test/golden_pages_test.dart`（470 行）。

**构成**：6 个页面 × 2 个视口 = 12 张——

```
360×800 @1.0          300×640 @1.25 字号
settings_360x800.png   settings_300x640_s125.png
account_360x800.png    account_300x640_s125.png
recommend_360x800.png  recommend_300x640_s125.png
mine_360x800.png       mine_300x640_s125.png
search_landing_360x800.png  search_landing_300x640_s125.png
messages_360x800.png   messages_300x640_s125.png
```

（`360x800` 为常规口径；`300x640 @1.25` 对齐 vivo 真机 1440×3168 @768dpi + 系统字号 1.25，与 `narrow_width_audit` 同口径。）

**维护成本（真实存在且不低）**：

| 成本项 | 现状 |
|---|---|
| 环境绑定 | 必须 `cwd = ui/`；依赖**本机** Skia 版本 + **本机** CJK 字体文件（探测 `/usr/share/fonts/.../NotoSansCJK*`），换机/升级 Flutter ⇒ 大面积假红，只能 `--update-goldens` 重出 |
| CI 覆盖 | **0**。三套 CI 都排除 golden；只有主动跑 `tools/ci.sh`（裸 `flutter test`）才会校验。因此"CI 绿"不代表布局没坏 |
| 单图代码量 | 470 行 / 12 张 ≈ **39 行/图**（每页一个 builder + 假数据装配），新增一个页面 ≈ 40–60 行 + 2 张 png |
| 页面覆盖 | **6 / 32 页面级文件（38 个 `show*` 入口）= 16%**，且集中在"我的/设置/推荐/消息"这类**低 churn 页**；churn top-10 里的 `detail_page`/`artist_page`/`feed_view` **一张都没有** |
| 假失败防护 | 已有两道：`ErrorWidget` 与"加载失败"文案断言、无 CJK 字体时 skip |
| 残留产物 | `ui/test/failures/`（36 张真/假/差异图）已被 `.gitignore` 排除，属正常 |

### 5.4 建议补什么（按投入产出）

1. **给 `async_view` + `error_views` 补直接单测（最高优先）**：这两个是全仓 19 处四态的唯一实现，却**零直接覆盖**——四态判定口径（未完成=loading、`hasError`=error、`null`/空 List/空串=empty）目前只靠"各页面测试顺带触发"。补 4 个用例（loading/error/empty/data + keepAlive 与 `future` 分支）约 100 行，**成本极低、防护面覆盖 19 个调用点**。
2. **把 golden 拉进 CI 的容器**（或改为自带字体资产）：现在"视觉回归只在本地跑"，等于没有门禁。最小方案：在 CI job 里 `apt-get install fonts-noto-cjk` 后去掉 `--exclude-tags golden`（需先验证 Skia 版本一致），或改成把 CJK 字体作为 test asset 提交（一次性 ~20 MB，可用子集）。
3. **给 churn top-10 且无 golden 的页面补 2–3 张**：`detail_page`（歌单详情，30 次 churn）、`artist_page`（23）、`feed_view`（21）。这三页是"改 A 坏 B"最可能发生的地方，且都有现成的假 loader 可复用。
4. **抽 `test/support/fakes.dart`**：**36 个测试文件各自定义 `rust.SongDto song(...)`**（24 个叫 `song`、2 个 `fakeSong`、1 个 `s`、1 个 `likedSong`）。抽一份带默认值的工厂 + 命名约定（`fakeSong({vip, coverUrl})`），能少写几百行样板，也让"新增 DTO 字段"只改一处。
5. **把 11 个批次命名测试改成行为命名**（`ui_batch_c_ia` → `search_results_ia` 之类）：只在**下次动到该测试时顺带改**，不做专门提交（避免一次性大 diff 撞上 §9 的 `dart format` 陷阱）。
6. **补一个 `dart_test.yaml`**（当前没有）：把 `network`/`golden` 的默认排除、超时、并发写进配置，就不必在每处 CI 命令里重复 `--exclude-tags 'network || golden'`（现在三套 CI 各写一遍，容易漂）。

## 6. 排序与前 5 建议

### 6.1 改动收益 / 风险 / 工作量排序表

评分口径：收益 = 消除的重复行数 + 降低的 churn 成本 + 防护面；工作量 S(<0.5d) / M(0.5–2d) / L(>2d)；风险按"可能引入用户可见回归 + 需要改动面"。

| # | 改动 | 收益 | 风险 | 工作量 | 收益/工作量 | 涉及文件 |
|---|---|---|---|---|---|---|
| 1 | **`async_view` + `error_views` 补直接单测**（四态口径 + `future`/`keepAlive` 分支） | 中（护住 19 个调用点） | **极低**（只加测试） | S (~100 行) | ⭐⭐⭐⭐⭐ | `src/async_view.dart`、`src/error_views.dart`、新增 `test/async_view_test.dart` |
| 2 | **main.dart 拆壳 S0+S1**（纯逻辑 + 全局槽位 + 外壳外移） | 中高（3877→~3300，纯搬运可 review） | 低（纯函数已有测试；外壳有 `player_bar_host`/`bottom_chrome_padding` 测试） | M | ⭐⭐⭐⭐ | `main.dart` → `src/lyric_source.dart`、`src/notification_mode.dart`、`src/back_policy.dart`、`src/app_shell.dart` |
| 3 | **P0 三个文件拆分**（detail / messages / discover） | 高（1558+886+882 → 6 个 ~300 行文件；三者都在 churn top-10） | 低中（纯函数/WIdget 搬家，调用点由 `show*` 入口隔离） | M | ⭐⭐⭐⭐ | `src/detail_page.dart`、`src/messages_page.dart`、`src/discover.dart` → `src/detail/`、`src/messages/`、`src/discover/` |
| 4 | **5 份歌曲行合并成 1 份** | **高**（删 ~450 行；"正在播放高亮"等全局口径只改一处，消掉整类"漏接一处"bug） | 中（4 个页面 × 5 个调用点，行内徽标/序号/菜单差异要参数化） | M | ⭐⭐⭐⭐ | `src/song_tile.dart`（落点）+ `detail_page`/`discover`/`artist_page`/`user_page` |
| 5 | **`onPlaySongs` 收成 `PlaybackBridge`** | **高**（20 文件 160 处透传 → 1 个入口；同时消掉 A/B/C 三通道并存） | 中高（要动每页签名 + 9 个 import main.dart 的测试） | M–L | ⭐⭐⭐ | `src/playback_bridge.dart`(新)、`main.dart`、`user_nav.dart`、`artist_nav.dart` + 20 个调用文件 |
| 6 | **main.dart 拆壳 S2–S7**（歌词/搜索/播放/动作/队列 controller 外移） | **高**（main.dart → ~700–1100 行） | **高**（状态所有权交叉 + 13 条全局钩子；见 §1.3） | L | ⭐⭐⭐ | `src/home/*.dart`（8 个） |
| 7 | **规则层阶段 2**（discover/messages/feed/comment 四态收口） | 中高（17 个手写四态文件 → 4） | 中（页面渲染路径要逐页验证） | M | ⭐⭐⭐ | 上述 4 文件 + `async_view.dart` |
| 8 | **规则层阶段 1**（vip / medal_wall / album_preview 接 AsyncView） | 中（三页整页四态归一） | 低 | S | ⭐⭐⭐ | `vip_page.dart`、`medal_wall.dart`、`album_preview.dart` |
| 9 | **golden 进 CI（容器装 fonts-noto-cjk 后去掉 exclude）** | 中（视觉回归从"本地自觉"变"门禁"） | 低（失败只是红，不改产品代码） | S–M | ⭐⭐⭐ | `.github/workflows/ci.yml`、`.gitlab-ci.yml`、`test/golden_pages_test.dart` |
| 10 | **抽 `test/support/fakes.dart`** | 低中（36 份重复 `rust.SongDto song()` → 1） | 极低 | S | ⭐⭐⭐ | `ui/test/support/fakes.dart`(新) + 36 个测试文件 |
| 11 | **补 3 张 golden**（detail / artist / feed，churn top-10 且无基准） | 中（护住最易回归的三页） | 低 | S（~150 行 + 6 张图） | ⭐⭐ | `test/golden_pages_test.dart`、`test/goldens/` |
| 12 | **DTO 映射层下移**（`mapVipOverview`/`mapMedalWall` 移出 UI 文件） | 低（层归位，行为不变） | 低 | S | ⭐⭐ | `vip_page.dart`、`medal_wall.dart` |
| 13 | **加 `ui/dart_test.yaml`**（默认排除 network/golden） | 低 | 极低 | S | ⭐⭐ | 新增 `ui/dart_test.yaml` + 三处 CI |
| 14 | **11 个批次命名测试改行为名** | 低 | 极低 | S | ⭐ | 11 个 test 文件（随触碰改） |
| 15 | **收紧 `check-tokens` 长尾白名单**（108/118/160/180/220/240） | 低（当前 0 越界，收紧无即时收益） | 低中（容易逼出 `// token-ok` 噪音） | S | ⭐ | `tools/check-tokens.sh` |

**不建议做的**（明确写出来避免走弯路）：
- 引入 provider/riverpod/bloc：现状无框架、依赖面极小，缺的是"通道统一"而不是"框架能力"（§3.5）。
- 拆 `recommend_view`/`eq_curve_chart`/`app_settings`/`queue`/`playback`：职责已单一，拆了只增 import 噪音（§2.2）。
- 顺手跑 `dart format`：Dart 3.13 tall style 会重排 ~10k 行（见项目 AGENTS.md 硬纪律）。

### 6.2 前 5 个建议（每条一句话 + 涉及文件）

1. **先给 `async_view` + `error_views` 补直接单测** —— 全仓 19 处四态唯一实现现在零直接覆盖，约 100 行测试就能护住 loading/error/empty/data 的口径。
   文件：`ui/lib/src/async_view.dart`、`ui/lib/src/error_views.dart`、新增 `ui/test/async_view_test.dart`。

2. **按 §1.2 的 S0→S1 起手拆 main.dart**（纯逻辑 → 全局槽位 + `PlayerBarHost` + `MiniNcmApp`），两步都是纯搬运，`main.dart` 从 3877 降到约 3300 行且 `main.dart` 用 `export` 保持 11 个公开符号，9 个测试文件零改动。
   文件：`ui/lib/main.dart` → 新增 `ui/lib/src/lyric_source.dart`、`notification_mode.dart`、`back_policy.dart`、`app_shell.dart`。

3. **把 `detail_page` / `messages_page` / `discover` 三个 P0 文件按"一页一文件"拆开**，它们在 1558/886/882 行里各塞了 2–5 个页面或 tab，且同时是 churn 榜前 10；`show*` 入口是天然的隔离面，拆分不触外调用方。
   文件：`ui/lib/src/detail_page.dart`、`ui/lib/src/messages_page.dart`、`ui/lib/src/discover.dart` → 各自子目录。

4. **把 5 份歌曲行合并成 `song_tile.dart` 里的一个 `SongRow`**（序号列/正在播放高亮/VIP 徽标/副标题参数化），预期删约 450 行重复，并让"正在播放"这类全局口径只剩一处。
   文件：`ui/lib/src/song_tile.dart` + `detail_page.dart`/`discover.dart`/`artist_page.dart`/`user_page.dart`（**排在建议 3 之后做**，否则在 1558 行文件里改 5 个调用点不好 review）。

5. **把 `onPlaySongs` 收成一个 `PlaybackBridge` 顶层入口**，消掉"A 的 nowPlayingSongId / B 的 UserNav·ArtistNav 静态注入 / C 的构造透传"三通道并存，160 处透传降到 1 个调用点（参数保留仅作测试注入）。
   文件：新增 `ui/lib/src/playback_bridge.dart`；改 `ui/lib/main.dart`、`src/user_nav.dart`、`src/artist_nav.dart` 及 20 个调用方。

### 6.3 建议节奏

- **第一批（低风险、当轮可完成）**：建议 1、2、8、9、10、13。
- **第二批（结构性改造，单独一个"重构"提交序列）**：建议 3 → 4 → 7。
- **第三批（最重，需要有整块时间 + 每步全量回归）**：建议 6 → 5。
