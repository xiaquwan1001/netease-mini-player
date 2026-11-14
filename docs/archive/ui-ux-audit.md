# 轻音 MiniNCM — UI/UX 走查报告(只读审查)

> 审查基线: commit `7b6bfbe`(2026-11)。范围 `ui/lib/main.dart` + `ui/lib/src/*.dart`(44 文件 36.7k 行, 其中 3 个 rust/frb 生成文件不计)。
> 方法: 静态阅读 + 定向 rg 证据链,未改动任何文件、未跑构建。
> 每条结论均附 `文件:行号` 证据,行号对应上述 baseline。

## 结论

**整体判断**:这个 App 的“页面级”质量不差(17 个二级页全有 AppBar 返回、破坏性操作都有确认、空态/错误态都接 `friendlyError` + 重试),
真正拉低体验的是**三个结构性缺口**和**一层“各写各的”组件重复**:

1. **两个核心功能不可达**:评论区没有“写评论”入口(`comment_thread.dart` 全文无输入框),
   播放队列没有任何 UI(`queue.dart` 纯逻辑,界面只有一行 `3/20`)。
2. **返回键语义没做**:全仓 0 处 `PopScope`。歌词页/非首 tab 按 Android 返回键 → 直接退出 App;
   弹层内部的二级层级(日推的历史日期)返回键会跳级关闭。
3. **信息架构错位**:设置里塞了账号/会员/诊断,账号入口散在 3 处,推荐页 8 个平级模块 + 4 种「更多」文案。

**量化**:P0 **3** 条 / P1 **15** 条 / P2 **13** 条;触控 <48dp 的高频控件 6 类;
错误态视觉有 6 种实现、时长格式化有 4 份、SnackBar 有 5 份私有实现;
文字截断覆盖率仅 25%(586 个 `Text` 里 142 个带 `maxLines`);
`300dp + 1.25 字号` 回归只覆盖 45 个测试文件里的 15 个,三个主 tab 都不在其中。

## Top5 先做的事(按 收益/成本 排序)

| # | 事项 | 覆盖条目 | 成本 | 为什么先做 |
|---|---|---|---|---|
| 1 | **返回键语义**:给 `HomePage` 加 `PopScope`,优先级 `歌词 → 底栏回搜索 → 退出` | P0-7.1 | **S**(只改 `main.dart:107/1631` 一处) | 误按返回直接退出应用,伤害频率最高(每天几十次),改动最小 |
| 2 | **`SongTile` 一行修三处**:时长改 `mm:ss`、红心变可点、右侧「...」补到 48dp + 行长按弹菜单 | P1-7.6、P1-7.7、P1-7.12、P2-7.19 | **S**(单文件 `song_tile.dart` + 一个共享 `fmtDuration`) | 这是全 App 复用面最大的组件(搜索/我的/最近听过),一次改动覆盖所有列表 |
| 3 | **评论可发 + 队列可看** | P0-7.2、P0-7.3 | **M**(各半天) | 两个“功能不可达”,用户会当成 bug;`queue.dart` 已是纯逻辑,补 `removeAt` 即可接 UI |
| 4 | **设置瘦身 + 账号入口 3→1** | P1-7.9、P1-7.10、P1-7.11 | **M**(`settings_view.dart` + `mine_view.dart`) | 归属错位是“越用越迷惑”的根源;顺手能修掉“退出登录只在设置里”这个反直觉点 |
| 5 | **推荐页 8→5 模块 + 「更多/全部」文案统一 + 专辑预览改全页** | P1-7.8、P1-7.13、P1-7.5 | **M**(`recommend_view.dart` + `album_preview.dart`) | 首屏认知过载 + 同一语义四种叫法;专辑 Dialog 改全页与歌单详情对齐 |

> 未进 Top5 但建议紧跟:**搜索页去掉重复的「取消」**(P1-7.4,S)、
> **全页列表补底部 safeArea**(P1-7.15,S)、**弹层统一 `SheetHeader` + `showDragHandle`**(P2-7.24,S)。

---

## 0. 结构事实校正

- 底部导航实际是 **5 栏**(不是 4 栏): 搜索 / 推荐 / 关注 / 我的 / 设置,
  `main.dart:1783-1814`;5 个 tab 全部塞进一个 `IndexedStack`,`_tabVisited` 懒构建(`main.dart:1843-1854`)。
- 全局只有一个 `Navigator`,`home: HomePage()`(`main.dart:107`);所有二级页都是 `Navigator.push` 或
  `showModalBottomSheet`(共 59 处入口)。
- 状态: 全部页面 `StatefulWidget` 自持;`MaterialApp.builder` 里只挂了 `AppSettings`(textScale/themeMode)
  和全局 `AppActions`(`main.dart:88-98`)。

---

## 1. 可达性与触控

全仓计数: `IconButton` 32 处 / `tooltip:` 26 处、`ListTile` 84 处(其中 `dense: true` 24 处)、
`VisualDensity.compact` 17 处、`InkWell` 28、`GestureDetector` 11、**`Semantics` 0 处**。

### 1.1 命中区 < 48dp(且都在高频位置)

| # | 位置 | 现象 | 尺寸估算 |
|---|---|---|---|
| A1 | `src/song_tile.dart:151-156` | 歌曲行「...」按钮 `iconSize: 20` + `visualDensity: VisualDensity.compact` | 40×40,低于 48dp 且是全 App 最高频按钮(搜索/最近听过/收藏列表都用它) |
| A2 | `src/detail_page.dart:1116-1124`、`src/artist_page.dart:435-449` | 「展开/收起」是**纯 Text + GestureDetector**,padding `h4/v2` | 约 24×18dp,无水波纹,无 second path |
| A3 | `src/song_actions.dart:99-102` | `SongOverflowButton` 只给 `size`,无 `constraints` | 随 iconSize 缩水;播放条上用 22(`main.dart:2232`) |
| A7 | `src/profile_header.dart:136-166` | 资料头右上「账号管理」药丸:`padding h8/v3` + `Icon 14` + `Text(fontSize: 12)` | 高约 20dp,是全页最不达标的可点元素 |
| A4 | `src/search_landing.dart:60` | 搜索历史 `ActionChip(visualDensity: compact)` | 高约 32dp;这行同时是「删除单条历史」唯一候选位(见 §3) |
| A5 | `src/search_landing.dart:49-52`、`src/podcast.dart:440`、`src/search_suggest.dart:111` | `TextButton.styleFrom(minimumSize: Size(0, 32))` | 32dp |
| A6 | `src/podcast.dart:577-581` | 节目详情关闭键 `visualDensity: compact` + `iconSize: 20` | 40dp |

### 1.2 无按压反馈 / 无语义

- 11 处 `GestureDetector` 全是"无 ink 的可点区域":`main.dart:2174`(播放条封面→专辑预览)、
  `src/feed_view.dart:549`/`:705`、`src/feed_detail_page.dart:219`/`:316`/`:334`(视频/单图/九宫格)、
  `src/cover_art.dart:346`(大图查看器)、`src/detail_page.dart:1105/1116`、`src/artist_page.dart:430/441`。
  对照 Android 惯例: 列表内可点图片应给 ripple 或 scale 反馈。
