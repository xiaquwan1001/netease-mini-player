// 他人主页「常听」栏的回归.
//
// 背景(2026-11-21 用户实测): 登录态下官方 PC 网页能看到别人的听歌排行
// (对一个累积 6114 首的账号有真实数据), 之前"匿名恒空 ⇒ 接了也看不到东西"的
// 判定只在匿名通道成立 —— 匿名请求 /api/v1/play/record 只回
// 200 + 空数组(实测), 所以"未登录"必须由 UI 按登录态自己判, 不能靠空列表。
//
// 这里用注入 loader + loggedIn 覆盖: 有数据渲染 / 周期切换 / 空态 / 失败重试 /
// 未登录给「登录后可见」, 不联网、不碰 FFI。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/user_page.dart';

import 'support/fakes.dart';

rust.ProfileDetail detail({String nickname = '小猫屿海'}) => rust.ProfileDetail(
  userId: BigInt.from(1822714196),
  nickname: nickname,
  avatarUrl: null,
  backgroundUrl: null,
  signature: '',
  vip: false,
  follows: BigInt.from(44),
  followeds: BigInt.from(11),
  level: BigInt.from(8),
);

rust.PlayRankEntryDto entry(int id, String name, int playCount) =>
    rust.PlayRankEntryDto(
      song: fakeSong(id: id, name: name, artist: '周杰伦'),
      playCount: BigInt.from(playCount),
      score: BigInt.from(playCount * 10),
    );

Widget host(Widget child) => MaterialApp(home: child);

/// 用户页有 220 横幅 + 身份卡 + pinned TabBar, 800x600 放不下排行卡片
void setTallView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(420, 1000);
  addTearDown(tester.view.reset);
}

