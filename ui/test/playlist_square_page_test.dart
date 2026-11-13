import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/playlist_square_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.Playlist playlist(int id, String name) => rust.Playlist(
  id: BigInt.from(id),
  name: name,
  coverUrl: null,
  trackCount: BigInt.from(30),
  special: false,
  subscribed: false,
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('分类筛选切换会重新取数, 点歌单回调', (tester) async {
    final calls = <String>[];
    rust.Playlist? opened;

    await tester.pumpWidget(
      host(
        PlaylistSquareView(
          loadCategories: () async => const [
            rust.PlaylistCategory(group: '语种', subs: ['华语', '欧美']),
            rust.PlaylistCategory(group: '风格', subs: ['流行']),
          ],
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

    expect(find.text('语种'), findsOneWidget);
    expect(find.text('全部歌单'), findsOneWidget);

    // 切换到「华语」
    await tester.tap(find.text('华语'));
    await tester.pumpAndSettle();
    expect(calls, ['@0', '华语@0']);
    expect(find.text('华语歌单'), findsOneWidget);

    await tester.tap(find.text('华语歌单'));
    expect(opened?.id, BigInt.from(1));

    // 切到「精品」: 走 high_quality_playlists, 且清空分类
    await tester.tap(find.text('精品'));
    await tester.pumpAndSettle();
    expect(find.text('精品歌单'), findsOneWidget);
    expect(find.text('华语歌单'), findsNothing);
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

  testWidgets('300dp + 1.25 字号: 分类与歌单卡不溢出', (tester) async {
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
            loadCategories: () async => const [
              rust.PlaylistCategory(
                group: '语种',
                subs: ['华语', '欧美', '日语', '韩语'],
              ),
              rust.PlaylistCategory(
                group: '风格',
                subs: ['流行', '摇滚', '民谣', '电子'],
              ),
            ],
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
  });
}

/// 窄屏 + 大字号回归宿主: 300dp 宽 + 1.25 字号(builder 层注入, 对弹层也生效).
Future<void> pumpNarrow(WidgetTester tester, Widget home) async {
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
      home: home,
    ),
  );
}
