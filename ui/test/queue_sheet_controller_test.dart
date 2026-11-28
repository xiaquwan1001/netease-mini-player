import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/home/queue_sheet_controller.dart';
import 'package:minincm/src/play_queue_sheet.dart';
import 'package:minincm/src/player_bar.dart' show isDesktopPlatform;
import 'package:minincm/src/queue.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

import 'support/fakes.dart';

// 拆壳 S6 回归: 队列面板 controller 的交互语义必须与拆分前 main.dart 的
// `_openQueueSheet` / `_moveInQueue` / `_removeFromQueue` / `_clearQueue` /
// `_stopAfterQueueEmpty` / `_cycleMode` 逐条等价(见 main.dart 的 G10 搬运)。
//
// 只测 controller 与队列/播放回调之间的契约, 面板自身的渲染由
// queue_sheet_test.dart 覆盖。

/// 模拟 HomePage 的接线: 真 PlayQueue + 记录侧效应
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
    toast: (m) => toasts.add(m),
    playSong: (song, {bool explicit = false}) async {
      played.add((song.name, explicit));
    },
    stopPlayback: () async => stopped.add('stop'),
    clearSavedState: () async => stopped.add('clearState'),
    setUserStopped: (v) => stopped.add('userStopped=$v'),
    leaveHeartMode: () {
      leaveCalls += 1;
      if (libraryTitle == '心动模式') libraryTitle = '正在播放';
    },
    syncActionState: () async => syncCalls += 1,
  );

  String? libraryTitle;

  final List<String> toasts = [];
  final List<(String, bool)> played = [];
  final List<String> stopped = [];
  int leaveCalls = 0;
  int syncCalls = 0;
  int rebuilds = 0;

  @override
  void initState() {
    super.initState();
    controller.addListener(() => rebuilds += 1);
  }

  /// 模拟页面 `_heartMode()` 成功后的两步: 引导态 + 歌单浏览态标题
  void enterHeart() {
    libraryTitle = '心动模式';
    controller.enterGuide(QueueGuide.heart);
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
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: _Harness(names: names, startAt: startAt),
    ),
  );
  return tester.state<HarnessState>(find.byType(_Harness));
}

