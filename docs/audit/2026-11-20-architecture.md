# 2026-11-20 架构审计（Flutter + Rust 网易云客户端）

> 目的：给后续「分批优化」挑活。每条结论都带 `文件:行` 指针；不复制源码。
> 范围：`ui/lib/src/**`、`core/crates/**`、`ui/test/**`、`tools/ci-gates.sh`。不含 `legacy/`（v1 只读存档）、`core/vendor/ncm-api`（钉死上游）。

## 0. 快照与方法

- 机器时间 2026-11-19 19:49 (+08:00)，HEAD `3f96996`（v0.28.0 发版后的 docs 提交）。
- **工作区当时不干净**：另有车道正在飞约 12 个未提交文件（随后仍在增加）（`app_settings.dart`、`app_settings_codec.dart`、`home/home_page.dart`、`home/search_controller.dart`、`recommend_view.dart`、`search_landing.dart` + 6 个测试）。因此 `dart analyze` 现在的 42 个 error 与 `dart format` 的 1 文件漂移**属于在飞改动**，不是 HEAD 存量（HEAD 的 `app_settings.dart` 仍有 21 处 `CustomQuickAction`，与旧测试自洽）。§6 把两者分开记。
- 只读审计：除本文件外未写任何文件，未 commit/push/checkout。
- 实际执行：`wc -l`/`find`/`grep` 统计；`tools/ci-gates.sh {tokens,row-padding,sheet-entry,docs,write-guard,lock-poison}`；`dart analyze`; `dart format --output=none --set-exit-if-changed lib test`。

## 1. 一页纸摘要

**体量坐标**：Dart 源码 46,117 行 / 161 个文件（另加 frb 生成 21,224 行）；Rust 源码 33,992 行（另加 `frb_generated.rs` 13,410 行）；FFI 面 158 个 `pub fn`（`core/crates/ncm-ffi/src/api.rs`）+ Dart 侧 156 个函数（`ui/lib/src/rust/api.dart`，4,716 行）；测试 Dart 193 文件 / Rust 370 例。

**五条主结论**

1. **Rust 依赖方向干净，UI 层边界靠"约定 + 门禁"维持，不靠结构。（好）** `ncm-domain → ncm-provider → ncm-service → {ncm-ffi, ncm-cli}` 单向（各 crate `Cargo.toml` 的 `[dependencies]` 段，见 §2.3），没有反向依赖；UI 侧 `serde_json.Value` 出现 0 次（`grep -rn 'serde_json' ui/lib/src` 无命中），四态/浮层/取值口径都有门禁脚本兜底。
2. **UI 目录仍是"大平层"。** `ui/lib/src/` 根目录 120 个 `.dart`，只有 10 个子目录共 41 个文件；`discover/`、`detail/`、`feed/`、`comment/`、`messages/` 已按页拆出并留了 barrel（`discover.dart:1-12`、`detail_page.dart:1-12`、`feed_view.dart:1-8`），但 `settings/mine/artist/user/vip/podcast` 等仍单文件上千行（§2.1）。
3. **跨层契约是"镜像 + 手写 DTO"的混合体，且 FFI 面偏散。** 65 个 `#[frb(mirror(...))]` 直接把 domain 类型按原名暴露给 Dart，另有 3 个手写 DTO（`api.rs:208 InitInfo`、`api.rs:217 ProviderInfo`、`api.rs:223 SongDto`），`Song` 因此有 domain/FFI 两个形状 + 两条转换函数（`api.rs:244 song_dto`、`api.rs:269 song_from_dto`）；而 158 个函数里 **64 个（40%）挤在同一段注释下**：`api.rs:2365` "推荐页(私人FM) / 我的(收藏播客/关注艺人/动态)"，横跨 `api.rs:2365-3247`（§3.3）。
4. **已知坑基本收口了，剩下的是"新代码可以绕过守卫"。** 18 处 `addPostFrameCallback` 全部自查了一遍：绝大多数回调进了自管 State（内部 `if (!mounted) return`，如 `adaptive_text.dart:166`、`marquee_text.dart:206`、`feed_detail_page.dart:108`），全局槽位的写入集中在 `home/home_wiring.dart:155`/`:194`（带 `_attached/_latest/_alive` 判据），跨页守卫封装在 `lifecycle_guard.dart:19`。唯一没有守卫的是 `detail_pane.dart:117`（帧后 `closeDetailPane()`，全局动作，风险低）。真正的结构性风险是**没有 lint 强制**走 `runPostFrameIfAlive`（§5）。
5. **门禁数量够但并不总是绿的，最容易漂的是 `dart-format` 与 "在飞车道 vs analyze 门"。** 六道 checker 本次全绿；`dart format` 在 `ui/lib/src/search_landing.dart` 上已漂（§6.3）；更严重的是"多车道并行改 lib + test"期间 `dart analyze` 会长期红，而 CI 只测合并后的树（§6.4）。

