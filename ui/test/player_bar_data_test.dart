// PlayerBarData: 不可变快照的相等性 + "数据没变不重复通知".
//
// HomePage 每帧生成一份快照投递到 playerBarData; 相等时 ValueNotifier 不通知,
// 播放条因此只在数据真变时才重建(本文件锁定这两个契约).

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/player_bar.dart';
import 'package:minincm/src/playback.dart';

PlayerView _view({BigInt? position, bool playing = false}) => PlayerView(
      trackId: BigInt.from(1),
      playing: playing,
      positionMs: position ?? BigInt.zero,
      durationMs: BigInt.from(200000),
      volume: 1.0,
    );

PlayerBarData _data({PlayerView? player, double? dragMs}) => PlayerBarData(
      player: player ?? _view(),
      current: null,
      liked: false,
      queueIndex: 1,
      queueLength: 10,
      dragMax: null,
      dragMs: dragMs,
    );

void main() {
  test('字段全等 ⇒ == 为真; 任意字段不同 ⇒ 不等(含 hashCode 一致性)', () {
    // 每帧新建的 PlayerView/SongDto 实例, 值相同就视为同一份数据
    expect(_data(), equals(_data(player: _view())));
    expect(_data().hashCode, _data(player: _view()).hashCode);

    expect(_data(player: _view(playing: true)), isNot(equals(_data())));
    expect(
      _data(player: _view(position: BigInt.from(5000))),
      isNot(equals(_data())),
    );
    expect(_data(dragMs: 1234.0), isNot(equals(_data())));
  });

  test('数据没变 ⇒ ValueNotifier 不重复通知; 变了 ⇒ 通知一次', () {
    final slot = ValueNotifier<PlayerBarData?>(null);
    var notifications = 0;
    slot.addListener(() => notifications++);

    final first = _data();
    slot.value = first; // 首次投递: 通知
    expect(notifications, 1);

    slot.value = _data(); // 同值新实例: 不通知(播放条不重建)
    expect(notifications, 1);

    slot.value = _data(dragMs: 999.0); // 拖动中: 数据变了, 通知
    expect(notifications, 2);

    slot.value = null; // 无曲目: 通知
    expect(notifications, 3);
  });
}
