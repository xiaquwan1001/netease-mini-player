import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/cover_art.dart' show CircleCover;
import 'package:minincm/src/feed_view.dart';
import 'package:minincm/src/layout.dart' show kPagePadding;
import 'package:minincm/src/rust/api.dart' as rust;

/// 顶部艺人横条「放几个」的自适应回归(2026-11-18 用户反馈 1)。
///
/// 之前是写死的 `_visibleAuthorCount = 8` + 每个 chip 固定 64dp: 与屏宽无关,
/// 1280 的桌面窗口与 360 的手机放同样多个(宽屏右侧一片空白)。
/// 现在 chip 宽是具名常量、个数由 LayoutBuilder 的**实际可用宽**算出来。

rust.FeedEventDto ev(
  int id, {
  int userId = 10,
  String name = '艺人甲',
  String text = '',
  int liked = 0,
}) => rust.FeedEventDto(
  id: BigInt.from(id),
  threadId: 'A_EV_2_${id}_$userId',
  userId: BigInt.from(userId),
  kind: 'text',
  userName: name,
  avatarUrl: null,
  text: text.isEmpty ? '动态 $id' : text,
  song: null,
  coverUrl: null,
  images: const [],
  videoUrl: null,
  title: '',
  timeMs: BigInt.from(1700000000000 - id * 1000),
  liked: false,
  likedCount: BigInt.from(liked),
  shareCount: BigInt.zero,
  commentCount: BigInt.zero,
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 20 位发布者(每人 1 条), 足够撑出"宽屏多放"的差异
FeedView feed(int authors) => FeedView(
  loggedIn: true,
  onLogin: () {},
  onOpenUrl: (_) async {},
  loadFeed: () async => [
    for (var i = 1; i <= authors; i++) ev(i, userId: 100 + i, name: '发布者$i'),
  ],
  loadSubscribedArtists: () async => const [],
);

/// chip 是私有组件, 且横滑 ListView 只构建可见的那几个 —— 直接读横向列表
/// 的 children 条数(渲染与计算共用同一份列表): 「全部」+ N 位作者 + 「进入全部」。
int chipCount(WidgetTester tester) {
  final bar = tester
      .widgetList<ListView>(find.byType(ListView))
      .firstWhere((l) => l.scrollDirection == Axis.horizontal);
  final delegate = bar.childrenDelegate as SliverChildListDelegate;
  return delegate.children.length;
}

/// 用特定窗口尺寸渲染并返回 chip 个数
Future<int> chipsAt(WidgetTester tester, Size size, {int authors = 20}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(host(feed(authors)));
  await tester.pumpAndSettle();
  return chipCount(tester);
}

void main() {
  group('visibleAuthorCountFor(纯函数)', () {
    int at(double width, {int total = 30, int minVisible = 8}) =>
        visibleAuthorCountFor(
          availableWidth: width,
          chipWidth: 64,
          gap: 10,
          total: total,
          minVisible: minVisible,
        );

    test('360dp: 铺不下也不低于兜底下限(8), 比"刚好铺满"的 2 个多', () {
      expect(at(360), 8);
    });

    test('600dp: 仍取兜底下限 8(不因算式变小而减少)', () {
      expect(at(600), 8);
    });

    test('840dp: 840/74 = 11 → 11 - 2 条固定入口 = 9', () {
      expect(at(840), 9);
    });

    test('1280dp: 1280/74 = 17 → 17 - 2 = 15', () {
      expect(at(1280), 15);
    });

    test('无限宽: 全部放出(不超过 total)', () {
      expect(at(double.infinity), 30);
      expect(at(double.infinity, total: 3), 3);
    });

    test('不足一个 chip: 至少给 1 个, 且不超过 total', () {
      expect(at(40, minVisible: 1), 1);
      expect(at(40, total: 2), 2);
    });

    test('total 为 0 时返回 0', () {
      expect(at(1280, total: 0), 0);
    });
  });

  testWidgets('宽屏(1280)比窄屏(360)放更多 chip', (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final narrow = await chipsAt(tester, const Size(360, 800));
    final wide = await chipsAt(tester, const Size(1280, 800));
    // 窄屏: 8 位作者 + 「全部」+「进入全部」
    expect(narrow, 10);
    // 宽屏: 14 位作者 + 两条固定入口
    expect(wide, 16);
    expect(wide, greaterThan(narrow), reason: '数量随可用宽自适应');
  });

  testWidgets('横条左右边缘与动态列表内容边缘对齐(±1dp)', (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await chipsAt(tester, const Size(800, 900), authors: 5);
    expect(tester.takeException(), isNull);

    // 横条第一个 chip 与第一张动态卡片的左边缘共线
    final chip = tester.getRect(
      find.byWidgetPredicate((w) => '${w.runtimeType}' == '_AuthorChip').first,
    );
    final card = tester.getRect(find.byType(Card).first);
    expect((chip.left - card.left).abs(), lessThanOrEqualTo(1));

    // 两条列表的水平内边距同口径(kPagePadding), 不是 12 vs 24 的两套数字
    final horizontal = tester
        .widgetList<ListView>(find.byType(ListView))
        .firstWhere((l) => l.scrollDirection == Axis.horizontal);
    final vertical = tester
        .widgetList<ListView>(find.byType(ListView))
        .firstWhere((l) => l.scrollDirection == Axis.vertical);
    final barPad = horizontal.padding! as EdgeInsets;
    final feedPad = vertical.padding! as EdgeInsets;
    expect(barPad.left, kPagePadding);
    expect(barPad.right, kPagePadding);
    expect(barPad.left, feedPad.left);
    expect(barPad.right, feedPad.right);

    // 头像仍是方形/圆形封面(没有被包成可跳转的入口: 见点击语义测试)
    expect(find.byType(CircleCover), findsWidgets);
  });
}
