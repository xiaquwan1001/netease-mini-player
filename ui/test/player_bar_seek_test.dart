// P-10: 桌面「边下边播」期进度条不能拖。
//
// 以前拖动会: UI 先跳到新位置 → `Cmd::Seek` 的 `let _ = try_seek(..)` 把错误吞掉 →
// 下一次轮询把位置弹回旧值, 全程没有任何提示(用户以为播放器卡死)。
// 现在源不可 seek 时进度条只弹一句提示、不回调 seek、位置不跳。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/player_bar.dart';

PlayerBarData _data({bool seekable = true}) => PlayerBarData(
  player: PlayerView(
    trackId: BigInt.one,
    playing: true,
    positionMs: BigInt.from(30 * 1000),
    durationMs: BigInt.from(200 * 1000),
    volume: 1.0,
    seekable: seekable,
  ),
  current: null,
  liked: false,
  queueIndex: 1,
  queueLength: 10,
  dragMax: null,
  dragMs: null,
);

PlayerBarActions _actions({
  required void Function(double) onStart,
  required void Function(double) onChanging,
  required void Function(double) onEnd,
}) => PlayerBarActions(
  onSeekStart: onStart,
  onSeekChanging: onChanging,
  onSeekEnd: onEnd,
  onToggleLyrics: () {},
  onOpenDetail: () {},
  onToggleLike: () {},
  onCycleMode: () {},
  onOpenQueue: () {},
  onToggle: () {},
  onPrevious: () {},
  onNext: () {},
);

Widget _app(PlayerBarData data, PlayerBarActions actions) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: MiniPlayerBar(
        data: data,
        actions: actions,
        absorbBottomInset: false,
      ),
    ),
  ),
);

void main() {
  testWidgets('源不可 seek(边下边播): 拖进度条不回调 seek, 只弹「缓存中」提示', (tester) async {
    var seeks = 0;
    await tester.pumpWidget(
      _app(
        _data(seekable: false),
        _actions(
          onStart: (_) => seeks++,
          onChanging: (_) => seeks++,
          onEnd: (_) => seeks++,
        ),
      ),
    );

    // AbsorbPointer 是故意的: Slider 自身收不到手势(所以这里会"打在空处"),
    // 手势由外层 GestureDetector 接住, 只负责弹提示。
    await tester.drag(
      find.byType(Slider),
      const Offset(60, 0),
      warnIfMissed: false,
    );
    await tester.pump();

    // 一次 seek 回调都不能有(以前这里会回调, 于是位置被拖走再弹回)
    expect(seeks, 0);
    // 但用户要得到解释
    expect(find.text(seekBlockedHint), findsOneWidget);
    // 位置仍然停在播放进度上, 没有被拖动值覆盖
    expect(tester.widget<Slider>(find.byType(Slider)).value, closeTo(30000, 1));
  });

  testWidgets('源可 seek(完整落盘文件): 拖动照常回调三件套', (tester) async {
    var starts = 0;
    var changes = 0;
    var ends = 0;
    await tester.pumpWidget(
      _app(
        _data(),
        _actions(
          onStart: (_) => starts++,
          onChanging: (_) => changes++,
          onEnd: (_) => ends++,
        ),
      ),
    );

    await tester.drag(find.byType(Slider), const Offset(60, 0));
    await tester.pump();

    expect(starts, 1);
    expect(changes, greaterThan(0));
    expect(ends, 1);
    expect(find.text(seekBlockedHint), findsNothing);
  });

  test('canSeek/seekBlocked: 渐进期不可拖要提示; 没有量程时静默禁用', () {
    expect(_data().canSeek, isTrue);
    expect(_data().seekBlocked, isFalse);

    expect(_data(seekable: false).canSeek, isFalse);
    expect(_data(seekable: false).seekBlocked, isTrue);

    // 未起播/已停止(时长 0): 进度条禁用, 但没有曲目就不该弹「缓存中」
    final idle = PlayerBarData(
      player: PlayerView.empty,
      current: null,
      liked: false,
      queueIndex: 1,
      queueLength: 1,
      dragMax: null,
      dragMs: null,
    );
    expect(idle.canSeek, isFalse);
    expect(idle.seekBlocked, isFalse);
  });

  test('快照相等性把 seekable 算进去(否则进度条会停在旧的可用态)', () {
    expect(_data(), equals(_data()));
    expect(_data().hashCode, _data().hashCode);
    expect(_data(seekable: false), isNot(equals(_data())));
  });

  group('Android 通道(Media3)不受影响', () {
    const channel = MethodChannel('ncm/player');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() => Playback.debugForceAndroid = true);
    tearDown(() {
      Playback.debugForceAndroid = false;
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('状态 map 没有 seekable 键 ⇒ 默认可 seek(移动端行为一个字没变)', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'state');
        return <String, Object?>{
          'trackId': 1,
          'playing': true,
          'positionMs': 30000,
          'durationMs': 200000,
          'volume': 1.0,
        };
      });
      final view = await Playback().state();
      expect(view.seekable, isTrue);
      expect(view.seekError, isNull);
      expect(view.playing, isTrue);
    });

    test('map 带了 seekable/seekError 也能透出(原生将来要禁用时不用再改 Dart)', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return <String, Object?>{
          'trackId': 1,
          'playing': true,
          'positionMs': 30000,
          'durationMs': 200000,
          'volume': 1.0,
          'seekable': false,
          'seekError': '缓存中, 暂不可跳转',
        };
      });
      final view = await Playback().state();
      expect(view.seekable, isFalse);
      expect(view.seekError, '缓存中, 暂不可跳转');
    });
  });
}
