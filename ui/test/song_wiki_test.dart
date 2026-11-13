import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/song_wiki.dart';

rust.SongDto song() => rust.SongDto(
  id: BigInt.from(1901371647),
  name: '孤勇者',
  artist: '陈奕迅',
  artistId: BigInt.one,
  album: '孤勇者',
  albumId: BigInt.one,
  coverUrl: null,
  durationMs: BigInt.from(255000),
  fee: 1,
  vip: true,
  paid: false,
  playable: true,
);

Widget host() => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (ctx) => TextButton(onPressed: () {}, child: const Text('open')),
    ),
  ),
);

void main() {
  testWidgets('歌曲百科: 两列展示 label/value', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(host());
    ctx = tester.element(find.text('open'));

    showSongWiki(
      ctx,
      song: song(),
      load: (_) async => const [
        rust.WikiFact(label: '曲风', value: '流行-华语流行 / 原声带-动画片原声'),
        rust.WikiFact(label: '语种', value: '国语'),
        rust.WikiFact(label: 'BPM', value: '64'),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('歌曲百科'), findsOneWidget);
    expect(find.text('孤勇者'), findsOneWidget);
    expect(find.text('曲风'), findsOneWidget);
    expect(find.text('流行-华语流行 / 原声带-动画片原声'), findsOneWidget);
    expect(find.text('国语'), findsOneWidget);
  });

  testWidgets('300dp + 1.25 字号: 弹窗长值不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    showSongWiki(
      tester.element(find.text('open')),
      song: song(),
      load: (_) async => const [
        rust.WikiFact(
          label: '曲风',
          value: '流行-华语流行 / 原声带-动画片原声-一段很长很长的曲风值用于小屏回归测试',
        ),
        rust.WikiFact(label: '语种', value: '国语'),
      ],
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('歌曲百科'), findsOneWidget);
    expect(find.text('国语'), findsOneWidget);
  });

  testWidgets('歌曲百科: 空列表给提示', (tester) async {
    await tester.pumpWidget(host());
    final ctx = tester.element(find.text('open'));

    showSongWiki(ctx, song: song(), load: (_) async => const []);
    await tester.pumpAndSettle();

    expect(find.text('这首歌还没有百科信息'), findsOneWidget);
  });

  testWidgets('歌曲百科: 失败可重试', (tester) async {
    await tester.pumpWidget(host());
    final ctx = tester.element(find.text('open'));
    var calls = 0;

    showSongWiki(
      ctx,
      song: song(),
      load: (_) async {
        calls++;
        if (calls == 1) throw Exception('[internal] 挂了');
        return const [rust.WikiFact(label: '语种', value: '国语')];
      },
    );
    await tester.pumpAndSettle();

    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('国语'), findsOneWidget);
  });
}
