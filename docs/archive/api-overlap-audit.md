# API / 实现重叠审计（netease-mini-player）

> 只读静态审计：阅读 + rg 计数，**未跑 cargo / flutter**（避开 `core/target` 锁）。口径复算 `bash tools/api-coverage.sh`。
> 权威基线（脚本输出）：vendor endpoint **382** / service 已调用 **118(30%)** / FFI 导出 **125** / 脚本判"无 UI 入口" **3**。
> ⚠ 数字为 2026-11-07 快照；P1 裁剪与 D1/D2/D5/D7 落地后(2026-11-10 复核)FFI 导出为 **132**, endpoint **118**, 无 UI 入口仍 **3**。以 `docs/api-coverage.md` 为准。
> **本审计推翻了其中 1 个：`lyric_lines_i18n` 其实有 UI 调用，是口径脚本 camel 误判（见 §4/附录）。真死导出 = 2。**

---

## 0. 结论 + 建议删除清单摘要

**一句话结论**：代码已高度去重，**"接口语义重叠"绝大多数是"同名不同义"（provider 已用 `kind/area` enum 合并，非重复实现）**；审计清单里"重复 friendlyError 分支""超长函数 >200 行""47 个 Capability"三条**均与实测不符**（实际：错误映射集中在 1 处、netease.rs 无 ≥150 行函数、Capability 实为 35 个）。真正可省的只有三块，且都不紧急。

### 建议删除清单（全为只读接口，零协议风险）

| # | 删除项 | 位置 | 证据(grep 计数) | 风险 | 受影响文件 |
|---|---|---|---|---|---|
| D1 | FFI `search`（单类型搜索） | `ncm-ffi/src/api.rs:160` | UI `rust.search\b`=**0**；已被 `search_all`(:226) 取代；provider.search 仍被 CLI 用(`ncm-cli/src/main.rs:133`)，删的是 **FFI 导出**非 provider | 零（只读，且 CLI 不走 FFI） | api.rs（删 fn+其 `SearchResultDto`）、frb_generated.rs 重生成、docs §6 |
| D2 | FFI `lyric_lines`（无翻译逐行） | `ncm-ffi/src/api.rs:607` | UI `rust.lyricLines(` =**0**；UI 只走 `wordLyricLines`→`lyricLinesI18N`→`lyric`(main.dart:843/875/901) | 零（只读） | api.rs（6 行）、frb 重生成、docs |

> `lyric_lines_i18n` **不在删除列**——它被 `main.dart:875 rust.lyricLinesI18N` 调用，脚本因 camel(`I18n`) ≠ frb 生成名(`I18N`) 误报。**先修 `tools/api-coverage.sh` 的 camel 函数**（数字结尾要 `i18n`→`I18N`），再据脚本重判。

### 不删但值得记的"重叠"（两边都在用，删任一都掉功能）
`album_new` / `album_newest` / `personalized_newsong`、`toplist_detail` / `toplist_detail_v2`、`lyric` / `lyric_new`、6 类评论 → 详见 §1，均为不同产品问题，**provider 层已合并**（`comments(kind)` 单方法打 7 个 endpoint）。

**需要用户决策的项**：见文末"待决策"。审计范围内**没有发现任何应删的写接口**（follow/like/playlist_edit/comment_delete/reply/sign_in 等写接口全部有 UI 入口且在用）。

---

## 1. 接口语义重叠（同一产品问题的同义对）

判定：把 provider 方法按"能否被另一个方法+参数覆盖"分组。★=真重复可删 / ◐=重叠但各喂不同 UI / ○=同名不同义已合并。

### 1.1 搜索族 — ○ 不重复
已接：`cloudsearch`(×2)、`search_suggest`(×3)、`search_default`、`search_hot`、`search_hot_detail`、`search_multimatch`。
- provider `search()` vs `search_all()`：`search` 单类型、`search_all` 多类型(`SearchBundle`)。**UI 只用 search_all**（searchLanding/search_results 全走 `rust.searchAll`，`rust.search`=0）。→ `search` 是**死代码**（见 D1），删之不影响 UI。
- `search_multimatch` 已在 service `netease.rs` 接入（`search_all` 内部），但 **docs §3-P0 仍把它列为"未接入搜索增强"——文档漂移**。
- suggest/hot/default 各喂搜索落地页不同控件，无重叠。

