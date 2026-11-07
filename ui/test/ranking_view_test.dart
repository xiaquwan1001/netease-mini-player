import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/ranking_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song(int id, String name) => rust.SongDto(
      id: BigInt.from(id),
      name: name,
      artist: '歌手',
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

rust.PlayRankEntryDto entry(int id, String name, int playCount) =>
    rust.PlayRankEntryDto(
      song: song(id, name),
      playCount: BigInt.from(playCount),
      score: BigInt.from(playCount * 10),
    );

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('总排行/当周切换各自取数, 点歌回调整批曲目', (tester) async {
    final periods = <String>[];
    List<rust.SongDto>? played;
    int? playedIndex;

    await tester.pumpWidget(host(PlayRankingView(
      load: (period) async {
        periods.add(period);
        return period == 'week'
            ? [entry(2, '本周单曲', 7)]
            : [entry(1, '常听单曲', 120), entry(3, '第二首', 80)];
      },
      onPlaySongs: (songs, index) {
        played = songs;
        playedIndex = index;
      },
    )));
    await tester.pumpAndSettle();

    // 默认总量排行
    expect(periods, ['all']);
    expect(find.text('常听单曲'), findsOneWidget);
    expect(find.text('120 次'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    // 切当周
    await tester.tap(find.text('当周'));
    await tester.pumpAndSettle();
    expect(periods, ['all', 'week']);
    expect(find.text('本周单曲'), findsOneWidget);
    expect(find.text('常听单曲'), findsNothing);

    await tester.tap(find.text('本周单曲'));
    expect(played?.single.name, '本周单曲');
    expect(playedIndex, 0);
  });

  testWidgets('compact 模式只显示前 5 条 + 查看全部', (tester) async {
    var opened = 0;
    await tester.pumpWidget(host(PlayRankingView(
      compact: true,
      onOpenAll: () => opened++,
      load: (_) async => [
        for (var i = 1; i <= 8; i++) entry(i, '歌曲$i', 100 - i),
      ],
      onPlaySongs: (_, __) {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('歌曲5'), findsOneWidget);
    expect(find.text('歌曲6'), findsNothing);

    await tester.tap(find.text('查看全部'));
    expect(opened, 1);
  });

  testWidgets('空排行显示提示', (tester) async {
    await tester.pumpWidget(host(PlayRankingView(
      load: (_) async => const [],
      onPlaySongs: (_, __) {},
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有听歌记录'), findsOneWidget);
  });

  testWidgets('整页首屏失败: friendlyError + 重试按钮, 重试后出数据', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(host(PlayRankingView(
      load: (period) async {
        attempts++;
        if (attempts <= 3) throw Exception('[network] reset');
        return [entry(1, '重试后的歌', 5)];
      },
      onPlaySongs: (_, _) {},
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('网络不稳定'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试后的歌'), findsOneWidget);
    expect(attempts, 4);
  });

  testWidgets('300dp + 1.25 字号: 有数据不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
        child: Scaffold(
          body: PlayRankingView(
            load: (_) async => [entry(1, '小屏上的第一名歌曲名很长', 999)],
            onPlaySongs: (_, _) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('小屏上的第一名歌曲名很长'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('300dp + 1.25 字号: 错误态不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
        child: Scaffold(
          body: PlayRankingView(
            load: (_) async => throw Exception(' boom'),
            onPlaySongs: (_, _) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Exception'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('300dp + 1.25 字号: 空态不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
        child: Scaffold(
          body: PlayRankingView(
            load: (_) async => const [],
            onPlaySongs: (_, _) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有听歌记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

}
