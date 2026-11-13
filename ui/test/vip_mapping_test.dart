import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/vip_page.dart';

rust.VipOverview overview({
  bool loggedIn = true,
  bool isVip = true,
  bool signedToday = true,
  bool taskDone = false,
}) => rust.VipOverview(
  loggedIn: loggedIn,
  membership: loggedIn
      ? rust.VipMembership(
          level: 3,
          redVipLevel: 3,
          // 2026-12-10T00:00:00Z 附近(本地时区展示为 yyyy-MM-dd)
          expireTimeMs: BigInt.from(1796774400000),
          isVip: isVip,
          annualCount: -1,
        )
      : null,
  growth: loggedIn
      ? rust.VipGrowth(
          level: 3,
          levelName: '黑胶·叁',
          growthPoint: 2195,
          todayScore: 6,
          maxLevel: false,
        )
      : null,
  sign: loggedIn
      ? rust.VipSign(
          signedToday: signedToday,
          weekSigned: signedToday ? 2 : 1,
          days: [
            rust.VipSignDay(
              date: '2026-11-06',
              signed: true,
              today: false,
              score: 3,
            ),
            rust.VipSignDay(
              date: '2026-11-07',
              signed: signedToday,
              today: true,
              score: signedToday ? 3 : 0,
            ),
          ],
        )
      : null,
  tasks: loggedIn
      ? [
          rust.VipTask(
            title: '浏览黑胶时光机',
            reward: '成长值+3',
            growthPoint: 3,
            progress: 0,
            target: 0,
            done: taskDone,
            showProgress: true,
            url: null,
          ),
          rust.VipTask(
            title: '每日听歌',
            reward: '成长值+2',
            growthPoint: 2,
            progress: 60,
            target: 60,
            done: true,
            showProgress: true,
            url: null,
          ),
        ]
      : const [],
  taskScore: 0,
);

void main() {
  test('映射: 会员/成长值/签到/任务 字段一一对应', () {
    final data = mapVipOverview(
      overview(),
      rust.ProfileDetail(
        userId: BigInt.from(42),
        nickname: '测试用户',
        avatarUrl: 'https://example.com/a.jpg',
        backgroundUrl: null,
        signature: '',
        vip: true,
        follows: BigInt.zero,
        followeds: BigInt.zero,
        level: BigInt.from(8),
      ),
    );
    expect(data.isLoggedIn, isTrue);
    final p = data.profile!;
    expect(p.nickname, '测试用户');
    expect(p.avatarUrl, 'https://example.com/a.jpg');
    expect(p.level, 3, reason: 'redVipLevel 优先');
    expect(p.levelName, '黑胶·叁');
    expect(p.isVip, isTrue);
    expect(p.expireDate, isNotNull);
    expect(p.growthValue, 2195);
    expect(p.todayGrowthValue, 6);

    final sign = data.sign!;
    expect(sign.days.length, 2);
    expect(sign.days.last.today, isTrue);
    expect(sign.weekSignedDays, 2);
    expect(sign.signedToday, isTrue);
    expect(sign.days.last.label, '六');

    expect(data.tasks.length, 2);
    expect(data.tasks[0].title, '浏览黑胶时光机');
    expect(data.tasks[0].rewardText, '成长值+3');
    expect(data.tasks[0].showBar, isFalse, reason: 'target=0 不显示进度条');
    expect(data.tasks[1].showBar, isTrue);
    expect(data.tasks[1].done, isTrue);
  });

  test('映射: 未登录只给 isLoggedIn=false', () {
    final data = mapVipOverview(overview(loggedIn: false));
    expect(data.isLoggedIn, isFalse);
    expect(data.profile, isNull);
    expect(data.sign, isNull);
    expect(data.tasks, isEmpty);
  });

  test('映射: 会员过期后 isVip=false, 等级仍保留', () {
    final data = mapVipOverview(overview(isVip: false));
    expect(data.profile!.isVip, isFalse);
    expect(data.profile!.level, 3);
  });

  test('映射: 今天未签时 signedToday=false', () {
    final data = mapVipOverview(overview(signedToday: false));
    expect(data.sign!.signedToday, isFalse);
    expect(data.sign!.weekSignedDays, 1);
  });
}
