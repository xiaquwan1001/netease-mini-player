// 风格推荐配图窗格: 推荐页直接能看到每个曲风的配图(不用点进详情页).
//
// 背景: 之前这里是一行纯文字 chips, 配图只在风格详情页头部出现; 用户要求
// 把配图窗格上提到推荐页, 每个风格 = 配图 + 名字(没有配图时退回钢琴图标占位).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/cover_art.dart';
import 'package:minincm/src/recommend_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Widget _recommend(List<rust.StyleTag> tags) => RecommendView(
  loggedIn: true,
  onPlaySongs: (_, _) {},
  onOpenPlaylist: (_) {},
  onOpenPodcast: (_) {},
  onHeartMode: () {},
  onOpenDaily: () {},
  loadDailySongs: () async => const [],
  loadDailyPlaylists: () async => const [],
  loadPodcasts: () async => const [],
  loadFm: () async => const [],
  loadStyles: () async => tags,
  loadNewSongs: () async => const [],
);

void main() {
  testWidgets('有配图的曲风: 推荐页直接渲染配图窗格(不用进详情页)', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _host(
        _recommend(const [
          rust.StyleTag(
            id: '1000',
            name: '流行',
            coverUrl: 'https://p6.music.126.net/obj/109951165924166690',
          ),
          rust.StyleTag(id: '1008', name: '摇滚'),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    // 风格推荐区块仍在(位置语义不变), 两个曲风都可见
    expect(find.text('风格推荐'), findsOneWidget);
    expect(find.text('流行'), findsOneWidget);
    expect(find.text('摇滚'), findsOneWidget);

    // 有配图的曲风: 渲染 CoverArt 窗格
    final covers = tester.widgetList<CoverArt>(find.byType(CoverArt)).toList();
    expect(
      covers.any(
        (c) => c.url == 'https://p6.music.126.net/obj/109951165924166690',
      ),
      isTrue,
      reason: '曲风配图要在推荐页直接可见',
    );
    // 没配图的曲风: 同尺寸钢琴图标占位(仍可点)
    expect(find.byIcon(Icons.piano), findsOneWidget);
  });

  testWidgets('窄屏 + 大字号: 配图窗格行不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.625)),
          child: Scaffold(
            body: _recommend(const [
              rust.StyleTag(id: '1', name: '一个很长很长的曲风名字用来测省略号'),
              rust.StyleTag(id: '2', name: '摇滚'),
              rust.StyleTag(id: '3', name: '电子'),
              rust.StyleTag(id: '4', name: '民谣'),
            ]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('风格推荐'), findsOneWidget);
  });
}
