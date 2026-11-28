// 回归: 纯位置 tick 不得重建整页(审计 audit-flutter-perf-20261128 §1)。
//
// 背景: 播放协调器每 500ms 轮询一次(歌词展开期 120ms), 只要 positionMs 变了就
// notifyListeners。HomePage 之前无条件 setState ⇒ IndexedStack 里所有访问过的
// tab 都被重建一次, 而位置 tick 的唯一真实消费者只有播放条快照。
//
// 这里用真壳(MiniNcmApp) + mock `ncm/player` 通道驱动轮询, 跨过一次 500ms tick
// 后用 Scaffold widget 实例同一性判定: 结构性字段没变就不该换实例。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart' show MiniNcmApp;
import 'package:minincm/src/app_shell.dart' show playerBarData, playerBarSlot;
import 'package:minincm/src/platform_is.dart' show debugForceAndroid;
import 'package:minincm/src/playback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ncm/player');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 每次 `state` 返回的播放位置(毫秒), 每次调用 +500(模拟播放推进)。
  var position = 0;

  setUp(() {
    position = 0;
    debugForceAndroid = true;
    Playback.debugResetUserAgentCache();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'state') {
        position += 500;
        return <String, Object?>{
          // 有曲目才投播放条快照(否则 showBar=false, data 恒为 null)。
          'trackId': 42,
          'playing': true,
          'positionMs': position,
          'durationMs': 200000,
          'volume': 1.0,
        };
      }
      return <String, Object?>{'playing': false, 'durationMs': 200000};
    });
  });

  tearDown(() {
    debugForceAndroid = false;
    Playback.debugResetUserAgentCache();
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('结构性字段不变时, 跨过 500ms 位置 tick 不重建整页', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MiniNcmApp());
    // 首帧 + 让 bootstrap 里的 500ms 轮询起起来(只 pump 固定帧, 不 pumpAndSettle:
    // 轮询 Timer 永不静止)。第一次轮询会把空播放态替换成有值快照 = 一次结构变化。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);

    final before = tester.widget(find.byType(Scaffold).first);
    final posBefore = playerBarData.value?.player.positionMs;
    // 再跨一次 500ms tick: 只有 positionMs 变化, 结构快照不变。
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    final after = tester.widget(find.byType(Scaffold).first);
    final posAfter = playerBarData.value?.player.positionMs;

    expect(
      identical(after, before),
      isTrue,
      reason: '纯位置 tick 不得重建整页(只有播放条快照该刷新)',
    );
    // 进度条数据必须照旧推进(否则就是把播放条改坏了)。
    expect(posBefore, isNotNull);
    expect(
      posAfter! > posBefore!,
      isTrue,
      reason: '纯位置 tick 仍须刷新播放条快照, 进度不能停在上一帧',
    );
  });

  testWidgets('底部导航只在结构键变化时才投新实例', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MiniNcmApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    addTearDown(() => playerBarSlot.value = null);

    final navBefore = playerBarSlot.value;
    expect(navBefore, isA<NavigationBar>(), reason: '根页面应有底部导航');

    await tester.pump(const Duration(milliseconds: 600));
    expect(
      identical(playerBarSlot.value, navBefore),
      isTrue,
      reason: '导航栏结构键没变时不得投新实例(否则底栏四层 builder 全重建)',
    );
  });
}
