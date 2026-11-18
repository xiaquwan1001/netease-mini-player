// P-10 方案 B 的 UI 面: 渐进播放期 seek 是**排队**, 不是拒绝。
//
// 历史(方案 A 时代): 源不可 seek 时进度条被钉死, 拖了只弹「缓存中, 暂不可跳转」——
// 因为那时 Rust 只会拒绝。方案 B 落地后 Rust 会把跳转登记成待跳, 缓存完成换源重建解码器
// 再跳过去, 于是:
//   · 进度条**一律可拖**(只要有时长), 拖动照常回调;
//   · 已排队时拇指停在待跳点, 信息行显示「已排队→mm:ss」;
//   · 真正被拒(下载失败等)只从 seek_error 回传, 由页面 toast, 不再在拖动时就骗用户。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/player_bar.dart';

PlayerBarData _data({bool seekable = true, BigInt? pendingSeekMs}) =>
    PlayerBarData(
      player: PlayerView(
        trackId: BigInt.one,
        playing: true,
        positionMs: BigInt.from(30 * 1000),
        durationMs: BigInt.from(200 * 1000),
        volume: 1.0,
        seekable: seekable,
        pendingSeekMs: pendingSeekMs,
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

/// 信息行是 `Text.rich`(data 为 null), find.text 默认不匹配富文本, 这里自己判。
bool _infoHas(WidgetTester tester, String needle) => tester
    .widgetList<Text>(find.byType(Text))
    .any((t) => (t.data ?? t.textSpan?.toPlainText() ?? '').contains(needle));

void main() {
  testWidgets('边下边播(seekable=false): 进度条照样可拖, 三件套照常回调', (tester) async {
    var starts = 0;
    var changes = 0;
    var ends = 0;
    await tester.pumpWidget(
      _app(
        _data(seekable: false),
        _actions(
          onStart: (_) => starts++,
          onChanging: (_) => changes++,
          onEnd: (_) => ends++,
        ),
      ),
    );

    await tester.drag(find.byType(Slider), const Offset(60, 0));
    await tester.pump();

    // 方案 B: 拖了就上报(Rust 排队), 不再在拖动阶段就被拦下
    expect(starts, 1);
    expect(changes, greaterThan(0));
    expect(ends, 1);
    // 旧的「缓存中, 暂不可跳转」闸门已撤; 真失败由 seek_error → toast 负责
    expect(_infoHas(tester, '暂不可跳转'), isFalse);
  });

  testWidgets('已排队: 拇指停在待跳点而不是旧进度', (tester) async {
    await tester.pumpWidget(
      _app(
        _data(seekable: false, pendingSeekMs: BigInt.from(120 * 1000)),
        _actions(onStart: (_) {}, onChanging: (_) {}, onEnd: (_) {}),
      ),
    );

    // 位置仍是 30s, 但待跳是 120s ⇒ 拇指必须跟着「将要跳到的位置」走, 否则用户看不出
    // 排队到底有没有被接受。
    expect(
      tester.widget<Slider>(find.byType(Slider)).value,
      closeTo(120000, 1),
    );
  });

  testWidgets('已排队: 信息行显示「已排队→mm:ss」', (tester) async {
    await tester.pumpWidget(
      _app(
        _data(seekable: false, pendingSeekMs: BigInt.from(42 * 1000)),
        _actions(onStart: (_) {}, onChanging: (_) {}, onEnd: (_) {}),
      ),
    );

    expect(_infoHas(tester, '已排队→00:42'), isTrue);
  });

  testWidgets('没有待跳时不显示「已排队」', (tester) async {
    await tester.pumpWidget(
      _app(
        _data(),
        _actions(onStart: (_) {}, onChanging: (_) {}, onEnd: (_) {}),
      ),
    );

    expect(_infoHas(tester, '已排队'), isFalse);
  });

  test('canSeek 只看量程: 渐进期也可拖, 停止/未起播(时长 0)才禁用', () {
    expect(_data().canSeek, isTrue);
    // 方案 B 的关键差异: seekable=false 不再等于不能拖
    expect(_data(seekable: false).canSeek, isTrue);

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
    expect(idle.pendingSeekMs, isNull);
  });

  test('快照相等性把 seekable/pendingSeekMs 算进去(否则进度条停在旧状态)', () {
    expect(_data(), equals(_data()));
    expect(_data().hashCode, _data().hashCode);
    expect(_data(seekable: false), isNot(equals(_data())));
    expect(_data(pendingSeekMs: BigInt.from(1000)), isNot(equals(_data())));
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

    test('状态 map 没有 seekable/pendingSeekMs 键 ⇒ 默认可 seek 且无待跳', () async {
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
      expect(view.pendingSeekMs, isNull);
      expect(view.playing, isTrue);
    });

    test('map 带了 seekable/seekError/pendingSeekMs 也能透出', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return <String, Object?>{
          'trackId': 1,
          'playing': true,
          'positionMs': 30000,
          'durationMs': 200000,
          'volume': 1.0,
          'seekable': false,
          'seekError': '下载失败, 重播一次可恢复',
          'pendingSeekMs': 90000,
        };
      });
      final view = await Playback().state();
      expect(view.seekable, isFalse);
      expect(view.seekError, '下载失败, 重播一次可恢复');
      expect(view.pendingSeekMs, BigInt.from(90000));
    });
  });
}