/// 排行榜行标题走跑马灯(无限动画)时 pumpAndSettle 永不收敛, 固定推进若干帧
Future<void> pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  testWidgets('常听栏: 有数据时渲染前几条 + 次数, 周期分段用官方措辞', (tester) async {
    setTallView(tester);
    final periods = <String>[];
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1822714196),
          loggedIn: true,
          loadProfile: (_) async => detail(),
          loadPlaylists: (_) async => const [],
          loadEvents: (_) async => const [],
          loadRanking: (period) async {
            periods.add(period);
            return [entry(1, '常听的歌', 120), entry(2, '第二常听', 80)];
          },
          initialTab: '常听',
        ),
      ),
    );
    await pumpFrames(tester);

    expect(periods, ['all']);
    expect(find.text('所有时间'), findsOneWidget);
    expect(find.text('最近一周'), findsOneWidget);
    expect(find.text('常听的歌'), findsOneWidget);
    expect(find.text('120 次'), findsOneWidget);
    // 名次 = 列表下标 + 1
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('常听栏: 切到最近一周会重新取数并换数据', (tester) async {
    setTallView(tester);
    final periods = <String>[];
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1822714196),
          loggedIn: true,
          loadProfile: (_) async => detail(),
          loadPlaylists: (_) async => const [],
          loadEvents: (_) async => const [],
          loadRanking: (period) async {
            periods.add(period);
            return period == 'week'
                ? [entry(3, '本周单曲', 7)]
                : [entry(1, '常听的歌', 120)];
          },
          initialTab: '常听',
        ),
      ),
    );
    await pumpFrames(tester);
    expect(find.text('常听的歌'), findsOneWidget);

    await tester.tap(find.text('最近一周'));
    await pumpFrames(tester);

    expect(periods, ['all', 'week']);
    expect(find.text('本周单曲'), findsOneWidget);
    expect(find.text('7 次'), findsOneWidget);
    expect(find.text('常听的歌'), findsNothing);
  });

  testWidgets('常听栏: 空列表给对方口径的空态(不是"登录后听几首歌就有了")', (tester) async {
    setTallView(tester);
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1822714196),
          loggedIn: true,
          loadProfile: (_) async => detail(),
          loadPlaylists: (_) async => const [],
          loadEvents: (_) async => const [],
          loadRanking: (_) async => const [],
          initialTab: '常听',
        ),
      ),
    );
    await pumpFrames(tester);

    expect(find.text('Ta 还没有公开的听歌记录'), findsOneWidget);
    expect(find.textContaining('登录后听几首歌就有了'), findsNothing);
  });

  testWidgets('常听栏: 非网络错误(如 internal)不弹错, 直接给对方的空态', (tester) async {
    // 用户反馈 3: 别人的常听页上直接铺出 `[internal error] ...`。
    // Rust 侧 play_ranking_of 已吞成空列表, 这里验 Dart 层双保险。
    setTallView(tester);
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1822714196),
          loggedIn: true,
          loadProfile: (_) async => detail(),
          loadPlaylists: (_) async => const [],
          loadEvents: (_) async => const [],
          loadRanking: (_) async => throw const rust.FfiError(
            kind: 'internal',
            retryable: false,
            detail: 'code=400',
          ),
          initialTab: '常听',
        ),
      ),
    );
    await pumpFrames(tester);

    expect(find.textContaining('[internal'), findsNothing);
    expect(find.text('Ta 还没有公开的听歌记录'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('常听栏: 网络错误仍交给四态 UI(可重试)', (tester) async {
    setTallView(tester);
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1822714196),
          loggedIn: true,
          loadProfile: (_) async => detail(),
          loadPlaylists: (_) async => const [],
          loadEvents: (_) async => const [],
          loadRanking: (_) async => throw const rust.FfiError(
            kind: 'network',
            retryable: true,
            detail: 'reset',
          ),
          initialTab: '常听',
        ),
      ),
    );
    // retryNetwork 退避 500ms + 1000ms 后才把错误交给 UI
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await pumpFrames(tester);

    expect(find.textContaining('网络不稳定'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('常听栏: 次数为 0 不渲染「0 次」', (tester) async {
    setTallView(tester);
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1822714196),
          loggedIn: true,
          loadProfile: (_) async => detail(),
          loadPlaylists: (_) async => const [],
          loadEvents: (_) async => const [],
          loadRanking: (_) async => [
            entry(1, '有次数的歌', 120),
            entry(2, '上游没给次数的歌', 0),
          ],
          initialTab: '常听',
        ),
      ),
    );
    await pumpFrames(tester);

    expect(find.text('120 次'), findsOneWidget);
    expect(find.text('0 次'), findsNothing);
    // 条目本身仍要在(不能因计数为 0 丢行)
    expect(find.text('上游没给次数的歌'), findsOneWidget);
  });

  testWidgets('常听栏: 预览 20 条(不是 5 条)', (tester) async {
    setTallView(tester);
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1822714196),
          loggedIn: true,
          loadProfile: (_) async => detail(),
          loadPlaylists: (_) async => const [],
          loadEvents: (_) async => const [],
          loadRanking: (_) async => [
            for (var i = 1; i <= 25; i++) entry(i, '常听$i', 100 - i),
          ],
          initialTab: '常听',
        ),
      ),
    );
    await pumpFrames(tester);

    // 第 6 条必须还在(预览口径从 5 改成 20), 第 21 条被截掉
    expect(find.text('常听6'), findsOneWidget);
    expect(find.text('常听20'), findsOneWidget);
    expect(find.text('常听21'), findsNothing);
  });

  testWidgets('常听栏: 未登录给「登录后可见」, 且根本不发请求', (tester) async {
    setTallView(tester);
    var calls = 0;
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1822714196),
          loggedIn: false,
          loadProfile: (_) async => detail(),
          loadPlaylists: (_) async => const [],
          loadEvents: (_) async => const [],
          loadRanking: (_) async {
            calls++;
            return const [];
          },
          initialTab: '常听',
        ),
      ),
    );
    await pumpFrames(tester);

    expect(find.text('登录后可见'), findsOneWidget);
    expect(find.textContaining('听歌排行需要登录'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('常听栏: 查看全部进整页排行', (tester) async {
    setTallView(tester);
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1822714196),
          loggedIn: true,
          loadProfile: (_) async => detail(),
          loadPlaylists: (_) async => const [],
          loadEvents: (_) async => const [],
          loadRanking: (_) async => [entry(1, '常听的歌', 120)],
          initialTab: '常听',
        ),
      ),
    );
    await pumpFrames(tester);

    await tester.tap(find.text('查看全部'));
    await pumpFrames(tester);

    // 整页排行: 标题是「听歌排行」, 且行不再只有 compact 的 5 条预览(走 PagedListView)。
    // 下面那条路由仍在树上, 所以歌曲名可能同时存在两份 → findsWidgets。
    expect(find.text('听歌排行'), findsOneWidget);
    expect(find.text('常听的歌'), findsWidgets);
  });
}
