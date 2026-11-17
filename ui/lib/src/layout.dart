import 'package:flutter/material.dart';

import 'app_settings.dart';

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
//   · 整页铺满的歌曲行 ...........  12  = 页面 padding 0 + kPageRowPadding 左边 12(右边 4)
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

/// 整页铺满列表的行留白: 左 = [kPagePadding](与 SectionHeader、页面标题严格共线),
/// 右 [kCardRowInset] 给行尾按钮。**歌曲行也是它** —— 行首是封面缩略图还是序号/图标,
/// 都不再分岔(见下)。
///
/// 列表行审计 C 级: 同一个「整页铺满」语义此前有 12/0/4、16/16(Material 默认)、
/// 8/0/4 三种数字并存; 2026-11-17 先收敛成「缩略图 8 / 其它 12」两级,**同日用户裁决
/// 取消这个二分**(同一页里封面行与序号行左右边界差 4dp 肉眼可见, 且与页面标题线不
/// 共线): 现在一律 12, 原 `kSongRowPadding`(8/0/4) 已删除, 不要再造第五种数字。
/// 父容器**已经**做了 [kPagePadding] 内缩的, 不要用这个(会叠成 24 = 三重叠加),
/// 用 [kCardRowPadding](叠出 16)或 [kPreviewRowPadding]。
const EdgeInsets kPageRowPadding = EdgeInsets.fromLTRB(
  kPagePadding,
  0,
  kCardRowInset,
  0,
);

/// 父容器已有水平内缩时, 行内不再重复加左右边(0), 上下给 6 的呼吸。
///
/// 艺人推荐单曲 / 他人主页「喜欢的音乐」预览行共用这一个口径
/// (此前两处各写一份 `symmetric(vertical: 6)`)。
const EdgeInsets kPreviewRowPadding = EdgeInsets.symmetric(vertical: 6);

/// 行内标题与 leading(封面/图标/序号)之间的水平间距。
/// Material 默认 16, 在 300dp 屏上等于白吃 5% 宽度。
const double kRowTitleGap = 8;

/// 行尾(trailing)一列最多吃掉行宽的多少 —— **全仓唯一口径**。
///
/// 之前各页各写一套(0.4 / 0.45 / 不设), 不设的那几处(排行 playCount、新歌发行
/// 日期、私信相对时间、关注按钮)行尾宽度完全由内容决定: 字号 1.625 倍或数字位数
/// 一变就把标题区挤扁(列表行审计 B5–B12)。取 0.45 与歌单详情 / song_tile 的既有
/// 口径一致, 与 [SectionHeader] 的 60% 同一思路 —— 标题区永远拿大头。
const double kRowTrailingMaxRatio = 0.45;

/// 给行尾内容加宽度上限: [availableWidth] 传行(或 LayoutBuilder 的
/// constraints.maxWidth)的可用宽。触顶时由行尾自己截断(时长/日期先省略),
/// 标题区不会被压到 0 宽。宽度拿不到上限(无限宽容器)时不套约束。
Widget capRowTrailing(double availableWidth, Widget child) => ConstrainedBox(
  constraints: BoxConstraints(
    maxWidth: availableWidth.isFinite
        ? availableWidth * kRowTrailingMaxRatio
        : double.infinity,
  ),
  child: child,
);

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
// 列表行的纵向口径(列表行审计 C 级 · 纵向 pitch, 2026-11-17)
//
// 横向留白收敛到具名常量之后, 纵向还留着几套隐式规则: 同一套 SongRow 在不同页面
// 实测落在**四个**高度(2026-11-17 探针, 360dp 宽, textScaler 1.0 / 1.3 / 1.625):
//
//   SongRow(tile 臂, 默认)                      64 / 63 / 76
//   SongRow(tile 臂, visualDensity.compact)     53 / 63 / 76
//   SongRow(tile 臂, kPreviewRowPadding 6/6)    76 / 75 / 88
//   SongRow(plain 臂, 无 itemExtent 时)         40 / 49 / 61   (只有封面高)
//   裸 ListTile(title+subtitle, Material 默认)  72 / 73 / 88
//
// 这些数不是色值猜测, 而是 ListTile 的 dense / minHeight / minVerticalPadding 与
// visualDensity 四条隐式规则叠加的结果 —— 谁调了其中一个, 整页 pitch 就变。
// 现在统一成一条:**行高 = [rowExtentFor], 行内纵向留白 = 0**。
// 唯一例外是父容器**已经**做过水平内缩的预览行([kPreviewRowPadding], 上下各 6):
// 那 6 是行内呼吸, 不参与行高计算(盒子仍按 [rowExtentFor] 定高)。
// ───────────────────────────────────────────────────────────────────────────

/// 给列表行一个确定的行高盒: 行高 = [rowExtentFor](基准 56 × 系统字号, 上限 2 倍)。
///
/// 用它包住 [ListTile] / 自绘行, 行高就不再由 ListTile 的 dense/minHeight/
/// visualDensity 决定(同一条行在不同页面会跑出 53/64/72/76 四个高度)。
/// 纵向留白仍由行内的 padding 决定(歌曲行 = 0, 预览行 = [kPreviewRowPadding]);
/// 盒子的高度已经包含它, 不要在外面再叠 SizedBox 间隔。
Widget rowHeightBox(BuildContext context, Widget child) =>
    SizedBox(height: rowExtentFor(context), child: child);

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

/// 方格网格的横向间距(列与列之间)。全仓网格统一用它, 不再一处 10 一处 12。
const double kGridCrossSpacing = 10;

/// 方格网格的纵向间距(行与行之间)。
const double kGridMainSpacing = 12;

