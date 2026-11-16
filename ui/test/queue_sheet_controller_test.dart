import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/home/queue_sheet_controller.dart';
import 'package:minincm/src/queue.dart';
import 'package:minincm/src/rust/api.dart' as rust;

import 'support/fakes.dart';

// 拆壳 S6 回归: 队列面板 controller 的交互语义必须与拆分前 main.dart 的
// `_openQueueSheet` / `_moveInQueue` / `_removeFromQueue` / `_clearQueue` /
// `_stopAfterQueueEmpty` / `_cycleMode` 逐条等价(见 main.dart 的 G10 搬运)。
//
// 只测 controller 与队列/播放回调之间的契约, 面板自身的渲染由
// queue_sheet_test.dart / queue_sheet_save_test.dart 覆盖。

/// 模拟 HomePage 的接线: 真 PlayQueue + 记录侧效应
class _Harness extends StatefulWidget {
  const _Harness({required this.names, this.startAt = 0, this.loggedIn = true});

  final List<String> names;
  final int startAt;
  final bool loggedIn;

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
    libraryTitleOf: () => libraryTitle,
    toast: (m) => toasts.add(m),
    loggedIn: () => widget.loggedIn,
    playSong: (song, {bool explicit = false}) async {
      played.add((song.name, explicit));
    },
    stopPlayback: () async => stopped.add('stop'),
    clearSavedState: () async => stopped.add('clearState'),
    setUserStopped: (v) => stopped.add('userStopped=$v'),
    heartMode: () async {
      heartCalls += 1;
      if (heartModeSucceeds) libraryTitle = '心动模式';
    },
    syncActionState: () async => syncCalls += 1,
  );

  String? libraryTitle;

  /// 心动模式取数是否成功(false = 未登录/无推荐, 页面会回落列表循环)
  bool heartModeSucceeds = true;

  final List<String> toasts = [];
  final List<(String, bool)> played = [];
  final List<String> stopped = [];
  int heartCalls = 0;
  int syncCalls = 0;
  int rebuilds = 0;

  @override
  void initState() {
    super.initState();
    controller.addListener(() => rebuilds += 1);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: const SizedBox.shrink());
}

Future<HarnessState> _pump(
  WidgetTester tester, {
  required List<String> names,
  int startAt = 0,
  bool loggedIn = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: _Harness(names: names, startAt: startAt, loggedIn: loggedIn),
    ),
  );
  return tester.state<HarnessState>(find.byType(_Harness));
}

