// 队列面板左滑删除 = 可撤销(2026-11-26 安卓交互审计 P2#6) + 触感只在 Android(P2#5)。
//
// 两个关键口径:
//   · **插回原下标**: 撤销走的是宿主的真实队列([PlayQueueSheet.onRestore] →
//     QueueSheetController.restore), 不是"本地塞一行"; 当前曲目不变(删的时候已经
//     换播了, 撤销只恢复列表)。
//   · **撤销条必须看得见**: 队列面板是模态 bottom sheet, 根 ScaffoldMessenger 的
//     SnackBar 画在面板底下的页面里(实测 y=740~800, 正好被面板盖死) —— 所以面板
//     自带一层 ScaffoldMessenger + 透明 Scaffold, 撤销条浮在面板内部。这条用
//     「SnackBar 的矩形落在面板矩形内」锁住, 不然改回根 messenger 也照样"绿"。
//
// 这里用真的 QueueSheetController(不是替身): onRemove/onRestore 的接线就是生产接线。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/home/queue_sheet_controller.dart';
import 'package:minincm/src/platform_is.dart' show debugForceAndroid;
import 'package:minincm/src/play_queue_sheet.dart';
import 'package:minincm/src/queue.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

import 'support/fakes.dart';

class _Harness extends StatefulWidget {
  const _Harness({required this.names, this.startAt = 0});

  final List<String> names;
  final int startAt;

  @override
  State<_Harness> createState() => HarnessState();
}

class HarnessState extends State<_Harness> {
  late final PlayQueue<rust.SongDto> queue = PlayQueue<rust.SongDto>()
    ..setAll([
      for (var i = 0; i < widget.names.length; i++)
        fakeSong(id: i + 1, name: widget.names[i]),
    ], startAt: widget.startAt);

  late final QueueSheetController controller = QueueSheetController(
    contextOf: () => context,
    isMounted: () => mounted,
    queue: queue,
    toast: (_) {},
    playSong: (song, {bool explicit = false}) async {},
    stopPlayback: () async => stopped.add('stop'),
    clearSavedState: () async {},
    setUserStopped: (_) {},
    leaveHeartMode: () {},
    syncActionState: () async {},
  );

  final List<String> stopped = [];

  List<String> get names => [for (final s in queue.items) s.name];

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}

Future<HarnessState> _pump(
  WidgetTester tester, {
  required List<String> names,
  int startAt = 0,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: _Harness(names: names, startAt: startAt),
    ),
  );
  return tester.state<HarnessState>(find.byType(_Harness));
}

/// 展开面板(等 hint 弹窗/进场动画都过去)。
///
/// `open()` 返回的 future **只有面板关掉才 complete**, 所以这里刻意不 await
/// (等它就是等死); 收尾由 [_closeSheet] 负责。
Future<void> _openSheet(WidgetTester tester, HarnessState h) async {
  unawaited(h.controller.open());
  await tester.pumpAndSettle();
  expect(find.byType(PlayQueueSheet), findsOneWidget);
}

/// 收起面板(面板的 route 收干净, 不把浮层留给下一个用例)
Future<void> _closeSheet(WidgetTester tester, HarnessState h) async {
  h.controller.close();
  await tester.pumpAndSettle();
}

