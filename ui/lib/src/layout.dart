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

/// 小组标题与下文内容的垂直间距; 历史上散落 6/8 两种, 统一到 8。
const double kSectionTitleGap = 8;

/// 小组标题行自身的 padding(只保留下方间距)。
const EdgeInsets kSectionTitlePadding = EdgeInsets.only(
  bottom: kSectionTitleGap,
);

/// 区块与区块之间的垂直间距(「我的」页里两块卡片/两个区块之间)。
const double kSectionGap = 16;

/// 相邻卡片之间的紧凑垂直间距。
const double kCardGap = 4;

// ───────────────────────────────────────────────────────────────────────────
// 固定行高列表(itemExtent)
//
// `SliverFixedExtentList` / `ListView(itemExtent:)` 的行高是**硬约束**: 内容比它高
// 就会被从下方裁掉并抛 RenderFlex vertical overflow。1.625 字号(系统 1.25 ×
// 应用"特大" 1.3)下「标题 + 2 + 副标题」自然高约 68dp, 塞进 56dp 就竖溢 12dp。
// 所以行高必须随系统字号等比放大, 与 `main.dart` 的歌词行高(`_lyricItemExtent`)
// 同一口径: 基准 × textScaler, 上限 2 倍(再大的字号靠系统层另行处理)。
// ───────────────────────────────────────────────────────────────────────────

/// 列表行基准行高(曲目/节目行, 即 textScaler = 1.0 时的值)。
const double kRowExtent = 56;

/// 固定行高列表的实际行高: [base] × 系统字号, 上限 2 倍。
///
/// 只在 `itemExtent` / 需要按行数算滚动偏移的地方用; 普通 `ListView`(不设
/// itemExtent)让行自己撑高即可, 不需要缩放。
double rowExtentFor(BuildContext context, [double base = kRowExtent]) {
  final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
  return base * scale;
}

// ───────────────────────────────────────────────────────────────────────────
// 定高横滑条(艺人筛选条 / 最近联系人条)
//
// 两条都是 `SizedBox(height: 84)` + 横滑 `ListView`, 结构相同: 头像(40/44) +
// 间距 + 一行 11sp 标签。写死 84 时 1.625 字号下标签行高变高, 整条**竖向溢出 4dp**;
// 所以只放大文字那一段, 头像与内边距保持原值。
// ───────────────────────────────────────────────────────────────────────────

/// 头像横滑条的基准高度(textScaler = 1.0 时的值)。
const double kAvatarStripHeight = 84;

/// 头像横滑条的实际高度: 固定部分(头像/内边距/间距) + 按字号放大的 11sp 标签行。
double avatarStripHeightFor(BuildContext context) {
  final label = MediaQuery.textScalerOf(context).scale(11) * 1.45;
  // -16 = 1.0 时的单行标签高, 保证 1.0 下仍是 84(既有几何不动)
  return kAvatarStripHeight - 16 + label;
}

// ───────────────────────────────────────────────────────────────────────────
// 方格网格(专辑 / 猜你喜欢 / 新碟 / 歌单广场)统一 delegate
//
// 之前三处各写一份 `SliverGridDelegateWithMaxCrossAxisExtent(max:160/180,
// childAspectRatio:0.72)`:
//   · 列数随屏宽漂移, 用户无法决定每行几张;
//   · 0.72 这个 aspect 是按 160dp 列宽手算的估值, 真实列宽变了以后高度不再贴合,
//     于是封面下方留出一条随屏幕宽度变化的空隙;
//   · 艺人页还用 `Expanded(CoverArt)` 去填这块高度, 结果方图被压成细长条。
// 现在: 列数由设置项 [AppSettings.gridColumns] 决定(2-4), 高度 = 正方形封面 +
// 间距 + 两行文字实测高(按 textScaler 放大), 末端不再有空隙。
// ───────────────────────────────────────────────────────────────────────────

/// 单个网格格子的宽度(整页铺满的场景: 屏宽 - 左右 padding - 列间距)。
double coverTileWidth(
  BuildContext context,
  int columns, {
  double crossAxisSpacing = 10,
}) {
  final width = MediaQuery.sizeOf(context).width;
  final usable = width - 2 * kPagePadding - (columns - 1) * crossAxisSpacing;
  return usable <= 0 ? 0 : usable / columns;
}

/// 方块网格 delegate: 列数固定、格子高 = 封面 + 两行文字(不再拍死 aspect)。
SliverGridDelegate coverGridDelegate(
  BuildContext context, {
  required int columns,
  double crossAxisSpacing = 10,
  double mainAxisSpacing = 12,
}) {
  final cols = columns < 1 ? 1 : columns;
  final tileWidth = coverTileWidth(
    context,
    cols,
    crossAxisSpacing: crossAxisSpacing,
  );
  final scaler = MediaQuery.textScalerOf(context);
  // 封面下的两行文字: 名字(labelMedium 12) + 副标题(labelSmall 11)。
  // 行高按 1.5 估 + 2dp 余量: 实测 1.4 时 300dp/大字下会溢出 3.8px
  // (GridView 的格子是硬约束, 溢出就是黄黑条), 宁可多留 2dp。
  final textHeight = 4 + scaler.scale(12) * 1.5 + scaler.scale(11) * 1.5 + 2;
  final tileHeight = tileWidth + textHeight;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: cols,
    mainAxisSpacing: mainAxisSpacing,
    crossAxisSpacing: crossAxisSpacing,
    childAspectRatio: tileHeight <= 0 ? 1 : tileWidth / tileHeight,
  );
}
