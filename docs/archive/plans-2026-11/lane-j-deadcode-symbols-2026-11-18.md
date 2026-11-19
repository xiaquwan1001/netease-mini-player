# J 车道:B 级公开符号清账(只被测试引用)—— 2026-11-18

范围: 3 条符号 + 3 个测试文件, 不动 UI 行为, 不动 `ContentWidthLimit`/`LayoutTier`。
上游: `docs/archive/plans-2026-11/deadcode-audit-2026-11-18.md`(E) / `arch-audit-ui-overlay-2026-11-18.md`(F) / `2026-11-18-next-batch.md`。

## 1. `kBrandSeed`(ui/lib/src/theme.dart)—— 已删

- 原引用(唯一): `ui/test/theme_accent_test.dart:59` `expect(AccentPalette.neteaseRed.seed, kBrandSeed);`
- 新断言(同一测试, 不降强度):
  ```dart
  expect(AccentPalette.neteaseRed.seed, const Color(0xFFF40000));
  expect(
    buildLightTheme().colorScheme.primary,
    const Color(0xFFBC0100),
    reason: '默认品牌红 seed 的浅色 primary 必须仍是改造前的 #BC0100',
  );
  ```
  原有「不传 accent == 传 neteaseRed」「深色同理」两条保持不动 ⇒ 现在是
  「常量值 + 同一 seed 推出的 primary 值 + 两条等价性」三重锚点。
- 顺带把 theme.dart / 该测试头注释里指向 `kBrandSeed` 的文字换成字面色值(否则成悬挂指针)。

## 2. `kPageHorizontalPadding`(ui/lib/src/layout.dart)—— 已删

- 原引用(唯一): `ui/test/layout_metrics_test.dart:157` 用它给 SectionHeader 当页面内缩。
- 新断言: 在同一个 SectionHeader 用例开头补现口径几何关系(用例数不增不减):
  ```dart
  expect(kPageInsets.left, kPagePadding);
  expect(kPageInsets.right, kPagePadding);
  expect(kPageInsets.horizontal, kPagePadding * 2);
  expect(kPageInsets.vertical, 8 + 24);
  expect(kPageRowPadding.left, kPagePadding);
  expect(kPageRowPadding.right, kCardRowInset);
  expect(kCardRowPadding.horizontal, kCardRowInset * 2);
  ```
- 测试里的 Padding 改 `EdgeInsets.symmetric(horizontal: kPagePadding)`(与原常量数学等价, 渲染坐标断言照旧)。

## 3. `shouldShowBadges`(ui/lib/src/adaptive_text_row.dart, 10 行)—— 已删

- 原引用: `ui/test/adaptive_text_row_test.dart` 的整个 `shouldShowBadges 纯函数(阈值判定)` group(2 个 test)。
- 迁移: group 改名 `shouldShowBadgesForWidth 纯函数(阈值判定, 现口径: 行宽 - 徽标宽)`, **仍是 2 个 test**(用例数不变),
  断言全部保留并补齐新口径:
  - 原宽度档位 60/80/119.9/120/121/200 → `shouldShowBadgesForWidth(w, 0)`(徽标 0 宽时两函数等价, 逐档保留);
  - 空徽标列表: `badgeGroupWidth(const []) == 0` + 判定退回整行宽(119.9 隐藏 / 120 显示);
  - 新口径核心: `titleAvailableWidth(130,72)==58`、`shouldShowBadgesForWidth(200,72)` true(可用 128)、
    `(191.9,72)` false(可用 119.9, 旧口径按整行宽会误判)、`(192,72)` true(恰好 120);
  - 自定义阈值: `(100,10,threshold:90)` true / `(99,10,90)` false / `(0,0)` false;
  - 钳位: `titleAvailableWidth(60,139)==0`、默认阈值 false、`threshold:0` true(证明确实钳到 0 而非负数)。
  textScaler / 300dp 等组件级边界在同一个文件里原样保留(未动)。

## 自验(现测, 2026-11-18)

| 门 | 结果 |
|---|---|
| `cd ui && dart analyze` | **No issues found!** |
| `dart format --set-exit-if-changed`(6 个改动文件) | exit 0, 0 changed |
| `flutter test test/theme_accent_test.dart test/layout_metrics_test.dart test/adaptive_text_row_test.dart` | **23 passed, 0 failed** |
| `flutter test --exclude-tags network`(先 `cargo build -p ncm_ffi`) | **1148 passed, 0 failed**(与基线同数, 未减) |
| `tools/check-tokens.sh --strict` | OK |
| `tools/check-row-padding.sh --strict` | OK |

## 删除行数(`git diff --numstat`, 只列本车道 6 个文件)

```
0	11	ui/lib/src/adaptive_text_row.dart   (删 shouldShowBadges 10 行 + 1 空行)
0	5	ui/lib/src/layout.dart              (删 kPageHorizontalPadding)
2	9	ui/lib/src/theme.dart               (删 kBrandSeed 6 行, 改 2 行注释)
44	12	ui/test/adaptive_text_row_test.dart
13	1	ui/test/layout_metrics_test.dart
10	2	ui/test/theme_accent_test.dart
```
lib 侧:**删 25 行 / 增 2 行** = 净删 23 行(其中被删的 3 个公开符号本体 6+4+10 = 20 行, 其余是失去指涉的注释/空行)。

## 注意

- 工作树里有**并行车道**同时改 `core/crates/ncm-ffi/src/api.rs`、`frb_generated.*`、`ui/lib/src/rust/*`
  (E 车道清 3 个真死 FFI 导出: `podcast_radio`/`playlist_tracks_add`/`signin_status`)。这些不是本车道改动, 未触碰、未回滚。
- 全量 1148 是在该并行状态下的工作树上跑的, 仍全绿。