void main() {
  setUp(() {
    // 面板首次展开会弹「左滑移除」提示(2026-11-18)。除了专门测它的用例,
    // 其余用例一律预置"已确认", 免得每条都要先点掉弹窗。
    AppSettings.instance.queueSwipeHintDismissed = true;
  });

  group('收起面板(U-02)', () {
    testWidgets('面板之上压着别的对话框时, close() 关的是自己那条, 不是栈顶', (tester) async {
      final h = await _pump(tester, names: ['a', 'b']);
      final opening = h.controller.open();
      await tester.pumpAndSettle();
      expect(find.text('当前播放队列'), findsOneWidget);

      // 真实场景: 面板里的「清空确认框」压在上面
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(PlayQueueSheet)),
          builder: (_) => const AlertDialog(title: Text('上层对话框')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('上层对话框'), findsOneWidget);

      h.controller.close();
      await tester.pumpAndSettle();
      // 旧实现是 Navigator.maybePop(): 弹掉的是栈顶的对话框, 面板自己还开着
      expect(find.text('当前播放队列'), findsNothing, reason: '关的是自己那条 route');
      expect(find.text('上层对话框'), findsOneWidget, reason: 'close() 不碰上层');
      expect(h.controller.isOpen, isFalse);

      Navigator.of(tester.element(find.text('上层对话框'))).pop();
      await tester.pumpAndSettle();
      await opening;
    });

    testWidgets('close() 关掉自己后, 面板 pop 掉也不会误退页面', (tester) async {
      final h = await _pump(tester, names: ['a']);
      final opening = h.controller.open();
      await tester.pumpAndSettle();
      h.controller.close();
      await tester.pumpAndSettle();
      expect(h.controller.isOpen, isFalse);
      expect(find.text('当前播放队列'), findsNothing);
      await opening;
      await tester.pumpAndSettle();
      // 页面本体还在(没有被多 pop 一层)
      expect(find.byType(_Harness), findsOneWidget);
    });
  });

  group('左滑提示', () {
    testWidgets('首次展开弹提示; 勾「确认后不再展示」后永久不再弹', (tester) async {
      AppSettings.instance.queueSwipeHintDismissed = false;
      final h = await _pump(tester, names: ['a', 'b']);
      final opening = h.controller.open();
      await tester.pumpAndSettle();
      // 文案按平台分叉: 桌面没有"左滑"这个手势(2026-11-26 审计 #10),
      // 宿主是 Linux ⇒ 这里跑的是桌面那一句。
      expect(
        find.textContaining(isDesktopPlatform ? '向左拖动' : '左滑'),
        findsOneWidget,
      );
      expect(find.text('确认后不再展示'), findsOneWidget);

      await tester.tap(find.text('确认后不再展示'));
      await tester.pump();
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(AppSettings.instance.queueSwipeHintDismissed, isTrue);
      expect(h.controller.isOpen, isTrue, reason: '确认完提示后照常展开面板');
      h.controller.close();
      await tester.pumpAndSettle();
      await opening;

      // 第二次: 不再弹
      final second = h.controller.open();
      await tester.pumpAndSettle();
      expect(find.text('确认后不再展示'), findsNothing);
      h.controller.close();
      await tester.pumpAndSettle();
      await second;
    });

    testWidgets('不勾选 = 只关掉本次提示, 下次还会弹', (tester) async {
      AppSettings.instance.queueSwipeHintDismissed = false;
      final h = await _pump(tester, names: ['a']);
      final opening = h.controller.open();
      await tester.pumpAndSettle();
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(AppSettings.instance.queueSwipeHintDismissed, isFalse);
      h.controller.close();
      await tester.pumpAndSettle();
      await opening;
    });

    testWidgets('提示框在场时再点一次队列键: 不会叠出第二个提示框/第二条面板', (tester) async {
      // 锁审计 2026-11-28 #1: 播放条的队列键在 Navigator 之外, 遮罩盖不到它。
      // 旧实现等提示框回答完才置 `_open`, 于是这段时间再点一次会再弹一个提示框,
      // 回答后压出第二条 sheet, 先压的那条 pop 时又把 isOpen 置 false。
      AppSettings.instance.queueSwipeHintDismissed = false;
      final h = await _pump(tester, names: ['a', 'b']);
      final first = h.controller.open();
      await tester.pumpAndSettle();
      expect(find.text('知道了'), findsOneWidget, reason: '提示框已弹出');
      expect(h.controller.isOpen, isTrue, reason: '正在展开也要算 open(防重入)');

      // 提示框在场时再点一次: 不叠提示框, 而是当作"收起"
      final second = h.controller.open();
      await tester.pumpAndSettle();
      expect(find.text('知道了'), findsOneWidget, reason: '只能有一个提示框');
      expect(h.controller.isOpen, isFalse);

      // 关掉提示框: 因为期间已经"收起", 不再压出面板
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      await first;
      await second;
      expect(find.text('当前播放队列'), findsNothing);
      expect(h.controller.isOpen, isFalse);
    });
  });

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

    // 撤销删除(2026-11-26 安卓交互审计 P2#6): 面板的撤销条走 [restore] 把被滑删的
    // 那一首插回**原下标**, 与 [remove] 严格互逆 —— 当前曲目不变、不重播。
    testWidgets('撤销删除非当前项: 插回原下标, 当前曲目不变', (tester) async {
      final h = await _pump(tester, names: ['a', 'b', 'c'], startAt: 1);
      final removed = h.queue.items[0];
      h.controller.remove(removed, false);
      expect([for (final s in h.queue.items) s.name], ['b', 'c']);
      expect(h.queue.index, 0);

      h.controller.restore(0, removed);

      expect([for (final s in h.queue.items) s.name], ['a', 'b', 'c']);
      expect(h.queue.current?.name, 'b', reason: '撤销只恢复列表, 当前曲目不变');
      expect(h.queue.index, 1, reason: '插回位置在当前项之前 ⇒ 当前下标 +1');
      expect(h.played, isEmpty);
      expect(h.stopped, isEmpty);
    });

    testWidgets('撤销删除当前项: 队列恢复原序, 播放不回到被删的那首', (tester) async {
      final h = await _pump(tester, names: ['a', 'b', 'c'], startAt: 1);
      final removed = h.queue.items[1];
      h.controller.remove(removed, true);
      await tester.pump();
      expect(h.played, [('c', false)]);

      h.controller.restore(1, removed);

      expect([for (final s in h.queue.items) s.name], ['a', 'b', 'c']);
      expect(h.queue.current?.name, 'c');
      expect(h.queue.index, 2);
      expect(h.played, [('c', false)], reason: '撤销不该再触发一次换歌');
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

    testWidgets('随机播放之后回到列表循环(轮转只有 4 档, 不再进心动模式)', (tester) async {
      final h = await _pump(tester, names: ['a']);
      h.queue.mode = PlayMode.shuffle;
      await h.controller.cycleMode();
      expect(h.queue.mode, PlayMode.repeatAll);
      expect(h.controller.heartActive, isFalse);
      await tester.pump();
      expect(find.text('列表循环'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('心动引导态中按播放顺序 = 退出引导回列表循环(标题一起改)', (tester) async {
      final h = await _pump(tester, names: ['a']);
      h.enterHeart();
      expect(h.controller.heartActive, isTrue);
      await h.controller.cycleMode();
      expect(h.queue.mode, PlayMode.repeatAll);
      expect(h.syncCalls, 1);
      // 2026-11-18 用户反馈的根因: 只改 mode 不改歌单浏览态标题 ⇒ heartActive
      // 永远为真, 图标变不回来、再点只反复弹「列表循环」。
      expect(h.controller.heartActive, isFalse, reason: '必须真的跳出心动模式');
      expect(h.leaveCalls, 1);
      expect(h.libraryTitle, '正在播放', reason: '队列还在, 标题回到正在播放而不是清空');
      await tester.pump();
      expect(find.text('列表循环'), findsOneWidget);
      // 顶部浮层 900ms 自动移除, 排掉这个 Timer 再结束用例
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('私人FM 引导态中按播放顺序 = 退出引导回列表循环(不动心动标题)', (tester) async {
      final h = await _pump(tester, names: ['a', 'b']);
      h.queue.mode = PlayMode.shuffle;
      h.controller.enterGuide(QueueGuide.fm);
      expect(h.controller.fmActive, isTrue);
      expect(h.controller.heartActive, isFalse);
      await h.controller.cycleMode();
      expect(h.controller.fmActive, isFalse);
      expect(h.queue.mode, PlayMode.repeatAll);
      expect(h.leaveCalls, 0, reason: 'FM 没有心动标题要改');
      await tester.pump();
      expect(find.text('列表循环'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  // 2026-11-19 用户反馈 4/5: 「播放顺序」与心动模式/私人FM 彻底分开 —— 进入时记下
  // 原来的 PlayMode, 退出(非播放顺序按钮路径)时恢复它。
  group('引导态进出', () {
    testWidgets('进入心动记录原模式, exitGuide() 恢复它', (tester) async {
      final h = await _pump(tester, names: ['a']);
      h.queue.mode = PlayMode.repeatOne;
      h.enterHeart();
      expect(h.queue.mode, PlayMode.repeatOne, reason: '进入引导不擅自改 mode');
      h.controller.exitGuide();
      expect(h.queue.mode, PlayMode.repeatOne, reason: '恢复进入前的 PlayMode');
      expect(h.controller.heartActive, isFalse);
      expect(h.libraryTitle, '正在播放');
    });

    testWidgets('FM → 心动: 记录的仍是回到普通播放要用的那个模式', (tester) async {
      final h = await _pump(tester, names: ['a']);
      h.queue.mode = PlayMode.sequence;
      h.controller.enterGuide(QueueGuide.fm);
      h.controller.enterGuide(QueueGuide.heart);
      h.controller.exitGuide();
      expect(h.queue.mode, PlayMode.sequence);
      expect(h.controller.guide, QueueGuide.none);
    });

    testWidgets('重复进入同一引导态不重复记录、不通知', (tester) async {
      final h = await _pump(tester, names: ['a']);
      h.queue.mode = PlayMode.shuffle;
      h.controller.enterGuide(QueueGuide.fm);
      final rebuilds = h.rebuilds;
      h.controller.enterGuide(QueueGuide.fm);
      expect(h.rebuilds, rebuilds);
      h.queue.mode = PlayMode.repeatAll;
      h.controller.exitGuide();
      expect(h.queue.mode, PlayMode.shuffle, reason: '记录的还是第一次进入前的模式');
    });

    testWidgets('enterGuide(none) = 退出引导', (tester) async {
      final h = await _pump(tester, names: ['a']);
      h.controller.enterGuide(QueueGuide.fm);
      h.controller.enterGuide(QueueGuide.none);
      expect(h.controller.guide, QueueGuide.none);
    });

    testWidgets('queueChanged(): 引导态续播追加了一批 ⇒ 通知面板重排', (tester) async {
      final h = await _pump(tester, names: ['a', 'b']);
      h.controller.enterGuide(QueueGuide.fm);
      final rebuilds = h.rebuilds;
      h.queue.append(fakeSong(id: 9, name: 'FM 新歌'));
      h.controller.queueChanged();
      expect(h.rebuilds, rebuilds + 1);
    });
  });
}