- **全仓 0 处 `Semantics`**:TalkBack 只能读 Text,读不到"这是搜索按钮/这是第 3 首"。
  最明显的是播放条三个核心键没有 tooltip —— `main.dart:2242`(上一首)、`:2243`(播放/暂停)、`:2248`(下一首)。
- 其余无 tooltip 的 IconButton:`src/detail_page.dart:679`(`_ProgramRow` 的详情键)、`:996`、
  `src/vip_page.dart:188`(返回)、`src/messages_page.dart:449`(关闭)。

### 1.3 列表行高

- 歌曲行 = `ListTile(dense: true)` + 40dp 封面 + 主副两行(`song_tile.dart:106-149`)。M3 下实高约 56dp,
  刚好达线;但 `textScale 1.25` 时上下 padding 被文字吃掉,观感接近 64dp,可接受。
- 歌单详情行是**另一套**自绘行,定高 `_kRowHeight = 56`(`detail_page.dart:757` `itemExtent: _kRowHeight`),
  达线。问题不是高度而是两套实现(见 §4)。
- 唱片区 `_CoverCard`(`src/recommend_view.dart:876` 起)高度由 `AppSettings.coverRows` 决定,
  没有最小高度保护,窄屏 + 两排时封面被压小。

**小结**:触控尺寸问题集中在"小图标 + compact 密度"这一族,收益最高的做法是抽两个组件
(`SongMenuButton`、`ExpandableText`)一次性修掉 A1/A2/A3。

## 2. 手势与返回

**全仓 0 处 `PopScope` / `WillPopScope` / `onWillPop`**(rg 无命中),这是本节所有问题的根因。

### P1-2.1 底栏非首 tab 按系统返回 = 直接退出 App
- 证据:`main.dart:107` `home: const HomePage()`(唯一根路由),无任何返回拦截;
  5 个 tab 是同一路由内的 `IndexedStack`(`main.dart:1843-1854`)。
- 现象:在「推荐/关注/我的/设置」按返回 → 直接退出应用。
- 惯例:网易云/QQ 音乐/微信 = 返回先回首页 tab,首页再按才退出(或 2 秒内双击退出)。
- 最小改法:`PopScope(canPop: _tab == 0, onPopInvokedWithResult: ...)` 里把 `_tab` 复位到 0。

### P1-2.2 歌词视图按返回 = 退出 App
- 证据:歌词是同一路由内的 overlay(`main.dart:1760-1768` `Positioned.fill(child: _buildLyrics())`),
  显隐由 `_showLyrics` 控制;界面上明明有「收起歌词」按钮(`main.dart:1675-1679`)。
- 现象:用户在歌词页按返回,期望"收起歌词回到列表",实际退出应用。
- 最小改法:同上 `PopScope`,优先级 `_showLyrics > _tab > 退出`。

### P1-2.3 弹层内部的二级层级不参与路由栈
- 证据:`src/discover.dart:253-263`:「历史日推」里点某一天后,用 `setState(_date = ...)` 切内容,
  自带一个「返回日期列表」箭头(`IconButton tooltip: '返回日期列表'`,`discover.dart:258-261`)。
- 现象:系统返回键直接关掉整个「每日推荐」sheet,而不是回到日期列表 → 与页内返回箭头语义冲突。
- 最小改法:该分支包 `PopScope(canPop: _date == null, onPopInvoked…: 清 _date)`。

### P1-2.4 账号面板可能溢出(非滚动弹层装可无限增长的列表)
- 证据:`main.dart:1008-1012`:`showModalBottomSheet` **未设 `isScrollControlled`**,
  `SafeArea > Column(mainAxisSize: MainAxisSize.min)`,账号条目 `for (final account in saved)` 无上限(`main.dart:1029-1050`)。
- 对照:同一 App 的「收藏到歌单」(`main.dart:1225-1240`)用固定 60% 高 + `Expanded(ListView.builder)` 兜住。
- 现象:账号多(或大字号)时底部被裁 / RenderFlex overflow。
- 最小改法:与「收藏到歌单」对齐(`isScrollControlled: true` + 固定高度 + `Expanded`)。

### 2.5 弹层关闭路径三种写法(新手要猜)
| 关闭手段 | 位置 |
|---|---|
| `SheetHeader`(标题 + 关闭键,高 52) | `src/detail_page.dart:39`(评论)、`src/song_wiki.dart:31`、`src/podcast.dart:99`、`src/discover.dart:39`、`:425` |
| `showDragHandle: true`(只有拖柄,无关闭键) | `src/comment_thread.dart:285`、`src/feed_view.dart:116`、`src/similar_sheet.dart:27`、`src/digital_album_page.dart:70` |
| 都没有(只能下滑或点蒙层) | `main.dart:1008`(账号)、`:1225`(收藏到歌单)、`:1334`(分享)、`src/song_actions.dart:113`(歌曲动作) |
| 自绘标题(第三套) | `src/podcast.dart:562-586`「节目详情」+ 自己的关闭键 |

最小改法:统一到 `SheetHeader`(有标题时)+ `showDragHandle: true`,四类弹层天然一致。

### 2.6 键盘遮挡
- 只有回复弹层显式处理了 `viewInsets`(`src/comment_thread.dart:771`)。
- 评论主面板是**固定 75% 高**(`src/detail_page.dart:36-38`),目前里面没有输入框(见 §3 P0),
  一旦补上「写评论」,不改这里必被键盘盖住。

### 2.7 二级页 AppBar 返回覆盖
- 17 个 `Scaffold` 页面全部有 `AppBar`(默认带返回箭头),覆盖完整:
  `detail_page:485/893`、`artist_page`、`new_release_page`、`playlist_square_page`、`all_charts_page`、
  `radio_explore_page:145`、`radio_subscribers_page:140`、`user_list_page`、`messages_page`、`medal_wall:351`、
  `digital_album_page`、`vip_page:188`、`feed_detail_page`、`style_page`、`ranking_view`。
- **例外**:专辑预览用 `showDialog`(`src/album_preview.dart:25`),没有 AppBar / 返回键视觉提示,
  只能点蒙层或按返回键 —— 与"歌单详情是全页、播客详情是全页"不匹配(见 §5 ⑤)。

## 3. 可发现性

### P0-3.1 评论区没有“写评论”入口(功能不可达)
- 证据:`src/comment_thread.dart`(874 行)全文**没有输入框**;`TextField` 只出现在 `_RepliesSheet`
  (`comment_thread.dart:843-856`,「回复这条评论…」)。评论入口链:`detail_page.dart:24` `showCommentsSheet`
  → `SheetHeader` + 只读列表 + 每条右侧「回复 N」。
- 现象:用户能看评论、能回复别人的评论,却**无法发表自己的顶层评论**;界面上也没有任何提示“这里不支持发评论”。
- 惯例(网易云/QQ 音乐):评论区右上「写评论」或底部常驻输入框。
- 最小改法:`showCommentsSheet` 底部加一条常驻输入框(需同时补 `viewInsets` padding,见 §2.6),
  或 `SheetHeader` 右侧加「写评论」按钮 → 复用 `_RepliesSheet` 的发送逻辑(把 parent 换成 threadId)。
- 成本:M。

### P0-3.2 播放队列完全没有 UI 入口
- 证据:`src/queue.dart:3` 注释写明“纯逻辑,无 IO/无 UI”;`PlayQueue` 有 `items/index/insertNext/mode`,
  但界面只有播放条一行文本 `'  $inQueue/${_queue.items.length}'`(`main.dart:2208`)。
  全仓无队列面板(`rg 'QueuePanel|播放队列'` 无命中)。
