// U-05 回归: 帧后回调的存活守卫 (runPostFrameIfAlive)。
//
// 背景(arch-audit-ui-overlay-2026-11-18 P2/U-05): HomePage 的 `_publishPlayerBar`
// 与 app_shell 的 `publishBottomBar` 都在 `addPostFrameCallback` 里写全局
// `ValueNotifier`(播放条数据 / 底部导航 / 正在播放样本)。回调离开 build 之后
// 页面可能已经被销毁 —— 旧实例的闭包仍会把死页面的状态写进全局槽位。
//
// 修法: 统一走 `runPostFrameIfAlive(context, cb)`([BuildContext.mounted] 判据)。
// 这里既测工具函数本身(存活/已销毁两条路), 也测一次"页面级"场景:
// 调度后同帧销毁 ⇒ 槽位一个字节都不该变。
//
// 注意(测试口径): `tester.pump()` 只在**有帧被调度**时才真的推进一帧
// (AutomatedTestWidgetsFlutterBinding 的 `if (hasScheduledFrame)`), 没有脏 widget
// 的时候要先 `binding.scheduleFrame()`, 否则帧后回调根本不会跑 —— 用例会假绿。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_shell.dart'
    show playerBarSlot, publishBottomBar;
import 'package:minincm/src/lifecycle_guard.dart';

/// 模拟"在 build 里投递帧后回调"的页面: 真正调度的是 [runPostFrameIfAlive]。
class Probe extends StatefulWidget {
  const Probe({super.key, required this.onFrame});

  /// 被投递出去的闭包(生产里是"写全局槽位")。
  final VoidCallback onFrame;

  @override
  State<Probe> createState() => ProbeState();
}

class ProbeState extends State<Probe> {
  /// 与 HomePage._publishPlayerBar 同形: 先在 build 里调度, 帧后才写槽位。
  void publish() => runPostFrameIfAlive(context, widget.onFrame);

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 推进一帧并把帧后回调队列跑完。
Future<void> flushFrame(WidgetTester tester) async {
  tester.binding.scheduleFrame();
  await tester.pump();
}

void main() {
  testWidgets('存活: 帧后回调照常执行, 槽位被写入', (tester) async {
    final key = GlobalKey<ProbeState>();
    final slot = ValueNotifier<String?>(null);
    addTearDown(slot.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Probe(key: key, onFrame: () => slot.value = 'alive'),
      ),
    );

    key.currentState!.publish();
    expect(slot.value, isNull, reason: '帧后才会写, 不能在调度时同步写');
    await flushFrame(tester);
    expect(slot.value, 'alive');
  });

  testWidgets('建 → 同一帧销毁 ⇒ 帧回调触发后槽位没被旧实例写脏', (tester) async {
    final key = GlobalKey<ProbeState>();
    final slot = ValueNotifier<String?>(null);
    addTearDown(slot.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Probe(key: key, onFrame: () => slot.value = 'stale'),
      ),
    );

    // 页面在 build 里投递了一份数据...
    key.currentState!.publish();
    // 对照组: 同一批帧后回调里的一条"没有守卫"的回调, 用来证明这一帧真的跑了
    var controlRan = false;
    WidgetsBinding.instance.addPostFrameCallback((_) => controlRan = true);
    // ...同一帧里就被换掉(销毁); 帧后回调在这之后才跑。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    expect(controlRan, isTrue, reason: '这一帧的帧后回调确实执行过(不是假绿)');
    expect(slot.value, isNull, reason: '已销毁实例不得再写全局槽位');
  });

  // 真实调用点(app_shell.publishBottomBar): 首页销毁后不再投递底部导航。
  testWidgets('publishBottomBar: 已销毁的页面不再写全局槽位', (tester) async {
    final before = playerBarSlot.value;
    addTearDown(() => playerBarSlot.value = before);
    late BuildContext probeCtx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            probeCtx = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    publishBottomBar(probeCtx, const Text('nav'));
    expect(playerBarSlot.value, isNull);
    tester.binding.scheduleFrame();
    await tester.pump();
    expect((playerBarSlot.value as Text?)?.data, 'nav');

    // 再投一份, 但同一帧里页面就被换掉 ⇒ 槽位必须停在上一份
    publishBottomBar(probeCtx, const Text('stale'));
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect((playerBarSlot.value as Text?)?.data, 'nav');
  });
}
