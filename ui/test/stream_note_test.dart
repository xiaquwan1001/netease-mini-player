// 取链提示(试听片段 / 静默降级)的口径 + 播放条落点。
//
// 背景(方案 A, 2026-11-18): 上游 song/url/v1 的 freeTrialInfo / level 以前
// 整块被丢弃 —— 45 秒试听片段被当整曲播, 请求无损被降级成 320k 也没人说。
// Rust 侧现在如实解析(ncm-domain::StreamUrl), 这里锁两件事:
//   1. StreamNote 的文案口径(纯函数, 不需要 widget);
//   2. 播放条第二行行首真的显示这条提示, 且只对**当前曲目**显示。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/player_bar.dart';
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/stream_note.dart';

rust.StreamUrl _stream({
  String? url = 'https://m7/1.mp3',
  String level = 'exhigh',
  String? actualLevel,
  bool isTrial = false,
  int? trialStartMs,
  int? trialEndMs,
}) => rust.StreamUrl(
  url: url,
  quality: level,
  br: BigInt.from(320000),
  size: BigInt.from(3000000),
  expireAt: BigInt.from(1700000000),
  actualLevel: actualLevel,
  format: 'mp3',
  md5: 'aabb',
  durationMs: BigInt.from(200000),
  trialStartMs: trialStartMs == null ? null : BigInt.from(trialStartMs),
  trialEndMs: trialEndMs == null ? null : BigInt.from(trialEndMs),
  isTrial: isTrial,
);

PlayerBarData _data(int trackId) => PlayerBarData(
  player: PlayerView(
    playing: true,
    positionMs: BigInt.from(30 * 1000),
    durationMs: BigInt.from(200 * 1000),
    volume: 1.0,
  ),
  current: rust.SongDto(
    id: BigInt.from(trackId),
    name: '歌名甲',
    artist: '艺人乙',
    artistId: BigInt.one,
    album: '专辑丙',
    albumId: BigInt.one,
    coverUrl: null,
    durationMs: BigInt.from(200 * 1000),
    fee: 0,
    vip: false,
    paid: false,
    playable: true,
  ),
  liked: false,
  queueIndex: 1,
  queueLength: 10,
  dragMax: null,
  dragMs: null,
);

PlayerBarActions _actions() => PlayerBarActions(
  onSeekStart: (_) {},
  onSeekChanging: (_) {},
  onSeekEnd: (_) {},
  onToggleLyrics: () {},
  onOpenDetail: () {},
  onToggleLike: () {},
  onCycleMode: () {},
  onOpenQueue: () {},
  onToggle: () {},
  onPrevious: () {},
  onNext: () {},
);

String _barText(WidgetTester tester) {
  final buf = StringBuffer();
  for (final t in tester.widgetList<Text>(
    find.descendant(
      of: find.byType(MiniPlayerBar),
      matching: find.byType(Text),
    ),
  )) {
    buf.write(t.data ?? t.textSpan?.toPlainText() ?? '');
    buf.write('\n');
  }
  return buf.toString();
}

Future<void> _pump(WidgetTester tester, PlayerBarData data) async {
  tester.view.physicalSize = const Size(700, 240);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(700, 240)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MiniPlayerBar(
              data: data,
              actions: _actions(),
              absorbBottomInset: false,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  tearDown(() => currentStreamNote.value = null);

  test('整曲且未降级 ⇒ 没有提示(播放条什么都不加)', () {
    expect(StreamNote.fromStream(_stream(actualLevel: 'exhigh')), isNull);
    // 上游没给 actual_level(旧上游/旧缓存) ⇒ 不猜, 也不提示降级
    expect(StreamNote.fromStream(_stream()), isNull);
  });

  test('试听片段: 文案是「试听 mm:ss」, 与播放条时间口径一致', () {
    final note = StreamNote.fromStream(
      _stream(
        level: 'lossless',
        actualLevel: 'standard',
        isTrial: true,
        trialStartMs: 0,
        trialEndMs: 45000,
      ),
    )!;
    expect(note.isTrial, isTrue);
    expect(note.isDegraded, isTrue);
    expect(note.label, '试听 00:45 · 已降级 标准  ');
  });

  test('只有降级没有试听 ⇒ 只说降级, 档位翻译成中文短名', () {
    final note = StreamNote.fromStream(
      _stream(level: 'lossless', actualLevel: 'exhigh'),
    )!;
    expect(note.isTrial, isFalse);
    expect(note.label, '已降级 极高  ');
  });

  test('是试听但上游没给起止 ⇒ 仍标「试听」(不带长度)', () {
    final note = StreamNote.fromStream(_stream(isTrial: true))!;
    expect(note.isTrial, isTrue);
    expect(note.label, '试听  ');
  });

  test('试听片段从第 10 秒开始: 长度只算 (end - start)', () {
    final note = StreamNote.fromStream(
      _stream(isTrial: true, trialStartMs: 10000, trialEndMs: 55000),
    )!;
    expect(note.trialLenMs, 45000);
    expect(note.label, '试听 00:45  ');
  });

  testWidgets('播放条第二行显示当前曲目的试听提示', (tester) async {
    publishStreamNote(
      BigInt.one,
      StreamNote.fromStream(
        _stream(isTrial: true, trialStartMs: 0, trialEndMs: 45000),
      ),
    );
    await _pump(tester, _data(1));
    expect(_barText(tester), contains('试听 00:45'));
  });

  testWidgets('提示只挂在它对应的曲目上(换曲后不串台)', (tester) async {
    publishStreamNote(
      BigInt.one,
      StreamNote.fromStream(
        _stream(isTrial: true, trialStartMs: 0, trialEndMs: 45000),
      ),
    );
    await _pump(tester, _data(2));
    expect(_barText(tester), isNot(contains('试听')));
  });

  test('publishStreamNote 幂等: 同值不重复通知', () {
    var calls = 0;
    void listener() => calls++;
    currentStreamNote.addListener(listener);
    addTearDown(() => currentStreamNote.removeListener(listener));
    final note = StreamNote.fromStream(
      _stream(isTrial: true, trialStartMs: 0, trialEndMs: 45000),
    )!;
    publishStreamNote(BigInt.one, note);
    publishStreamNote(BigInt.one, note);
    expect(calls, 1);
    publishStreamNote(null, null);
    expect(calls, 2);
    expect(currentStreamNote.value, isNull);
  });
}