**排序后的建议清单（详见 §7）**

| 序 | 事 | 收益 | 风险 | 量 | 可并行 |
|---|---|---|---|---|---|
| 1 | 恢复绿门：format 漂移 + 在飞改动的测试对齐 | 高（门不绿则后面全白搭） | 低 | 小 | 否（串在其他车道之后） |
| 2 | 拆 `ncm-ffi/src/api.rs` 按域分模块 + 删/标注 6 个无调用点函数 | 中高 | 低 | 中 | 是 |
| 3 | 消掉 `ui/lib/src/lyric_source.dart` 的 Rust 打分镜像 | 中高（双份业务规则，已漂移风险） | 中 | 中 | 是 |
| 4 | 统一 LRU/分页小工具（3 处手写 LRU + `cloud_page` 手写分页） | 中 | 低 | 小 | 是 |
| 5 | 补 `home/playback_coordinator.dart`、`home/account_actions.dart` 直测 | 中 | 低 | 中 | 是 |
| 6 | 把 6 个进程级 `ValueNotifier` 收进一个 AppShell 作用域（或加 lint） | 中 | 中 | 中 | 否 |
| 7 | 拆 `home/home_page.dart`（1907 行，46 个方法） | 高 | 中高 | 大 | 否（热文件） |
| 8 | UI 根目录按域继续迁移（120 → 目标 ≤60） | 中 | 中 | 大 | 仅顺序 |

## 2. 模块边界

### 2.1 `ui/lib/src/` 目录职责

- 根目录 120 文件，子目录 10 个、41 文件：`home/ 8`、`detail/ 8`、`messages/ 6`、`discover/ 6`、`comment/ 5`、`rust/ 4`、`feed/ 4`、`vip/ 1`、`medal/ 1`、`image/ 1`。
- 拆分是**渐进**的，方式是"根目录保留 barrel + 实现下沉"，例如 `discover.dart:5-12`、`detail_page.dart:7-12`、`feed_view.dart:5-8`。好处是调用方零改动；代价是同一域出现"同名根文件 + 同名子目录"两处入口，新人无法从路径判断实现位置（`comment_page.dart` 43 行是独立页壳而不是 barrel，`messages_page.dart` 170 行同时是 barrel + 自有代码，`messages_page.dart:11-19`）。
- 未拆的大文件（Dart 侧 Top 20，`wc -l`，已排除 `ui/lib/src/rust/**`）：

```
1907 home/home_page.dart        1231 app_settings.dart        1051 mine_view.dart
1049 settings_view.dart         1000 artist_page.dart          939 feed_share.dart
 928 recommend_view.dart         917 comment/comment_thread.dart 909 word_lyric_view.dart
 857 song_tile.dart              849 feed/feed_view_body.dart   794 user_page.dart
 736 eq_curve_chart.dart         675 home/playback_coordinator.dart 670 login_sheet.dart
 670 detail/playlist_detail_page.dart 625 layout.dart         589 player_bar.dart
 576 radio_explore_page.dart     571 cover_art.dart
```

  Rust 侧 Top（`wc -l`，排除生成文件）：`api.rs 3334`、`ncm-domain/src/lib.rs 1853`、`ncm-playback/src/lib.rs 1815`、`ncm-cli/src/main.rs 1791`、`netease/song.rs 1149`、`netease/search.rs 1098`、`ttml_source.rs 1021`。
- `home/home_page.dart` 是唯一的"上帝对象"：46 个方法，既有全局槽位注册（`:205 initState`、`:396 dispose`）、播放协调（`:823 _playFromList`、`:960 _next`）、搜索跳转（`:850-906`）、tab 构建（`:1380 _buildTabPages`、`:1483 _buildSearchTab`）与 tab 选择（`:1255 _onTabSelected`）。`:1082 build` 之后 800 行全是 UI，逻辑与布局不可分。

### 2.2 页面与状态管理