- 现象:看不到“接下来播什么”、不能跳曲、不能从队列里移除/清空;只能一首首点“下一首”。
- 惯例:主流播放器播放条右侧/播放页有队列按钮,点开全屏或半屏列表,当前项高亮,可拖动排序。
- 最小改法:播放条加一个 `Icons.queue_music` IconButton → `showModalBottomSheet` 列 `_queue.items`,
  当前项高亮 + 点击跳播;`PlayQueue` 补 `removeAt` 即可(已经是泛型列表)。
- 成本:M(UI 半天;`queue.dart` 补 2 个方法 + 单测)。

### P1-3.3 红心是“只读指示器”(同一视觉两种行为)
- 证据:`src/song_tile.dart:126-130`:红心只在 `liked` 时以 `Icon(Icons.favorite, size: 13)` 画在歌名后,
  **不可点**;点它命中的是整行 `onTap`(`song_tile.dart:161`)也就是“播放”。
  对照:`detail_page.dart:1216-1225` 的 `_SongRow` 里同一个红心是 `IconButton(onPressed: onToggleLike)`。
- 现象:用户在搜索结果里点红心想取消收藏 → 结果开始播放这首歌;收藏状态没有任何反馈。
- 最小改法:要么把 `SongTile` 的红心也做成按钮(与 `_SongRow` 对齐),要么改成明确不可点的状态块并挪到副标题行。
- 成本:S。

### P1-3.4 没有长按路径,只有“精准点小图标”
- 证据:全仓 `onLongPress` 0 处。
- 现象:歌曲行想弹菜单必须点右侧 40dp 的「...」(`song_tile.dart:151`);搜索历史想删一条没有任何路径
  (`search_landing.dart:55-66` 只有 `ActionChip` 点击=搜索)。
- 惯例:Android 列表长按 = 上下文菜单 / 多选(网易云长按歌曲 = 弹出动作面板)。
- 最小改法:`SongTile`/`_SongRow` 的 `ListTile`/`InkWell` 加 `onLongPress: onMenu`;历史 chip 加 `onDeleted`(chips 自带 ✕)。
- 成本:S。

### P1-3.5 搜索页一行挤了 4 个控件,且“清空”重复两次
- 证据:`main.dart:1997-2040`:TextField(`suffixIcon` 清空,`:2006-2012`)+ `FilledButton`「搜索/搜索中」(`:2021-2024`)
  + `TextButton`「取消」(`:2026-2035`)。`suffixIcon` 与「取消」都是 `_clearSearch`,同一行为。
- 现象:窄屏(300dp)+1.25 字号下 `Expanded` 内的输入框被压到极窄;两个“清空”让用户不知道该按哪个。
  `FilledButton` 文案在 `搜索`/`搜索中` 间切换 → 按钮宽度跳动。
- 最小改法:去掉「取消」TextButton(返回用 `suffixIcon` 或系统返回,见 §2);按钮改定宽或 loading 图标。
- 成本:S。

### P1-3.6 搜索历史「清空」无二次确认,且没有单条删除
- 证据:`src/search_landing.dart:47-53`(`_SectionTitle` 的 `trailing: TextButton('清空')` 直接调 `onClearHistory`),
  同一动作还挂在 `src/settings_view.dart:185-189`。
- 对照:同 App 里破坏性操作**都**有确认(删歌单 `detail_page.dart:379`、删评论 `comment_thread.dart:316`)。
- 最小改法:复用现有 `AlertDialog` 写法加确认,或 `SnackBar` + Undo。
- 成本:S。

### P1-3.7「更多/全部」入口文案与位置四种
| 文案 | 位置 |
|---|---|
| 「更多」 | `src/recommend_view.dart:431`(新歌速递)、`:790`(推荐播客) |
| 「全部」 | `src/recommend_view.dart:554`(排行榜) |
| 「查看全部」 | `src/recommend_view.dart:668`(每日推荐歌曲)、`src/mine_view.dart:429`、`:710` |
| 列表末尾独立按钮「歌单广场」 | `src/recommend_view.dart:134-143`(推荐歌单区块**没有** header trailing) |

- 现象:同一语义(看完整列表)四种叫法;「推荐歌单」的出口在区块下方而不是标题右侧,与上面 5 个区块不一致。
- 最小改法:统一为「全部」(标题右侧 `TextButton`),歌单广场改成 header trailing,广场页作为“全部”的落地。
- 成本:S。

### P2-3.8 主操作只有图标
- 播放条 5 个图标(`main.dart:2236-2254`):播放模式(`repeat/shuffle`)、上一首、播放、下一首、心动模式(`auto_awesome`)。
  「心动模式」和「播放模式」是新用户读不出来的语义,只有长按 tooltip。
- `src/recommend_view.dart:626-634`:所有风格 chip 共用 `Icons.piano` → 视觉上全一样,只能读字。

### P2-3.9 体量接近全页的内容塞进弹层
见 §5 ⑤:每日推荐(3 tab)、最近听过(4 tab)等放进 72% 高的 sheet。

## 4. 一致性

### 4.1 同一语义的多种实现(横向对照表)

| 语义 | 实现 A | 实现 B | 实现 C | 结论 |
|---|---|---|---|---|
| 时长格式 | `_fmt` mm:ss (`main.dart:45`,用于播放条 `:2206`) | `_fmtDuration` h:mm:ss, **逐字复制 4 份** (`detail_page.dart:60`、`artist_page.dart:460`、`podcast.dart:21`、`radio_explore_page.dart:511`) | `song_tile.dart:147` 直接 `'${song.durationMs ~/ 1000}s'` → 行上显示「245s」 | 最常用的歌曲行格式最差;**必改** |
| 分页 | 底部「加载更多」按钮 (`user_list_page.dart:277`) | 「加载更多评论」(`comment_thread.dart:506`) | 「加载更多」(听众 `radio_subscribers_page.dart:196`) | 彼此一致,但**全 App 无一处滚到底自动加载**;与网易云/主流 App 惯例不符 |
| 下拉刷新 | 12 处 `RefreshIndicator`(`recommend_view:101`、`mine_view:131`、`podcast:175`…) | 8 个 `Scaffold` 页**没有**(歌单详情 `detail_page.dart:484`、歌手页 `artist_page`、榜单 `ranking_view`、消息 `messages_page`、新歌新碟 `new_release_page`、全部榜单 `all_charts_page`、粉丝列表 `user_list_page`、动态详情 `feed_detail_page`) | — | 刷新手势时有时无,用户只能靠猜 |
| 详情容器 | 全页 `Scaffold`(歌单 `detail_page.dart:484`、播客 `:892`) | 弹层 `sheet`(评论 `detail_page.dart:31`,电台 `podcast.dart:51`) | `Dialog`(专辑 `album_preview.dart:25`) | 四类同重量内容四种容器,见 §5 ⑤ |
| 错误态视觉 | `_InlineError`(行内文案+重试,`recommend_view.dart:302`) | `_ErrorView`(**两份同名实现**:`vip_page.dart:232`、`discover.dart:656`) | 页内 `Center(Column(...))`(`feed_view.dart:161-179`、`radio_subscribers_page.dart:157-172`、`radio_explore_page` …) | 至少 5 种;`net_retry.dart` 只统一了文案/重试策略,没有统一视觉 |
| SnackBar | 各文件私有 `_snack`(`comment_thread.dart:368`、`user_list_page.dart:154`、`recommend_view.dart:196`、`feed_detail_page.dart:152`、`radio_subscribers_page.dart:130`) | `main.dart` 的 `_toast` | `song_actions.dart:151` 现场取 messenger | 5 份实现;样式都是默认黑条,无 `action`(Undo) |
| 收藏入口 | 心形 `IconButton`(歌单 `detail_page.dart:490`;歌曲 `detail_page.dart:1216`;播放条 `main.dart:2219`) | 菜单项「喜欢」/「收藏到歌单」(`song_actions.dart:174-189`) | 不可点的红心指示器(`song_tile.dart:129`) | 见 §3.3 |
| 弹层标题 | `SheetHeader`(5 处:评论/百科/电台/日推/最近) | 自绘「节目详情」+关闭键(`podcast.dart:562-586`) | 无标题/无关闭(`main.dart:1334` 分享、`song_actions.dart:113`) | 见 §2.5 |
| 删除确认 | 有(`detail_page.dart:379` 歌单、`comment_thread.dart:316` 评论) | 无(`search_landing.dart:50`、`settings_view.dart:185`) | — | 见 §3.6 |
| 加载态 | 区块/整页 `CircularProgressIndicator`(24 个文件 136 处) | 行内小圈 20×20(`user_list_page.dart:274`、`comment_thread.dart:497`) | **无骨架屏**(全仓 0 处 shimmer/skeleton) | 可接受,但推荐页首屏会“白-圈-跳”,加骨架屏体验更好(P2) |

