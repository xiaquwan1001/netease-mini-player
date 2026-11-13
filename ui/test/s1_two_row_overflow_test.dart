import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/cover_art.dart';
import 'package:minincm/src/chart_section.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song(int id, String name) => rust.SongDto(
  id: BigInt.from(id),
  name: name,
  artist: '艺人',
  artistId: BigInt.one,
  album: '专辑',
  albumId: BigInt.one,
  coverUrl: null,
  durationMs: BigInt.from(1000),
  fee: 0,
  vip: false,
  paid: false,
  playable: true,
);

rust.Playlist playlist(int id, String name) => rust.Playlist(
  id: BigInt.from(id),
  name: name,
  coverUrl: null,
  trackCount: BigInt.from(3),
  special: false,
  subscribed: false,
);

rust.PodcastRadio radio(int id, String name) => rust.PodcastRadio(
  id: BigInt.from(id),
  name: name,
  coverUrl: null,
  description: '',
  djName: '主播',
  programCount: BigInt.from(2),
  playCount: BigInt.zero,
);

rust.ChartSummary chart(int id, String name, String updateFrequency) =>
    rust.ChartSummary(
      id: BigInt.from(id),
      name: name,
      coverUrl: null,
      updateFrequency: updateFrequency,
      trackCount: BigInt.from(100),
      playCount: BigInt.from(1000),
    );

rust.AlbumItem album(int id, String name) => rust.AlbumItem(
  id: BigInt.from(id),
  name: name,
  coverUrl: null,
  artist: '艺人',
  trackCount: BigInt.from(8),
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  setUp(() async {
    // AppSettings 是单例: 切到两排, tearDown 恢复成 1, 避免污染同进程其它用例.
    await AppSettings.instance.update(coverRows: 2);
  });

  tearDown(() async {
    await AppSettings.instance.update(coverRows: 1);
  });

  Future<void> pumpRecommend(
    WidgetTester tester, {
    required double width,
    double textScale = 1.0,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    // 参考 recommend_view_test.dart: 页面很长, 用高视口一次构建整页,
    // 避免靠滚动定位造成的不稳定; 宽度按用例保持 300/360, 只放宽高度。
    tester.view.physicalSize = Size(width, 4200);
    addTearDown(tester.view.reset);
    if (textScale != 1.0) {
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    // 排行榜现已挂在搜索落地页; 两排封面溢出的回归直接测 ChartSection。
    await tester.pumpWidget(
      host(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ChartSection(
            onOpen: (_) {},
            load: () async => [
              chart(19723756, '飙升榜', '刚刚更新'),
              chart(3779629, '新歌榜', '每天更新'),
              chart(2884035, '热歌榜', '每天更新'),
              chart(19723757, '原创榜', '每周更新'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('coverRows=2: 300dp + textScale 1.25 两排封面不溢出', (tester) async {
    await pumpRecommend(tester, width: 300, textScale: 1.25);

    // 修复前这里会得到 "A RenderFlex overflowed by 4.0 pixels".
    expect(tester.takeException(), isNull);

    // 4 个榜均分两排: 飙升榜在第一排, 热歌榜在第二排, 两排都渲染出来.
    expect(find.text('飙升榜'), findsOneWidget);
    expect(find.text('热歌榜'), findsOneWidget);
    expect(find.byType(CoverArt), findsWidgets);
  });

  testWidgets('coverRows=2: 360dp + textScale 1.0 两排封面不溢出', (tester) async {
    await pumpRecommend(tester, width: 360);

    expect(tester.takeException(), isNull);
    expect(find.text('飙升榜'), findsOneWidget);
    expect(find.text('热歌榜'), findsOneWidget);
    expect(find.byType(CoverArt), findsWidgets);
  });
}