- 全局可变槽位共 8 个 `ValueNotifier`：`app_shell.dart:50 actionsHost`、`:60 pageDepth`、`:68 modalRouteOpen`、`:189 playerBarSlot`、`:193 playerBarData`、`:197 playerBarActions`，加 `now_playing.dart:13`、`stream_note.dart:107`、`detail_pane.dart:35`。
- 唯一"单例状态"是 `AppSettings`（`app_settings.dart:408 static final instance`），已提供作用域订阅（`:1198 addScopedListener`）避免全员重建——这一点在 `app_settings.dart:454` 的注释里明确写出动机（上百个封面订阅者）。
- 生命周期收口在 `home/home_wiring.dart`（attach/detach 配对 + `_alive` 栈，见文件头 1-60 行的对照表），是这套全局槽位唯一的结构化约束。它的语义是"后 attach 覆盖先 attach"，对生产（单 HomePage 实例）恒为栈深 1。
- 判定：**页面状态归 State、进程级状态归 notifier** 的界线是清楚的，测试也在守（`ui/test/home_wiring_stack_test.dart`、`app_settings_scoped_notify_test.dart`）。真正的耦合点是"页面 → 全局 notifier"这条写入路径只靠人守，见 §5。

### 2.3 `core/` 依赖方向

- 依赖图（`core/crates/*/Cargo.toml` 的 `[dependencies]`）：`ncm-domain`（无内部依赖，仅 serde/serde_json）← `ncm-provider`（+domain）← `ncm-service`（+domain+provider+**ncm-api-rs**）← `ncm-ffi`（+domain+provider+service+playback）/`ncm-cli`（+domain+provider+service+playback+**ncm-api-rs**）；`ncm-playback` 只依赖 domain；`ncm-plugin` 只依赖 domain+provider。
- **无循环、无反向依赖**，方向单向。两处"看起来像泄漏"但成立：`ncm-service` 直接依赖 vendor（`Cargo.toml` 行 5），因为它是 vendor 的唯一包装层（`ncm-service/src/lib.rs:13 pub mod netease`，`lib.rs:22 pub use netease::NeteaseProvider`）；`ncm-cli` 也直连 vendor 做 headless 验证。
- 真正的悬空点：**`ncm-plugin` 无人依赖**（`grep -rn ncm-plugin --include=Cargo.toml` 只命中自身与 workspace 成员列表 `core/Cargo.toml:8`），20 例测试是切片 1 的存量，`docs/remaining-batches.md:198` 已记录"未接入产品"。它不是死码（有测试、有 README），但确实在 workspace 里占一份编译与门禁时间。
- 层内结构：`ncm-service` 13 个平铺模块（`cache/cloud_chunk/credential_*/fsutil/history/identity/loudness_store/netease/read_cache/ttml_source`），`netease/` 下 8 个 endpoint 文件；`ncm-domain/src/lib.rs` 1853 行是**单一 models 文件**（`lib.rs:55 Artist`、`:72 Song`、`:517 Playlist`…），域模型与 seq 解析（`parse_ttml`）混在一起。

## 3. 跨层契约

### 3.1 UI 不吃 `serde_json::Value`（好）

`grep -rn 'serde_json\|Value' ui/lib/src --include=*.dart | grep -v '/rust/'` 只命中 `ValueChanged/ValueKey/withValues`；UI 侧只有 typed DTO。这条属于"已成事实、后续别破坏"。

### 3.2 DTO 与镜像混用

- 65 个 `#[frb(mirror(...))]`（`api.rs:293` 起到 `api.rs:3248` 之前），把 `StreamUrl/SearchArtist/.../CloudPage` 按 domain 原名暴露（完整清单可用 `grep -n '#\[frb(mirror' core/crates/ncm-ffi/src/api.rs` 复现）。好处：零转换、单一形状。代价：**改 domain 字段 = 直接改 Dart API**，即 domain crate 事实上是公开契约的一部分，flutter_rust_bridge 的重生成（`ui/lib/src/rust/api.dart` 4716 行）成为跨层变更的必经步骤。
- 3 个本地 DTO 中 `SongDto`（`api.rs:223`）是 domain `Song`（`ncm-domain/src/lib.rs:72`）的**扁平投影**（`artist` 单串 + `vip/paid` 预计算），双向转换在 `api.rs:244`/`:269`；`song_from_dto` 只保留展示字段且把多艺人压成一人（`:280-292`），本地历史落盘后再读会丢多艺人。这是目前唯一"两个 Song 形状"的地方，且注释已承认取舍。
- `FfiError`（`api.rs:36-50`）与 `ProviderError{kind,retryable,detail}` 的映射统一在一处（`api.rs:78-90`），UI 侧 `net_retry.dart:39 retryNetwork` 按 `retryable` 决策，口径一致——没有第二份错误分类。

