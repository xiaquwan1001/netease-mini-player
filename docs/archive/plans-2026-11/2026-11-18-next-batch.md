# 下一批任务规划 + 三条审计车道(2026-11-18)

> 状态: 规划 + 手段登记。**门禁数字唯一权威在 `docs/PROGRESS.md` 头部表**, 本文件不复制数字, 只写「下一批做什么 / 怎么验收」。
> 前置事实: HEAD `5b79e5a`(v0.21.0 之后 8 个未发版切片), 工作树干净;
> 2026-11-18(四) 收尾实测 `tools/ci-gates.sh verify`(NCM_DESKTOP_SMOKE=1) = ALL GATES OK, Dart **1123** / Rust **313**。

## 1. 现状判断(为什么先做审计, 不直接堆功能)

`docs/remaining-batches.md` §11.A 剩余 6 项里 5 项是「需人眼 / 需真机 / 需用户」(视觉过目、deb 装包冒烟、
Windows 扫码、keyring 装包、诊断 Worker 部署), 本机 LLM 车道**无法闭环验收**; §12 里 12.1/12.2/12.3/12.4/12.5 已完成,
12.6 只差不可变快照(触发条件未到), 12.1b 已裁决暂不拆, 12.7 暂不做; §13 只剩两项需真人。
⇒ 结构债务清单已基本清空, **继续堆功能前先补三类"看不见"的账**: 文档与事实漂移、死代码存量、UI 层的浮层/返回栈/生命周期契约。

## 2. 三条只读审计车道(本批派发, 2026-11-18)

| 车道 | 产物 | 边界 |
|---|---|---|
| D · 文档进度核实与精简 | 直接改 `docs/*.md` + `.pi/memory/*.md`(订正/精简/死指针), 报告段落写进 `docs/PROGRESS.md` 当日小节 | **只改文档**; 不改代码/不跑 `dart format`; 门禁数字未经实测不许改 |
| E · 死代码检查 | `docs/archive/plans-2026-11/deadcode-audit-2026-11-18.md`(只读审计 + 分级清单) | **不删代码**(删除另开一批); 生成代码 `ui/lib/src/rust/**`、`core/crates/ncm-ffi/src/frb_generated.rs` 排除 |
| F · UI 浮层/切换钩子/返回栈/生命周期架构评估 | `docs/archive/plans-2026-11/arch-audit-ui-overlay-2026-11-18.md`(缺陷 + 分级 + 触发条件) | **只读评估**; 只登记不排期(口径同 §13) |

| G · UI 横屏/宽屏响应式布局(调研+实施) | `docs/archive/plans-2026-11/ui-adaptive-layout-2026-11-18.md` + 改 `ui/lib/src/layout.dart`、壳层(宽档 NavigationRail)与新增测试 | **唯一会改产品代码的车道**; 分 P1 断点/P2 内容限宽/P3 导航栏位置(可降级)/P4 只写方案; 不改 `docs/*`(避免与 D 撞车) |

编排者预置线索(子代理须自行核实, 不得直接抄进结论):

- **浮层无单一入口**: 现查 `showModalBottomSheet` **23 处 / 18 文件**, `showDialog` **20 处 / 16 文件**, 全仓**没有** `showAppSheet(...)` 这类统一入口(前端审计 2026-11-15 的建议从未落地, 只有 `sheet_header.dart` 统一了标题栏)。
- **返回栈**: `PopScope` 3 处(`back_policy.dart` + `history_tab.dart`, 其中 1 处是注释); `WillPopScope`/`BackButtonListener`/`NavigatorPopHandler`/`RouteAware`/`didPopNext` **全为 0**; `navigator.push` **28** / `Navigator.pop` **40** / `maybePop` **1**; `back_policy.dart` 只覆盖根页面(`HomeBackAction`), 二级页/弹层的返回语义靠各处手写(队列面板/登录弹层已于 2026-11-18 加「切 tab 时收起」补丁)。
- **生命周期钩子**: `WidgetsBindingObserver` **3 处 / 2 文件**、`TickerProviderStateMixin` **6 处 / 4 文件**、`AppLifecycleListener` 与 `didChangeAppLifecycleState` **全 0**(即没有任何页面级前后台钩子); `home_wiring.dart` 一次性注册 **10 条进程级静态钩子**(通知栏 skip/action、settings listener、actionsHost、playerBarActions、ArtistNav、updatePrompt、pageDepth), 靠 `_latest` 单实例语义; 另有 `WidgetsBindingObserver` 3 处、`TickerProviderStateMixin` 6 处、`Overlay`/`OverlayEntry` 2/3 处(播放条宿主在 Navigator 之外)。Android 侧返回键: `LoginActivity` 已迁 `OnBackPressedDispatcher`, `MvPlayerActivity`/`MainActivity` 需查。
- **宽屏布局**: 全仓**没有** NavigationRail / AdaptiveScaffold / Breakpoints 类, 唯一宽度阈值是 `layout.dart:148 kPlayerBarRoomyWidth = 600`(只给播放条用); 也**没有内容区限宽**(`ConstrainedBox(maxWidth: 840)` 之类) ⇒ 宽屏左右空荡是缺"布局决策层", 不是缺页面。
- **切页钩子**: 没有 `RouteAware`, 「切 tab 要做什么」(暂停/刷新/收起弹层)散落在 `home_page.dart` 的 `_onTabSelected` 与各 controller。

