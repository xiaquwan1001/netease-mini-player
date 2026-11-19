import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/recommend_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

import 'support/fakes.dart';
import 'support/playback_spy.dart';

// 共享工厂 + 本文件口径(3 首推荐歌单 / 主播 2 期电台), 位置参数签名保持不变。
rust.Playlist playlist(int id, String name) => fakePlaylist(id: id, name: name);

rust.PodcastRadio radio(int id, String name) => fakeRadio(id: id, name: name);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void narrow(WidgetTester tester) {
  tester.view.physicalSize = const Size(300, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget scaled(Widget child) => MaterialApp(
  home: MediaQuery(
    data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
    child: Scaffold(body: child),
  ),
);

/// 长文本走跑马灯(无限循环动画)时 pumpAndSettle 永不收敛, 固定推进若干帧
/// 让 FutureBuilder/布局稳定即可(与 queue_sheet_test 同款处理).
Future<void> pumpFrames(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  testWidgets('推荐页展示每日推荐/歌单/播客/榜单/新碟, 点歌回调整批曲目', (tester) async {
    // 页面很长(榜单/风格/每日推荐/新歌/歌单/新碟/播客), 用高视口一次构建,
    // 避免在测试里反复滚动造成的不稳定。
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    List<rust.SongDto>? played;
    int? playedIndex;
    installPlaybackSpy((songs, index) {
      played = songs;
      playedIndex = index;
    });
    addTearDown(resetPlaybackSpy);
    rust.Playlist? openedPlaylist;
    rust.PodcastRadio? openedRadio;
    rust.AlbumItem? openedAlbum;
    var heart = 0;
    var moreTaps = 0;

    await tester.pumpWidget(
      host(
        RecommendView(
          loggedIn: true,
          loadDailySongs: () async => [
            fakeSong(id: 1, name: '每日一歌'),
            fakeSong(id: 2, name: '每日二歌'),
          ],
          loadDailyPlaylists: () async => [playlist(10, '推荐歌单A')],
          loadPodcasts: () async => [radio(20, '推荐播客A')],
          loadFm: () async => [fakeSong(id: 3, name: 'FM 曲')],
          loadStyles: () async => const [
            rust.StyleTag(id: '1009', name: '粤语流行'),
            rust.StyleTag(id: '1020', name: '华语流行'),
          ],
          loadNewSongs: () async => [fakeSong(id: 30, name: '新歌速递一')],
          loadNewAlbums: () async => [
            rust.AlbumItem(
              id: BigInt.from(40),
              name: '新碟A',
              coverUrl: null,
              artist: '艺人',
              trackCount: BigInt.from(8),
            ),
          ],
          onOpenAlbum: (album) => openedAlbum = album,
          onOpenNewRelease: () => moreTaps++,

          onOpenPlaylist: (p) => openedPlaylist = p,
          onOpenPodcast: (r) => openedRadio = r,
          onHeartMode: () => heart++,
          onOpenDaily: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 排行榜区块已按用户要求从推荐页移到搜索页(这里不再有区块);
    // B7 之后顶栏第一格是「自定义」快捷卡, 默认绑定动作就是排行榜 ⇒
    // 文案「排行榜」只在快捷卡上出现一次(区块/榜单列表不渲染)。
    expect(find.text('排行榜'), findsOneWidget);
    expect(find.text('飙升榜'), findsNothing);

    // 风格推荐
    expect(find.text('风格推荐'), findsOneWidget);
    expect(find.text('粤语流行'), findsOneWidget);
    expect(find.text('华语流行'), findsOneWidget);

    // 每日推荐(批次 C: 「每日推荐歌曲」与「每日推荐歌单」合并成一格)。
    // B7 之后顶栏第一格不再是「每日推荐」(改成自定义动作卡), 所以只剩区块标题 1 处。
    expect(find.text('每日推荐'), findsOneWidget);
    expect(find.text('每日一歌'), findsOneWidget);
    // 推荐页歌曲卡铺满屏宽(页面横向 padding=0), 歌名文字不再被额外内缩
    expect(tester.getRect(find.text('每日一歌')).left, lessThan(70));
    await tester.tap(find.text('每日二歌'));
    expect(played?.length, 2);
    expect(playedIndex, 1);

    // 新歌速递(带"更多"入口 → 新歌/新碟/艺人分类页)
    expect(find.text('新歌速递'), findsOneWidget);
    expect(find.text('新歌速递一'), findsOneWidget);
    // 排行榜搬走后剩 4 个「全部」:
    // 每日推荐 / 推荐歌单 / 新歌新碟 / 推荐播客
    expect(find.text('更多'), findsNothing);
    expect(find.text('查看全部'), findsNothing);
    expect(find.text('全部'), findsNWidgets(4));
    // at(2) = 新歌新碟 标题右侧那个(顺序: 每日推荐, 推荐歌单, 新歌新碟, 播客)
    await tester.tap(find.text('全部').at(2));
    await tester.pumpAndSettle();
    expect(moreTaps, 1);

    // 推荐歌单
    expect(find.text('推荐歌单'), findsOneWidget);
    await tester.tap(find.text('推荐歌单A'));
    expect(openedPlaylist?.id, BigInt.from(10));

    // 新碟上架
    expect(find.text('新碟上架'), findsOneWidget);
    await tester.tap(find.text('新碟A'));
    expect(openedAlbum?.id, BigInt.from(40));

    // 推荐播客
    expect(find.text('推荐播客'), findsOneWidget);
    await tester.tap(find.text('推荐播客A'));
    expect(openedRadio?.id, BigInt.from(20));

    // 心动模式快捷卡片
    await tester.tap(find.text('心动模式'));
    expect(heart, 1);
  });

  testWidgets('300dp + 1.25 字号不溢出(长名日推/歌单/播客/榜单)', (tester) async {
    narrow(tester);
    await tester.pumpWidget(
      scaled(
        RecommendView(
          loggedIn: true,
          loadDailySongs: () async => [
            fakeSong(id: 1, name: '一首名字特别特别长的日推歌曲用于小屏回归测试'),
          ],
          loadDailyPlaylists: () async => [
            playlist(10, '一个名字特别特别长的推荐歌单用于小屏回归测试'),
          ],
          loadPodcasts: () async => [radio(20, '一个名字特别特别长的推荐播客用于小屏回归测试')],
          loadFm: () async => [fakeSong(id: 3, name: 'FM 曲')],
          loadStyles: () async => const [
            rust.StyleTag(id: '1009', name: '粤语流行'),
          ],
          loadNewSongs: () async => [fakeSong(id: 30, name: '新歌速递一')],
          loadNewAlbums: () async => [
            rust.AlbumItem(
              id: BigInt.from(40),
              name: '新碟A',
              coverUrl: null,
              artist: '艺人',
              trackCount: BigInt.from(8),
            ),
          ],
          onOpenAlbum: (_) {},
          onOpenNewRelease: () {},

          onOpenPlaylist: (_) {},
          onOpenPodcast: (_) {},
          onHeartMode: () {},
          onOpenDaily: () {},
        ),
      ),
    );
    // 长名歌单/播客/日推标题走跑马灯(无限动画) → 固定帧推进
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('每日推荐'), findsWidgets);
    // 排行榜已搬到搜索页, 窄屏下这里只校验页面本身不溢出
    expect(find.text('风格推荐'), findsOneWidget);
  });

  testWidgets('私人 FM 播放按钮加载后回调曲目', (tester) async {
    List<rust.SongDto>? played;
    installPlaybackSpy((songs, _) => played = songs);
    addTearDown(resetPlaybackSpy);
    await tester.pumpWidget(
      host(
        RecommendView(
          loggedIn: true,
          loadDailySongs: () async => const [],
          loadDailyPlaylists: () async => const [],
          loadPodcasts: () async => const [],
          loadFm: () async => [fakeSong(id: 7, name: 'FM 曲')],
          loadStyles: () async => const [],
          loadNewSongs: () async => const [],
          loadNewAlbums: () async => const [],

          onOpenPlaylist: (_) {},
          onOpenPodcast: (_) {},
          onHeartMode: () {},
          onOpenDaily: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('私人FM'));
    await tester.pumpAndSettle();
    expect(played?.single.name, 'FM 曲');
  });

  // 回归 2026-11-18(用户反馈): 未登录时推荐页把后端内部错误 `[auth] Unknown error`
  // 当错误占位直接显示在「推荐歌单」位置。
  //
  // 根因两层:
  //  1) _DailyPlaylistsSection 不判登录态, 未登录也发 /personalized/playlist
  //     (RecommendResource 需要登录) ⇒ 必抛 auth 错误;
  //  2) friendlyError 只处理 network/forbidden, auth 走 describeError 兜底,
  //     于是 `[auth] Unknown error` 原文进了 InlineError。
  // 修法: 区块按**登录态**门控(未登录不发请求, 换中性引导), friendlyError 另加
  // auth 兜底。这里同时验证两点: 页面不出现内部错误文本, 且显示中性文案。
  testWidgets('未登录 + 推荐歌单接口抛 auth 错误: 不暴露 [auth], 改中性引导', (tester) async {
    var playlistCalls = 0;
    await tester.pumpWidget(
      host(
        RecommendView(
          loggedIn: false,
          loadDailySongs: () async => [fakeSong(id: 1, name: '匿名日推歌')],
          // 模拟后端: 未登录时 RecommendResource 返回 auth 错误
          loadDailyPlaylists: () async {
            playlistCalls++;
            throw Exception('[auth] Unknown error');
          },
          loadPodcasts: () async => [radio(20, '推荐播客A')],
          loadFm: () async => const [],
          loadStyles: () async => const [],
          loadNewSongs: () async => const [],
          loadNewAlbums: () async => const [],

          onOpenPlaylist: (_) {},
          onOpenPodcast: (_) {},
          onHeartMode: () {},
          onOpenDaily: () {},
        ),
      ),
    );
    await pumpFrames(tester);

    // 后端内部错误文本一个字都不许出现
    expect(find.textContaining('[auth]'), findsNothing);
    expect(find.textContaining('Unknown error'), findsNothing);
    // 也不该出现「重试」按钮(错误态的标志)
    expect(find.text('重试'), findsNothing);
    // 换成中性引导, 且区块标题仍在(不整块消失, 用户知道这里有什么)
    expect(find.text('推荐歌单'), findsOneWidget);
    expect(find.text('登录后显示每日推荐歌单'), findsOneWidget);
    // 压根没有发过这个需要登录的请求
    expect(playlistCalls, 0, reason: '未登录时不该请求需要登录的推荐歌单接口');
  });

  testWidgets('已登录时 auth 错误也只给中性文案(不泄露 kind 前缀)', (tester) async {
    await tester.pumpWidget(
      host(
        RecommendView(
          loggedIn: true,
          loadDailySongs: () async => const [],
          loadDailyPlaylists: () async =>
              throw Exception('[auth] Unknown error'),
          loadPodcasts: () async => const [],
          loadFm: () async => const [],
          loadStyles: () async => const [],
          loadNewSongs: () async => const [],
          loadNewAlbums: () async => const [],

          onOpenPlaylist: (_) {},
          onOpenPodcast: (_) {},
          onHeartMode: () {},
          onOpenDaily: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('[auth]'), findsNothing);
    expect(find.text('需要登录后才能查看'), findsOneWidget);
  });
}