### 3.3 FFI 面：158 函数，按域分布高度不均

`api.rs` 里以 `// -------------` 分段统计 `pub (async) fn`：

```
 64  推荐页(私人FM)/我的(收藏播客/关注艺人/动态)   api.rs:2365-3247
 12  多账号(账号簿)                              api.rs:728-1022
 11  歌单详情/评论/分享                          api.rs:1845-2102
 11  收藏(红心)与歌单                            api.rs:1023-1297
  9  个人主页资料                                api.rs:608-727
  7  播放                                        api.rs:1298-1445
  7  搜索建议/历史                               api.rs:1732-1817
  6  歌手全部歌曲/MV                             api.rs:462-607
  4  电台发现(只读) / 4 播放参数 / 4 搜索增强
  3  音乐云盘 / 3 每日推荐 / 3 播客 / 3 响度测量
  2  音频缓存占用上限
  1 ×5：综合搜索 / 歌手详情 / 搜索页热词 / 专辑封面预览 / (未命名段)
```

- 第一段就是问题本身：**40% 的 FFI 面在一个"grab-bag"段里**（`api.rs:2365` 的标题同时挂了三件事：私人 FM、我的收藏、关注动态），跨近 900 行。任何"我的"页相关改动都要碰这个热文件。
- 无调用点函数（`ui/lib` + `ui/test` 全文 0 命中，只存在于生成的 `api.dart`）：`cache_stats`（`api.rs:1560`）、`cloud_song_url`（`:955`）、`player_tuning`（`:1538`）、`eq_profile_normalize`（`:1505`）、`consent_plaintext_storage`（`:877`）、`user_play_ranking`（`:632`）。要么补 UI，要么标 `#[frb(ignore)]`/删掉——现在它们是"每层都要生成的死面"。
- Dart 侧耦合度量：161 个非生成 lib 文件里 85 个直接 `import 'rust/api.dart'`（52%），193 个测试文件里 112 个（58%）。即"FFI 生成物是全局单例命名空间"这一现状没有被任何 facade 收窄（`playback.dart`、`daily_cache.dart` 是零散的薄封装，不是系统性的）。

## 4. 重复与死码

### 4.1 重复实现（按"同一规则几份"排）

| 规则 | 位置 | 备注 |
|---|---|---|
| 逐字歌词打分/择优 | `ui/lib/src/lyric_source.dart:45,58,61,160,233` ↔ `core/crates/ncm-service/src/ttml_source.rs:21,24,27,129,247,311,435` | 常量逐个镜像（0.6 / 0.9 / 权重 0.3,0.2,0.15,0.15,0.2），文件头自称"与 Rust 同口径的 Dart 镜像"。**两份业务规则**，改一处必须改两处，且各有单测各测各的。 |
| LRU 缓存 | `cover_art.dart:49`（字节 200 张）、`cover_palette.dart:365`（palette）、`word_lyric_view.dart:638`（排版） | 三份手写 LRU，各自 touch/淘汰逻辑不同，没有共享小工具。 |
| 分页 | `paged_list_view.dart:123`（带 `_generation` 竞态令牌，14 个调用方）↔ `cloud_page.dart:136-164`（手写 offset 追加 + `_loadingMore`）↔ `artist_page.dart` 三页签各自翻页 | `PagedListView` 已支持 `nextCursor`，云盘是可以用它的（`cloud_page.dart:55,124`）。 |
| 四态 | `async_view.dart:127`（唯一实现）+ 24 个调用方 | **已收敛**：`FutureBuilder` 在 `ui/lib/src` 只剩 `async_view.dart:127` 一处（`ranking_view.dart:180`、`chart_section.dart:43` 只是注释提到历史）。这条已成事实。 |
| 重试 | `net_retry.dart:39`（UI 唯一）↔ `ncm-service/src/cloud_chunk.rs:373 put_part_with_retry` + `cache.rs` 下载重试 | 分层不同（网络 vs 分片上传），口径都是"只重试 retryable 一次"，算可接受；但没有共享常量。 |

### 4.2 死码

