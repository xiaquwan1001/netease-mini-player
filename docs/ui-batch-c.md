# UI 批次 C — 信息架构重排(纯 Dart)

> 审计依据 `docs/ui-ux-audit.md` §5(布局归类/§5-④ 过载模块)、P1-7.5 / 7.8 / 7.9 / 7.10 / 7.11 / 7.14。
> 门禁: `dart analyze` error/warning = 0;`flutter test` 305 passed + 1 skip(本批 +11,0 删除)。
> **人工视觉复核留到最后**:本批只保证结构与行为正确,所有"看着可能不对"的细节集中在 §7 待人工过目。

## 0. 结论

- 设置页 8 个分组 → **3 个分组 + 1 个二级页入口**,账号/会员/诊断·数据全部搬出(P1-7.9)。
- 账号入口 **3 → 1**(P1-7.10):AppBar 的账号图标与设置页的账号卡都删除,唯一账号面是「我的」页资料头 → 新的 `账号与会员` 全页;退出登录在账号页底部。
- 推荐页平级模块 **8 + 1 游离按钮 → 首屏 5**(快捷区 / 每日推荐 / 排行榜 / 推荐歌单 / 新歌新碟),播客保留但降到第 2 屏;每个模块的落地页与回调零删除(P1-7.8)。
- 专辑详情 **Dialog → 全页 Scaffold**(P1-7.5),`showAlbumPreview` 签名、loader 注入、测试语义不变。
- 每日推荐 / 最近听过 **72% 高 sheet → 全页 Scaffold**(§5.6),并顺手补上历史日推的 `PopScope`(P1-7.14)。

## 1. 页面树:重排前 → 重排后

### 1.1 设置(P1-7.9)

```
重排前 [底栏] 设置 SettingsView                       重排后 [底栏] 设置 SettingsView
├─ 账号      登录/切换/账号管理/退出登录               ├─ 界面     主题模式 / 字号 / 卡片排列
├─ 会员      黑胶会员 → vip_page                     ├─ 通用     切 tab 清空(开关) / 取链音质(Dropdown)
├─ 界面      主题/字号/卡片排列                       └─ 关于     轻音 MiniNCM + 「诊断与数据」→ 二级页
├─ 搜索      切 tab 清空                                  └─ 诊断与数据(全页)
├─ 播放      取链音质                                          ├─ Rust 通道自检
├─ 诊断      Rust 通道自检                                      └─ 设备 ID / 数据目录
├─ 数据      清空搜索历史 / 设备 ID / 数据目录
└─ 关于      轻音 MiniNCM                           账号/会员 → 搬到「我的」(见 1.2)
                                                    清空搜索历史 → 只留搜索落地页(动作发生处)
```

### 1.2 账号(P1-7.10)

```
重排前(3 个入口, 都是 60% 高的 sheet)              重排后(1 个入口 → 全页)
├─ AppBar 右上 Icons.account_circle                  └─ [底栏] 我的 → 资料头(整块点击 / 右上「账号管理」)
├─ 我的 → 资料头 / 「账号管理」药丸                          └─ 账号与会员(全页)
└─ 设置 → 账号卡(里面才有「退出登录」)                        ├─ 当前账号卡(昵称/VIP/登录)
                                                             ├─ 会员 → 黑胶会员
                                                             ├─ 账号簿(切换 / 忘记) + 添加账号
                                                             └─ 退出登录
```

### 1.3 推荐(P1-7.8 / §5.5)

```
重排前(8 平级 + 1 游离)                            重排后(首屏 5 + 播客第 2 屏)
1 快捷区(3 卡)                                     A 快捷区(3 卡, 不变)
2 排行榜          「全部」→ 全部榜单               B 每日推荐          「全部」→ 每日推荐页(歌曲/歌单/历史)
3 风格推荐        chips → 风格详情                  C 排行榜            「全部」→ 全部榜单
4 每日推荐歌曲    「全部」→ 每日推荐 sheet                   └─ 风格推荐 chips(下沉为次级内容, 无自己的出口)
5 新歌速递        「全部」→ 新歌新碟 ┐             D 推荐歌单          「全部」→ 歌单广场(原游离按钮上提)
6 推荐歌单(无出口)+ 末尾「歌单广场」按钮            E 新歌新碟          「全部」→ 新歌/新碟/歌手分类页
7 新碟上架        「全部」→ 新歌新碟 ┘                    ├─ 新歌速递(小标题)
8 推荐播客        「全部」→ 电台广场                      └─ 新碟上架(小标题)
                                                   F 推荐播客          「全部」→ 电台广场(保留, 降到最底)
```