### 1.2 新歌新碟族 — ◐ 三个都在用，但语义可再压
`personalized_newsong`(新歌速递 6 首预览) / `album_new`(新碟·分地区) / `album_newest`(精选新碟·固定12无分页)。
- 三者产品问题不同（新歌 vs 新碟 vs 编辑精选），provider 分方法：`new_songs`/`new_albums`/`new_songs_by_area`/`new_albums_by_area`/`newest_albums`。
- **docs 自相矛盾**：§2 说 `album_newest`"与 `album_new` 不同"，§3-P0 又说它"与已接入的新碟基本重复"。实测两者**都接、都进 UI**（all_charts/new_release 页）。建议只统一文案，不删。

### 1.3 榜单族 — ○ 各喂不同页，已合并
`toplist_detail`(provider `charts()` → `chartList`，recommend_view.dart:85 横排) / `toplist_detail_v2`(`toplist_catalog()` → `toplistCatalog`，all_charts_page.dart:69 全 45 榜)。
- `toplist`、`toplist_artist` **未接入**（service grep=0），与 docs 一致，属未做非重叠。
- 两版 detail 语义不同（单榜详情 vs 榜单目录），UI 各走其一，**保留两个**。

### 1.4 取链族 — ○ 只用 v1，其余本就没接
service 仅 `song_url_v1`(×1)。`song_url`(0) / `song_download_url`(0) / `song_url_v1_302` / `song_url_match` **全部未接入**（docs §5 已列"不建议实现"）。→ **无重叠，无删除动作**，provider `song_url()` 已只包 v1。

### 1.5 歌词族 — ★1 真死 + 其余各司其职
`lyric`(行级 LRC) + `lyric_new`(逐字 yrc) **都接**(`netease.rs:1147/1157`)，UI 有回落链（yrc→i18n→plain）。
- **D2**：FFI `lyric_lines`(无翻译) UI=0，真死。
- `song_lyrics_mark*`(4 个收藏歌词接口) **未接入**，属未做非重叠。

### 1.6 评论族 — ○ provider 已合并（正确做法范例）
13 个 `comment_*` endpoint 全接，但 **provider 只有 `comments(kind)` 一个方法** 打 music/playlist/album/dj/mv/video/event 七个目标；`comment_like/floor/reply/hot/info_list/delete` 各自独立动作，非重复。**无冗余可删**，是 provider 抽象正面样板。

### 1.7 用户/动态族 — ○
`user_account`/`user_detail`/`user_follows`/`user_followeds`/`user_record`/`user_subcount`/`event`/`follow`/`resource_like` 各喂不同页。`follow_counts()`(provider) 已导出但 **资料卡数字来自 `profile_detail`**（docs §6 已记），可作刷新补一次，不删。

### 1.8 推荐族 — ○ 无重叠
已接 `recommend_songs`/`recommend_resource`/`personal_fm`/`playmode_intelligence_list`/`history_recommend_songs`/`recommend_songs_dislike`/`fm_trash`/`personalized_newsong`，**每个回答不同问题**。docs 担心的 `personalized`/`personalized_djprogram`/`recommend_playlist`/`daily_songs` **全部未接入**。
- 但 UI 层有**重复调用**：`dailyRecommendSongs`/`Playlists` 被 `discover.dart:27-28` 与 `recommend_view.dart:75-77` **各抓一次** → 见 §4。

### 1.9 电台族 — ○ 15 个 dj_* 各不同，全在用
`dj_hot/detail/program/program_detail/sublist/catelist/category_recommend/recommend_type/toplist/toplist_hours/newcomer/pay/popular/program_toplist/subscriber`，对应"推荐/详情/节目/订阅/分类/榜单"不同视图，**无重复**。

---

## 2. Provider 层冗余（Capability 粒度 / 同 DTO 合并）

