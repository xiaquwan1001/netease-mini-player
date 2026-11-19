# 轻音 MiniNCM — UI/API 整合改造方案（2026-11-13）

来源：5 条只读分析 lane（.pi/analysis/2026-11-13/{msg,search,artist,reco,api}.md）+ 主会话实测复核。

## 0. 结论先行

- 用户报的 10 条里，**3 条是「现状已正常」**（评论头像跳转、搜索分类枚举、API 无 serde_json::Value）；
- **3 条有精确根因且改动很小**（心动 icon 重复、消息角标、网格末端空隙）；
- **2 条是真回归/真缺陷**（「查看全部」点了不动、「艺人页专辑封面被拉成细条」）；
- **2 条需要用户拍板**（私信发送要不要逆协议、搜索分类如何复现）。

实测补充：匿名跑 `ncm-cli searchall "晴天"` 返回 songs=30 / artists=10 / albums=10 / playlists=10 / podcasts=10
⇒ 搜索分类的数据侧是好的，问题在 UI 呈现策略（空分类直接隐藏 chip）。

---

## 1. 「我的」→ 消息中心：去红点角标，改文字（改动最小）

- 现状：`mine_view.dart:826-831` Badge 包 Icon，数字 total；副标题已输出「私信 n · 通知 n · 评论 n」。
- 改：leading 只留 `Icon(Icons.forum_outlined)`；副标题补「@我 n」一项（`counts.forwards`）。
- 顺带修刷新：计数只在 initState 拉一次（`mine_view.dart:802`）+ `AutomaticKeepAliveClientMixin`，从消息页返回不刷新。改 `main.dart:3176` 的 onOpenMessages 为 await 后回调刷新。
- 风险：低（纯展示层）。

## 2. 消息中心「填充」而不只读（需要拆两件事）

**2.1 评论回复**（可落地，已有 Rust 能力）
- 已有 `reply_comment(threadId, commentId, content)` / `delete_comment`（api.rs:2518/2631），评论线程 UI 已用。
- 缺口在**数据**：`InboxItem{id,kind,actor,avatar_url,text,detail,time_ms}`（ncm-domain lib.rs:916）没有 `user_id/thread_id/comment_id`，消息页无从跳转或回复。
- 方案：ncm-provider 解析 notice/comment 消息时补 `user_id`、`thread_id`、`comment_id` 三字段 → 三步 codegen → 消息项可点开线程并回复（复用 comment_thread 的回复框）。

**2.2 私信发送**（★需拍板）
- vendor（锁定 commit）**没有任何发私信 API**：只有 msg_private / msg_private_history / msg_recentcontact / notices / comments / forwards。
- 方案 A（安全）：私信页保留只读，加「复制内容 / 在官方客户端打开」出口，不做发送。
- 方案 B（要逆协议）：自行实现 weapi/eapi 发送端点（/api/msg/web/send 一类），属**新增协议封装**，与「不重写加密、只用 vendor」的项目规则冲突，且风控未知。
- 建议：先做 A；B 作为独立实验 lane，且必须先抓包验证再动代码。

**2.3 消息项点击行为**
- @我/评论/通知三类 ListTile **完全没有 onTap**（`messages_page.dart:576-605 / 668-694`）；私信项只弹只读 Sheet。
- 修：有 thread 数据的跳评论线程，没有的至少跳用户主页（见 §5）。

## 3. 搜索分类（★需复现词）

- 现状：`search_results.dart:46-74` 五个分类（单曲/歌手/专辑/歌单/播客），**按数据非空动态显示**。
- 因此「只看到单曲/专辑/播客」= 该次搜索的 artists 与 playlists 同时为空（或 chip 条横滑被裁）。
- 改（无论能否复现都该做）：
  1. 分类条**始终显示全部 5 个**，空分类进入后显示「该分类没有结果」，不再隐藏（消除「分类消失」的困惑）；
  2. chip 条改 `Wrap`（或等分 TabBar），避免窄屏横滑把后几个藏起来；
  3. `search.rs:71-110` 侧栏失败被 `result_of(...).ok()` **静默吞成空**，改为把侧栏错误透出（至少在 UI 标注「歌手加载失败」而不是假装没有）。
