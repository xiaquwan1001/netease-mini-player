# P1: 桌面版播放栏隐藏队列排位(2026-11-18)

## 用户原话 / 目标
桌面版底部播放栏不要显示当前歌曲在队列的排位,比如 2/35。手机端保留。

## 判据
- 平台判据: `!kIsWeb && (Platform.isLinux || Platform.isWindows)` → `bool get isDesktopPlatform`
  (player_bar.dart, 顶层 getter)。**与窗口宽度/档位无关** —— 窄窗口的桌面仍是桌面版。
- 纯函数判据: `bool playerBarShowsQueueIndex({required bool isDesktop}) => !isDesktop;`
  同为 player_bar.dart 顶层, 只吃平台布尔, 便于单测。

## 改动
- `ui/lib/src/player_bar.dart`
  - 新增 `isDesktopPlatform` getter 与 `playerBarShowsQueueIndex` 纯函数(含口径注释)。
  - `MiniPlayerBar` 新增可选参数 `desktopPlatformOverride`(null = 按当前进程平台);
    只在测试里注入, 因为 widget 测试跑在 Linux 宿主机上, 否则「手机端仍显示」无法验。
  - 第二行文案: 位置/时长**任何平台都留**; `N/M` 仅在 `showQueueIndex` 为真时追加
    (`已排队→mm:ss` 是 P-10 方案 B 的状态提示, 不算排位, 保留)。
- `ui/test/player_bar_tiers_test.dart`
  - `_pump` 增加 `desktopPlatform` 注入; 中/宽档既有断言钉成手机平台(`desktopPlatform: false`),
    排位覆盖不退化为「宿主机平台碰运气」; 中档补一条 `00:30 / 03:20` 断言。
  - 新增组「队列排位: 桌面隐藏 / 手机保留」: 桌面 700/1200 无 `N/M` 且歌名/艺人/位置时长仍在;
    桌面 + 待跳仍显示「已排队→00:42」; 手机 700 仍显示 3/12。
  - 新增组「排位判据(playerBarShowsQueueIndex)」纯函数单测。

## 验证
- `dart analyze`: No issues found (0)。
- `flutter test test/player_bar_tiers_test.dart`: 15 passed。
- `flutter test --exclude-tags network`: **1210 passed / 0 failed**(基线 1205 + 新增 5)。
- 既有 player_bar_*(narrow/seek/spacing/data/host)与 bottom_chrome_padding 全绿。
- `tools/check-tokens.sh`: OK;`tools/check-row-padding.sh`: 所有行留白都在具名口径里。
- golden: 未变化(golden 页宽 300/360 = 窄档, 窄档本来就不渲染文字块, 逐张无需重录)。
- 只对改动过的两个文件跑过 `dart format`(全仓格式化仍按项目纪律禁止)。

## 未做
- 未 commit;未动 docs/PROGRESS.md、docs/remaining-batches.md。