- FFI：见 §3.3 的 6 个无调用点函数。
- `legacy/`：代码引用 0 处（`grep -rn 'legacy/' --include=*.dart --include=*.rs` 只命中注释/文档）。符合 AGENTS.md 定位，**不是问题**，但 540K 目录仍在仓库里（既往 `docs/audits/2026-11-13-asset-docs-audit.md:76` 已讨论过）。
- `ncm-plugin`：无 crate 依赖它（§2.3），属"未接入的切片 1"。
- 历史审计项复核（`docs/audits/2026-11-12-code-audit.md`）：
  - A3 `_CoverCard` 三处逐字节重复 → **已消**（`grep 'class _CoverCard' ui/lib/src` 0 命中）。
  - A4 `radio_subscribers_page` 手写分页 → **已收敛**到 `PagedListView`（`radio_subscribers_page.dart` 在 14 个调用方内）。
  - A5 手写 SnackBar → **剩 1 处**：`home/home_page.dart:950`（其余 2 处在 `toast.dart:63,88` 实现内部，正常）。
  - L1 `PagedListView` 刷新/loadMore 竞态 → **已修**，`paged_list_view.dart:123 _generation` + 4 处 `gen != _generation` 早退（`:142,150,183,191`）。
  - L3 计数格式化口径 → `format.dart:45 formatOneDecimal`、`:58 formatCountMagnitude`、`:70 formatFanCount` 仍是三条相近路径（`:70` 复用了 `:45`，属可接受）。

## 5. 状态与生命周期风险

- 18 处 `addPostFrameCallback` 全量核查结果：**13 处写的是自管 State 字段，回调内自带 `if (!mounted) return` 或等价判据**（`adaptive_text.dart:166`、`marquee_text.dart:206`/`:249-252`、`feed_detail_page.dart:108`、`user_page.dart:156`、`cover_art.dart:192`、`feed/feed_view_body.dart:814`、`home/home_page.dart:515`、`comment/comment_thread.dart:720-724` 用 `currentContext == null` 判据、`play_queue_sheet.dart:122-126` 用 `hasClients` 判据）。
- 写全局槽位的 2 处集中在 `home/home_wiring.dart:155`（写入 `actionsHost/playerBarActions`，判据 `_attached && identical(_latest, this)`）与 `:194`（清空，判据 `_alive.isNotEmpty`），并有 `ui/test/home_wiring_stack_test.dart` 锁定 attach/detach 栈语义。
- 未加守卫的全局动作 1 处：`detail_pane.dart:117` 帧后无条件 `closeDetailPane()`（宽档 build 里发现 detail 请求不匹配时自我纠正）。因为写的是全局 `detailPaneSlot` 而非已销毁 State，风险是"多一次无意义重建"，不是悬挂引用。
- 故意延后 dispose 1 处：`profile_scaffold.dart:463`（`syncProfileTabs` 把旧 `TabController` 推到帧末释放，注释与 `artist_page` 的历史坑对应），测试在 `ui/test/artist_page_tabs_test.dart`。
- **结构性缺口**：`lifecycle_guard.dart:19 runPostFrameIfAlive` 是唯一推荐入口，但没有任何 lint/脚本拦住"在 build 里直接写全局 notifier"或"绕过 guard"。`tools/check-sheet-entry.sh` 那种"按 API 名拦截"的模式可以照抄一份（例如禁 `ui/lib/src/**` 里对 `actionsHost.value =`/`playerBarData.value =` 的直接赋值，白名单 `app_shell.dart`/`home_wiring.dart`/`detail_pane.dart`）。
- 路由/返回栈：`back_policy.dart:30 resolveHomeBackAction` 是纯函数 + 单测（`ui/test/ui_batch_a_back_nav_test.dart` 经 `main.dart` barrel），30 处 `Navigator.push` 里 15 处集中在页面入口函数（如 `all_charts_page.dart:34`、`my_collections_page.dart:20`），浮层统一经 `app_sheet.dart`（门禁绿，`tools/check-sheet-entry.sh`）。

## 6. 测试与门禁

### 6.1 测试分布

- Dart 193 个测试文件（+3 个 `ui/test/support/`），Rust 370 例：`ncm-service 252`、`ncm-domain 49`、`ncm-playback 47`、`ncm-plugin 20`、`ncm-provider 1`、`ncm-ffi 1`、`ncm-cli 0`。
- Dart 侧按域（文件名前缀计）：feed 12、comment 9、player_bar 8、search 7、song 6、lyric 6、profile 5、eq 5、app 5、queue 4、cover 4；**home 域只有 1 个直测文件**（`home_wiring_stack_test.dart`）。
- 覆盖率盲点（按 import 图算）：161 个非生成 lib 文件里 119 个被测试直接 import；其余经 barrel 间接覆盖（`discover.dart`、`detail_page.dart`、`messages_page.dart` 等）。真正"只有间接覆盖"的大文件是 `home/playback_coordinator.dart`（675 行，仅经 `home_page` 集成路径）与 `home/account_actions.dart`（516 行）。
- Rust 侧 `ncm-ffi` 只有 1 例（`frb_smoke` 属 Dart 侧），`ncm-cli` 0 例：FFI 转换层（`api.rs` 3334 行，+65 mirror）基本靠 Dart 侧间接验证。