### 4.2 同一页面内两种点击语义

- 歌单详情 `detail_page.dart:760-775`:普通态点行 = **播放**;开了「移出曲目」后点行 = **移出歌单**。
  模式切换的唯一提示是顶部一条 `secondaryContainer` 横条(`detail_page.dart:521-534`),列表行外观不变、
  `AppBar` 上的菜单项文案会变(`:505`),但用户很容易在错误模式下误删曲目。
  惯例:破坏性批量模式应换行尾控件(显示 ✕ / 复选)而不是复用整行点击。
- `mine_view.dart:442-470`:「我喜欢的音乐」预览行点 = 播放,但同卡片右上「查看全部」(`:429`)= 进详情,
  而「收藏的歌单」区块同位置的行点 = **进详情**(`mine_view.dart:505-520`)。
  两个相邻区块,行点击语义相反,且没有任何视觉区分。

### 4.3 视觉与主题

- 深色模式:主题统一走 `ThemeData(colorSchemeSeed)`(`main.dart:84-91`),**没有硬编码底色**;
  17 处 `Colors.black54/white/white70` 都是叠在图片上的遮罩与文字(`artist_page.dart:186-218`、
  `feed_view.dart:718-746`、`feed_detail_page.dart:230-232`、`profile_header.dart:128-244`、
  `radio_explore_page.dart:495-500`、`cover_art.dart:345-355`),在深色下语义正确。
  唯一需要留意的是 `settings_view.dart:311` 的 `Colors.green`(自检成功图标),在深色下偏刺眼(P2)。
- 一处硬编码品牌红:`profile_header.dart:221` `Color(0xFFE0342C)`,与主题种子 `0xFFE60026` 不一致(P2)。

## 5. 布局归类(页面树 + 重排建议)

### 5.1 页面树(按调用链,标注容器类型)

```
HomePage (唯一根路由, main.dart:107)
├─ [底栏] 搜索  ← 默认 tab
│   ├─ 搜索落地页  SearchLanding (内嵌, search_landing.dart)
│   │    ├─ 搜索历史 chips + 「清空」
│   │    ├─ 猜你想搜 → 搜索
│   │    └─ 热门搜索 / 重试
│   ├─ 输入联想    SearchExactBar (search_exact_bar.dart) + KeywordSuggestBar (search_suggest.dart)
│   ├─ 综合结果    SearchResultsView (内嵌, search_results.dart): 单曲/歌手/专辑/歌单/播客
│   ├─ 歌单浏览态  _buildList (内嵌, main.dart:2039) — 从我的/推荐点进来的歌单
│   ├─ 歌单详情    showPlaylistDetail → 全页 Scaffold (detail_page.dart:73/484)
│   │    ├─ 评论     showCommentsSheet → sheet 75% (detail_page.dart:24)
│   │    │    └─ 回复   _RepliesSheet → sheet + dragHandle (comment_thread.dart:282)
│   │    ├─ 分享     _showResourceShareSheet → sheet (detail_page.dart:1303)
│   │    └─ 编辑/移出/删除 (自己歌单, PopupMenu detail_page.dart:497)
│   ├─ 歌手页      showArtistDetail → 全页 (artist_page.dart:10)
│   ├─ 专辑预览    showAlbumPreview → **Dialog** (album_preview.dart:25)
│   ├─ 播客详情    showPodcastDetail → 全页 (detail_page.dart:784)
│   │    ├─ 听众列表 showRadioSubscribers → 全页 (radio_subscribers_page.dart:14)
│   │    └─ 节目详情 ProgramDetailSheet → sheet (podcast.dart:488)
│   └─ 歌曲“...”    showSongActionsSheet → sheet, 8~11 项 (song_actions.dart:108)
│        ├─ 收藏到歌单 → sheet (main.dart:1225)
│        ├─ 分享       → sheet (main.dart:1334)
│        ├─ 歌曲百科   showSongWiki → sheet (song_wiki.dart:14)
│        └─ 相似歌曲   showSimilarSongs → sheet 80% + dragHandle (similar_sheet.dart:16)
├─ [底栏] 推荐  RecommendView (recommend_view.dart) — **8 个平级模块**
│   ├─ 快捷区 3 卡: 每日推荐 / 心动模式 / 私人FM (recommend_view.dart:337-388)
│   ├─ 排行榜 → showAllChartsPage 全页 (all_charts_page.dart:25) → 歌单详情
│   ├─ 风格推荐 chips → showStyleDetail 全页 (style_page.dart:15)
│   ├─ 每日推荐歌曲「查看全部」→ showDiscoverSheet → sheet 72% (discover.dart:29)
│   │    ├─ tab 推荐歌曲 / 推荐歌单
│   │    └─ tab 历史日推 → 日期列表 → 某天曲目(页内 setState 层级, discover.dart:253)
│   ├─ 新歌速递「更多」→ showNewReleasePage 全页 4 tab (new_release_page.dart:23)
│   ├─ 推荐歌单(无 header 出口)+ 末尾「歌单广场」按钮 → showPlaylistSquare 全页 (playlist_square_page.dart:17)
│   ├─ 新碟上架「更多」→ 同 showNewReleasePage
│   └─ 推荐播客「更多」→ RadioExplorePage 全页 (radio_explore_page.dart)
├─ [底栏] 关注  FeedView (feed_view.dart)
│   ├─ 艺人筛选条 → 全部艺人 sheet 75% + dragHandle (feed_view.dart:113)
│   └─ 动态卡 → showFeedDetail 全页 (feed_detail_page.dart:13) → 图片查看器 showImageViewer
│        (cover_art.dart:335, 全屏 Dialog + 左右翻页)
├─ [底栏] 我的  MineView (mine_view.dart)
│   ├─ 资料头 ProfileHeader (profile_header.dart) → 关注/粉丝 showUserList 全页 (user_list_page.dart:14)
│   ├─ 账号管理 → 账号 sheet (main.dart:999)
│   ├─ 消息中心 MessageEntryCard → showMessagesPage 全页 (messages_page.dart:19)
│   │    └─ 私聊 showPrivateChat → sheet 70% (messages_page.dart:428)
│   ├─ 数字专辑 → DigitalAlbumPage 全页 (digital_album_page.dart) → 详情 sheet + dragHandle
│   ├─ 等级与勋章 → showMedalWall 全页 (medal_wall.dart:214)
│   ├─ 签到卡 SigninCard
│   ├─ 我喜欢的音乐「查看全部」→ 歌单详情
│   ├─ 收藏的歌单/播客/专辑 → 各自详情
│   ├─ 听歌排行 → RankingView 全页 (ranking_view.dart:20)
│   └─ 最近听过「查看全部」→ showRecentSheet → sheet 72% 4 tab (discover.dart:400)
├─ [底栏] 设置  SettingsView (settings_view.dart) — **8 个分组**
│   ├─ 账号(登录/切换/退出)  :39
│   ├─ 会员(黑胶)            :49  → showVipPage 全页 (vip_page.dart:510)
│   ├─ 界面(主题/字号/卡片排列) :62
│   ├─ 搜索(切 tab 是否清空)  :138
│   ├─ 播放(取链音质)        :151
│   ├─ 诊断(Rust 通道自检)    :174
│   ├─ 数据(清空搜索历史/设备ID/数据目录) :180
│   └─ 关于                  :212
└─ [覆盖层] 播放器
    ├─ 播放条 (main.dart:2140-2290): Slider + 标题行(封面/标题/红心/...) + 控件行 5 键
    │    ├─ 封面 → 专辑 Dialog；标题 → 歌词 overlay
    │    └─ “...” → 歌曲动作 sheet
    └─ 歌词视图 (overlay, main.dart:2085) WordLyricView / PlainLyricView
```