**实测**：`ncm-provider/src/lib.rs` Capability 枚举 **35 个变体**（`lib.rs:30`–`80`），**非 47**（任务书口径偏高 12）。trait `Provider`(`lib.rs:263`–`1006`) 共 **124 个 `fn`**，扣 `id/name/capabilities/supports` 元数据 = **约 104 个 API 方法**（≈ 118 endpoint 量级，因部分方法复用同一 endpoint、部分 endpoint 被一方法多调）。

- **粒度重叠**：**未发现** v1/v2 双 Capability。榜单只有 `Chart` 一个 cap，内部 `charts()` + `toplist_catalog()` 两方法(detail vs v2)共用一个 cap；`NewRelease` 一个 cap 内部 5 方法。即"双实现"发生在**方法级而非 cap 级**，cap 粒度干净。
- **同 DTO 只差参数可合并**：按返回 DTO 归并，候选集中三族——`Vec<Song>` **12 个**、`Vec<Playlist>` **7 个**、`Vec<AlbumItem>` **5 个**。
- **"可被现有方法组合表达"估计**：这 24 个方法来源 endpoint 不同、parse 函数不同，**不能靠参数合并成一个**；能合并的是**签名风格**（统一 `songs(SongSource)` 带 enum），属**可读性收敛**非"减维护面"。真正可删的死方法：trait `search()`（仅 CLI 用）可下沉 CLI helper 或标 `#[deprecated]`。**净可删 provider 方法 ≈ 0–1**（架构健康）。

---

## 3. 实现可精简（netease.rs / ncm-ffi/api.rs）

### 3.1 重复 parse 样板 —— **已高度抽象，无大块可抽**
helper `str_of(v,key)` 用 **237** 次、`u64_of` **170** 次、`.map_err(map_error)` **111** 次。剩唯一重复是 `body.get(k).and_then(Value::as_array).map(|a| a.iter().filter_map(parse_x).collect()).unwrap_or_default()` 列表解析样板（`.filter_map(`=73、`.unwrap_or_default()`=172 里占比大）。可抽 `list_of(body,key,parse_x)->Vec<T>`，触及 ~40–60 处 × 平均 4 行 ≈ **省 120–180 行**，改动面大、纯收益一般，**低优先**。

### 3.2 重复 friendlyError / ProviderError 分支 —— **不存在（前提不成立）**
netease.rs 错误映射**已全部集中**：`map_error()`(`netease.rs:329`) + `map_code()`(:344) + `check_body()` + `take_body()`。全文件仅 **5 处** `ProviderErrorKind::*` 直接出现，均在这几个集中点。FFI 侧统一 `.map_err(|e| e.to_string())`。**无可删重复分支。**

### 3.3 超长函数(>200 行) —— **0 个（前提不成立）**
netease.rs 318 个函数，跨度分布：1–19 行 **191**、20–49 **121**、50–99 **5**、**≥100 仅 1 个**：`parse_feed_events`(L5005, 120 行)。最大 120 < 200。**无可拆目标**；若非要动，只 `parse_feed_events` 一处可切"事件头/资源块/评论预览"。

### 3.4 同一 DTO 三层各定义一次 —— **74 组**（最大精简点，但改造重）
- domain `ncm-domain/src/lib.rs`：**74** 个 `pub struct/enum`（1403 行）。
- ffi `ncm-ffi/src/api.rs`：**74** 个 `pub struct *Dto`，约 **646 行**是 Dto 结构体定义；`impl From` = 0，转换用**内联 `.map()` 闭包**（api.rs 内 `Dto` token **307** 次）。
- frb 生成 dart：76 class / `api.dart` 3553 行（生成物，不算人工）。
- 即**同一数据结构 domain + ffi 各写一遍**。frb 2.13 支持给 domain 类型直接打 `@dart_api` 透传 → 理论可删 74 Dto struct(~646 行) + 内联转换闭包(~400 行) = **api.rs 有望减 ~1000 行**。**代价**：domain 引入 frb 依赖/注解，跨 crate 契约耦合，需全量回归。→ **列"可选大重构"，非本轮删减。**