### 6.2 门禁口径（`tools/ci-gates.sh`）

- 唯一实现，本地 `tools/ci.sh` 与 GitHub 两套 workflow 都只调它（文件头注释 `ci-gates.sh:1-40` 说明了集中动机与历史漂移）。`verify` = rust-lint + rust-test + dart-format + dart-analyze + 5 道 checker（write-guard/lock-poison/tokens/row-padding/sheet-entry）+ docs + flutter-test（含 golden，排除 `network`）+ android-unit + android-lint（`ci-gates.sh:cmd_verify`）。
- 本次实测六道 checker：**全绿**（`tokens` 0 例外之外的门、`row-padding` 20 处纵向 0 + 1 处 6、`sheet-entry` 白名单 3 项、`docs` 死链 0/索引缺 0/白名单命中 0、`write-guard` OK、`lock-poison` 生产 0 处/测试 5 处放行）。

### 6.3 已观测到的漂移

1. **`dart format` 门当前是红的**：`dart format --output=none --set-exit-if-changed lib test` → `Changed lib/src/search_landing.dart`（差异在 `:78` 的 `hasReason` 换行与 `:178` 的 for-in 换行；该文件正是万辆在飞车道改的文件）。这是"格式化只跑改动文件、门却查全仓"的典型结果。
2. **`dart analyze` 门当前是红的（42 error）**，全部来自"lib 改了 API、test 未同步"：`test/recommend_quick_action_test.dart` 等 4 个文件用 `CustomQuickAction`（lib 侧已被在飞改动删掉），`test/search_landing_test.dart` 等 6 个文件按旧签名传 `String`（lib 侧已改为 `List<RecommendedKeyword>`，`search_landing.dart:15`）。结论：**门本身没错，是多车道并行 + 无 pre-commit 导致的时序问题**。

### 6.4 哪些门最容易漂（按"能否本地自然发现"）

- 第一档（合并期必红、本地不做就发现不了）：`dart-format`（全仓口径 vs 只格式化改动文件）、`dart-analyze`（lib/test 不同步）。
- 第二档（依赖外部资源、静默 skip）：`flutter-test` 的 golden（缺 `fonts-noto-cjk` 会整组 skip ⇒ 没测也算绿，`ci-gates.sh:cmd_flutter_test` 注释）、`android-instrumented`/`android-test-emu`/`desktop-smoke`（无设备/bundle 时 `SKIP 退 0`，`ci-gates.sh:cmd_android_instrumented` 等）。
- 第三档（规则写死在脚本里，改代码不触发）：`tokens`/`row-padding`/`sheet-entry`/`write-guard`/`lock-poison`/`docs`——本次全绿，且有 16 处 `// token-ok:` 例外需要人工复核是否过期。

## 7. 高价值优化清单（供分批挑活）

> 每条的"是否适合独立车道并行"按文件冲突面判，不按难度。

### 7.1 恢复绿门（P0，前置） ✅ **已落**
- 问题：`dart-format` 1 文件漂移 + `dart-analyze` 42 error，全部来自在飞改动；任何后续审计/重构都会踩在红树上。
- 证据：`ui/lib/src/search_landing.dart:78,178`；`ui/test/recommend_quick_action_test.dart:40,110`、`ui/test/search_landing_test.dart:29`。
- 方案：等在飞车道把 lib 改完 → 同步 6 个测试 → 对改动文件跑 `dart format` → 再跑 `tools/ci-gates.sh dart-format && dart-analyze`。可选：加 `.git/hooks/pre-commit` 只对 staged `.dart` 跑 format。
- 收益：门可信。风险：低。量：小。并行：**否**（必须串在在飞车道之后）。

