import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/recommend_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/search_landing.dart';

rust.HotSearchTermDto hot(int rank, String keyword) =>
    rust.HotSearchTermDto(rank: rank, keyword: keyword);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('搜索历史: 「清空」与历史 chip 命中区都 ≥48dp', (tester) async {
    await tester.pumpWidget(host(SearchLanding(
      history: const ['七里香', '稻香'],
      hot: const [],
      recommended: null,
      onSelected: (_) {},
      onClearHistory: () {},
    )));

    final clearSize = tester.getSize(find.widgetWithText(TextButton, '清空'));
    expect(clearSize.height, greaterThanOrEqualTo(48));
    expect(clearSize.width, greaterThanOrEqualTo(48));

    for (final keyword in ['七里香', '稻香']) {
      final size = tester.getSize(find.widgetWithText(ActionChip, keyword));
      expect(size.height, greaterThanOrEqualTo(48), reason: keyword);
    }
  });

  testWidgets('历史 chip 点击仍然只做搜索', (tester) async {
    String? chosen;
    await tester.pumpWidget(host(SearchLanding(
      history: const ['七里香'],
      hot: const [],
      recommended: null,
      onSelected: (k) => chosen = k,
      onClearHistory: () {},
    )));
    await tester.tap(find.text('七里香'));
    expect(chosen, '七里香');
  });

  testWidgets('热词重试按钮命中区 ≥48dp', (tester) async {
    await tester.pumpWidget(host(SearchLanding(
      history: const [],
      hot: const [],
      recommended: null,
      onSelected: (_) {},
      onClearHistory: () {},
      hotError: '网络不稳定',
      onRetryHot: () {},
    )));
    final size = tester.getSize(find.widgetWithText(TextButton, '重试'));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('推荐页「全部」入口措辞统一(不再有 更多/查看全部)', (tester) async {
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(RecommendView(
      loggedIn: true,
      loadDailySongs: () async => const [],
      loadDailyPlaylists: () async => const [],
      loadPodcasts: () async => const [],
      loadFm: () async => const [],
      loadStyles: () async => const [],
      loadCharts: () async => const [],
      loadNewSongs: () async => const [],
      loadNewAlbums: () async => const [],
      onOpenAlbum: (_) {},
      onOpenNewRelease: () {},
      onPlaySongs: (_, _) {},
      onOpenPlaylist: (_) {},
      onOpenPodcast: (_) {},
      onHeartMode: () {},
      onOpenDaily: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('更多'), findsNothing);
    expect(find.text('查看全部'), findsNothing);
    // 排行榜 / 每日推荐 / 新歌速递 / 新碟上架 / 推荐播客 各一个
    expect(find.text('全部'), findsNWidgets(5));
  });
}