void main() {
  group('面板开关', () {
    testWidgets('空队列点开: 只给提示, 不弹面板', (tester) async {
      final h = await _pump(tester, names: []);
      await h.controller.open();
      expect(h.toasts, ['播放队列是空的']);
      expect(h.controller.isOpen, isFalse);
      expect(find.text('当前播放队列'), findsNothing);
    });

    testWidgets('点开 = 压面板, 再点 = 收起(不叠加)', (tester) async {
      final h = await _pump(tester, names: ['a', 'b']);
      final first = h.controller.open();
      await tester.pumpAndSettle();
      expect(h.controller.isOpen, isTrue);
      expect(find.text('当前播放队列'), findsOneWidget);

      final second = h.controller.open();
      await tester.pumpAndSettle();
      expect(find.text('当前播放队列'), findsNothing);
      expect(h.controller.isOpen, isFalse);
      await first;
      await second;
    });

    testWidgets('点某一项: 先关面板, 再按跳播(explicit)换歌', (tester) async {
      final h = await _pump(tester, names: ['a', 'b'], startAt: 0);
      final opening = h.controller.open();
      await tester.pumpAndSettle();
      await tester.tap(find.text('b'));
      await tester.pumpAndSettle();
      await opening;
      expect(h.queue.index, 1);
      expect(h.played, [('b', true)]);
      expect(h.controller.isOpen, isFalse);
    });
  });

  group('队列内增删改', () {
    testWidgets('拖拽重排: 队列原地改, 不换歌不重播', (tester) async {
      final h = await _pump(tester, names: ['a', 'b', 'c'], startAt: 0);
      h.controller.move(0, 2);
      expect([for (final s in h.queue.items) s.name], ['b', 'c', 'a']);
      // PlayQueue.moveTo 自己修当前下标: 当前曲目没变, 仍是 a
      expect(h.queue.current?.name, 'a');
      expect(h.queue.index, 2);
      expect(h.played, isEmpty);
      expect(h.rebuilds, 1);
    });

    testWidgets('删非当前项: 只动列表', (tester) async {
      final h = await _pump(tester, names: ['a', 'b', 'c'], startAt: 1);
      h.controller.remove(h.queue.items[0], false);
      expect([for (final s in h.queue.items) s.name], ['b', 'c']);
      expect(h.queue.current?.name, 'b');
      expect(h.played, isEmpty);
      expect(h.stopped, isEmpty);
    });

    testWidgets('删当前项: 明确换到顶上来的下一首', (tester) async {
      final h = await _pump(tester, names: ['a', 'b', 'c'], startAt: 1);
      h.controller.remove(h.queue.items[1], true);
      await tester.pump();
      expect([for (final s in h.queue.items) s.name], ['a', 'c']);
      expect(h.played, [('c', false)]);
    });

    testWidgets('删空队列: 标记用户停止 + 清现场 + 停播 + 提示', (tester) async {
      final h = await _pump(tester, names: ['a'], startAt: 0);
      h.controller.remove(h.queue.items[0], true);
      await tester.pump();
      expect(h.queue.items, isEmpty);
      expect(h.stopped, ['userStopped=true', 'clearState', 'stop']);
      expect(h.toasts, ['播放队列已清空, 播放已停止']);
    });

    testWidgets('清空: 队列清空后停播(确认弹窗在面板里, 这里只收结果)', (tester) async {
      final h = await _pump(tester, names: ['a', 'b']);
      await h.controller.clear();
      expect(h.queue.items, isEmpty);
      expect(h.stopped, ['userStopped=true', 'clearState', 'stop']);
      expect(h.toasts, ['播放队列已清空, 播放已停止']);
      expect(h.played, isEmpty);
    });
  });

  group('播放模式轮转', () {
    testWidgets('列表循环 → 单曲循环, 顶部浮层给模式名', (tester) async {
      final h = await _pump(tester, names: ['a']);
      h.queue.mode = PlayMode.repeatAll;
      await h.controller.cycleMode();
      await tester.pump();
      expect(h.queue.mode, PlayMode.repeatOne);
      expect(find.text('单曲循环'), findsOneWidget);
      expect(h.syncCalls, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('单曲循环'), findsNothing);
    });

    testWidgets('心动模式中再轮转 = 回列表循环, 且不取心动数据', (tester) async {
      final h = await _pump(tester, names: ['a']);
      h.libraryTitle = '心动模式';
      expect(h.controller.heartActive, isTrue);
      await h.controller.cycleMode();
      expect(h.queue.mode, PlayMode.repeatAll);
      expect(h.heartCalls, 0);
      expect(h.syncCalls, 1);
      await tester.pump();
      expect(find.text('列表循环'), findsOneWidget);
      // 顶部浮层 900ms 自动移除, 排掉这个 Timer 再结束用例
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('随机之后下一步 = 取心动数据, 成功则留在心动模式', (tester) async {
      final h = await _pump(tester, names: ['a']);
      h.queue.mode = PlayMode.shuffle;
      await h.controller.cycleMode();
      expect(h.heartCalls, 1);
      expect(h.queue.mode, PlayMode.shuffle);
      expect(h.toasts, isEmpty);
      await tester.pump();
      expect(find.text('心动模式'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('心动取数失败: 回落列表循环(原 _cycleMode 的兜底)', (tester) async {
      final h = await _pump(tester, names: ['a']);
      h.queue.mode = PlayMode.shuffle;
      h.heartModeSucceeds = false;
      await h.controller.cycleMode();
      expect(h.heartCalls, 1);
      expect(h.queue.mode, PlayMode.repeatAll);
      await tester.pump();
      expect(find.text('列表循环'), findsOneWidget);
      expect(h.syncCalls, 1);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('存为歌单入口', () {
    testWidgets('未登录: 只提示, 不弹选择面板', (tester) async {
      final h = await _pump(tester, names: ['a'], loggedIn: false);
      await h.controller.saveAsPlaylist(h.queue.items);
      expect(h.toasts, ['存为歌单需要先登录']);
      expect(find.text('存为歌单'), findsNothing);
    });

    testWidgets('空快照: 直接返回(面板按 id 去重后可能为空)', (tester) async {
      final h = await _pump(tester, names: ['a']);
      await h.controller.saveAsPlaylist(const []);
      expect(h.toasts, isEmpty);
      expect(find.text('存为歌单'), findsNothing);
    });
  });
}