### 7.2 FFI 面按域拆分 + 清死面 ✅ **已落(v0.29.0, T2)**: `api.rs` 3334→380 行, 按域 14 个 `api/*.rs` + Dart barrel + 手写 `api_all.dart` 入仓
- 问题：`api.rs` 3334 行单文件、158 函数，其中 64 个挤在 `api.rs:2365-3247`；6 个函数 UI 零调用。
- 证据：`api.rs:2365` 段标题；`api.rs:1560/955/1538/1505/877/632`；Dart 侧 85/161 文件直连生成物。
- 方案：① 把 `api.rs` 拆成 `api/search.rs / api/me.rs / api/playback.rs / api/social.rs`（frb 支持多模块，`#[frb] pub use` 或保持 `api.rs` 只做 `mod`+`pub use`）；② 6 个死面标 `#[frb(ignore)]` 或补 UI；③ `mirror` 清单单独成 `dto.rs` 并加注释"改这里 = 改 Dart API"。
- 收益：meta 控件热文件冲突下降；生成物体量可测地缩小（6/158 ≈ 4% 函数 + 相关 DTO）。风险：低（纯搬移 + 标忽略，行为不变；需重跑 codegen 三步）。量：中。并行：**是**（`api.rs` 目前只有本类改动）。

### 7.3 消掉歌词打分的 Dart 镜像 ✅ **已落(v0.29.0, T3)**: 打分/阈值/择优唯一事实源在 Rust, Dart 只转发 + 真 Rust parity 测试
- 问题：同一套阈值/权重/择优规则在 Rust 与 Dart 各一份，且各有单测。
- 证据：`lyric_source.dart:45,58,61,160,233` ↔ `ttml_source.rs:21,24,27,129,247,311,435`。
- 方案：把"打分/择优/理由"整段下沉到 Rust（已有 `word_lyric_with_fallback`（`ncm-service/src/lib.rs:27 pub use`），只把结果 + reason 回传），Dart 只保留 loader 注入（`lyric_source.dart:13 LyricSourceLoaders` 的测试价值）。若必须保留 Dart 侧（离线/无 bridge 场景），则改为由 Rust 生成常量 JSON 供 Dart 读取，禁止手抄。
- 收益：单一事实源；少一份 200 行打分逻辑与重复测试。风险：中（涉及切歌主路径与"省一次网络探测"行为；现有 `lyric_source_*_test.dart` 可当回归网）。量：中。并行：**是**。

### 7.4 统一 LRU / 分页小工具 ✅ **已落(`2088352` + T4)**: 新 `ui/lib/src/lru.dart`, 云盘页归位 `PagedListView`
- 问题：3 份手写 LRU；云盘页手写 offset 分页与 `PagedListView` 重复。
- 证据：`cover_art.dart:49`、`cover_palette.dart:365`、`word_lyric_view.dart:638`；`cloud_page.dart:136-164` vs `paged_list_view.dart:123`。
- 方案：抽 `ui/lib/src/lru.dart`（`LinkedHashMap` + `maxEntries`，统一 touch/淘汰），三处替换；云盘页改用 `PagedListView` 的 `nextCursor`（`paged_list_view.dart:16`）或反之把云盘的分页抽成 `PagedListView` 的一种 loader 适配。
- 收益：消 ~3 处重复淘汰逻辑；云盘页少 1 份 `_loadingMore` 状态机。风险：低（各有单测：`cover_palette_test.dart`、`cloud_page_test.dart`）。量：小。并行：**是**。

### 7.5 补最大未直测的两个 home 逻辑文件 ✅ **已落(v0.29.0, T5)**: +37 例直测
- 问题：`home/playback_coordinator.dart`（675 行，播放/歌词/主色/通知栏协调）与 `home/account_actions.dart`（516 行，登录态/红心/账号切换动作）只有间接覆盖。
- 证据：`ui/test` 中 `grep -rln 'src/home/'` 只命中 6 个文件，均不直测这两个；体量见 §2.1。
- 方案：给两者注入现有 fake（`ui/test/support/fakes.dart`、`playback_spy.dart`）写直测：先覆盖"切歌→同步主色/动作态"与"账号切换→重取红心/失效态"两条主链。
- 收益：这两个文件是下一轮重构（§7.7）的安全网。风险：低。量：中。并行：**是**。