- 「电台」是新分类，不是回归：cloudsearch 1009 目前映射到播客（声音）；电台要另验 type，属**新增功能**，单独立项。

## 4. 心动模式 icon 与每日推荐重复（一行修）

- `recommend_view.dart:319` 每日推荐 = `auto_awesome`；`player_bar.dart:316` 心动档也用 `auto_awesome`；`recommend_view.dart:327` 心动入口却是 `bolt`。
- 最小修：`player_bar.dart:316` 改 `Icons.bolt`（与推荐页心动入口一致，每日推荐继续独占 auto_awesome）。
- 备选：心动全 App 统一 `local_fire_department`（两处一起换）。
- 风险：modeIcon 会同步 Android 通知（`playback.dart:102`），需在 Kotlin 侧确认没有图标名硬编码。

## 5. 头像进个人主页（基本已覆盖，缺口集中在消息中心）

- 已全量覆盖：comment_thread.dart:926/1034/1314 三处主楼/回复/楼层头像均走 `UserAvatarTap`；歌单/播客/MV/动态评论都复用 CommentThread；关注/粉丝列表整行可点。
- 真缺口：
  - `messages_page.dart:658` @我（ForwardItem 有 user_id）→ 包 UserAvatarTap；
  - `messages_page.dart:309` 最近联系人（RecentContact 有 user_id）→ 同上；
  - `messages_page.dart:575` 通知/评论页签 → 缺 user_id，随 §2.1 一起补字段；
  - `messages_page.dart:247` 会话列表头像（PrivateSession 有 user_id）→ 包里层，整行仍弹聊天。

## 6. API 去重与统一（低风险，先做 P0）

- **P0（安全）**
  1. 删两个 UI 零调用的死导出：`lyric_lines_i18n`(api.rs:917)、`word_lyric_with_fallback`(api.rs:1052)（删前 rg ncm-cli）。
  2. `account.rs:32-56` `profile_detail` / `user_profile` 是同一 user_detail 端点的两份近逐字实现 → 收敛为私有 `user_detail_raw(uid: Option<u64>)`，trait 面不变。
  3. 歌词回落编排 Rust/Dart 各一份（`ttml_source.rs` vs `main.dart:1564-1565`）→ 单一来源。
- **P1（有回归面，等 UI 批次一起做）**：分页参数统一 `(..., limit, cursor)`（`artist_songs_page` offset 在前、`last_time`/`last_time_ms` 类型混用）；`artist_sub_toggle` → `set_artist_subscribed(…, on)`。
- **纪律**：读=名词短语，写=动词短语，布尔开关统一 `set_x(id, on: bool)`；DTO 保持全具名（现状 0 处 serde_json::Value，已达标）。

## 7. 网格排版：列数设置 + 均分 + 封面恒方

根因（三处同款）：`SliverGridDelegateWithMaxCrossAxisExtent(max:160/180, childAspectRatio:0.72)` —— aspect 是按 160 宽拍死的，实际列宽随屏宽变化后高度不再贴合 ⇒ 文字下留白 / 封面被压。
- `artist_page.dart:644` + 668 `Expanded(CoverArt)` ⇒ 封面被拉成细长条（**用户报的第 10 条**）。
- `new_release_page.dart:318`、`playlist_square_page.dart:133` 同隐患。

修法（一次做完，避免第三份重复）：
1. `AppSettings` 新增 `int gridColumns = 3`（照 `coverRows` 四件套：字段/load/update/JSON），设置页「通用」分组加 2–4 分段选择；
2. 抽公共 `coverGridDelegate(context, columns)`（放 layout.dart）：列宽 =(宽-(n-1)gap)/n，高 = 列宽 + gap + 两行文字实测高 → `childAspectRatio = w/h`；
3. 三处网格改 `FixedCrossAxisCount(crossAxisCount: gridColumns)`；`artist_page.dart:668` 的 `Expanded(CoverArt)` → `AspectRatio(1, CoverArt)`。
- 风险：文字行高需按 textScaler 计算（照 `cover_row.dart:82-86` 既有做法）；列数下限 2。

