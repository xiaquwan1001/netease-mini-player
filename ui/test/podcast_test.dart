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

rust.PodcastRadio radio([String name = '深夜电台']) => rust.PodcastRadio(
      id: BigInt.from(5),
      name: name,
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

Widget host(VoidCallback onTap, {bool narrow = false}) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler:
              narrow ? const TextScaler.linear(1.25) : TextScaler.noScaling,
        ),
        child: child!,
      ),
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

  testWidgets('详情页打开即用后端最新数据刷新电台信息', (tester) async {
    final detailIds = <BigInt>[];
    await tester.pumpWidget(host(() {
      showPodcastSheet(
        tester.element(find.text('open')),
        onPlay: (_, _) {},
        loadRadios: (_) async => [radio()],
        loadPrograms: (_, _, _) async => [program(11, '第一期')],
        loadRadioDetail: (id) async {
          detailIds.add(id);
          return radio('深夜电台(最新)');
        },
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深夜电台'));
    await tester.pumpAndSettle();

    // 详情 loader 用列表带来的电台 id 调用, 且标题栏换成了最新名字
    expect(detailIds, [BigInt.from(5)]);
    expect(find.text('深夜电台(最新)'), findsOneWidget);
    expect(find.text('第一期'), findsOneWidget);
  });

  testWidgets('详情刷新失败: 保留旧数据 + 顶部错误条可重试', (tester) async {
    var calls = 0;
    await tester.pumpWidget(host(() {
      showPodcastSheet(
        tester.element(find.text('open')),
        onPlay: (_, _) {},
        loadRadios: (_) async => [radio()],
        loadPrograms: (_, _, _) async {
          calls++;
          if (calls == 2) throw Exception('后端打盹了');
          if (calls == 3) return [program(11, '刷新后的一期')];
          return [program(11, '第一期'), program(12, '第二期')];
        },
        loadRadioDetail: (_) async => radio(),
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深夜电台'));
    await tester.pumpAndSettle();
    expect(find.text('第一期'), findsOneWidget);

    // 下拉刷新 → 第二次调用失败
    await tester.fling(find.byType(ListView), const Offset(0, 300), 1200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 旧数据保留, 不整页清空, 顶部出现错误条
    expect(find.text('第一期'), findsOneWidget);
    expect(find.textContaining('后端打盹了'), findsOneWidget);

    // 错误条上的重试 → 第三次成功, 错误条消失
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('刷新后的一期'), findsOneWidget);
    expect(find.textContaining('后端打盹了'), findsNothing);
  });

  testWidgets('电台列表下拉刷新', (tester) async {
    var calls = 0;
    await tester.pumpWidget(host(() {
      showPodcastSheet(
        tester.element(find.text('open')),
        onPlay: (_, _) {},
        loadRadios: (_) async {
          calls++;
          return [radio(calls == 1 ? '深夜电台' : '新榜电台')];
        },
        loadPrograms: (_, _, _) async => [program(11, '第一期')],
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('深夜电台'), findsOneWidget);

    await tester.fling(find.byType(ListView), const Offset(0, 300), 1200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('新榜电台'), findsOneWidget);
  });

  testWidgets('节目列表首屏加载失败: 整页错误+重试可恢复', (tester) async {
    var calls = 0;
    await tester.pumpWidget(host(() {
      showPodcastSheet(
        tester.element(find.text('open')),
        onPlay: (_, _) {},
        loadRadios: (_) async => [radio()],
        loadPrograms: (_, _, _) async {
          calls++;
          if (calls == 1) throw Exception('首屏失败');
          return [program(11, '重试后的一期')];
        },
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深夜电台'));
    await tester.pumpAndSettle();

    expect(find.textContaining('首屏失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试后的一期'), findsOneWidget);
    expect(find.textContaining('首屏失败'), findsNothing);
  });

  testWidgets('300dp 窄屏 + 1.25 字号: 电台页与节目页都不溢出', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(300, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(
      () {},
      narrow: true,
    ));
    await tester.pumpWidget(host(() {
      showPodcastSheet(
        tester.element(find.text('open')),
        onPlay: (_, _) {},
        loadRadios: (_) async => [radio('这是一个非常非常长的电台名称用来挤窄屏空间')],
        loadPrograms: (_, _, _) async => [
          program(11, '这是一期名字特别特别特别长的节目, 用来验证窄屏大字号下不溢出'),
        ],
        loadRadioDetail: (_) async => radio('这是一个非常非常长的电台名称用来挤窄屏空间'),
      );
    }, narrow: true));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.textContaining('这是一个非常非常长的电台名称'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