### 7.6 全局槽位写入加"结构约束"而非继续加约定 ✅ **①已落(`2088352`)**: `tools/check-global-slots.sh` 进 verify; ②(作用域化)明确不做
- 问题：8 个进程级 `ValueNotifier` 的写入点分散；`runPostFrameIfAlive` 靠人记。
- 证据：`app_shell.dart:50,60,68,189,193,197`、`now_playing.dart:13`、`stream_note.dart:107`、`detail_pane.dart:35`；`lifecycle_guard.dart:19`；未守卫点 `detail_pane.dart:117`。
- 方案（择一，不建议大改）：① 加一道 `tools/check-global-slots.sh`（按 `<notifier>.value =` 匹配，白名单 `app_shell/home_wiring/detail_pane`），照抄 `check-sheet-entry.sh` 的实现；② 更彻底：把这些 notifier 收进 `InheritedNotifier` 作用域（要动 `PlayerBarHost` 在 `MaterialApp.builder` 之外的渲染前提，风险明显更高）。
- 收益：新代码不会悄悄绕过生命周期守卫。风险：低（①）/中（②）。量：小（①）/中（②）。并行：**否**（`app_shell.dart` 是公共热文件）。

### 7.7 拆 `home/home_page.dart`
- 问题：1907 行 / 46 方法，逻辑（播放、搜索跳转、账号、更新提示）与布局（5 tab + 歌词页 + 主从分栏）混在一个 State。
- 证据：`:127 _retryLast`…`:1082 build`…`:1380 _buildTabPages`；既有 4 个"协调器/控制器"文件（`home/playback_coordinator.dart`、`home/lyric_controller.dart`、`home/search_controller.dart`、`home/song_action_wiring.dart`）说明拆分方向已定，只是主文件没跟着瘦。
- 方案：按"行为"而非"行数"切：`_playFromList/_next/_previous/_guideNext` → coordinator（已有）；`_openExact*/_openSearch*/_openDiscover/_openRecent` → `home/navigation.dart`；`_buildTabPages/_buildTabPage/_buildSearchTab/_buildList` → `home/tab_builder.dart`。每步之后跑 `flutter test ui/test/home_wiring_stack_test.dart app_shell_first_frame_test.dart tab_switch_popups_test.dart`。
- 收益：单文件从 1907 降到 ~700，tab 结构调整不再碰播放逻辑。风险：中高（回归面是"整个首页"，且依赖全局槽位时序）。量：大。并行：**否**（热文件，必须独占）。

### 7.8 UI 根目录按域继续迁移
- 问题：120 个根文件 vs 41 个子目录文件；barrel 与目录同名（`discover.dart`/`discover/`）造成双入口。
- 证据：`discover.dart:5-12`、`detail_page.dart:7-12`、`feed_view.dart:5-8`、`messages_page.dart:11-19`。
- 方案：按风险从低到高迁：`settings/`（`settings_view.dart` 1049 + 4 个 `settings_*_page.dart`）→ `mine/`（`mine_view.dart` 1051 + `my_collections_page` 等）→ `artist/`（1000 + `artist_sections/artist_nav`）→ `user/`（794 + `user_list_page/user_nav`）。每批只做"移动 + 根目录留 barrel + 更新 import"，不改行为，独立提交。
- 收益：定位成本下降；后续 §7.7 类拆分有落点。风险：中（纯 import churn，但 diff 大、易与其它车道冲突）。量：大。并行：**仅顺序**（跨多域，与所有 UI 车道冲突）。

### 7.9（可选）`ncm-plugin` 的接线或显式隔离 ✅ **隔离已落(`2088352`)**: 主门禁 `--exclude ncm-plugin` + 独立门 `rust-plugin`(21 例); 接线 = 插件切片 2, 待拍板
- 问题：workspace 成员但无人依赖，每轮 `rust-lint/rust-test` 都为它付时间。
- 证据：`core/Cargo.toml:8,24`；`docs/remaining-batches.md:198`。
- 方案：二选一——接 `ncm-ffi`（切片 2 的活，量大）或从 `members` 移出（保留目录、用独立 workspace 或 `--exclude` 在门禁里跳过，能力不丢、门禁变快）。
- 收益：门禁时间。风险：低。量：小。并行：**是**。

## 8. 未覆盖 / 需要后续补的

- 没有做运行时剖析（启动耗时、帧时间、内存），本报告只覆盖静态结构。
- `core/vendor/ncm-api`（上游移植）未审：按 AGENTS.md 是钉死上游、不该改的部分。
- Android 原生层（`ui/android/**` Kotlin：Media3/MediaSession/登录 WebView）不在本次维度内；只核对了门禁口径（`android-unit`/`android-lint`）。
- 本文件未登记进 `docs/README.md` 索引（本轮只允许写本文件）；如需纳入 docs 索引导航，由后续文档车道补一行。