**旁证**:`showPodcastSheet`(`src/podcast.dart:34`,750 行的 `_PodcastBrowser` = 电台浏览弹层)在生产代码里**零调用**,
只有 `test/podcast_test.dart`、`test/program_detail_test.dart` 在用;实际入口都走全页 `showPodcastDetail`。
这块存量 UI 与它内部的 `_RetryView`(`podcast.dart:460`)属于可清理的历史包袱。

### 5.2 ① 同一功能入口散落在 ≥2 处

| 功能 | 入口们 | 结论 |
|---|---|---|
| 账号/切换/退出 | ① AppBar 右上 `Icons.account_circle`(`main.dart:1699-1703`) ② 我的页资料头 + 「账号管理」按钮(`mine_view.dart:124`、`profile_header.dart`) ③ 设置→账号卡片(`settings_view.dart:39-46`,含「退出登录」`settings_view.dart:426-430`) | 3 处;**“退出登录”只在设置里**,而用户的心理模型在「我的」 |
| 黑胶会员 | 只有 设置→会员(`settings_view.dart:49-58`);而 我的页资料头会显示 VIP 徽标(`profile_header.dart:213`)但不可点 | 会员是账号资产,藏在设置里,反直觉 |
| 清空搜索历史 | ① 搜索落地页「清空」(`search_landing.dart:47-53`) ② 设置→数据(`settings_view.dart:185-189`) | 动作应在数据产生处;设置里那条可删 |
| 每日推荐 | ① 快捷卡(`recommend_view.dart:337-347`) ② 「每日推荐歌曲」区块的「查看全部」(`:668`) | 同屏两个入口指向同一 sheet,区块标题重复 |
| 心动模式 | ① 快捷卡(`recommend_view.dart:357-366`) ② 播放条图标(`main.dart:2250-2254`) | 可接受(不同上下文),但两处图标同为 `auto_awesome`,建议其中一处加文字 |
| 新歌/新碟 | 两个区块各自的「更多」都指向同一个 `showNewReleasePage`(`recommend_view.dart:431`/`:506`) | 应在 UI 上合并成一格 |
| 播放队列 | **无入口**(见 §3.2) | 缺失 |

### 5.3 ② 设置里混入了不属于设置的内容

`settings_view.dart` 的 8 个分组里,只有 3 个真正属于“设置”:

| 分组 | 行号 | 归属判断 | 建议 |
|---|---|---|---|
| 账号 | :39 | **属于「我的」** | 删掉,统一到账号 sheet;「退出登录」移入账号 sheet 底部 |
| 会员 | :49 | **属于「我的」** | 移到「我的」资料头/列表项 |
| 界面 | :62 | 属于设置 ✓ | 保留 |
| 搜索(切 tab 清空) | :138 | 属于设置 ✓(行为开关) | 保留,但归入「通用/行为」 |
| 播放(取链音质) | :151 | 属于播放 ✓,但只有一个开关时不必独立分组 | 并入「通用」或保留 |
| 诊断(Rust 自检) | :174, 实现 `settings_view.dart:297-320` | **开发者诊断**,不该占设置一级分组 | 下沉为 关于 → 「诊断」二级页 |
| 数据(设备ID/数据目录) | :180-210 | **开发者诊断**,且 `SelectableText` 长串会撑高行 | 同上二级页 |
| 关于 | :212 | 属于设置 ✓ | 保留,作为诊断页的入口 |

### 5.4 ③ 「我的」与「设置」边界(目标态)

- **我的** = 身份与资产:资料头 / 会员 / 消息 / 数字专辑 / 等级勋章 / 我喜欢的 / 收藏 / 排行 / 最近听过 / 退出登录。
- **设置** = 偏好与系统:外观(主题·字号·卡片排列) / 行为(切 tab 清空) / 播放(取链音质) / 关于(→ 诊断二级页)。
- 判定规则:一句话能写成“我的 XX”的进「我的」,“App 怎么表现”的进「设置」。按此规则当前有 **4 项放错栏**(账号/会员/清空搜索历史/诊断×2)。

### 5.5 ④ 推荐页平级模块超载(8 > 7)

当前首屏从上到下的平级区块:

1. 快捷区(3 卡) 2. 排行榜 3. 风格推荐 4. 每日推荐歌曲 5. 新歌速递 6. 推荐歌单(+歌单广场按钮)
7. 新碟上架 8. 推荐播客  —— 共 **8 个平级模块 + 1 个游离按钮**。

后果:首屏只能看到“快捷区 + 排行榜的前半截”,新碟上架/播客要滑 3~4 屏;而且 5、7 指向同一个页面(重复)。

**具体重排(保留/合并/下沉)**:

