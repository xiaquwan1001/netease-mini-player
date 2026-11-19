# K 车道 · U-01 + U-02 落地记录(2026-11-18)

来源: `docs/archive/plans-2026-11/arch-audit-ui-overlay-2026-11-18.md` §0(P1 U-01 / P2 U-02) + `docs/remaining-batches.md` §14。
边界: 只做「切 tab 收起浮层」+「队列面板关自己那条 route」; **不**引 `showAppSheet`(U-03, 另一批)、
不动二级页返回键语义(U-07/P3)。

## 1. 新的单一入口

- **`dismissAllPopups()`** — `ui/lib/src/app_shell.dart`,切底部 tab 的唯一调用点
  (`home_page.dart` 的 `_onTabSelected` 只调它一次;旧的 `dismissLoginSheet()` + `_queueUI.close()`
  两行手写调用已删除)。
- 底座: `NcmRouteObserver`(已有观察者)从「只数弹层个数」升级为**登记表**——
  `static final List<PopupRoute> _popups`(栈序底→顶),`didPush/didPop/didRemove` 三处维护;
  新增只读快照 `openPopups`。
- 关法: 从栈顶往下逐条 `dismissPopupRoute(route)` = `isCurrent ? pop() : removeRoute(route)`。
  是 sheet 还是 dialog 无关,只要是 `PopupRoute` 就收。
- 新文件 `ui/lib/src/popup_routes.dart` 两把公共扳手(被队列面板/登录弹层/壳层共用,不复制三份):
  - `buildAppSheetRoute<T>()`: 与 `showModalBottomSheet` 同口径(主题捕获/遮罩文案/拖拽条)的底部面板
    路由工厂 —— 解决「`showModalBottomSheet` 不交出 route」这个根因;
  - `dismissPopupRoute(route)`: 关**这一条**,不碰上下层。

## 2. U-02

`QueueSheetController` 现在**持有自己的 route**(`ModalBottomSheetRoute<void>? _route`,
建 → `navigator.push` → finally 清空),`close()` 走 `dismissPopupRoute`(旧实现
`Navigator.maybePop()` 弹的是栈顶,面板上压着「清空确认框」时关错)。
登录弹层的 `dismissLoginSheet()` 收敛到同一个 `dismissPopupRoute`(一份实现,语义仍是"只关自己")。
`open()` 里"已展开再点 = 收起"也改成 `close()`,不再直连 `Navigator.pop()`。

## 3. 审计列的 5 类漏项各自怎么被覆盖

全部是 `showModalBottomSheet`/`showDialog`(`ModalBottomSheetRoute`/`DialogRoute`,两者都是
`PopupRoute` 子类)⇒ 走登记表,**无需逐类接线**:

| 漏项 | 代码位置 | 路由类型 |
|---|---|---|
| 歌曲动作面板 | `song_actions.dart:159` `showSongActionsSheet` + `home/song_action_wiring.dart:340`(分享) | ModalBottomSheetRoute |
| 收藏到歌单 | `home/song_action_wiring.dart:231`(选歌单) + `:301`(新建歌单 dialog) | ModalBottomSheetRoute / DialogRoute |
| 分享面板 | `song_share.dart:261`、`feed_share.dart:490/504/519` | ModalBottomSheetRoute |
| 关注页艺人筛选 | `feed/feed_view_body.dart:242`(`artist_filter_bar` 同库) | ModalBottomSheetRoute |
| 更新弹窗 | `update_dialog.dart:15` | DialogRoute |

全仓现查 44 处 `showModalBottomSheet|showDialog`(`ui/lib/src` 排除生成代码),
**没有** `showGeneralDialog`/`showBottomSheet`(常驻式)用法,所以"浮层"这一类已被这一条路径全覆盖。
**确实不在本路径**: 无路由浮层 —— 播放条宿主 `OverlayEntry`(`app_shell.dart`,常驻,不该被 tab 收起)
与队列面板的顶部 toast(`OverlayEntry` + 900ms 自动消失)、`ScaffoldMessenger` SnackBar(3s 自动消失)。

## 4. 新增/改动的测试

新增 `ui/test/tab_switch_popups_test.dart`(5 例,壳层装配与生产一致: `NcmRouteObserver` +
`PlayerBarHost`,1200 宽走宽档 Rail,断言用 `support/nav_chrome.dart` 的档位中立查找器):
1. `dismissAllPopups` 一次收掉 sheet 上叠 dialog(返回 2,两者都消失);
2. **U-02 回归**: 队列面板 → 面板里点「清空队列」弹出「清空播放队列?」→ 切 tab ⇒ 两者都关、
   `pageDepth` 不变、tab 真切了、`controller.isOpen == false`;
3. U-01 歌曲动作面板 → 切 tab ⇒ 关闭且 `pageDepth` 不变;
4. U-01 分享面板(`showSongShareSheet`)→ 切 tab ⇒ 关闭;
5. U-01 更新弹窗(`showUpdateDialog`)→ 切 tab ⇒ 关闭。

`ui/test/queue_sheet_controller_test.dart` 新增「收起面板(U-02)」2 例:
- 面板之上压着对话框时 `close()` 关的是自己那条,上层不动(**已实测: 把 `close()` 换回旧
  `maybePop()` 写法时这一例失败**,是真回归用例);
- `close()` 自己 pop 完不误退页面。

`ui/test/login_sheet_test.dart` 的「切 tab 收起登录弹层」用例补 `navigatorObservers: [NcmRouteObserver()]`
(与生产装配对齐;新入口要靠观察者的登记表,不挂就收不到),断言一条没改。

## 5. 自验数字(本机实测,2026-11-18)

| 门 | 结果 |
|---|---|
| `cd ui && dart analyze` | **No issues found!** |
| `dart format --set-exit-if-changed`(改动的 8 个文件) | 0 changed |
| 相关单跑(`tab_switch_popups` / `login_sheet*` / `queue_sheet*` / `ui_batch_a_back_nav` / `content_width_limit` / `nav_rail_shell` / `top_bar_no_duplicate`) | 全绿 |
| 全量 `flutter test --exclude-tags network` | **1163 passed / 0 failed** |
| `check-tokens` / `check-row-padding` / `check-write-guard` | OK / OK / OK |
| golden | 18 张**未变化**(无重出) |

⚠️ 1163 不等于「1148 + 本批 7」: 工作树里并行着别的车道(MV 音频焦点、`adaptive_text_row`、`theme_accent`、
`layout_metrics` 等都有未提交改动与新用例),`git status` 现查可核。本车道新增 = `tab_switch_popups_test` 5 例
+ `queue_sheet_controller_test` 2 例 = **7 例**,其余差值属其它车道。

## 6. 未尽事项 / 已知边界

- `showAppSheet` 统一入口仍是 U-03(未做,本批刻意不碰 23 处 call site,避免撞车)。
- 同一 tab 再点一次(`_onTabSelected` 的 `_tab == index` 早退)仍不会收浮层 —— 与改动前一致,
  本批未改这条语义(要改属新需求)。
- `QueueSheetController.isOpen` 现在只剩 controller 自身与测试在用(页面侧已不读);保留 getter,
  若 E 车道判死码可一并清。
- `NcmRouteObserver` 仍未处理 `didReplace`(审计 U-07/P3,本批不动)。
- 浮层收起是"栈顶带动画 pop + 其余 removeRoute(瞬收)",没有为多条浮层编排动画 —— 一帧内全清,
  视觉上就是"切过去已经是干净页面"。