### 1.4 容器:Dialog / sheet → 全页(P1-7.5, §5.6)

| 内容 | 重排前 | 重排后 |
|---|---|---|
| 专辑详情 | `showDialog`(无 AppBar/无返回键) | `Navigator.push` 全页 `Scaffold`(AppBar + 返回键) |
| 每日推荐(3 tab) | `showModalBottomSheet` 72% 高 | 全页 `Scaffold`(AppBar + `TabBar` bottom) |
| 最近听过(4 tab) | `showModalBottomSheet` 72% 高 | 全页 `Scaffold`(AppBar + `TabBar` bottom) |

## 2. 改动清单(file:line)

### 2.1 新建

| 文件 | 说明 |
|---|---|
| `ui/lib/src/settings_account_page.dart` | `showAccountPage()` :15 / `AccountPage` :46 —— 唯一账号面(当前账号卡 :152、会员 :209、账号簿 :216、添加账号、退出登录 :273) |
| `ui/lib/src/settings_diagnostics_page.dart` | `showDiagnosticsPage()` :10 / `DiagnosticsPage` :23 / `ChannelSelfCheckTile` :80(从 settings_view.dart 原样搬移) |
| `ui/test/ui_batch_c_ia_test.dart` | 11 条可达性回归(见 §4) |

### 2.2 设置瘦身

| file:line | 改动 |
|---|---|
| `ui/lib/src/settings_view.dart:16-33` | `SettingsView` 参数从 7 个(`info/isAndroid/onLogin/onLogout/onShowAccounts/onClearSearchHistory/onOpenVip`)收到 **1 个**(`info`,只给诊断页用) |
| `settings_view.dart:35` / `:113` / `:152` | 只剩「界面」「通用(原搜索+播放合并)」「关于」3 组 |
| `settings_view.dart` (删除) | 账号卡、会员卡、诊断组、数据组(设备ID/数据目录)、清空搜索历史 |
| `settings_view.dart:152-175` | 「关于」组新增 `诊断与数据` 入口 → `showDiagnosticsPage` |
| `settings_diagnostics_page.dart` 全文 | `Colors.green` 成功图标改 `colorScheme.primary`(顺带 P2-7.26 的一半) |
| `ui/lib/main.dart:2007` | `SettingsView(info: _info)` |

### 2.3 账号入口 3→1 + 会员搬栏

| file:line | 改动 |
|---|---|
| `ui/lib/main.dart:1762-1770` | AppBar 删掉 `Icons.account_circle`(账号入口)与「已登录时的空占位」;未登录仍保留「登录」TextButton |
| `ui/lib/main.dart:1049-1071` | `_showAccountSheet`(底部 sheet) → `_openAccountPage`(push `AccountPage`);账号簿的"记住/切换/忘记"回调仍在 main.dart 编排(`_switchAccount`、`onRemoveAccount`) |
| `ui/lib/main.dart:1982` | `MineView(onOpenAccounts: _openAccountPage)` —— 唯一入口 |
| `ui/lib/main.dart:2000` | `MineView(onOpenVip: _openVip)` |
| `ui/lib/main.dart:1021-1023` | `_openVip` 注释改为"我的页 / 账号页的会员分组" |
| `ui/lib/src/mine_view.dart:33/68-70/158-170` | 新增 `onOpenVip`(可选)+「黑胶会员」行(消息中心与数字专辑之间) |
| `settings_account_page.dart:273` | 「退出登录」从设置搬到账号页底部(P1-7.10) |

**入口常驻**:`ProfileHeader` 的整卡点击与右上「账号管理」药丸在登录/未登录两种状态下都在(`mine_view.dart:120-124` 恒传 `onTap`);未登录时点击 → 登录流程,登录后同一位置 → 账号页。