## 8. 搜索建议开关搬到搜索页 + 热门搜索常驻

- 现状：开关在设置页（`settings_view.dart:140-163`，`showHotSearch`），搜索页 `search_landing.dart:79` 读它决定是否整块渲染；热门榜一次渲染全部条目、无折叠（:166-197）。
- 改：
  1. 删设置页那条 SwitchListTile；
  2. 搜索页**热门搜索栏常驻**，标题右侧放按钮（展开/收起 + 关闭）；
  3. 折叠态只留标题一行；关闭态按钮变成「开启」并直接 `AppSettings.instance.update(showHotSearch: true)`，空态文案去掉「在设置里」；
  4. 展开态建议会话内不持久化（要持久化就加 `hotSearchExpanded`，向后兼容靠现有 `is bool` 防御）。

## 9. 艺人页 / 用户页模板统一

- 骨架其实**已经统一**：两页都用 `ProfileScaffold`（user_page.dart:209、artist_page.dart:278），tab 也统一按数据可用性生成。
- 剩下的割裂在 `sections`：艺人页塞了「相似歌手/简介/推荐单曲/专辑/详细艺人」5 块，用户页 `sections` 为空。
- 改：section 抽成同一组可选组件（`if (数据非空)`），用户页补「简介（签名）/热门/专辑」等能拿到的块，两页共用同一顺序与同一批 widget；缺数据整块不渲染（机制已有）。
- 「详细艺人」条目：来自 `detail.briefDesc` / 艺人资料弹层（`artist_page.dart:431-437`），与上方「简介」重复且命名含糊 → 建议并入「简介」区（尾部「更多资料」），或直接删除。

### 9.1 差异表（lane-artist 实测，详见 .pi/analysis/2026-11-13/artist.md §1.2）

两页共用骨架的事实已确认（git `733bf13` 建骨架、`2332ea2` 迁移艺人页），剩下的 16 项差异里**真正的语义割裂只有 4 项**：

| 差异 | 艺人页 | 用户页 | 处置 |
|---|---|---|---|
| TabBar 之上 `sections` | 5 块（相似歌手/简介/推荐单曲/专辑/详细艺人） | **空** | ★核心：抽成可选区块列表，用户页有数据就填 |
| 顶栏 `actions` / `searchBar` | 有页内搜索 | 无 | 下沉为骨架能力，两页都可开 |
| 统计 chip 配方 | 作品数 + 关注 | 关注/粉丝 + 等级 | 统一为一个可组合 chip 列表（缺字段不渲染） |
| 首屏错误策略 | 三请求独立容错（similar/MV 静默） | `Future.wait` 任一失败 → 整页错误卡 | 统一成"主资料失败才整页错误" |

纯样式漂移（应顺手对齐，否则永远是"两个 App"）：

- 身份卡头像：艺人 64（默认） vs 用户 56；
- 主标题字号：艺人 `headlineSmall` vs 用户默认 `titleMedium`；
- 副标题槽位：艺人装「别名」、用户装「签名」——同一槽位两种语义，需在 `ProfileIdentity` 上拆成 `subtitle` + `aliases` 或明确标注；
- 「我的」页是**第三套视觉**（`profile_header.dart` + 身份卡上浮 12dp），而艺人/他人页平接 —— 建议 `ProfileScaffold` 加 `liftIdentity` 参数把「我的」页也收进来。

重复实现应下沉到骨架：`_onScroll`（offset>90 折叠标题）两份、`_rebuildTabs` 两份。