### 3.5 `ncm-ffi/api.rs` 薄封装 `Ok(provider().x().await?)` —— 34 个，其中 ~20 可宏生成
125 个导出按函数体行数：**thin(≤6行) 34** / mid(7–15) 36 / thick(≥16) 55。
- 34 个 thin 里，**纯 provider 转发**约 **20 个**（set_liked / like_event / set_album_subscribed / create_playlist / delete_playlist / rename_playlist / update_playlist_desc / remove_from_playlist / dislike_recommend_song / trash_fm_song / history_recommend_dates / new_songs / follow_counts / signin_status / sign_in / user_level / style_preference / podcast_hot / radio_recommend / search_suggest_keywords），形态统一 `let p=with_provider(Capability::X)?; p.method(args).await.map_err(friendly)`。
- 其余 ~14 个是 player_* / accounts / search_history 等**本地状态**，非 provider 转发，宏化无意义。
- **方案**：声明宏 `ffi_forward!(fn 名(参数) => via Capability::X: provider.方法(参数))`，展开成上面 3 行 + frb 签名。覆盖 ~20 函数，**净省 ~60–100 行**，新增同类接口少写样板。**风险低**，**收益中小**。

---

## 4. UI 冗余（重复页面 / 三件套复用率 / 无入口 FFI）

**45 个业务 dart 文件、19,387 行**（不含生成 `src/rust/`）。

### 4.1 "三件套(分页+空态+错误重试)" —— 只有 1/3 被抽象，且抽象体不是组件
- `net_retry.dart` **不是 Widget**，是函数库：`isNetworkError()` + `retryNetwork<T>()` + `friendlyError()`。**被 27 个 dart 文件 import**（复用率高 ✓）。
- 但 **"分页"与"空态"无公共实现**：空态文案(暂无/还没有/…)手写 **31** 处、错误/重试文案 **22** 处散落各页（all_charts/new_release/playlist_square/messages/radio_* 等列表页各写各的 `if(isEmpty) 空态 else ListView` + 触底 loadMore）。
- 建议：抽 `PagedListView<T>`(数据源+loadMore+空态+错误重试) 公共 widget，替换 ~12–15 个列表页、省 **~300–500 行 dart**。**中优先、纯 UI 零协议风险**。

### 4.2 重复页面/详情 —— 无整页级重复，但有**重复取数**
- 列表/详情复用良好（`showPodcastDetail`/`showAlbumPreview`/`showSimilarSheet` 被多处调用）。
- **重复抓数**：`dailyRecommendSongs`/`Playlists` 在 `discover.dart:27` 与 `recommend_view.dart:75` **各调各的**（同一份日推抓两次）。→ 抽 provider/cache 层或在 discover 里向 recommend_view 传回调，省一次网络往返。
- 3 个"无 UI 入口"FFI 复核：**真死 2 个**（`search`、`lyric_lines`），`lyric_lines_i18n` 是误报。

---

## 5. 删减候选清单（证据 / 风险 / 受影响文件）

| ID | 动作 | 证据 | 风险 | 受影响文件 |
|---|---|---|---|---|
| **D1** | 删 FFI `search`(`api.rs:160`,54行) + `SearchResultDto` | UI `rust.search\b`=0（`search_all` 取代）；provider.search 仍服务 CLI，不受影响 | 零（只读导出） | api.rs / frb_generated.rs / docs §6 |
| **D2** | 删 FFI `lyric_lines`(`api.rs:607`,6行) | UI `rust.lyricLines(`=0 | 零（只读） | api.rs / frb 重生成 |
| D3 | 修 `tools/api-coverage.sh` camel：`i18n`→`I18N` | 脚本产 `lyricLinesI18n`，frb 生成 `lyricLinesI18N`，差一大写→误报 | 低（工具） | tools/api-coverage.sh / docs §1/§6 |
| D4 | 同步文档漂移 | `search_multimatch` 实已接(§3-P0 未更新)；`album_newest` §2 与 §3 矛盾；§6 "search 可直接删"未落 | 低（文档） | docs/api-coverage.md |
| D5(可选) | FFI 转发宏覆盖 ~20 薄封装 | §3.5 | 低 | api.rs |
| D6(可选) | `PagedListView` 公共 widget | §4.1 | 低 | 12–15 个 UI 页 |
| D7(可选大改) | frb 直接透传 domain 类型，删 74 Dto | §3.4 | **中高**（跨 crate 契约+全量回归） | domain/lib.rs / api.rs / frb |