## 2.5 第一批回执(2026-11-18 晚, 编排者独立复核后)

| 车道 | 结果 | 编排者复核 |
|---|---|---|
| D 文档 | 订正 12 处漂移 + 清死指针, `remaining-batches.md` 409→385 行 | 抽查 `api.rs` 3325 行 / `pub fn` 161 / `ffi_forward!` 77 / domain 1750 行·91 struct / `app_settings.dart` 594 行 / 三份 docs 内链 `test -f` 0 missing / api-coverage 实测 — 全部与现码一致 |
| E 死码审计 | `docs/archive/plans-2026-11/deadcode-audit-2026-11-18.md`(320 行): A 级 8 条/48 行 · B 级 3 条/14 行 · C 级 9 个 FFI 孤儿(4 保留 / 4 真死 / 1 待决策) · D 级 3 条 | 抽查 `setVolume` 零调用、`cupertino_icons` 零引用、api-coverage 少报根因 —— 均复现。**发现门假绿**: `tools/api-coverage.sh` 旧判定(小写化标识符集合)让 `rust.SigninStatus`(类型)与 `rust.PodcastRadio(`(构造调用)把同名导出顶替成「有入口」⇒ 少报 3 个。**已修**(改为「小写开头 + 调用/tearoff 形态」), 实测 6→**9**, 文档口径同步 |
| G 响应式 | 断点三档 + 内容限宽 + 宽档 NavigationRail, 页面零改动; P4 只出方案 | `dart analyze` 0 · 全量 `flutter test` 1123→**1148** · golden 18 未重出 · format/token/row-padding/write-guard 全 OK。**编排者补一处**: 限宽盒在 Navigator 外面 ⇒ 弹层 `ModalBarrier` 也只有 840 宽(1280 下遮罩「破两条」) ⇒ 新增 `NcmRouteObserver`/`modalRouteOpen` + `kContentGapBarrierColor`, 弹层在场时两侧留白按遮罩同色压暗, 并加 1 例测试锁住「遮罩宽度=840(已知边界)」与压暗/复位 |

## 2.6 第二批(H · 死码清账, 进行中)

只做 E 报告里**零风险且无需产品决策**的 7 条(A 级 6 条 + `cupertino_icons` 依赖):
Rust `PROVIDER_NETEASE` / `with_channel` / `set_gain_db`; Dart `uploadJson` / `kImageHeaders` / `DailyPlaylistCache.purge`; pubspec 去掉 `cupertino_icons`。
**明确不做**: `requiresPurchase`、`validateEqProfile`(是未接线功能)、`Playback.setVolume` 整链(0..1 音量档无入口, 需产品决策)、C 级 4 条 FFI 真死出口(要 codegen 独占窗口)、B 级 3 条(要先改测试断言)。

## 2.7 第三批(v0.22.0 之后, 2026-11-18 晚 · 四条车道并行)