### 2.4 推荐页 8→5

| file:line | 改动 |
|---|---|
| `recommend_view.dart:104-160` | 区块顺序/组合重排(新增注释表) |
| `recommend_view.dart:719` | `每日推荐歌曲` → **每日推荐**(与"每日推荐歌单"合并;歌单在落地页第二个 tab) |
| `recommend_view.dart:533` | 新增 `_NewReleaseSection`(单一 header「新歌新碟」+ 单一「全部」) |
| `recommend_view.dart:511` | 新增 `_Caption`(合并区块内的次级小标题) |
| `recommend_view.dart:581-646` | `_ChartSection` 增加 `loadStyles/onPlaySongs`,榜单封面下方渲染风格 chips |
| `recommend_view.dart:648` | `_StyleSection` → `_StyleChips`(去掉自己的 `_SectionHeader` 与「全部」,降为次级内容) |
| `recommend_view.dart:774-790` | `_DailyPlaylistsSection` 增加 `onOpenAll` → 标题右侧「全部」= 歌单广场 |
| `recommend_view.dart` (删除) | 区块末尾游离的「歌单广场」按钮(原 `:134-143`) |

**可达性**:每个模块的落地页/回调全部保留 —— 每日推荐→`onOpenDaily`;排行榜→`showAllChartsPage`;风格→`showStyleDetail`(每枚 chip);推荐歌单→`onOpenPlaylist` + 歌单广场;新歌新碟→`onOpenNewRelease`(NewReleasePage 已有 新歌/新碟/歌手/精选新碟 4 tab)+ `onOpenAlbum`;推荐播客→`onOpenPodcast` + RadioExplorePage。

### 2.5 专辑详情 Dialog → 全页

| file:line | 改动 |
|---|---|
| `album_preview.dart:17-46` | `showDialog` → `Navigator.push(MaterialPageRoute)`;`showAlbumPreview` 签名/loader 注入(`loadAlbum`/`setSubscribed`/`initiallySubscribed`)完全不变 |
| `album_preview.dart:49` | `_AlbumPreviewDialog` → 公开的 `AlbumPreviewPage` |
| `album_preview.dart:172-180` | AppBar 标题(专辑名,省略号),正文不再重复标题 |
| `album_preview.dart:196-206` | 曲目列表从"`ConstrainedBox(maxHeight:320)` + `shrinkWrap`"改为 `Expanded(ListView.builder)`(全页空间足),底部补手势条 inset |
| `album_preview.dart` (删除) | 右下角「关闭」按钮(Dialog 专用;全页用 AppBar 返回) |

点曲目仍 `Navigator.pop` + `onPlay(整张专辑, index)` → 语义不变。

### 2.6 日推 / 最近听过 sheet → 全页

| file:line | 改动 |
|---|---|
| `discover.dart:20-48` | `showDiscoverSheet` → `showDiscoverPage`(push `DailyRecommendPage`) |
| `discover.dart:50-95` | `DailyRecommendPage`:`SheetHeader` → `AppBar(title, bottom: TabBar)`;72% 高度限制删除 |
| `discover.dart:449-479` | `showRecentSheet` → `showRecentPage`(push `RecentPlayedPage`) |
| `discover.dart:481-540` | `RecentPlayedPage`:同上,4 个 tab 进 `AppBar.bottom` |
| `discover.dart:270-290` | `_HistoryTab` 包 `PopScope(canPop: _date == null)` + `_buildBody()` 拆分 → **P1-7.14**:选过某一天后按返回先退回日期列表 |
| `discover.dart:5` (删除) | `sheet_header.dart` import(全页不再用 sheet 头) |
| `ui/lib/main.dart:700 / :718` | `showDiscoverPage` / `showRecentPage` |

## 3. 断言/符号变更逐条说明(无删除用例)

