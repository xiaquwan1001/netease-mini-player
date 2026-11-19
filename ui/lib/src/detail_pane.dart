/// 主从分栏(master-detail)的右栏详情槽位 + 统一入口(方案 B · S4)。
///
/// 为什么**不是**一条路由: 右栏是"同一页里的第二列", 不是新页面。
///   · 做成嵌套 Navigator: 根上的 [NcmRouteObserver] 只挂根 Navigator, 右栏里弹出的
///     底部面板/对话框不会被登记 ⇒ `dismissAllPopups` 漏收、`modalRouteOpen` 不亮
///     (U-01/U-02 复发); 给嵌套 Navigator 也挂 observer 又会让 `pageDepth` 双计;
///   · 所以右栏只是一个 **Widget 槽位**(与 `playerBarSlot` 同形), 不产生路由:
///     右栏里弹的 sheet 仍然走根 Navigator, 登记面与改动前完全一致。
///
/// 几何: 壳层把内容限宽到 `kContentMaxWidth`=840, 主从分栏在 840 内切成
/// 左(列表, Expanded) / 间距 [kTwoColumnGap]=12 / 右 [kDetailPaneWidth]=420。
library;

import 'package:flutter/material.dart';

import 'layout.dart' show kDetailPaneWidth, kTwoColumnGap, twoColumnFor;

/// 右栏详情的一次请求。
class DetailPaneRequest {
  const DetailPaneRequest({required this.key, required this.builder});

  /// 选中态锚点(歌单 id / 专辑 id ...): 左栏据此高亮"右栏正在看的那一行",
  /// 右栏用它当 Widget key —— 换一条就用新的 State, 不复用上一条的滚动位置。
  final Object key;

  /// 右栏内容。调用方应给"内嵌形态"(如歌单详情的 `embedded: true`:
  /// 去 AppBar / 去返回箭头), 否则右栏里会出现一条"返回箭头退整页"的错语义。
  final WidgetBuilder builder;
}

/// 右栏详情的全局槽位(null = 没有右栏, 页面整宽)。
///
/// 全应用**只有一个**右栏: 主从分栏的左栏主人同一时刻只有一个(当前是 HomePage
/// 根路由), 所以不需要栈 —— 换详情就是换 value。
final ValueNotifier<DetailPaneRequest?> detailPaneSlot =
    ValueNotifier<DetailPaneRequest?>(null);

/// 左栏据此高亮选中行; null = 没有选中(没有右栏)。
Object? get detailPaneKey => detailPaneSlot.value?.key;

/// 关掉右栏(返回键新层级 / 切 tab / 窗口缩到非宽档都走这里)。返回是否真的有关。
bool closeDetailPane() {
  if (detailPaneSlot.value == null) return false;
  detailPaneSlot.value = null;
  return true;
}

/// 是否处在主从分栏态(右栏有内容)。
bool get detailPaneOpen => detailPaneSlot.value != null;

/// 已挂载的"会渲染右栏的宿主"页数。
///
/// 为什么需要: [openDetail] 只有在**宿主在场**时才该填右栏。歌单详情页自己的
/// 双列/golden 测试里并没有 HomePage(没人渲染右栏), 那时必须照旧 push 出一整页,
/// 否则详情"打开后什么都没有"。
int _hostCount = 0;

/// 宿主是否在场(只有 HomePage 这类根路由会调用 [attachDetailPaneHost])。
bool get detailPaneHostActive => _hostCount > 0;

/// 页面挂载时调用(与 [detachDetailPaneHost] 成对, 用计数而不是 bool:
/// 测试里换树时新旧页面的 initState/dispose 顺序不保证)。
void attachDetailPaneHost() => _hostCount += 1;

void detachDetailPaneHost() {
  if (_hostCount > 0) _hostCount -= 1;
}

/// 打开一个详情的**统一入口**: 宽档填右栏, 窄/中档照旧 push 一整页。
///
/// 判定顺序(必须按这个顺序, 三条都可能否决右栏):
///   1. 宿主在场([detailPaneHostActive]) —— 没有右栏可填就只能 push;
///   2. 调用者所在的路由是**根路由**(`route.isFirst`) —— 从歌单广场这类
///      "已经压上来的全屏页"里点详情, 右栏在下面那层(看不见), 也必须 push;
///   3. 窗口满足 [twoColumnFor](宽 >= 900 且 高 >= 560)。
///
/// [key] 是选中态锚点, [pane] 是内嵌形态, [route] 是窄档的全屏形态 —— 两者必须是
/// 同一份内容(歌单详情的 `embedded` 只影响 AppBar/返回箭头/双列判定)。
Future<void> openDetail(
  BuildContext context, {
  required Object key,
  required WidgetBuilder pane,
  required Route<void> Function() route,
}) async {
  final current = ModalRoute.of(context);
  final atRoot = current == null || current.isFirst;
  if (detailPaneHostActive &&
      atRoot &&
      twoColumnFor(MediaQuery.sizeOf(context))) {
    detailPaneSlot.value = DetailPaneRequest(key: key, builder: pane);
    return;
  }
  await Navigator.of(context).push(route());
}

/// 主从分栏: 右栏有详情时把 [master] 与右栏排成一行, 否则原样返回 [master]。
///
/// [master] 收一个 builder 而不是 Widget: 左栏要能读到"当前选中哪一条"
/// ([detailPaneKey]) 来画选中态, 所以槽位一变左栏必须跟着重建。
///
/// 窗口从宽档缩到窄/中档时**关掉右栏**(帧后), 语义与"返回键只清右栏"一致:
/// 右栏放不下就没有'正在看这个详情'这件事了, 下次点还是走 push。
class DetailPaneSplit extends StatelessWidget {
  const DetailPaneSplit({super.key, required this.master});

  final Widget Function(BuildContext context, Object? selectedKey) master;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DetailPaneRequest?>(
      valueListenable: detailPaneSlot,
      builder: (context, request, _) {
        final masterView = master(context, request?.key);
        if (request == null) return masterView;
        if (!twoColumnFor(MediaQuery.sizeOf(context))) {
          // 帧后关: 在 build 里同步写 ValueNotifier 等于 markNeedsBuild 祖先
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => closeDetailPane(),
          );
          return masterView;
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: masterView),
            const SizedBox(width: kTwoColumnGap),
            SizedBox(
              width: kDetailPaneWidth,
              child: DetailPaneSurface(
                // 换一条详情 = 新的 key ⇒ 右栏换新 State(不复用上一条的滚动位置)
                child: KeyedSubtree(
                  key: ValueKey<Object>(request.key),
                  child: request.builder(context),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 右栏的视觉外壳: 圆角 + 细边框, 与左栏列表在视觉上分开(不是第二条滚动容器)。
class DetailPaneSurface extends StatelessWidget {
  const DetailPaneSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(12);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: radius,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: ClipRRect(borderRadius: radius, child: child),
    );
  }
}
