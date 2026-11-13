import 'package:flutter/widgets.dart';

// ───────────────────────────────────────────────────────────────────────────
// 横向留白栅格(lane/ui-layout / 需求 10)
//
// 全仓只允许**两级**横向留白, 任何页面都不再自造第三种数字:
//
//   [屏幕边缘] ─ kPagePadding(12) ─ [卡片/区块左边缘]
//                                    ─ kCardRowInset(4) ─ [行内内容]
//
// 叠加后的目标「距屏」值(从左边缘算起, 单位 dp):
//
//   · 卡片 / 区块外边缘 ............ 12  = kPagePadding
//   · 区块标题(纯文本) ............ 12  = kPagePadding(SectionHeader 自己不带左右 padding)
//   · 卡片内行内容(封面/图标) ..... 16  = kPagePadding + kCardRowInset
//   · 整页铺满的歌曲行 .............  8  = 页面 padding 0 + kSongRowPadding 左边 8(右边 4)
//   · 行内标题与 leading 的间距 ....  8  = kRowTitleGap(Material 默认 16, 白吃 8dp)
//
// 反面案例(2026-11 用户反馈「左右空隙大」的根因, 不要再出现):
//   页面 12 + 列表 12 + ListTile 16 = 44 三重叠加;
//   Card 用默认 margin 4 或 all(12) 叠在页面 padding 上 = 16 / 24;
//   同一页里 8/4、12/4、12/12、不设(16/16)、0/0 五种行留白并存。
// ───────────────────────────────────────────────────────────────────────────

/// 页面级水平留白(卡片、区块、区块标题的外边缘都对齐这条线)。
const double kPagePadding = 12;

/// 页面级水平留白(只左右)。
const EdgeInsets kPageHorizontalPadding = EdgeInsets.symmetric(
  horizontal: kPagePadding,
);

/// 可滚动页面的标准 padding: 左 12 / 右 12, 顶部 8, 底部 24(给底部播放条留量)。
const EdgeInsets kPageInsets = EdgeInsets.fromLTRB(
  kPagePadding,
  8,
  kPagePadding,
  24,
);

/// 卡片内的行相对卡片边缘再内缩的量。
/// 目标距屏 = [kPagePadding] + 本值 = 16; 取 4 而不是 0 是为了不被卡片圆角切到。
const double kCardRowInset = 4;

/// 卡片内的行留白(ListTile.contentPadding): 左贴卡片边缘+4, 右边 4 给行尾按钮。
const EdgeInsets kCardRowPadding = EdgeInsets.fromLTRB(
  kCardRowInset,
  0,
  kCardRowInset,
  0,
);

/// 歌曲行留白: 用在**整页铺满**(页面 padding 0)的歌曲列表里,
/// 左侧 8 保证和封面留一点呼吸, 右侧 4 给行尾按钮。
const EdgeInsets kSongRowPadding = EdgeInsets.fromLTRB(8, 0, 4, 0);

/// 行内标题与 leading(封面/图标/序号)之间的水平间距。
/// Material 默认 16, 在 300dp 屏上等于白吃 5% 宽度。
const double kRowTitleGap = 8;

/// 卡片统一外边距 —— 永远不给 Card 留 margin。
/// Material 默认 margin 是 4, 会悄悄叠在页面 padding 上。
const EdgeInsets kCardMargin = EdgeInsets.zero;

/// 区块标题与下文内容的垂直间距。
const double kSectionHeaderGap = 8;

/// 区块标题行自身的 padding(只保留下方间距)。
const EdgeInsets kSectionHeaderPadding = EdgeInsets.only(
  bottom: kSectionHeaderGap,
);

/// 区块与区块之间的垂直间距(「我的」页里两块卡片/两个区块之间)。
const double kSectionGap = 16;

/// 相邻卡片之间的紧凑垂直间距。
const double kCardGap = 4;
