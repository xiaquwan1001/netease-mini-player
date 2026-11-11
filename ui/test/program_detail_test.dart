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

rust.PodcastProgramDto program(
  int id,
  String name, {
  String description = '',
  bool withSong = true,
}) =>
    rust.PodcastProgramDto(
      id: BigInt.from(id),
      name: name,
      coverUrl: null,
      durationMs: BigInt.from(61000),
      djName: '主播A',
      radioId: BigInt.from(5),
      radioName: '深夜电台',
      description: description,
      song: withSong ? song(1000 + id, name) : null,
    );

Widget sheetHost(Widget child, {bool narrow = false}) => MaterialApp(
      builder: (context, c) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler:
              narrow ? const TextScaler.linear(1.25) : TextScaler.noScaling,
        ),
        child: c!,
      ),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('节目详情: 打开即用 podcast_program 拉完整数据(列表 description 是空的)', (tester) async {
    final ids = <BigInt>[];
    await tester.pumpWidget(sheetHost(ProgramDetailSheet(
      program: program(11, '第一期'),
      loadDetail: (id) async {
        ids.add(id);
        return program(11, '第一期', description: '完整简介: 本集聊聊深夜电台的十年');
      },
    )));
    await tester.pumpAndSettle();

    expect(ids, [BigInt.from(11)]);
    expect(find.text('节目详情'), findsOneWidget);
    expect(find.text('完整简介: 本集聊聊深夜电台的十年'), findsOneWidget);
    // 列表数据里没有音频时不给播放按钮 -- 这里 song 存在但 onPlay 未传, 也要置灰
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });

  testWidgets('节目详情: 拉取失败保留占位 + 错误条可重试', (tester) async {
    var calls = 0;
    await tester.pumpWidget(sheetHost(ProgramDetailSheet(
      program: program(11, '第一期', description: '列表里的旧简介'),
      loadDetail: (id) async {
        calls++;
        if (calls == 1) throw Exception('后端打盹了');
        return program(11, '第一期', description: '重试后的完整简介');
      },
    )));
    await tester.pumpAndSettle();

    // 占位数据仍在, 错误文案出现
    expect(find.text('第一期'), findsOneWidget);
    expect(find.text('列表里的旧简介'), findsOneWidget);
    expect(find.textContaining('后端打盹了'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试后的完整简介'), findsOneWidget);
    expect(find.textContaining('后端打盹了'), findsNothing);
  });

  testWidgets('节目详情: 没有音频的节目播放按钮置灰并提示', (tester) async {
    await tester.pumpWidget(sheetHost(ProgramDetailSheet(
      program: program(11, '第一期', withSong: false),
      loadDetail: (id) async => program(11, '第一期', withSong: false),
    )));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.text('这一集没有可播放的音频'), findsOneWidget);
  });

  testWidgets('节目详情: 300dp + 1.25 字号不溢出', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(300, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(sheetHost(
      ProgramDetailSheet(
        program: program(11, '这是一期名字特别特别特别长的节目, 用来验证窄屏大字号下不溢出'),
        loadDetail: (id) async => program(
          11,
          '这是一期名字特别特别特别长的节目, 用来验证窄屏大字号下不溢出',
          description: List.generate(20, (_) => '这是一段很长很长的简介。').join(),
        ),
        onPlay: () {},
      ),
      narrow: true,
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('节目详情: 没有音频的单集也能看完整简介', (tester) async {
    await tester.pumpWidget(sheetHost(ProgramDetailSheet(
      program: program(11, '第一期', withSong: false),
      loadDetail: (id) async =>
          program(11, '第一期', description: '第一期的完整简介', withSong: false),
    )));
    await tester.pumpAndSettle();

    // 没有音频的那一集也能看详情: 完整简介正常展示, 播放按钮置灰
    expect(find.text('第一期的完整简介'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('节目详情: 有音频时点播放本集触发回调', (tester) async {
    var played = 0;
    await tester.pumpWidget(sheetHost(ProgramDetailSheet(
      program: program(11, '第一期'),
      loadDetail: (id) async => program(11, '第一期'),
      onPlay: () => played++,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('播放本集'));
    await tester.pumpAndSettle();
    expect(played, 1);
  });
}
