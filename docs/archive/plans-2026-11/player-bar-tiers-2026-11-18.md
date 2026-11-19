# N2 · 底部播放条竖屏/横屏文案分档(2026-11-18)

## 需求

竖屏设备底部只要歌曲图形 icon; 横屏(平板/电脑)显示完整歌名 + 艺人名, 空间还有就加专辑名。

## 落地

- `ui/lib/src/player_bar.dart`
  - 档位复用 `layout.dart` 的 `layoutTierFor`(窄 < `kCompactMaxWidth` 600 <= 中 < `kWideMinWidth` 900 <= 宽), 不自造阈值。
  - 窄档: 信息块整块不渲染, 用 `Spacer()` 把右侧控件推到与中/宽档相同的位置; 只剩封面(`CoverArt` 自带 `music_note` 中性占位图标, 无封面/加载失败不会留白)。
  - 中档: 两行 —— 第 1 行歌名(VIP/付费仍是行首彩色前缀), 第 2 行艺人 + 位置/时长 + 队列序号(既有信息不丢, P-10「已排队→mm:ss」仍在第 2 行行首)。
  - 宽档: 同上, 第 2 行在**空间还有**时追加 ` · 专辑名`。
  - 新增 `playerBarShowsAlbum({tier, infoWidth})`: 唯一判据 = 宽档 + 信息块实测可用宽 >= `kPlayerBarAlbumMinWidth`(120)。可用宽由信息块的 `LayoutBuilder` 给出(不是窗口宽), 所以壳层把播放条塞进窄容器时不会硬塞专辑名。
  - 交互零回退: 点封面仍 `onOpenDetail`, 点信息区仍 `onToggleLyrics`, 进度条/上一首/下一首/喜欢/队列/`absorbBottomInset` 全未动。
- `ui/lib/src/layout.dart`: 新增 token `kPlayerBarAlbumMinWidth = 120`(带口径注释, 与 `kPlayerBarRoomyWidth` 同节)。
- 文案来源: **不加字段** —— `rust.SongDto` 已有 `name` / `album` / `artist`, `PlayerBarData.current` 直接可读, 无需动 Rust/FFI, 也不需要从 queue 另取(零新全局状态)。

## 测试

新增 `ui/test/player_bar_tiers_test.dart`(10 例): 360 只有 icon 无文字 + 无封面兜底 `music_note` · 360 点封面进详情 + 控件齐全 · 700 名+艺人不带专辑 + `3/12` · 700 点信息区开歌词 · 1200 名+艺人+专辑 · 700/1200 × textScale 1.25 不溢出 · 700 无曲目给「未在播放」· `playerBarShowsAlbum` 纯函数 2 例(档位 + 阈值含等于)。

改既有 `ui/test/player_bar_narrow_test.dart`: 300dp 原先断言 `find.textContaining('3/12')`, 现在窄档无任何文字, 改为断言播放条内 `Text` 为 0。

## 自验(本机实测)

- `cd ui && dart analyze` → No issues found(0 issue)。
- 播放条相关 6 个测试文件 → 30 例全绿。
- 全量 `flutter test --exclude-tags network` → 1199 例, **1 失败**: `update_checker_test.dart: 设置页「检查更新」项 UI ... 300dp + 1.25 字号`(设置页找不到「检查更新」项)。与播放条无关 —— 工作树里另有车道的 `settings_view.dart` / `settings_audio_page.dart` / `settings_sleep_timer_page.dart` 改动(定时关闭/音质), 该失败归那条车道, 本车道未碰这些文件。
- golden: 18 张无变化(日志 `Failing tests` 只有上面那一条)。
- `tools/check-tokens.sh --strict` → OK; `tools/check-row-padding.sh --strict` → OK; 自己改的 4 个文件 `dart format --set-exit-if-changed` → 0 changed。

## 备注

- 中/宽档是两行文本块(歌名 + 艺人/专辑/时间), 1.0 字号下总高约 37dp < 封面 40dp, 所以播放条高度基本不变; 大字号(1.25/1.625)时播放条会随文字自然变高, 不溢出。
- 窄档仍保留 `Slider` 进度条: 用户口径只针对「文案」, 进度条是交互面, 未按档位隐藏。