回归面：`profile_scaffold_test.dart` / `user_page_test.dart` / `artist_page_tabs_test.dart` 的既有断言。
另注：给用户页补 sections 会把 TabBar 顶出首屏 → 必须与 §10「切 tab 要滚动」同批做。

## 10. 「查看全部」/「全部 n 张 ›」点不动 + 字太小

- 点不动根因：`_switchToTab(kind)`（`artist_page.dart:181-187`）只改 `_tabController.index`，**不滚动**；此时用户停在页面上半部（sections 区），TabBarView 内容在折线以下 ⇒ 视觉上毫无反应。修：切 tab 同时 `_scroll.animateTo(maxScrollExtent)`（或先把 NestedScrollView 收起来）。
- 字太小根因：`SectionHeader` 把 trailing 放进 `FittedBox(scaleDown)` 且限宽 45%（`section_header.dart:60-72`），「播放全部 + 查看全部 n 首 ›」放不下就整体缩小。修：把「播放全部」从 trailing 挪出（或改图标按钮），并给 `SectionSeeAllButton` 设最小可读字号，宁可省略标题也不缩按钮。

## 11. 落地顺序（每批都能独立验证）

| 批次 | 内容 | 门禁 |
|---|---|---|
| B1 小修 | §1 角标、§4 icon、§5 三处头像、§10 字体（不含滚动） | `cd ui && dart analyze` + flutter test |
| B2 布局 | §7 网格列数设置、§8 搜索页热搜按钮、§10 切 tab 滚动 | `dart analyze` + 模拟器 a34 目视 |
| B3 模板 | §9 两页 sections 统一、「详细艺人」收敛、§3 分类条常显 | `dart analyze` + 目视 |
| B4 数据/API | §2.1 InboxItem 补三字段（三步 codegen）、§6 P0 去重 | `cargo clippy --workspace --all-targets` + codegen + 回归 |
| B5 待定 | §2.2 私信发送、§3 电台新分类、§6 P1 分页统一 | 需先拍板 |

## 12. 待你拍板

1. **私信发送**：只做「复制/跳官方」(A)，还是逆协议做真发送 (B)？
2. **搜索分类只显示三类**：给一个复现的搜索词（我匿名实测五类都有数据）。
3. **心动 icon**：最小改（播放条改 bolt）还是全 App 统一 `local_fire_department`？
4. **网格列数**默认 3 列（2–4 可选）是否可以？

---

## 13. 落地记录（2026-11-13 当轮已实现）

| 项 | 状态 | 落点 |
|---|---|---|
| ① 角标→文字 | ✅ | `mine_view.dart` 去 Badge，副标题加「@我 n」 |
| ② 私信可回复 | ✅ | vendor `send_text.rs`(weapi `/api/msg/private/send`) → provider/service `private_send` → ffi `privateSend` → 聊天 sheet 底部输入框 |
| ② 评论消息回复 | ⏳ | 需先给 `InboxItem` 补 thread_id/comment_id/user_id（未做） |
| ③ 分类常显 + 最长匹配 | ✅ | `search_results` 恒显示 5 chip + Wrap 换行 + 空分类提示；Rust `prefix_candidates` 空分类按前缀回退（实测「大树王容」→ 6 歌手 / 10 专辑） |
| ④ 心动 icon 统一 | ✅ | `player_bar`/`recommend_view` 统一 `local_fire_department`；每日推荐独占 `auto_awesome` |
| ⑤ 头像进主页 | ✅（消息中心三处）| @我 / 最近联系人 / 会话列表头像包 `UserAvatarTap`；通知页签仍缺 user_id |
| ⑥ API 去重 | 🟡 部分 | 已合并两份 `_ExpandableText` → `expandable_text.dart`；P0 的 `user_detail_raw` 收敛与删死导出未做 |
| ⑦ 网格列数 | ✅ | `AppSettings.gridColumns`(2–4) + `coverGridDelegate` + 三处网格改 FixedCrossAxisCount |
| ⑦ 热搜开关搬搜索页 | ✅ | 设置页删该项；`search_landing` 新增 `_HotSection`（栏目标题常驻 + 展开/收起/关闭/开启） |
| ⑦ 搜索联想纵向分类 | ✅ | `SuggestionPanel` 按 kind 分组 + 分组标题 |
| ⑧ 模板统一 | ✅（骨架+槽位）| 用户页补 `sections`（简介），签名从身份卡副标题移到区块；`ProfileScaffold` 两页共用 |
| ⑨ 查看全部点不动 | ✅ | `_switchToTab` 去掉「同 index 就返回」的 guard + 切完滚到内容区 |
| ⑨ 字体偏小 | ✅ | SectionHeader trailing 上限 45%→60%；「播放全部」改图标按钮 |
| ⑨ 全部 n 张只有 20 张 | ✅ | 新增 `artist_albums_page`(`/api/artist/albums/{id}`) + 专辑 tab 改 PagedListView |
| ⑨ 详细艺人 | ✅ | 删除该条目（内容与页面上方重复） |
| ⑩ 封面细长 | ✅ | `Expanded(CoverArt)` → `AspectRatio(1)`（真实成因：CoverArt 无 size 时 tight 44×剩余高） |
| 测试 | ✅ | 更新 4 个用例、新增私信发送用例；`dart analyze` 0 issue |

