import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/home/song_action_wiring.dart' show MvIdCache;
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/song_actions.dart';

import 'support/fakes.dart' as fakes;

/// 歌曲操作面板的「官方 MV」入口:
/// - 只在真的查到 MV 时出现(打开面板就预取, 不等用户点);
/// - 点击打开 MV 播放页(测试里由 host.openMv 假实现代表 showMvPage);
/// - 没有 MV / 查询失败 ⇒ 这一项不出现, 面板其余项照常;
/// - 预取结果有缓存: 同曲第二次打开不再打接口, 失败不缓存。
void main() {
  final song = fakes.fakeSong(id: 42, name: '测试歌曲', artist: '测试艺人');

  SongActionHost hostWith({
    required Future<BigInt?> Function(rust.SongDto) mvId,
    Future<void> Function(rust.SongDto, BigInt)? openMv,
    bool loggedIn = true,
  }) => SongActionHost(
    loggedIn: loggedIn,
    isLiked: (_) => false,
    toggleLike: (_) async {},
    playNext: (_) async {},
    addToPlaylist: (_) async {},
    share: (_) async {},
    comments: (_) async {},
    openArtist: (_) async {},
    openAlbum: (_) async {},
    download: (_) async {},
    mvId: mvId,
    openMv: openMv ?? (_, _) async {},
  );

  Widget app(SongActionHost host) => MaterialApp(
    home: Scaffold(
      body: AppActions(
        host: host,
        child: SongOverflowButton(song: song),
      ),
    ),
  );

  Future<void> openSheet(WidgetTester tester, SongActionHost host) async {
    await tester.pumpWidget(app(host));
    await tester.tap(find.byType(SongOverflowButton));
    await tester.pumpAndSettle();
  }

  testWidgets('有 MV: 面板出现「官方 MV」, 点击打开该 MV 并关闭面板', (tester) async {
    var fetchCalls = 0;
    BigInt? openedMvId;
    rust.SongDto? openedSong;
    await openSheet(
      tester,
      hostWith(
        mvId: (_) async {
          fetchCalls++;
          return BigInt.from(5432);
        },
        openMv: (s, id) async {
          openedSong = s;
          openedMvId = id;
        },
      ),
    );

    // 打开即预取, 不需要先点任何东西
    expect(fetchCalls, 1);
    expect(find.text('官方 MV'), findsOneWidget);
    expect(find.text('这首歌的官方 MV'), findsOneWidget);

    await tester.ensureVisible(find.text('官方 MV'));
    await tester.tap(find.text('官方 MV'));
    await tester.pumpAndSettle();

    expect(openedMvId, BigInt.from(5432));
    expect(openedSong?.id, song.id);
    expect(find.byType(BottomSheet), findsNothing, reason: '与其它菜单项一样先关面板');
  });

  testWidgets('没有 MV(mvId 返回 null): 该项不出现, 不留灰条', (tester) async {
    await openSheet(tester, hostWith(mvId: (_) async => null));

    expect(find.text('官方 MV'), findsNothing);
    // 面板其余项一个不少
    expect(find.text('查看评论'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
  });

  testWidgets('查询失败: 该项不出现, 面板不报错', (tester) async {
    await openSheet(
      tester,
      hostWith(mvId: (_) async => throw Exception('boom')),
    );

    expect(find.text('官方 MV'), findsNothing);
    expect(find.text('喜欢'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未登录也有「官方 MV」(MV 与播放权限无关)', (tester) async {
    await openSheet(
      tester,
      hostWith(mvId: (_) async => BigInt.from(7), loggedIn: false),
    );
    expect(find.text('官方 MV'), findsOneWidget);
  });

  testWidgets('没挂 mvId 加载器时不出该项(老调用方行为不变)', (tester) async {
    final host = SongActionHost(
      loggedIn: true,
      isLiked: (_) => false,
      toggleLike: (_) async {},
      playNext: (_) async {},
      addToPlaylist: (_) async {},
      share: (_) async {},
      comments: (_) async {},
      openArtist: (_) async {},
      openAlbum: (_) async {},
      download: (_) async {},
    );
    await openSheet(tester, host);
    expect(find.text('官方 MV'), findsNothing);
    expect(find.text('下一首播放'), findsOneWidget);
  });

  group('MvIdCache', () {
    test('同曲第二次不再打接口(只发一个请求)', () async {
      var calls = 0;
      final cache = MvIdCache(
        request: (id) async {
          calls++;
          return BigInt.from(99);
        },
      );
      final first = await cache.of(BigInt.from(1));
      final second = await cache.of(BigInt.from(1));
      expect(first, BigInt.from(99));
      expect(second, BigInt.from(99));
      expect(calls, 1);
      expect(cache.length, 1);
    });

    test('并发打开只发一个请求(Future 级合并)', () async {
      var calls = 0;
      final cache = MvIdCache(
        request: (id) async {
          calls++;
          await Future<void>.delayed(Duration.zero);
          return BigInt.from(5);
        },
      );
      final both = await Future.wait([
        cache.of(BigInt.from(2)),
        cache.of(BigInt.from(2)),
      ]);
      expect(both, [BigInt.from(5), BigInt.from(5)]);
      expect(calls, 1);
    });

    test('失败不缓存: 下一次查询会重新请求', () async {
      var calls = 0;
      final cache = MvIdCache(
        request: (id) async {
          calls++;
          if (calls == 1) throw Exception('网络抖动');
          return BigInt.from(11);
        },
      );
      await expectLater(cache.of(BigInt.from(3)), throwsException);
      expect(cache.length, 0, reason: '失败条目必须从缓存里删掉');
      expect(await cache.of(BigInt.from(3)), BigInt.from(11));
      expect(calls, 2);
    });

    test('超过上限淘汰最久未用的条目', () async {
      final cache = MvIdCache(request: (_) async => null, maxEntries: 2);
      await cache.of(BigInt.from(1));
      await cache.of(BigInt.from(2));
      await cache.of(BigInt.from(3));
      expect(cache.length, 2);
    });
  });
}
