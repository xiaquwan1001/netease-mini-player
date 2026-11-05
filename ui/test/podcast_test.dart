import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/podcast.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song(int id, String name) => rust.SongDto(
      id: BigInt.from(id),
      name: name,
      artist: '主播',
      artistId: BigInt.one,
      album: '',
      albumId: BigInt.zero,
      coverUrl: null,
      durationMs: BigInt.from(60000),
      fee: 0,
      vip: false,
      paid: false,
      playable: true,
    );

rust.PodcastRadioDto radio() => rust.PodcastRadioDto(
      id: BigInt.from(5),
      name: '深夜电台',
      coverUrl: null,
      description: 'desc',
      djName: '主播A',
      programCount: BigInt.from(33),
      playCount: BigInt.from(100),
    );

rust.PodcastProgramDto program(int id, String name) => rust.PodcastProgramDto(
      id: BigInt.from(id),
      name: name,
      coverUrl: null,
      durationMs: BigInt.from(61000),
      djName: '主播A',
      radioId: BigInt.from(5),
      radioName: '深夜电台',
      description: '',
      song: song(1000 + id, name),
    );

Widget host(VoidCallback onTap) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: onTap,
            child: const Text('open'),
          ),
        ),
      ),
    );

void main() {
  testWidgets('播客: 电台 → 节目 → 点单集回调曲目列表', (tester) async {
    List<rust.SongDto>? played;
    int? playedIndex;
    await tester.pumpWidget(host(() {
      showPodcastSheet(
        tester.element(find.text('open')),
        onPlay: (songs, index) {
          played = songs;
          playedIndex = index;
        },
        loadRadios: (_) async => [radio()],
        loadPrograms: (_, _, _) async => [
          program(11, '第一期'),
          program(12, '第二期'),
        ],
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('深夜电台'), findsOneWidget);
    expect(find.textContaining('33 集'), findsOneWidget);

    await tester.tap(find.text('深夜电台'));
    await tester.pumpAndSettle();
    expect(find.text('第一期'), findsOneWidget);
    expect(find.text('第二期'), findsOneWidget);

    await tester.tap(find.text('第二期'));
    await tester.pumpAndSettle();
    expect(played?.length, 2);
    expect(playedIndex, 1);
    expect(played![1].name, '第二期');
  });

  testWidgets('播客: 空节目列表有提示', (tester) async {
    await tester.pumpWidget(host(() {
      showPodcastSheet(
        tester.element(find.text('open')),
        onPlay: (_, _) {},
        loadRadios: (_) async => [radio()],
        loadPrograms: (_, _, _) async => const [],
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深夜电台'));
    await tester.pumpAndSettle();
    expect(find.text('这个电台还没有节目'), findsOneWidget);
  });
}