| # | 文件:用例 | 改动 | 原因 |
|---|---|---|---|
| 1 | `test/discover_test.dart` 6 处 | `showDiscoverSheet(`→`showDiscoverPage(`,`showRecentSheet(`→`showRecentPage(` | 弹层改全页,函数改名;注入参数/断言全部原样 |
| 2 | `test/discover_test.dart:88` '每日推荐: 歌单页签展示并可打开' | `tap(find.text('推荐歌单').last)` → `tap(find.widgetWithText(ListTile, '推荐歌单'))` | 全页后 `Scaffold` 把 **body 排在 AppBar/TabBar 之前**,`find.text().last` 命中的是 tab 标签而不是列表行(旧 sheet 里 `SheetHeader` 在前,所以 `.last` 恰好是列表行)。断言仍验证"点歌单行 → 回调整批歌单" |
| 3 | `test/ui_batch_d_narrow_test.dart:46`(D 车道文件) | `showDiscoverSheet`→`showDiscoverPage`,**只改符号不改断言** | 同上改名;该用例仍是"每日推荐 300dp+1.25 不溢出" |
| 4 | `test/settings_selftest_test.dart` import + 末条用例 | `import settings_view.dart`→`settings_diagnostics_page.dart`;`SettingsView(info:…, isAndroid:…, onLogin:…)` → `DiagnosticsPage(info: fakeInfo())`,并新增 `设备 ID` / `dev-1` 断言 | 通道自检+设备ID 已搬到诊断二级页;`SettingsView` 不再有这些参数。用例意图(挂载不崩 + 不点自检)不变 |
| 5 | `test/recommend_view_test.dart:112` | `find.text('每日推荐歌曲') findsOneWidget` → `find.text('每日推荐') findsNWidgets(2)` | 与"每日推荐歌单"合并后区块改名;该文案同时出现在快捷卡与区块标题,故 2 个 |
| 6 | `test/recommend_view_test.dart:127` | `find.text('全部').at(2)` → `.at(3)` | 区块顺序变化(每日推荐提到第 1,新歌新碟在第 4);`findsNWidgets(5)` 保持不变 —— 合并后出口仍是 5 个 |
| 7 | `test/album_preview_test.dart` | **未改断言** | 改为全页后,正文不再重复专辑名,`find.text('叶惠美') findsOneWidget` 反而恢复为单命中(原先 Dialog 里标题只出现一次,我第一版全页实现重复了一次,已按测试语义修正 lib 而非改测试) |

## 4. 可达性测试清单(`ui/test/ui_batch_c_ia_test.dart`,11 条)

| # | 用例 | 证明什么 |
|---|---|---|
| 1 | 设置首页: 账号/会员/诊断/清空搜索历史已搬走, 只留分组入口+开关 | 设置里不再出现「账号/会员/诊断/Rust 通道自检/清空搜索历史」;界面·通用·关于仍在 |
| 2 | 设置 → 关于 → 诊断与数据: 二级页可达 | Rust 自检 / 设备 ID(dev-1)/ 数据目录(/tmp/minincm)都能从设置进到 |
| 3 | 我的页: 资料头是账号入口, 黑胶会员入口也可达 | 「账号管理」药丸触发账号入口;「黑胶会员」行可点(会员从设置搬到我的) |
| 4 | 账号与会员页: 账号簿/切换/忘记/添加/退出登录/会员 全部可达 | 6 个动作逐个断言(切换 `switched`、忘记 `removed`、添加 `logins`、会员 `vip`、退出 `logouts`) |
| 5 | 推荐页: 平级区块 8→5 | 5 个区块标题各命中;`每日推荐歌曲`/游离`歌单广场`不再作为区块;新歌/新碟降为小标题但内容仍在 |
| 6 | 推荐页: 风格推荐下沉为排行榜区块内 chips | chip 仍渲染,且纵向位置在榜单封面之后、「每日推荐」之后(次级内容) |
| 7 | 推荐页: 新歌新碟 合并后唯一「全部」仍进分类页 | `全部` 仍 5 个;第 4 个 → `onOpenNewRelease` 触发 1 次 |
| 8 | 推荐页: 推荐歌单「全部」进歌单广场 | 点第 3 个 `全部` → 出现「歌单广场」页(原游离按钮功能不丢) |
| 9 | 专辑详情是全页 Scaffold, 点曲目仍回调整张专辑 | 无 `Dialog`、有 `AppBar`/`BackButton`;返回可回上一页;点曲目仍回调整张专辑 index=1 |
| 10 | 每日推荐是全页; 历史日推用返回键退回日期列表 | 无 `BottomSheet`;选某天后 `pageBack()` **不关整页**而是回日期列表(P1-7.14) |
| 11 | 最近听过是全页(4 个 tab) | 无 `BottomSheet`;单曲/专辑/歌单/播客 4 个 tab 齐全 |