| 模块 | 处置 | 落地方式 |
|---|---|---|
| 快捷区 3 卡 | **保留** | 不变(`recommend_view.dart:337`) |
| 每日推荐歌曲 + 每日推荐歌单 | **合并**为一格「每日推荐」 | 保留快捷卡 + 一个区块;点开仍是 `showDiscoverSheet`,但取消同屏第二个「查看全部」 |
| 排行榜 | **保留**(横滑) | 不变 |
| 推荐歌单 | **保留**(横滑),把「歌单广场」提到 header trailing 作为「全部」 | 删除列表末尾游离按钮(`recommend_view.dart:134-143`) |
| 新歌速递 + 新碟上架 | **合并**成一格「新歌新碟」 | 一个 header + 一个「全部」→ `showNewReleasePage`(它已经有 新歌/新碟/歌手/精选新碟 4 个 tab,足以承接) |
| 风格推荐 | **下沉**到搜索落地页/「更多」 | 或折叠进排行榜区块下方一行 chips,不单独占区块 |
| 推荐播客 | **保留但降到最底** | 不变 |

重排后首屏 5 个平级模块(快捷区 / 每日推荐 / 排行榜 / 推荐歌单 / 新歌新碟),播客在第 2 屏,风格在 1 次点击内。

### 5.6 ⑤ 弹层 vs 全页:选择与内容体量不匹配

| 内容 | 当前容器 | 体量 | 判断 | 建议 |
|---|---|---|---|---|
| 专辑曲目列表(封面+信息+整张曲目) | **Dialog**(`album_preview.dart:25`) | 大(等同歌单详情) | 不匹配:无 AppBar、无返回键、`insetPadding` 32 上下留白,300dp × 大字号下内容被压 | **改全页**,与歌单详情 `detail_page.dart:484` 对齐 |
| 每日推荐(3 tab:歌曲/歌单/历史) | sheet 72% (`discover.dart:29`) | 大(3 个列表 + 内部二级) | 不匹配:内部还有 setState 层级(§2.3),tab 在 72% 高度里滚动局促 | **改全页** |
| 最近听过(4 tab:单曲/专辑/歌单/播客) | sheet 72% (`discover.dart:400`) | 大(4 个列表) | 同上 | **改全页** |
| 评论(含回复二级) | sheet 75% (`detail_page.dart:36`) | 大(无限列表 + 输入框) | 半匹配:sheet 是合理的(轻上下文),但必须能装输入框 + 键盘 | 保留 sheet,改 `DraggableScrollableSheet` + 输入框 |
| 歌曲动作 / 分享 / 收藏到歌单 / 歌曲百科 / 相似歌曲 | sheet | 小(列表/短文本) | 匹配 ✓ | 保留(统一补 `SheetHeader`) |
| 歌单广场 / 全部榜单 / 新歌新碟 / 歌手页 / 粉丝列表 / 消息 / 勋章墙 / VIP | 全页 | 大 | 匹配 ✓ | 保留 |
| 电台浏览(`_PodcastBrowser`) | sheet,生产零调用 | 大 | 死代码 | 删除或改全页接入 |
| **勘误(2026-11-09, 批次 D 实测)** | **`podcast.dart` 整文件不是死代码**: `ProgramDetailSheet` 被 `detail_page.dart:1016` 及 3 个测试真实引用。真正零调用的是入口 `showPodcastSheet`(`:26-61`)+`_PodcastBrowser`(`:63-82`)/`_PodcastBrowserState`(`:84-115`), 合计 **约 88 行**(非 300); 但它被 10 处测试当宿主调用(`podcast_test.dart` 8 + `program_detail_test.dart` 2), 删除需一并改写那些用例 ⇒ **单列一批, 不在 D 批做** | 中 | 半死 | 删 88 行 + 改 10 处测试调用 |
| 播放队列 | **不存在** | 中 | — | 新增 sheet(从播放条进) |

## 6. 移动端细节(安全区/小屏/深色/截断)

### 6.1 安全区:全页列表没算底部手势条

- `SafeArea` 只出现在弹层与播放条(共 9 处):`detail_page.dart:34/1312`、`discover.dart:34/420`、`song_actions.dart:116`、`similar_sheet.dart:28`、`digital_album_page.dart:218`、`podcast.dart:551`、`main.dart:2156`(播放条)、`comment_thread.dart:836`。
- 17 个全页 `Scaffold` 的 `body` **都没有 SafeArea**,也不读底部 inset:
  `artist_page.dart:105`、`ranking_view.dart:29`、`all_charts_page.dart:83`、`playlist_square_page.dart:28`、`new_release_page.dart:88`、`messages_page.dart:127`、`user_list_page.dart:27`、`feed_detail_page.dart:167`、`digital_album_page.dart:83`、`style_page.dart:27`、`detail_page.dart:484` 等。
- 全仓 **0 处** 读 `MediaQuery.padding.bottom` / `viewPadding`;列表底部内边距是固定常量,最常见是 `EdgeInsets.fromLTRB(12, 8, 12, 24)`(7 处)。
- 现象:全面屏手势条(24~48dp)会压住最后一行/最后一条评论;`Scaffold` 只吃 `AppBar` 的 top inset,不处理 bottom。
- 最小改法:上述列表底部 padding 改 `24 + MediaQuery.viewPaddingOf(context).bottom`,或 body 包 `SafeArea(top: false)`。成本 S。

### 6.2 小屏 300dp 溢出

用脚本扫了 44 个文件的 `Row(...)` 块(条件:含 ≥2 个 `Text` 且块内无 `Expanded|Flexible|Spacer|Wrap`):

| 位置 | 判断 |
|---|---|
| `src/comment_thread.dart:399-418` | **真风险**:评论面板标题 `Text(widget.title)`(运行时字符串,歌名/歌单名,`main.dart:1372` 传 `song.name`),无 `maxLines`/`overflow`,外层 `Row` 无 `Flexible` → 长标题必出黄条 |
| `src/comment_thread.dart:488-500` | 无风险(「加载更多评论」按钮行) |
| `src/search_results.dart:192-205` | 无风险(标题是字面量 + 数字后缀) |

- 已做对的典型:播放条标题行 `Flexible` + `maxLines: 1` + `ellipsis`(`main.dart:2193-2203`);`AppBar` 标题用 `FittedBox`( `main.dart:1648-1673`)。
- **已知窄屏痛点有代码注释留证**:`main.dart:2169-2170`「窄屏(411dp)+ 大字号下,标题若和 5 个按钮抢同一行会被挤成‘晴…’,因此标题独占一行,控件单独居中一行」——
  代价是播放条变成三层:

```
Slider(≈48) + 标题行(≈56) + 控件行 5 个 IconButton(≈56) + 8 ≈ 168dp
再加 NavigationBar(80dp)         ≈ 248dp
在 640dp 可用高度里占 39%
```

  这是本报告建议里改动量最大的一项(见 P1-7.4):把控件行收成「播放 + 下一首 + 队列 + 更多」,
  其余(上一首/播放模式/心动模式)搬进点开的「正在播放」页。

### 6.3 文字截断覆盖率低

- 全仓 `Text(` **586 处**,其中带 `maxLines` 仅 **142 处**,带 `overflow: TextOverflow.*` **145 处** → 覆盖率约 **25%**。
- 缺截断的典型(运行时字符串):`comment_thread.dart:402-408`(评论面板标题)、
  `detail_page.dart:486`(`AppBar` 标题直接用 `Text(_detail?.name ?? widget.name)`,靠 `AppBar` 自身限制,
  大字号下会两行���高;对比 `radio_subscribers_page.dart:145-148` 就写了 `overflow: ellipsis`)。
- 做对的地方:`subtitle: [...]` 四段拼装(`recommend_view.dart:519/804`、`mine_view.dart:556/643`)每项都带 `ellipsis`;
  `SheetHeader` 标题带 `maxLines: 1 + ellipsis`(`sheet_header.dart:36-40`)。

