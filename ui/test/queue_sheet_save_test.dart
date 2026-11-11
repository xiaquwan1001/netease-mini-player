import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/play_queue_sheet.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song(int id, String name) => rust.SongDto(
      id: BigInt.from(id),
      name: name,
      artist: '歌手$id',
      artistId: BigInt.from(900 + id),
      album: '专辑$id',
      albumId: BigInt.from(800 + id),
      coverUrl: null,
      durationMs: BigInt.from(200000),
      fee: 0,
      vip: false,
      paid: false,
      playable: true,
    );

/// 「存为歌单」面板行为测试: 全部注入假 onSaveAsPlaylist, 不联网。
/// 宿主(main.dart)负责选歌单 sheet / 调 Rust / toast; 面板只管意图+去重+防重复。
class SaveHarness extends StatefulWidget {
  const SaveHarness({super.key, required this.songs, this.onSave});

  final List<rust.SongDto> songs;
  final Future<void> Function(List<rust.SongDto> songs)? onSave;

  @override
  State<SaveHarness> createState() => _SaveHarnessState();
}

class _SaveHarnessState extends State<SaveHarness> {
  late List<rust.SongDto> items = List.of(widget.songs);

  final List<List<rust.SongDto>> saved = [];

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: PlayQueueSheet(
            items: items,
            index: items.isEmpty ? -1 : 0,
            onSelect: (_) {},
            onRemove: (_, _) {},
            onSaveAsPlaylist:
                widget.onSave ?? (songs) async => saved.add(songs),
          ),
        ),
      );
}

Future<void> _pump(WidgetTester tester, SaveHarness harness) async {
  await tester.pumpWidget(harness);
  await tester.pump();
}

void main() {
  testWidgets('空队列: 不出现「存为歌单」按钮(禁用语义由不渲染表达)',
      (tester) async {
    await _pump(tester, SaveHarness(key: const ValueKey('empty'), songs: const []));
    expect(find.byTooltip('存为歌单'), findsNothing);
  });

  testWidgets('非空队列: 「存为歌单」按钮出现', (tester) async {
    await _pump(tester, SaveHarness(key: const ValueKey('nonempty'), songs: [song(1, '晴天')]));
    expect(find.byTooltip('存为歌单'), findsOneWidget);
  });

  testWidgets('成功: 回调收到队列快照(顺序保持)', (tester) async {
    final songs = [song(1, '晴天'), song(2, '江南'), song(3, '听海')];
    await _pump(tester, SaveHarness(songs: songs));
    await tester.tap(find.byTooltip('存为歌单'));
    await tester.pumpAndSettle();
    final savedSongs = (tester.state(find.byType(SaveHarness))
            as _SaveHarnessState)
        .saved;
    expect(savedSongs, hasLength(1));
    expect([for (final s in savedSongs.single) s.id], [
      BigInt.one,
      BigInt.two,
      BigInt.from(3),
    ]);
  });

  testWidgets('去重: 同一首歌多次入队只传一份', (tester) async {
    final songs = [song(7, 'A'), song(7, 'A'), song(8, 'B'), song(7, 'A')];
    await _pump(tester, SaveHarness(songs: songs));
    await tester.tap(find.byTooltip('存为歌单'));
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(SaveHarness)) as _SaveHarnessState;
    expect(state.saved, hasLength(1));
    expect([for (final s in state.saved.single) s.id.toInt()], [7, 8]);
  });

  testWidgets('防重复点击: 回调未完成时按钮置灰, 只触发一次', (tester) async {
    final completer = Completer<void>();
    var calls = 0;
    await _pump(
      tester,
      SaveHarness(songs: [song(1, '晴天'), song(2, '江南')],
          onSave: (songs) async {
        calls += 1;
        await completer.future;
      }),
    );
    await tester.tap(find.byTooltip('存为歌单'));
    await tester.pump();
    expect(calls, 1);
    // 挂起期间再点: onPressed 为 null, 不触发
    await tester.tap(find.byTooltip('存为歌单'), warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);
    // 完成后恢复可点
    completer.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('存为歌单'));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('失败: 假实现抛异常, 面板不崩且按钮恢复可点', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      SaveHarness(songs: [song(1, '晴天')], onSave: (songs) async {
        calls += 1;
        throw Exception('boom');
      }),
    );
    await tester.tap(find.byTooltip('存为歌单'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.takeException(), isNull);
    // 失败后可重试
    await tester.tap(find.byTooltip('存为歌单'));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('300dp + 1.25 字号: 面板不溢出且「存为歌单」可用', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.25)),
        child: child!,
      ),
      home: Scaffold(
        body: PlayQueueSheet(
          items: [
            song(1, '一首名字特别特别长的歌用于窄屏回归测试'),
            song(2, '江南'),
          ],
          index: 0,
          onSelect: (_) {},
          onRemove: (_, _) {},
          onSaveAsPlaylist: (_) async {},
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('存为歌单'), findsOneWidget);
    expect(find.text('一首名字特别特别长的歌用于窄屏回归测试'), findsOneWidget);
  });
}

/// 窄屏 + 大字号回归宿主: 300dp 宽 + 1.25 字号(builder 层注入, 对弹层也生效).
Future<void> pumpNarrow(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(300, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: const TextScaler.linear(1.25)),
      child: child!,
    ),
    home: home,
  ));
}
