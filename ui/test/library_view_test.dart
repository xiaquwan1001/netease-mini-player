import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/library_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto s(int id, {bool playable = true}) => rust.SongDto(
      id: BigInt.from(id),
      name: 'song$id',
      artist: 'a',
      album: 'b',
      albumId: BigInt.zero,
      coverUrl: null,
      durationMs: BigInt.from(1000),
      fee: 0,
      vip: false,
      paid: false,
      playable: playable,
    );

void main() {
  final all = [s(1), s(2, playable: false), s(3, playable: false), s(4)];

  test('无版权 + 没收藏 → 搜不出来(不显示)', () {
    final shown = visibleSongs(all, {BigInt.one});
    expect(shown.map((x) => x.id.toInt()), [1, 4]);
    expect(hiddenUnplayableCount(all, {BigInt.one}), 2);
  });

  test('无版权 + 已收藏 → 保留(调用方灰显并可提示)', () {
    final shown = visibleSongs(all, {BigInt.from(2)});
    expect(shown.map((x) => x.id.toInt()), [1, 2, 4]);
    expect(hiddenUnplayableCount(all, {BigInt.from(2)}), 1);
  });

  test('全部可播时什么都不隐藏', () {
    final ok = [s(1), s(2)];
    expect(visibleSongs(ok, <BigInt>{}).length, 2);
    expect(hiddenUnplayableCount(ok, <BigInt>{}), 0);
  });
}