### 未做 / 下一轮
- `InboxItem` 补 user_id/thread_id/comment_id（解锁消息→评论线程跳转与回复）
- API P0：`account.rs` 的 `profile_detail`/`user_profile` 收敛；删 `lyric_lines_i18n`/`word_lyric_with_fallback` 两个死导出（删前 rg ncm-cli）
- P1 分页签名统一、`artist_sub_toggle` → `set_artist_subscribed`
- 搜索结果增加「用户」分类（SearchBundle 需要 users 字段）
- 「我的」页并入 `ProfileScaffold`（第三套视觉，liftIdentity）

## 14. 第二轮（同日）：补全消息/搜索/API 归并

| 项 | 状态 | 落点 |
|---|---|---|
| `InboxItem` 补三字段 | ✅ | `user_id` / `thread_id` / `comment_id`（domain + parser + ffi mirror，codegen 已跑） |
| 消息中心通知/评论可点开 | ✅ | 新 `comment_page.dart`（`CommentThread(threadId:)` 独立页）；列表行有线程时显示 chevron 并可点进评论区**直接回复** |
| 消息中心头像 | ✅ | 通知/评论页签头像包 `UserAvatarTap`（全页 6 处齐了） |
| 搜索「用户」分类 | ✅ | cloudsearch type=1002 + `SearchBundle.users` + `parse_search_users` + 第 6 个 chip（走 `UserNav`，测试覆盖） |
| 用户分类最长匹配 | ✅ | 与歌手/专辑同一套 `prefix_candidates` 兜底 |
| `profile_detail`/`user_profile` 双实现 | ✅ | 收敛为 `account.rs::user_detail_raw(Option<u64>)`，trait 面不变 |
| 删死导出 | ✅（部分）| 删 `word_lyric_with_fallback`（UI/CLI 均 0 调用，策略与 Dart `resolveLyricSource` 重复）；**`lyric_lines_i18n` 实际在用**（`main.dart:1566/1617`，lane-api 报告误判为死代码，已纠正） |
| 新增测试 | ✅ | Rust：`thread_from_resource` ×3、`parse_search_users`；Dart：用户分类 chip + UserNav 跳转 |

### 仍未做（需单独立项）
- 「我的」页并入 `ProfileScaffold`（第三套视觉：`profile_header.dart` + 身份卡上浮 12dp）
- P1 分页签名统一、`artist_sub_toggle` → `set_artist_subscribed`
- `InboxItem.thread_id` 依赖 `resourceJson` 的 type/id 约定，**只在解析层做了多形态兜底，未登录态无法实测**；登录后若仍为空，按 .pi/memory/notes-api.md 补一次真实报文采样
