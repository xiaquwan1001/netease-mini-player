# T3 · 浮层入口第二批(U-03 收尾) · 2026-11-18

基线: HEAD = v0.25.0(Dart 1265 用例 / analyze 0 / `tools/check-sheet-entry.sh` 已接 ci-gates verify + CI,
待迁名单冻结 `PENDING_EXPECT=7`)。本批把剩下 **7 处**直连全部迁到统一入口, 门里**不再有待迁名单**。

## 1. 逐处迁移(语义逐字不变)

| # | 文件:行 | 原调用 | 迁移后 | 参数处置 |
|---|---|---|---|---|
| 1 | `ui/lib/src/detail/podcast_detail_page.dart:307` `_openProgramDetail` | `showModalBottomSheet<void>` | `showAppSheet<void>(context, builder:)` | 原写 `isScrollControlled: true` + `showDragHandle: true` = 入口默认 ⇒ 省略 |
| 2 | `ui/lib/src/home/home_page.dart:521` `_offerDesktopIntegration` | `showDialog<bool>` | `showAppDialog<bool>(context, builder:)` | barrierDismissible/useSafeArea 未写 = `showDialog` 默认 = `showAppDialog` 默认 ⇒ 省略 |
| 3 | `ui/lib/src/home/queue_sheet_controller.dart:192` `_maybeShowSwipeHint` | `showDialog<void>` | `showAppDialog<void>(context, builder:)` | 同上 |
| 4 | `ui/lib/src/home/song_action_wiring.dart:231` `_showAddToPlaylist` | `showModalBottomSheet<Object>` | `showAppSheet<Object>(context, isScrollControlled: false, builder:)` | **少数派显式写**: 原未写 = false, 面板高 0.6 屏被 9/16 屏上限夹 ✅ 行为不变 |
| 5 | `ui/lib/src/home/song_action_wiring.dart:301` `_createPlaylistAndAdd` | `showDialog<String>` | `showAppDialog<String>(context, builder:)` | 默认值一致 ⇒ 省略 |
| 6 | `ui/lib/src/home/song_action_wiring.dart:340` `_showShareSong` | `showModalBottomSheet<void>` | `showAppSheet<void>(context, isScrollControlled: false, builder:)` | **少数派显式写**: 原未写 = false(三行小列表) |
| 7 | `ui/lib/src/mine_view.dart:190` `_editSignature` | `showDialog<String>` | `showAppDialog<String>(context, builder:)` | 默认值一致 ⇒ 省略 |

泛型实参全部逐字保留(`void` / `bool` / `Object` / `String`); 高度包裹(SizedBox 0.6 屏 / `mainAxisSize.min` /
builder 内 `SafeArea`)一处未动 ⇒ 尺寸零变化。`useSafeArea` 一处都没开过(默认 false, 与旧口径一致)。

## 2. 门收敛 `tools/check-sheet-entry.sh`

- 删掉 `PENDING` 正则与 `PENDING_EXPECT=7`; 违规判定不再分流, `violations=$(scan)` 直接全量判红。
- `--self-test` 改为断言 `scan` 非空(以前是 `scan | grep -Ev "$PENDING"`)。
- 头注释同步: 「没有待迁移名单了, 白名单外一处直连都不许有」; `--help` 行范围随之从 `2,28` 改成 `2,22`。
- 现状: `bash tools/check-sheet-entry.sh` rc=0, 输出「浮层全部经 app_sheet.dart 入口」; `--self-test` rc=0
  (临时插一处 `showModalBottomSheet` 仍被抓到)。

## 3. 与 U-01/U-02 弹出登记表的兼容(新增测试)

7 处全部经 `buildAppSheetRoute`(sheet)或 `showDialog` 内部的 `DialogRoute`(dialog), 二者都是 `PopupRoute`,
因此都进 `NcmRouteObserver` 的 `openPopups` 登记表, 切 tab 时被 `dismissAllPopups()` 按 route 摘除。

新增用例: `ui/test/tab_switch_popups_test.dart` →
「U-03: home 歌曲动作装配的分享面板(wiring 入口)切 tab ⇒ 关闭」:
用 `SongActionWiring`(全注入, 不碰 Rust)调 `buildHost().share(song)` 打开 `_showShareSong`, 断言
① route 是 `ModalBottomSheetRoute<void>`(⇒ 走的是 `buildAppSheetRoute`) ② `switchToMine()` 后
`livePopups()` 空 ③ `pageDepth` 不误退。要点: 这条覆盖的正是本批从 `showModalBottomSheet` 迁过来的
home 入口(以前只能靠"恰好是 PopupRoute"兜住)。

## 4. 自验(编排者独立重跑)

| 门 | 结果 |
|---|---|
| `cd ui && dart analyze` | **No issues found!**(0) |
| `bash tools/check-sheet-entry.sh` | rc=0, 白名单外 0 处直连, 待迁 **0** |
| `--self-test` | rc=0(负向仍红) |
| `ci-gates.sh flutter-test`(全量, --exclude-tags network) | **1266 / 0 失败**(1265 + 新增 1), golden **20** 张**全部不变** |
| `ci-gates.sh {dart-format,write-guard,lock-poison,tokens,row-padding}` | 全 OK; `dart format` 342 文件 **0 changed** |

## 5. 改动面

```
tools/check-sheet-entry.sh                  | 28 ++++---------
ui/lib/src/detail/podcast_detail_page.dart  |  8 +++---
ui/lib/src/home/home_page.dart              |  5 ++--
ui/lib/src/home/queue_sheet_controller.dart |  5 ++--
ui/lib/src/home/song_action_wiring.dart     | 20 +++++++-----
ui/lib/src/mine_view.dart                   |  5 ++--
ui/test/tab_switch_popups_test.dart         | 43 ++++++++++++++++++++++++-
```
(工作区另有一处**非本批**改动 `tools/diag-worker/wrangler.toml`, 进来前就在, 未触碰。)

边界: 未改业务行为; 未动 `app_shell.dart` / `home_wiring.dart`; 未动 Rust; 未 commit;
未改 `docs/PROGRESS.md` 与 `docs/remaining-batches.md`(其「剩 7 处冻结」表述需由编排者统一更新)。