| 车道 | 范围 | 依据 |
|---|---|---|
| I FFI 孤儿清理 | 删 \`playlist_tracks_add\` / \`podcast_radio\` / \`signin_status\` 三个 FFI 出口(provider 层保留给 \`ncm-cli\`), 走 codegen 三步, 导出 161→158 / 无入口 9→6 | deadcode-audit §3 |
| J B 级死码 + 测试迁移 | \`kBrandSeed\` / \`kPageHorizontalPadding\` / \`shouldShowBadges\` 三条只被测试引用 —— **迁移断言到现行口径**后再删, 不许把测试删空 | deadcode-audit §2 |
| K U-01/U-02 | 「切 tab 收起浮层」收敛成单一入口(现已漏 5 类) + \`QueueSheetController.close()\` 改持有 route/removeRoute(现在误关确认框) | arch-audit-ui-overlay §U-01/U-02 |
| M U-04 | 播 MV 不暂停歌曲 + MV Activity 无音频焦点 ⇒ 双音源并发; 真机听感交用户 | arch-audit-ui-overlay §U-04 |

**未派(下下批或需决策)**: U-03 统一 \`showAppSheet\`(23 处, M 级, 与 K 撞车) · U-05/U-06 守卫 · `0..1 音量档`与`EQ 导入校验`两条需产品决策 · §11.A 的 5 项真人/真机冒烟。

## 2.8 第三批回执(v0.22.1, 2026-11-18 深夜)

| 车道 | 结果 | 编排者复核 |
|---|---|---|
| I FFI 孤儿 | 删 3 个真死导出 + codegen 三步; `api.rs` -18, 生成文件为纯删减 + funcId 重编号 | 导出 **158**/无入口 **6** · `api.rs` numstat `0 18` · provider 方法仍在 · Dart 侧零残留 |
| J B 级死码 | 3 条公开符号删除, 断言**迁移**到现行口径(不是删测试); 净删 23 行 | `dart analyze` 0 · 全量 1163 |
| K U-01/U-02 | `dismissAllPopups()` 单一入口 + `PopupRoute` 登记表; 队列面板 `close()` 改 `dismissPopupRoute`; +7 例(含「换回旧写法就红」的回归) | 结构已核(`openPopups`/`dismissAllPopups`/`home_page:1104` 唯一调用) · 全量 1163 |
| M U-04 | Dart duck/unduck + MV 申请音频焦点 + 歌曲 ExoPlayer `handleAudioFocus=true`(media3 默认 false 已实证) | Kotlin 单测 3→7 · lint 0 error · 需用户真机验听感 |

发版: **v0.22.1** 已双推 + tag, GitHub CI 与 Release 全绿(9 个分发物)。

## 2.9 下一批候选(v0.22.1 之后)

1. **U-03 统一 `showAppSheet`**(44 处弹层调用, M 级; K 车道已把路由工厂 `buildAppSheetRoute` 建好, 迁移可分批)。
2. **U-05/U-06**(帧后回调 `mounted` 守卫 + `HomeWiring._latest` 的 A/B 组合) 与 **U-07 `didReplace`**。
3. **需用户拍板**: 0..1 音量档(补入口 or 三端一起删) · EQ 导入是否接回 `validateEqProfile` 校验。
4. **需真机/人眼**: MV 双音源 3 步听感 · 桌面宽屏观感(1280+ / 1280x800 golden 基准) · §11.A 的 5 项冒烟。

## 2.10 第四批(v0.23.0 之后, 2026-11-18 晚 · 用户新反馈 4 条 + 冒烟 + 双列)

| 车道 | 范围 | 备注 |
|---|---|---|
| P1 桌面播放条 | 桌面平台隐藏队列排位(N/M), 手机保留; 判据抽纯函数 | 只改 `player_bar.dart` + 测试 |
| P2 关注页 | ① 顶部横条数量按可用宽自适应(根因: `_visibleAuthorCount=8` + chip 固定 64)且与列表等宽 ② 点击语义统一: 横条(含头像)只聚焦、动态卡头像才进用户页 ③ 刷新: 修「刷新后条目变少」+ 桌面加拖拽/滚轮到顶刷新 | 一个车道按 1→2→3 |
| P3 AppImage 冒烟 | §11.A 只做 AppImage: 本地构建 + xvfb/dbus 运行期断言 + 资产清单 + 固化成脚本 | 不 sudo/不装包 |
| P4 双列 S0+S1 | `twoColumnFor(Size)`(宽≥900 且 高≥560) + 歌单详情页内双列 300/12/528 | 不改窄/中档分支、不碰路由 |

## 3. 审计结果如何转成下一批

审计收口后, 下一批按「可自动验收」优先挑:

1. **E 车道的 A 级死代码**(零风险: 无人引用的私有/半私有成员、真无入口的 FFI 导出、过期常量) → 一批删除 + 门禁回归, 目标 `dart analyze` 仍 0。
2. **F 车道的 P1 项**(若有「返回键能退出 App / 弹层叠栈 / dispose 后回调」这类真缺陷) → 与 E 同批或紧随, 每条一个 commit。
3. **D 车道清出的文档债** → 随上述任一批顺带提交(文档提交不单独发版)。
4. 需真人/真机的 5 项继续挂 §11.A 等用户窗口, 不派子代理(派了也无法验收)。
5. 版本号: 若本批只有删除/文档/小修且反馈数 ≤5 ⇒ **patch +1**(0.21.0 → 0.21.1); 含返回栈/浮层架构改动 ⇒ **minor**。

## 4. 验收口径(编排者独立重跑, 不采信子代理自报)

- 文档车道: `git diff --stat` 只落在 `docs/` 与 `.pi/memory/`; 抽查 3 条被删/被改的事实与 HEAD 现码一致; `docs/README.md` 内链全部可解析(`rg -o '\]\(([^)]*)\)'` 逐个 test -f)。
- 死代码车道: 报告里每条候选附「引用计数命令 + 输出」; 抽样 5 条用 `rg` 复核; 确认没有把生成代码/测试夹具误判。
- UI 评估车道: 每条结论附文件:行号; 抽样 3 条复核; 不得出现「建议全面重构」这类无落点的结论。
- 三车道都要求: `■ 结束` 收尾、单轮内完成、不跑长构建(需要数字时读 `docs/PROGRESS.md` 头部表并注明是抄的)。
