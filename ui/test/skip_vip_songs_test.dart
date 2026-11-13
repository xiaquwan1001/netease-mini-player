// 「播放跳过 VIP 歌曲」的判定口径: 只跳会员曲目(fee=1), 不跳数字专辑(fee=4),
// 也不和无版权(playable=false)混为一谈 —— 后者在取链前就已被拦掉。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/playback_policy.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song({
  int id = 1,
  bool vip = false,
  bool paid = false,
  bool playable = true,
  int fee = 0,
}) => rust.SongDto(
  id: BigInt.from(id),
  name: '曲目$id',
  artist: '艺人',
  artistId: BigInt.one,
  album: '专辑',
  albumId: BigInt.one,
  coverUrl: null,
  durationMs: BigInt.from(1000),
  fee: fee,
  vip: vip,
  paid: paid,
  playable: playable,
);

void main() {
  test('开关关闭: 任何曲目都不跳过', () {
    expect(
      shouldSkipVipSong(song(vip: true, fee: 1), skipVipEnabled: false),
      isFalse,
    );
  });

  test('开关打开: 只跳 VIP 曲目', () {
    expect(
      shouldSkipVipSong(song(vip: true, fee: 1), skipVipEnabled: true),
      isTrue,
    );
    expect(shouldSkipVipSong(song(fee: 0), skipVipEnabled: true), isFalse);
    // 数字专辑(fee=4)不是 VIP, 不跳(用户可能已购买)
    expect(
      shouldSkipVipSong(song(paid: true, fee: 4), skipVipEnabled: true),
      isFalse,
    );
    // 无版权曲目由 playable 拦截, 不属于本策略
    expect(
      shouldSkipVipSong(song(playable: false), skipVipEnabled: true),
      isFalse,
    );
  });

  test('设置持久化: skipVipSongs 落盘并读回', () async {
    final dir = await Directory.systemTemp.createTemp('skip_vip_settings');
    addTearDown(() => dir.delete(recursive: true));
    final settings = AppSettings.instance;
    await settings.load(dir.path);
    expect(settings.skipVipSongs, isFalse, reason: '默认不改变现有行为');

    await settings.update(skipVipSongs: true);
    settings.skipVipSongs = false; // 模拟新进程默认值
    await settings.load(dir.path);
    expect(settings.skipVipSongs, isTrue);
  });
}
