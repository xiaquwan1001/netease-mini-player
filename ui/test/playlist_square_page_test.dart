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
    );

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('分类筛选切换会重新取数, 点歌单回调', (tester) async {
    final calls = <String>[];
    rust.Playlist? opened;

    await tester.pumpWidget(host(PlaylistSquareView(
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
    )));
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
    await tester.pumpWidget(host(PlaylistSquareView(
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
    )));
    await tester.pumpAndSettle();
    expect(offsets, [0]);

    // D6 迁移后: 触底自动加载下一页(不再依赖手动"加载更多"按钮)
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(offsets, [0, 30, 60], reason: '触底自动连续预取两页');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(offsets.length, 5, reason: '继续触底自动加载(每页 offset +30)');
    // 第 31 个歌单由第二页(offset=30)返回
    expect(offsets, contains(30));
  });
}
