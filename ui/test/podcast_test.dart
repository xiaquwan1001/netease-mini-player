import 'dart:async';

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
      song: song(1000 + id, name),
    );

Widget sheetHost(Widget child) => MaterialApp(home: Scaffold(body: child));

// 本文件原先围绕已删除的播客浏览弹层一族(电台列表/节目列表)编写;
// 生产入口早已由 radio_explore_page + detail_page 的电台详情页接管,
// podcast.dart 存活的只有 ProgramDetailSheet, 因此改测它的行为。
void main() {
  testWidgets('节目详情: 打开即拉取完整数据, 加载中头部有 loading', (tester) async {
    final ids = <BigInt>[];
    final done = Completer<rust.PodcastProgramDto>();
    await tester.pumpWidget(sheetHost(ProgramDetailSheet(
      program: program(11, '第一期'),
      loadDetail: (id) {
        ids.add(id);
        return done.future;
      },
    )));

    // 占位数据先上屏; loader 用列表带来的节目 id 调用; 头部有 loading 指示
    expect(ids, [BigInt.from(11)]);
    expect(find.text('第一期'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    done.complete(program(11, '第一期', description: '完整简介: 本集聊聊深夜电台的十年'));
    await tester.pumpAndSettle();
    expect(find.text('完整简介: 本集聊聊深夜电台的十年'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('节目详情: 没有文字简介时给出占位提示', (tester) async {
    await tester.pumpWidget(sheetHost(ProgramDetailSheet(
      program: program(11, '第一期'),
      loadDetail: (id) async => program(11, '第一期'),
    )));
    await tester.pumpAndSettle();

    expect(find.text('这一集没有文字简介'), findsOneWidget);
  });

  testWidgets('300dp + 1.25 字号不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
        child: child!,
      ),
      home: Scaffold(
        body: ProgramDetailSheet(
          program: program(11, '第一期名字很长很长很长很长很长'),
          loadDetail: (id) async => program(11, '第一期名字很长很长很长很长很长',
              description: '简介也很长' * 20),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