### 6.4 深色模式

- 主题统一由 `colorSchemeSeed: Color(0xFFE60026)` 派生(`main.dart:84-91`),**没有硬编码底色**,深色可用。
- 17 处 `Colors.black/white` 常量全叠在图片上作遮罩或白字(`artist_page.dart:186-218`、`feed_view.dart:718-746`、
  `feed_detail_page.dart:230-232`、`profile_header.dart:128-244`、`radio_explore_page.dart:495-500`、`cover_art.dart:345-355`),
  深色下语义仍然正确(P2 可视为达标)。
- 两处需打磨:`settings_view.dart:311` 自检成功用 `Colors.green`(深色下刺眼);
  `profile_header.dart:221` 硬编码 `Color(0xFFE0342C)` 与主题种子 `0xFFE60026` 不是一个红。

### 6.5 「300dp + 1.25 字号」回归实际覆盖只有 1/3

- 45 个测试文件里,**15 个**做了 `Size(300, ...)` 或 `TextScaler.linear(1.25)` 断言:
  `vip_page`、`user_list_page`、`ranking_view`、`digital_album_page`、`style_page`、`radio_subscribers_page`、
  `all_charts_page`、`medal_wall`、`album_preview`、`playlist_square_page`、`radio_explore_page`、`search_exact_bar`、
  `program_detail`、`word_lyric_view`、`comment_stats_bar`。
- **没有**窄屏断言的 30 个里包含首页级组件:`recommend_view_test`、`mine_view_test`、`messages_page_test`、
  `new_release_page_test`、`feed_view_test`、`comment_thread_test`、`song_tile_test`、`search_landing_test`、
  `search_results_test`、`search_suggest_test`、`playlist_square_page_test`。
- 结论:项目约定“窄屏按 300dp + textScale 1.25 兜过回归”目前覆盖的是二级页,三个主 tab(搜索/推荐/我的)都不在其中;
  而 §6.2 的播放条标志(三层)恰好就在没覆盖的 `main.dart` 里。

## 7. 结论表(P0/P1/P2)

### P0 — 阻碍正常使用

| 编号 | 位置 | 现象 | 为什么反直觉 | 最小改法 | 成本 |
|---|---|---|---|---|---|
| P0-7.1 | `main.dart:107`(`home: HomePage`)、`:1760-1768`(歌词 overlay)、`:1843-1854`(IndexedStack);全仓无 `PopScope`/`WillPopScope` | 在「推荐/关注/我的/设置」或歌词页按 Android 返回键 → **直接退出应用** | Android 惯例:返回键先退当前层级(收起歌词 / 回首页 tab),到栈底才退出;主流音乐 App 还会“再按一次退出” | `PopScope(canPop: _tab == 0 && !_showLyrics, onPopInvokedWithResult: (didPop, _) { if (_showLyrics) 收歌词; else if (_tab != 0) 回 0; })` | S |
| P0-7.2 | `src/comment_thread.dart`(874 行,**无输入框**);入口 `src/detail_page.dart:24-58` | 评论区只能看/回复,不能发表顶层评论,也没有任何“此处不支持”提示 | 网易云/QQ 音乐评论区都有“写评论”;用户会当成 bug | `showCommentsSheet` 底部加输入框(补 `viewInsets` padding)或 `SheetHeader` 右侧加「写评论」,复用 `_RepliesSheet._send`(`comment_thread.dart:744-760`) | M |
| P0-7.3 | `src/queue.dart:3`(纯逻辑无 UI);`main.dart:2208`(只有 `$inQueue/$total` 文本) | 播放队列不可见、不可跳曲、不可移除;只能一路点“下一首” | 播放器必备视图;现在“接下来播什么”完全黑箱 | 播放条加 `Icons.queue_music` → sheet 列 `_queue.items`,当前项高亮、点击跳播;`PlayQueue` 补 `removeAt` | M |

### P1 — 明显不直觉

| 编号 | 位置 | 现象 | 为什么反直觉 | 最小改法 | 成本 |
|---|---|---|---|---|---|
| P1-7.4 | `main.dart:1997-2040` | 搜索行 4 个控件(输入框 + 清空 suffix + 搜索 + 取消),「取消」与清空同义;「搜索/搜索中」导致按钮宽度抖动 | iOS/Android 搜索页惯例:输入框 + 清空,不需要“取消”和“搜索”并列 | 删「取消」;按钮定宽或换 loading 圈 | S |
| P1-7.5 | `src/album_preview.dart:25`(Dialog)vs `src/detail_page.dart:484`(歌单详情全页) | 专辑详情是 Dialog:无 AppBar、无返回键,`insetPadding` 上下 32,内容挤在圈里 | 同重量内容应同容器;Dialog 只适合“确认/选择” | 改 `Navigator.push` 全页,复用 `_PlaylistDetailPage` 的骨架 | M |
| P1-7.6 | `src/song_tile.dart:147` | 歌曲行时长显示 `245s`(原始秒数) | 所有音乐 App 都是 `4:05`;同 App 播放条就是 `mm:ss`(`main.dart:45`) | 抽 `lib/src/fmt.dart` 的 `fmtDuration`,行内改用它 | S |
| P1-7.7 | `src/song_tile.dart:126-130` vs `src/detail_page.dart:1216-1225` | 同一个红心:通用行里**不可点**(点=播放),歌单详情行里**可点**(=收藏) | 同一视觉两种行为;用户点红心却开始了播放 | 二选一统一:要么都做成 `IconButton`,要么都改成不可点的状态块 | S |
| P1-7.8 | `src/recommend_view.dart:103-160` | 首屏 **8 个平级模块 + 1 个游离按钮**,其中“新歌速递”和“新碟上架”的「更多」指向同一页 | 超过 7 个平级入口就认知过载;重复入口让用户以为两处内容不同 | 见 §5.5:合并 新歌+新碟、合并 每日推荐两处入口、歌单广场提到 header | M |
| P1-7.9 | `src/settings_view.dart:39`(账号)、`:49`(会员)、`:174/180`(诊断/数据) | 设置里混入“账号 / 黑胶会员 / Rust 自检 / 设备ID / 数据目录” | 「我的」= 我的东西,「设置」= App 怎么表现;诊断是开发者向,不该占一级分组 | 账号+会员移「我的」;诊断+设备ID+数据目录下沉到 关于→诊断 二级页 | M |
| P1-7.10 | `main.dart:1699`(AppBar)、`src/mine_view.dart:124`(我的页)、`src/settings_view.dart:39-46`(设置) | 账号入口 3 处,而「退出登录」只在设置里(`settings_view.dart:426-430`) | 用户找“退出登录”会去「我的」 | 保留 AppBar(全局可达)+ 我的页;退出登录移进账号 sheet 底部 | S |
| P1-7.11 | `src/search_landing.dart:47-53`、`src/settings_view.dart:185-189` | “清空搜索历史”挂在两个地方,且**无二次确认** | 同一动作两处入口会让人怀疑是否同一个;破坏性操作无确认与 App 内其它删除(有确认)不一致 | 只留搜索落地页那条 + `AlertDialog` 确认或 SnackBar Undo | S |
| P1-7.12 | `src/song_tile.dart:151-156`、`src/detail_page.dart:1116-1124`、`src/artist_page.dart:441-449`、`src/profile_header.dart:136-166`、`src/search_landing.dart:60` | 高频控件命中区 <48dp:「...」40dp、「展开/收起」约 24×18dp、头像头「账号管理」药丸约 20dp、历史 chip 32dp | Material/Android 最小触控 48dp;iOS HIG 44pt | 抽 `SongMenuButton`/`ExpandableText`,统一 `constraints: BoxConstraints(minWidth: 48, minHeight: 48)` | S |
| P1-7.13 | `src/recommend_view.dart:431/554/668/790`、`src/mine_view.dart:429/710` | 同一语义四种文案:「更多」「全部」「查看全部」+ 游离「歌单广场」 | 一致性是最低成本的可用性 | 统一「全部」,一律放区块标题右侧 `TextButton` | S |
| P1-7.14 | `src/discover.dart:253-263` | 「历史日推 → 某天」是 sheet 内的 `setState` 层级,自带返回箭头;系统返回键却关整个 sheet | 页内返回箭头 vs 系统返回键语义冲突 | `PopScope(canPop: _date == null, …清 _date)` | S |
| P1-7.15 | 17 个全页 `Scaffold` 的 body(如 `artist_page.dart:105`、`feed_detail_page.dart:167`);全仓 0 处读 `viewPadding` | 列表底部固定 24dp,手势导航条(24~48dp)会压住最后一行 | 全面屏是当前主流形态 | 底部 padding 加 `MediaQuery.viewPaddingOf(context).bottom`,或 `SafeArea(top: false)` | S |
| P1-7.16 | `main.dart:2140-2290` | 播放条三层 ≈168dp + NavigationBar 80dp ≈ 248dp,640dp 屏里占 39%(代码注释 `main.dart:2169-2170` 已记录窄屏挤压) | 主流播放条是单行(封面+标题+播放+下一首+队列),点开才是全屏播放页 | 控件行收成「播放/下一首/队列/更多」,其余搬进“正在播放”页 | L |
| P1-7.17 | `src/comment_thread.dart:399-418` | 评论面板标题 `Text(widget.title)` 无 `maxLines`,外层 `Row` 无 `Flexible` → 长歌名/歌单名必出黄条 | 任何运行时字符串进 `Row` 都要给边界 | 加 `Flexible` + `maxLines: 1` + `ellipsis` | S |
| P1-7.18 | `user_list_page.dart:277`、`comment_thread.dart:506`、`radio_subscribers_page.dart:196` | 三个分页列表都靠底部「加载更多」按钮,**全 App 无自动加载** | 移动端惯例是滚到底自动加载 | 加 `ScrollController + extentAfter < 200` 触发 `_loadMore`,按钮保留为兜底 | M |