## 5. 门禁数据

| 项 | 数值 |
|---|---|
| `dart analyze`(ui) | **error 0 / warning 0**(39 条 info,均为既有 lint:`unnecessary_underscores`、`use_null_aware_elements` 等) |
| `flutter test` 本批前(HEAD `b70f934`) | **294 passed + 1 skip** |
| `flutter test` 本批后 | **305 passed + 1 skip**(+11 新用例, 0 删除, 6 条断言/符号微调见 §3) |
| 我接手时的门禁基线 | 289 passed + 1 skip;期间 D6b(`b70f934`)合并 `new_release_page_test` +5 用例,故本轮实测基线为 294 |

## 6. 未做项 / 边界

1. **P1-7.11 的二次确认未加**:"清空搜索历史"已从设置页删除(唯一入口回到搜索落地页),但 `AlertDialog` 确认需要改 `search_landing.dart`(本批禁改) → 留给后续批次。
2. **AppBar 账号图标已删**:任务要求"3→1",审计 P1-7.10 的最小改法是"保留 AppBar(全局可达)+ 我的页"。本批按任务取 1 个入口(我的页资料头);若要恢复全局入口,只需在 `main.dart:1762` 那组 actions 里加回一个指向 `_openAccountPage` 的 `IconButton`(一行)。
3. **推荐页区块计数口径**:平级区块为 **首屏 5 个**(快捷区 / 每日推荐 / 排行榜 / 推荐歌单 / 新歌新碟);「推荐播客」按审计 §5.5 "保留但降到最底"留在第 2 屏,所以全页仍有 6 个区块(原 8 个 + 1 游离按钮)。若要求严格 5 个区块,需把播客也下沉到电台广场并在快捷区加入口 —— 待人工定夺。
4. 「风格推荐」下沉后不再有独立小标题+副标题("按你的听歌口味"并进 caption 之外的语义),`showStyleDetail` 的可点性由既有 `style_page_test` 覆盖。
5. 未触碰另两条车道的文件:`detail_page.dart`、`comment_thread.dart`、`queue.dart`、`song_tile.dart`、`search_landing.dart`、`paged_list_view.dart`、`new_release_page.dart`、`all_charts_page.dart`、`digital_album_page.dart` 等(仅在 `main.dart` 里按原签名调用)。

## 7. 待人工过目(视觉, 不做像素级调优)

1. **账号与会员页**:当前账号卡 / 会员 / 账号簿 / 退出登录 四段的间距与层级是否够清楚;「忘记这个账号」用的删除图标是否需要二次确认。
2. **推荐页合并区块**:「新歌新碟」内两个 `_Caption`(labelMedium + outline 色)与上方区块标题的层级是否分得开;新歌行(6 条)与新碟横滑行接在一起会不会显得太长。
3. **风格 chips 的归属**:现在紧跟在排行榜封面下方,只有一行 `风格推荐` 小字;如果看起来像"排行榜的一部分"而非独立内容,可考虑加分隔线或改成折叠入口。
4. **专辑详情全页**:封面 120 + 信息块之后直接是曲目列表,AppBar 已是专辑名,正文首行现在是歌手名,是否显得头重/留白奇怪。
5. **日推 / 最近听过全页**:`AppBar(title, bottom: TabBar)` 的组合在深色/大字号下的高度;三个 tab 是否还需要首屏滚动位置的记忆(现已保活,但未记忆滚动位置)。
6. **设置页只剩 3 组**:是否显得太空,需要补一两个设置入口(如"通知/缓存")来平衡。
7. **我的页顺序**:「黑胶会员」插在[消息中心]与[数字专辑]之间;若认为应紧跟资料头或放到"资产"之后,只需调整 `mine_view.dart:158` 那个 `if` 块的位置。
8. **账号页「添加账号」**在没有记住账号时紧跟在空态行之后,是否符合预期。