> **不删清单（明确保留）**：`album_new`/`album_newest`/`personalized_newsong`、`toplist_detail`/`toplist_detail_v2`、`lyric`/`lyric_new`、6 类评论、15 个 dj_*、recommend 全族、以及全部写接口（follow/like/playlist_edit/comment_delete/reply/sign_in/set_follow/event_forward）——均有 UI 入口且回答不同产品问题。

---

## 6. 量化收益（全量执行 D1–D7 的估计）

| 类别 | 减少行数(约) | 减少 endpoint/导出维护面 | 协议风险 |
|---|---|---|---|
| D1 FFI search | api.rs ~60 | -1 FFI 导出 | **零（只读）** |
| D2 FFI lyric_lines | api.rs ~8 | -1 FFI 导出 | **零（只读）** |
| D3/D4 文档/工具 | ~0 | 口径可信度↑ | 无 |
| D5 转发宏(§3.5) | api.rs ~60–100 | 0（样板消失） | 零 |
| D6 PagedListView | dart ~300–500 | 0 | 零 |
| D7 domain 透传 | ffi ~1000（74 Dto+闭包） | -74 人工 DTO | **中**（frb 契约/回归） |

**分层小计（保守，仅低风险 D1+D2+D5+D6）**：
- provider(ncm-service/provider)：**~0 行**（已健康：无死方法/无超长函数/无重复错误映射）
- ffi(ncm-ffi/api.rs)：**~130–170 行**（D1+D2+D5）
- dart(ui 业务)：**~300–500 行**（D6）
- 合计 **~430–670 行** 低风险可减；加 D7 可达 **~1400–1800 行**但需全量回归。

**协议风险总评**：D1–D6 **全为只读接口/前端样板/文档，删除零协议风险**。D7 不改网络行为，只改类型透传路径。**本轮无任何"删写接口"建议**（不存在死写接口）。

---

## 待用户决策
1. **D7 是否做**：删 74 个 FFI Dto、让 frb 直接透传 domain——收益最大(~1000 行)但要给 domain 加 frb 注解、跨 crate 契约变动、需完整双端回归。建议**排在 vendor 裁剪车道之后**再单独开一车道。
2. **D5/D6 是否现在做**：纯样板收敛、零协议风险，但改 `ncm-ffi/*`（触发 frb 重生成）与多页 UI，**可能与当前占用 target 的车道冲突** → 需排队。
3. **文档口径**：是否授权改 `tools/api-coverage.sh`(D3) 并同步 `api-coverage.md`(D4)——只动脚本/文档、不动代码，可安全并当前车道。

---

## 附录：审计方法与口径修正
- 计数：`grep -oE | wc -l`/`python3` 静态解析；函数跨度用花括号配平；**全程未跑 cargo/flutter**。
- **推翻任务书/文档 3 处**：① Capability 实为 35（非 47）；② netease.rs 无 >200 行函数（最大 120）；③ 错误映射无重复（集中 `map_error`|`map_code`|`check_body`|`take_body`）。
- **推翻 `api-coverage.sh` 的"无 UI 入口"1 项**：`lyric_lines_i18n` 有调用(main.dart:875)，因 camel 不处理数字尾大写；真死导出 = `search`、`lyric_lines` 共 **2**。
- 关键 file:line：Capability `lib.rs:30` / trait `lib.rs:263` / map_error `netease.rs:329` / parse_song_with `netease.rs:734` / FFI search `api.rs:160` / FFI lyric_lines `api.rs:607` / net_retry 库 `ui/lib/src/net_retry.dart`。
