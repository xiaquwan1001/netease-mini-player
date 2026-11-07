import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/medal_wall.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.UserLevelDto levelDto({int level = 9}) => rust.UserLevelDto(
      level: level,
      nowPlayCount: BigInt.from(2301),
      nextPlayCount: BigInt.from(12000),
      nowLoginCount: BigInt.from(350),
      nextLoginCount: BigInt.from(350),
      progress: 0.19175,
      privileges: r'60G音乐网盘免费容量$黑名单上限120',
    );

rust.UserMedalDto medalDto(String name, {bool obtained = true}) =>
    rust.UserMedalDto(
      code: 'code-$name',
      name: name,
      picUrl: null,
      wearPicUrl: null,
      condition: '达成条件',
      obtained: obtained,
      obtainTimeMs: obtained ? BigInt.from(1700000000000) : null,
      levelTitle: null,
      progressText: null,
      rankText: null,
      status: obtained ? 'OBTAIN' : 'NOT_OBTAIN_PROCESS',
    );

void main() {
  test('映射: 等级进度按听歌数, 勋章按 obtained 区分', () {
    final data = mapMedalWall(
      levelDto(),
      [medalDto('早期用户'), medalDto('乐迷 Lv.4', obtained: false)],
      isVip: true,
    );
    expect(data.level!.level, 9);
    expect(data.level!.progress, 2301);
    expect(data.level!.target, 12000);
    expect(data.level!.isVip, isTrue);
    expect(data.level!.fraction, closeTo(2301 / 12000, 1e-9));

    expect(data.medals.length, 2);
    expect(data.medals.first.name, '早期用户');
    expect(data.medals.first.obtained, isTrue);
    expect(data.medals.last.obtained, isFalse);
    expect(data.medals.last.description, '达成条件');
  });

  test('映射: 等级拉取失败时只是没有等级卡, 勋章照常', () {
    final data = mapMedalWall(null, [medalDto('勋章')]);
    expect(data.level, isNull);
    expect(data.medals.length, 1);
  });

  test('映射: 空勋章列表', () {
    final data = mapMedalWall(levelDto(), const []);
    expect(data.medals, isEmpty);
    expect(data.level, isNotNull);
  });
}