### P2 — 打磨项

| 编号 | 位置 | 现象 | 最小改法 | 成本 |
|---|---|---|---|---|
| P2-7.19 | 全仓 `Semantics` 0 处;`main.dart:2242/2243/2248`、`detail_page.dart:679/996`、`vip_page.dart:188`、`messages_page.dart:449` 的 `IconButton` 连 `tooltip` 都没有 | 读屏软件读不出控件含义;上一首/播放/下一首三个核心键最严重 | 补 `tooltip`;播放键补 `Semantics(label: '播放/暂停')` | S |
| P2-7.20 | 11 处 `GestureDetector`:`main.dart:2174`、`feed_view.dart:549/705`、`feed_detail_page.dart:219/316/334`、`cover_art.dart:346`、`detail_page.dart:1105/1116`、`artist_page.dart:430/441` | 可点图片/文本无水波纹、无按压反馈 | 换 `InkWell`(有 `Material` 祖先)或加 `InkResponse`,`borderRadius` 与图片一致 | S |
| P2-7.21 | `recommend_view.dart:303`、`mine_view.dart:312`、`style_page.dart:215`(三份同名 `_InlineError`)+ `vip_page.dart:232`、`discover.dart:656`(两份同名 `_ErrorView`)+ `podcast.dart:460` `_RetryView` | 错误态 **6 种实现** | 抽一个 `lib/src/error_views.dart`(`InlineError` / `FullError`),各处替换 | S |
| P2-7.22 | `comment_thread.dart:368`、`user_list_page.dart:154`、`recommend_view.dart:196`、`feed_detail_page.dart:152`、`radio_subscribers_page.dart:130` + `main.dart` `_toast` | SnackBar **6 份私有实现**,均无 `action` | 抽 `showToast(context, msg, {action})` 统一 | S |
| P2-7.23 | `main.dart:45`、`detail_page.dart:60`、`artist_page.dart:460`、`podcast.dart:21`、`radio_explore_page.dart:511`、`new_release_page.dart:235` | 时长格式化 **5 份复制 + 1 份变体**(`new_release` 不带小时) | 抽 `fmtDuration` 到 `lib/src/fmt.dart`,`new_release` 那处改成同一口径或明确“分钟级” | S |
| P2-7.24 | `main.dart:1008`(账号)、`:1225`(收藏到歌单)、`:1334`(分享)、`song_actions.dart:113` vs `SheetHeader`(5 处)、`showDragHandle`(4 处)、`podcast.dart:562-586`(自绘) | 弹层**四种标题/关闭写法**,其中 4 个弹层既无拖柄也无关闭键 | 统一 `showDragHandle: true` + 有标题的用 `SheetHeader` | S |
| P2-7.25 | `main.dart:1008-1012` | 账号面板非 `isScrollControlled` + `Column(min)`,账号无上限 → 大字号/多账号时裁切溢出(同 App 的「收藏到歌单」`main.dart:1225-1240` 已用 60% 高 + `Expanded` 兜住) | 与「收藏到歌单」对齐 | S |
| P2-7.26 | `settings_view.dart:311`(`Colors.green`)、`profile_header.dart:221`(`0xFFE0342C` vs 种子 `0xFFE60026`) | 深色下自检绿刺眼;两处“品牌红”不一致 | 用 `colorScheme.tertiary` / 统一到一个主题色常量 | S |
| P2-7.27 | 全 App 0 处骨架屏(136 处 spinner) | 推荐页首屏“白→转圈→跳变” | 只给推荐页三个横滑区加占位骨架 | M |
| P2-7.28 | `src/podcast.dart:34` `showPodcastSheet` + `_PodcastBrowser`(约 300 行) | 生产零调用(仅测试用);内部还有第 6 种错误视图 `_RetryView` | 删除,或改全页接入后替换 `showPodcastDetail` | M |
| P2-7.29 | `src/recommend_view.dart:626-634` | 所有风格 chip 共用 `Icons.piano` | 按风格首字/分类给图标,或干脆去掉图标只留文字 | S |
| P2-7.30 | `src/word_lyric_view.dart`(无 `onTap`/seek) | 歌词页点某一句不会跳转;也没有封面/曲目信息 | 每行包 `GestureDetector` → `_seekTo(lineTime)` | M |
| P2-7.31 | `ui/test/`:45 个文件里仅 15 个做 `300dp + 1.25` 断言,三个主 tab(搜索/推荐/我的)都不在其中 | 窄屏回归是“部分覆盖” | 给 `recommend_view`/`mine_view`/`messages_page`/`comment_thread`/`song_tile` 补 300dp+1.25 用例 | M |
