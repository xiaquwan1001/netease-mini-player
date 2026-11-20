import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/playlist_square_page.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

import 'support/fakes.dart';

// 共享工厂 + 本文件口径(广场歌单按 30 首展示), 位置参数签名保持不变。
rust.Playlist playlist(int id, String name) =>
    fakePlaylist(id: id, name: name, trackCount: 30);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 官方 `/api/playlist/catlist` 的形态(语种/风格/场景/情感/主题 五组, 顺序即接口顺序)。
/// 分类**天然带分组**, 分组名与子分类名都来自接口, UI 侧不维护固定分组表
/// (解析在 core/crates/ncm-service/src/netease/playlist.rs 的 parse_playlist_categories)。
const List<rust.PlaylistCategory> kCategories = [
  rust.PlaylistCategory(group: '语种', subs: ['华语', '欧美', '日语']),
  rust.PlaylistCategory(group: '风格', subs: ['流行', '摇滚']),
  rust.PlaylistCategory(group: '场景', subs: ['清晨', '夜晚']),
  rust.PlaylistCategory(group: '情感', subs: ['怀旧']),
  rust.PlaylistCategory(group: '主题', subs: ['影视']),
];

/// 歌单网格自己的滚动位置(不是 chips 的行内横向滚动)。
double gridOffset(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byType(CustomScrollView),
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable.first).position.pixels;
}