/// 搜索结果 / 收藏 / 网格页的统一内边距: 左 [kPagePadding] / 右 [kPagePadding],
/// 顶部 4(紧接分类条), 底部 24(给底部播放条与安全区留量)。
const EdgeInsets kGridInsets = EdgeInsets.fromLTRB(
  kPagePadding,
  4,
  kPagePadding,
  24,
);

/// 单个网格格子的宽度。
///
/// [availableWidth] 是**网格真实能拿到的横向宽度**(视口/容器宽 - 页面左右 padding),
/// 由 [LayoutBuilder]/SliverConstraints 给出。以前这里用
/// `MediaQuery.sizeOf(context).width`(整屏宽)再减 2×[kPagePadding]:
/// 只要网格不在「满屏 - 12/12」的位置(嵌在 tab/卡片里、容器自带 padding、
/// 窄视口下还有固定尺寸的子组件), 格子宽就被高估, 格子高跟着偏大,
/// 固定宽度的封面(CoverArt)还会溢出格子右边 —— 肉眼看就是「3 列只剩 2 列」。
double coverTileWidth(
  double availableWidth,
  int columns, {
  double crossAxisSpacing = kGridCrossSpacing,
}) {
  final cols = columns < 1 ? 1 : columns;
  final usable = availableWidth - (cols - 1) * crossAxisSpacing;
  return usable <= 0 ? 0 : usable / cols;
}

/// 方块网格 delegate: 列数固定、格子高 = 封面 + 两行文字(不再拍死 aspect)。
///
/// 调用方一律从 `PagedListView.gridDelegateBuilder` 拿 [availableWidth]
/// (SliverConstraints.crossAxisExtent - 页面左右 padding), 不要自己用整屏宽算。
SliverGridDelegate coverGridDelegate(
  double availableWidth, {
  required int columns,
  double crossAxisSpacing = kGridCrossSpacing,
  double mainAxisSpacing = kGridMainSpacing,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final cols = columns < 1 ? 1 : columns;
  final tileWidth = coverTileWidth(
    availableWidth,
    cols,
    crossAxisSpacing: crossAxisSpacing,
  );
  final scaler = textScaler;
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

// ───────────────────────────────────────────────────────────────────────────
// 共享方格网格构建器(需求 8: 列的 n 只部分生效 / 搜索结果右侧留白)
//
// 以前每处网格各自写一份: 搜索结果用「固定 118dp 卡片 + Wrap」(列数与设置项
// AppSettings.gridColumns 无关, 窄屏排不下就右侧空一大片), 新碟/歌单广场用
// maxCrossAxisExtent(列数随屏宽漂移)。现在统一走 [CoverGrid]:
//   · 列数 = AppSettings.gridColumns(2-4, 设置一变立即重建);
//   · 格子宽 = (真实可用宽度 - (n-1) × [crossAxisSpacing]) / n, 每行正好 n 个,
//     右侧**没有**固定留白(只剩最后不足一行时右侧空白, 且末行左对齐);
//   · 格子高 = 正方形封面 + 两行文字实测高(见 [coverGridDelegate])。
// ───────────────────────────────────────────────────────────────────────────

/// 等宽方格网格: 列数固定、格子宽均分、末行左对齐。
///
/// [itemBuilder] 会拿到**真实格子宽**([tileWidth]), 封面请直接用它当边长
/// (不要写死 size: 118), 否则一改列数/字号就会溢出或右侧留白。
///
/// 默认是可滚动整页网格; 需要嵌在别的滚动容器里时传 [shrinkWrap]。
class CoverGrid extends StatelessWidget {
  const CoverGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = kGridInsets,
    this.columns,
    this.crossAxisSpacing = kGridCrossSpacing,
    this.mainAxisSpacing = kGridMainSpacing,
    this.shrinkWrap = false,
    this.physics,
    this.controller,
  });

  final int itemCount;

  /// (context, index, 真实格子宽)
  final Widget Function(BuildContext context, int index, double tileWidth)
  itemBuilder;

  final EdgeInsetsGeometry padding;

  /// 列数; 传 null 用 [AppSettings.gridColumns](设置项改动实时生效)。
  final int? columns;

  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final bool shrinkWrap;
  final ScrollPhysics? physics;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final cols = (columns ?? AppSettings.instance.gridColumns).clamp(1, 12);
    return LayoutBuilder(
      builder: (context, box) {
        final horizontal = padding
            .resolve(Directionality.of(context))
            .horizontal;
        // 嵌在横滑容器里时 maxWidth 是无限的, 退化成整屏宽(再减自身 padding)。
        final width = box.maxWidth.isFinite
            ? box.maxWidth
            : MediaQuery.sizeOf(context).width;
        final available = width - horizontal;
        final tileWidth = coverTileWidth(
          available,
          cols,
          crossAxisSpacing: crossAxisSpacing,
        );
        return GridView.builder(
          controller: controller,
          padding: padding,
          // 末行左对齐是 GridView 的默认行为(不像 Wrap 里居中的 center 对齐);
          // 这里显式用 start, 避免外层全局对齐方式把网格改成居中。
          physics:
              physics ??
              (shrinkWrap
                  ? const NeverScrollableScrollPhysics()
                  : const AlwaysScrollableScrollPhysics()),
          shrinkWrap: shrinkWrap,
          gridDelegate: coverGridDelegate(
            available,
            columns: cols,
            crossAxisSpacing: crossAxisSpacing,
            mainAxisSpacing: mainAxisSpacing,
            textScaler: MediaQuery.textScalerOf(context),
          ),
          itemCount: itemCount,
          itemBuilder: (context, i) => itemBuilder(context, i, tileWidth),
        );
      },
    );
  }
}