/// 左滑删掉某一首
Future<void> _swipeAway(WidgetTester tester, String name) async {
  await tester.drag(find.text(name), const Offset(-500, 0));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // 首次展开的「左滑移除」提示与本文件无关, 预置成已确认
    AppSettings.instance.queueSwipeHintDismissed = true;
  });

  testWidgets('左滑删除: 行消失, 撤销条浮在面板内部(不是被面板盖住的页面底部)', (tester) async {
    final h = await _pump(tester, names: ['第一首', '第二首', '第三首'], startAt: 1);
    await _openSheet(tester, h);

    await _swipeAway(tester, '第一首');

    expect(find.text('第一首'), findsNothing);
    expect(h.names, ['第二首', '第三首'], reason: '删的是非当前项, 其余内容不变');
    expect(find.text('已从队列移除《第一首》'), findsOneWidget, reason: '左滑删除要给撤销窗口');
    expect(find.text('撤销'), findsOneWidget);

    // 撤销条必须落在面板矩形内(根 messenger 的横条画在面板底下, 用户看不见)
    final sheet = tester.getRect(find.byType(PlayQueueSheet));
    final toast = tester.getRect(find.byType(SnackBar));
    expect(
      sheet.top <= toast.top && sheet.bottom >= toast.bottom,
      isTrue,
      reason: '撤销条跑到面板外(会被模态面板盖住): sheet=$sheet toast=$toast',
    );
    await _closeSheet(tester, h);
  });

  testWidgets('点撤销: 该行回到**原下标**, 当前曲目不变', (tester) async {
    final h = await _pump(tester, names: ['第一首', '第二首', '第三首'], startAt: 1);
    await _openSheet(tester, h);
    expect(h.queue.current!.name, '第二首');

    await _swipeAway(tester, '第一首');
    expect(h.names, ['第二首', '第三首']);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect(h.names, ['第一首', '第二首', '第三首'], reason: '撤销要插回原下标 0, 不是追加到队尾');
    expect(h.queue.current!.name, '第二首', reason: '撤销只恢复列表, 不能把播放拽回被删的那首');
    expect(h.queue.index, 1, reason: '当前项下标要跟着插回位置修正');
    expect(find.text('第一首'), findsOneWidget, reason: '面板要跟着真队列恢复那一行');
    expect(find.text('撤销'), findsNothing, reason: '点过就收起撤销条');
    await _closeSheet(tester, h);
  });

  testWidgets('撤销删除当前项: 队列恢复原序, 播放不回到被删的那首', (tester) async {
    final h = await _pump(tester, names: ['第一首', '第二首', '第三首'], startAt: 1);
    await _openSheet(tester, h);

    await _swipeAway(tester, '第二首');
    expect(h.names, ['第一首', '第三首']);
    expect(h.queue.current!.name, '第三首', reason: '删当前项时顶上来的下一首开始播');

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect(h.names, ['第一首', '第二首', '第三首']);
    expect(h.queue.current!.name, '第三首', reason: '撤销只恢复列表 —— 被删的那首不会抢回播放');
    expect(h.queue.index, 2);
    await _closeSheet(tester, h);
  });

  testWidgets('删空后撤销: 该曲回到队列唯一位置(播放仍停着)', (tester) async {
    final h = await _pump(tester, names: ['唯一一首']);
    await _openSheet(tester, h);

    await _swipeAway(tester, '唯一一首');
    expect(h.queue.isEmpty, isTrue);
    expect(h.stopped, contains('stop'));

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect(h.names, ['唯一一首'], reason: '撤销后队列里要有那一首');
    expect(h.queue.index, 0);
    expect(find.textContaining('播放队列是空的'), findsNothing, reason: '面板不能还停在空态');
    await _closeSheet(tester, h);
  });

  group('触感反馈只在 Android(桌面不震动)', () {
    /// 抓 SystemChannels.platform 上我们发的 selectionClick 触感
    List<MethodCall> captureHaptics(WidgetTester tester) {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate' &&
              call.arguments == 'HapticFeedbackType.selectionClick') {
            calls.add(call);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      return calls;
    }

    testWidgets('Android: 左滑删除发一次 selectionClick 触感', (tester) async {
      debugForceAndroid = true;
      addTearDown(() => debugForceAndroid = false);
      final haptics = captureHaptics(tester);
      final h = await _pump(tester, names: ['第一首', '第二首']);
      await _openSheet(tester, h);

      await _swipeAway(tester, '第一首');

      expect(haptics.length, 1, reason: '左滑成功要给一次触感确认');
      await _closeSheet(tester, h);
    });

    testWidgets('桌面(Linux/Windows): 左滑删除不震动', (tester) async {
      final haptics = captureHaptics(tester);
      final h = await _pump(tester, names: ['第一首', '第二首']);
      await _openSheet(tester, h);

      await _swipeAway(tester, '第一首');

      expect(haptics, isEmpty, reason: '桌面没有振动器, 不该发触感调用');
      await _closeSheet(tester, h);
    });
  });
}