void main() {
  testWidgets('分类区默认按官方一级分组渲染: 组名 + 同组横向 chips', (tester) async {
    await tester.pumpWidget(
      host(
        PlaylistSquareView(
          loadCategories: () async => kCategories,
          loadPage: (cat, limit, offset) async => [playlist(1, '全部歌单')],
          loadHighQuality: (cat, limit) async => const [],
          onOpenPlaylist: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 五组一级分组名都在, 且每组子分类都渲染出来
    for (final group in kCategories) {
      expect(
        find.text(group.group),
        findsOneWidget,
        reason: '缺少分组 ${group.group}',
      );
      for (final sub in group.subs) {
        expect(find.text(sub), findsOneWidget, reason: '缺少子分类 $sub');
      }
    }

    // 组名与同组 chips 在同一行(横向), 且 chips 行可横向滚动
    for (final group in kCategories) {
      expect(
        tester.getCenter(find.text(group.group)).dy,
        closeTo(tester.getCenter(find.text(group.subs.first)).dy, 1),
        reason: '${group.group} 的组名与 chips 必须在同一行',
      );
    }
    expect(
      find.ancestor(
        of: find.text('华语'),
        matching: find.byWidgetPredicate(
          (w) =>
              w is SingleChildScrollView &&
              w.scrollDirection == Axis.horizontal,
        ),
      ),
      findsWidgets,
      reason: '子分类 chips 行必须能横向滚动',
    );

    // 组与组之间的 chips 不能串行
    final chipsRow = find
        .ancestor(of: find.text('华语'), matching: find.byType(Row))
        .first;
    expect(
      find.descendant(of: chipsRow, matching: find.text('欧美')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chipsRow, matching: find.text('流行')),
      findsNothing,
      reason: '「风格」组的 chip 不能跑到「语种」那一行',
    );

    // 默认 全部分类
    expect(find.text('全部分类'), findsOneWidget);
    expect(find.text('收起分类'), findsOneWidget);
  });

  testWidgets('选中分类: 收起分组 chips + 摘要显示当前分类 + 重新取数', (tester) async {
    final calls = <String>[];
    rust.Playlist? opened;

    await tester.pumpWidget(
      host(
        PlaylistSquareView(
          loadCategories: () async => kCategories,
          loadPage: (cat, limit, offset) async {
            calls.add('$cat@$offset');
            return [playlist(1, cat.isEmpty ? '全部歌单' : '$cat歌单')];
          },
          loadHighQuality: (cat, limit) async => [playlist(9, '精品歌单')],
          onOpenPlaylist: (pl) => opened = pl,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('全部歌单'), findsOneWidget);
    expect(calls, ['@0']);

    // 切到「华语」
    await tester.tap(find.text('华语'));
    await tester.pumpAndSettle();
    expect(calls, ['@0', '华语@0'], reason: '切分类要用新 cat 重新取数');
    expect(find.text('华语歌单'), findsOneWidget);
    // 分类区自动收起, 但当前分类要一眼可见
    expect(find.text('当前：华语'), findsOneWidget);
    expect(find.text('欧美'), findsNothing, reason: '选完分类后 chips 收起, 把空间还给网格');
    expect(find.text('选择分类'), findsOneWidget);

    await tester.tap(find.text('华语歌单'));
    expect(opened?.id, BigInt.from(1));

    // 展开分类区 → chips 回来, 换一个分类
    await tester.tap(find.text('选择分类'));
    await tester.pumpAndSettle();
    expect(find.text('欧美'), findsOneWidget);
    await tester.tap(find.text('欧美'));
    await tester.pumpAndSettle();
    expect(calls.last, '欧美@0');
    expect(find.text('当前：欧美'), findsOneWidget);

    // 点摘要 chip = 回到全部分类, 同时展开分类区
    await tester.tap(find.text('当前：欧美'));
    await tester.pumpAndSettle();
    expect(calls.last, '@0');
    expect(find.text('全部分类'), findsOneWidget);
    expect(find.text('流行'), findsOneWidget, reason: '回到全部后分类区重新展开');
  });

  testWidgets('切换分类后歌单网格回到顶部', (tester) async {
    await tester.pumpWidget(
      host(
        PlaylistSquareView(
          loadCategories: () async => kCategories,
          loadPage: (cat, limit, offset) async => [
            for (var i = 0; i < limit; i++)
              playlist(offset + i + 1, '$cat-${offset + i + 1}'),
          ],
          loadHighQuality: (cat, limit) async => const [],
          onOpenPlaylist: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(gridOffset(tester), 0);

    // 往下滚一点(分类条随列表滚走一部分, 但底下两组 chips 仍在视口内)
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(gridOffset(tester), greaterThan(0));

    // 在滚动状态下切到「影视」(主题组)
    await tester.tap(find.text('影视'));
    await tester.pumpAndSettle();
    expect(gridOffset(tester), 0, reason: '切分类必须回到顶部, 不能停在旧位置');
    expect(find.text('当前：影视'), findsOneWidget);
  });

  testWidgets('精品与热门互斥: 切精品隐藏分类区并走精品接口, 切回热门恢复分组', (tester) async {
    final pageCalls = <String>[];
    final hqCalls = <String>[];

    await tester.pumpWidget(
      host(
        PlaylistSquareView(
          loadCategories: () async => kCategories,
          loadPage: (cat, limit, offset) async {
            pageCalls.add(cat);
            return [playlist(1, '${cat.isEmpty ? '全部' : cat}歌单')];
          },
          loadHighQuality: (cat, limit) async {
            hqCalls.add(cat);
            return [playlist(9, '精品歌单')];
          },
          onOpenPlaylist: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 先选一个分类, 再切精品: 精品模式不分分类 ⇒ cat 必须清空
    await tester.tap(find.text('华语'));
    await tester.pumpAndSettle();
    expect(find.text('当前：华语'), findsOneWidget);

    await tester.tap(find.text('精品'));
    await tester.pumpAndSettle();
    expect(hqCalls, [''], reason: '精品模式用空 cat(全部)');
    expect(find.text('精品歌单'), findsOneWidget);
    expect(find.text('华语歌单'), findsNothing);
    // 分类区(分组 chips + 摘要)整块隐藏, 换一句模式说明
    expect(find.text('语种'), findsNothing);
    expect(find.text('当前：华语'), findsNothing);
    expect(find.text('官方精选 · 不分分类'), findsOneWidget);

    await tester.tap(find.text('热门'));
    await tester.pumpAndSettle();
    expect(pageCalls.last, '', reason: '切回热门重新按分类取数');
    expect(find.text('全部歌单'), findsOneWidget);
    // 回到热门: 分类区与摘要 chip 回来(分类区保持用户上次的收起状态)
    expect(find.text('全部分类'), findsOneWidget);
    expect(find.text('语种'), findsNothing);
    expect(find.text('官方精选 · 不分分类'), findsNothing);
    await tester.tap(find.text('选择分类'));
    await tester.pumpAndSettle();
    expect(find.text('语种'), findsOneWidget, reason: '展开后分组 chips 就绪');
  });

  testWidgets('空态: 热门分类与精品各用各的文案, 且筛选条仍在(能切回)', (tester) async {
    await tester.pumpWidget(
      host(
        PlaylistSquareView(
          loadCategories: () async => kCategories,
          loadPage: (cat, limit, offset) async => const [],
          loadHighQuality: (cat, limit) async => const [],
          onOpenPlaylist: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('这个分类下暂时没有歌单'), findsOneWidget);
    // 空态下筛选条必须还在, 否则用户被锁在这个模式里
    expect(find.text('热门'), findsOneWidget);
    expect(find.text('语种'), findsOneWidget);

    await tester.tap(find.text('精品'));
    await tester.pumpAndSettle();
    expect(find.text('暂时没有精品歌单'), findsOneWidget);
    expect(find.text('这个分类下暂时没有歌单'), findsNothing);

    await tester.tap(find.text('热门'));
    await tester.pumpAndSettle();
    expect(find.text('这个分类下暂时没有歌单'), findsOneWidget);
  });

  testWidgets('分类加载失败可重试', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      host(
        PlaylistSquareView(
          loadCategories: () async {
            attempts++;
            if (attempts == 1) throw Exception('boom');
            return kCategories;
          },
          loadPage: (cat, limit, offset) async => [playlist(1, '歌单1')],
          loadHighQuality: (cat, limit) async => const [],
          onOpenPlaylist: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('分类加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('分类加载失败'), findsNothing);
    expect(find.text('语种'), findsOneWidget);
    expect(find.text('华语'), findsOneWidget);
  });

  testWidgets('加载更多按 offset 追加', (tester) async {
    final offsets = <int>[];
    await tester.pumpWidget(
      host(
        PlaylistSquareView(
          loadCategories: () async => const [],
          loadPage: (cat, limit, offset) async {
            offsets.add(offset);
            return [
              for (var i = 0; i < limit; i++)
                playlist(offset + i + 1, '歌单${offset + i + 1}'),
            ];
          },
          loadHighQuality: (cat, limit) async => const [],
          onOpenPlaylist: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(offsets, [0]);

    // D6 迁移后: 触底自动加载下一页(不再依赖手动"加载更多"按钮)
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(offsets, [0, 30, 60], reason: '触底自动连续预取两页');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    // 每页条数不变, 但网格列数/行高由设置与 coverGridDelegate 决定, 单屏可见条数会变;
    // 这里只断言「继续触底仍在按 offset 追加」, 不再钉死到第 5 页。
    expect(
      offsets.length,
      greaterThanOrEqualTo(3),
      reason: '继续触底自动加载(每页 offset +30)',
    );
    // 第 31 个歌单由第二页(offset=30)返回
    expect(offsets, contains(30));
  });

  testWidgets('300dp + 1.25 字号: 分组分类条与歌单卡不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Scaffold(
          body: PlaylistSquareView(
            loadCategories: () async => kCategories,
            loadPage: (cat, limit, offset) async => [
              playlist(1, '一个名字特别特别长的歌单名称用于窄屏回归测试'),
            ],
            loadHighQuality: (cat, limit) async => [playlist(9, '精品歌单')],
            onOpenPlaylist: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('一个名字特别特别长的歌单名称用于窄屏回归测试'), findsOneWidget);
    expect(find.text('语种'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);
  });

  // A5 回归: 「模式切换 + 分类加载失败」在 300dp x1.625 下曾经超出屏宽。
  // 修法是横向滚动(而不是 Wrap 换行 —— 换行会让筛选栏高度随错误文案跳动,
  // 下方歌单网格跟着位移)。
  testWidgets('300dp x1.625: 分类加载失败时切换行可横向滚动, 不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.625;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        PlaylistSquareView(
          // 不用 [network] 前缀: 那会走 retryNetwork 的退避重试, 错误要 1.5s 后才
          // 冒出来(pumpAndSettle 在等待 timer 时会提前结束), 本用例只想拿错误态
          loadCategories: () async => throw Exception('boom'),
          loadPage: (cat, limit, offset) async => [playlist(1, '歌单1')],
          loadHighQuality: (cat, limit) async => const [],
          onOpenPlaylist: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '筛选行不允许 overflow');
    expect(find.text('分类加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // 模式切换行必须是横向滚动容器: 它是「热门」segment 的祖先
    expect(
      find.ancestor(
        of: find.text('热门'),
        matching: find.byWidgetPredicate(
          (w) =>
              w is SingleChildScrollView &&
              w.scrollDirection == Axis.horizontal,
        ),
      ),
      findsWidgets,
      reason: '模式切换行必须能横向滚动(不许 Wrap 换行)',
    );
  });
}
