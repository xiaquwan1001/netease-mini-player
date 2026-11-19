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
    show
        actionsHost,
        playerBarData,
        playerBarSlot,
        publishActionsHost,
        publishBottomBar,
        publishPlayerBarSnapshot;
import 'package:minincm/src/lifecycle_guard.dart';
import 'package:minincm/src/now_playing.dart' show nowPlayingSongId;
import 'package:minincm/src/song_actions.dart' show SongActionHost;

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

/// 全局动作宿主的壳(内容与本组用例无关, 只用来判"槽位里是不是这一份")。
SongActionHost fakeHost() => SongActionHost(
  loggedIn: true,
  isLiked: (_) => false,
  toggleLike: (_) async {},
  playNext: (_) async {},
  addToPlaylist: (_) async {},
  share: (_) async {},
  comments: (_) async {},
  openArtist: (_) async {},
  openAlbum: (_) async {},
  download: (_) async {},
);

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

  // 真实调用点(app_shell.publishActionsHost): 动作宿主是"页面状态生成的菜单回调
  // 集合", 页面销毁后它的闭包还指着死页面的 State —— 旧实例一份都不许再写进去。
  testWidgets('publishActionsHost: 帧后才写, 销毁后不写', (tester) async {
    final before = actionsHost.value;
    addTearDown(() => actionsHost.value = before);
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

    final host = fakeHost();
    publishActionsHost(probeCtx, host);
    expect(actionsHost.value, same(before), reason: '帧后才会写, 不能在调度时同步写');
    await flushFrame(tester);
    expect(actionsHost.value, same(host));

    // 再投一份, 但同一帧里页面就被换掉 ⇒ 槽位必须停在上一份
    publishActionsHost(probeCtx, fakeHost());
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(actionsHost.value, same(host), reason: '已销毁实例不得再写全局槽位');
  });

  // 真实调用点(app_shell.publishPlayerBarSnapshot): 播放条快照与"正在播放"样本
  // 必须在同一个帧后回调里写(同帧只通知一轮), 且同样受存活判据保护。
  testWidgets('publishPlayerBarSnapshot: 快照与播放态同帧投递, 销毁后都不写', (tester) async {
    final beforeId = nowPlayingSongId.value;
    final beforeData = playerBarData.value;
    addTearDown(() {
      nowPlayingSongId.value = beforeId;
      playerBarData.value = beforeData;
    });
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

    publishPlayerBarSnapshot(probeCtx, data: null, nowPlayingId: BigInt.two);
    expect(nowPlayingSongId.value, beforeId, reason: '帧后才会写');
    await flushFrame(tester);
    expect(nowPlayingSongId.value, BigInt.two);

    publishPlayerBarSnapshot(
      probeCtx,
      data: null,
      nowPlayingId: BigInt.from(3),
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(nowPlayingSongId.value, BigInt.two, reason: '已销毁实例不得再写高亮样本');
  });
}
