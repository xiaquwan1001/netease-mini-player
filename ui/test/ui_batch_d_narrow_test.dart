import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/digital_album_page.dart';
import 'package:minincm/src/discover.dart';
import 'package:minincm/src/feed_view.dart';
import 'package:minincm/src/mine_view.dart';
import 'package:minincm/src/new_release_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

/// 批次 D: 给此前未覆盖 300dp + 1.25 字号的页面补"不溢出"回归
/// (审计 P2-7.31: 45 个测试文件仅 15 个覆盖窄屏回归).

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

rust.SongDto song(int id, String name) => rust.SongDto(
  id: BigInt.from(id),
  name: name,
  artist: '一个名字特别特别长的歌手用于小屏回归测试',
  artistId: BigInt.one,
  album: '一张名字特别特别特别长的专辑用于小屏回归测试',
  albumId: BigInt.one,
  coverUrl: null,
  durationMs: BigInt.from(245000),
  fee: 0,
  vip: false,
  paid: false,
  playable: true,
);

void main() {
  testWidgets('每日推荐 sheet: 300dp + 1.25 不溢出', (tester) async {
    narrow(tester);
    await tester.pumpWidget(
      scaled(
        Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showDiscoverPage(
              ctx,
              onPlaySongs: (_, _) {},
              onOpenPlaylist: (_) {},
              loadSongs: () async => [song(1, '小屏日推歌')],
              loadPlaylists: () async => [],
              loadHistoryDates: () async => [],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('每日推荐'), findsOneWidget);
  });

  testWidgets('新歌速递/新碟上架: 300dp + 1.25 不溢出', (tester) async {
    narrow(tester);
    await tester.pumpWidget(
      scaled(
        NewReleasePage(
          onPlaySongs: (_, _) {},
          onOpenAlbum: (_) {},
          onOpenArtist: (_) {},
          loadSongs: (_) async => [song(1, '小屏新歌')],
          loadNewestAlbums: () async => [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('新歌'), findsOneWidget);
  });

  testWidgets('已购数字专辑页: 300dp + 1.25 不溢出', (tester) async {
    narrow(tester);
    await tester.pumpWidget(
      scaled(
        DigitalAlbumPage(
          loadAlbums: () async => rust.DigitalAlbumPurchased(
            total: BigInt.one,
            albums: [
              rust.DigitalAlbumPurchasedEntry(
                albumId: BigInt.one,
                albumName: '一张名字特别特别特别长的已购专辑用于小屏回归测试',
                artistId: BigInt.one,
                artistName: '一个名字特别特别长的歌手用于小屏回归测试',
                coverUrl: '',
                paidTimeMs: BigInt.from(1638063971559),
                boughtCount: BigInt.one,
              ),
            ],
          ),
          loadSongs: () async => rust.SongPurchasedPage(
            count: BigInt.one,
            hasMore: false,
            songs: [
              rust.PurchasedSongEntry(
                songId: BigInt.one,
                name: '一首名字特别特别特别长的已购单曲用于小屏回归测试',
                artistName: '一个名字特别特别长的歌手用于小屏回归测试',
                coverUrl: '',
                paidTimeMs: BigInt.from(1638063971559),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('已购数字专辑(1)'), findsOneWidget);
  });

  testWidgets('我的页(登录态): 300dp + 1.25 不溢出', (tester) async {
    narrow(tester);
    await tester.pumpWidget(
      scaled(
        MineView(
          loggedIn: true,
          onLogin: () {},
          onOpenAccounts: () {},
          loadLiked: () async => [song(1, '喜欢的歌')],
          loadPlaylists: () async => [],
          loadPodcasts: () async => [],
          loadAlbums: () async => [],
          loadRecent: () async => [],
          loadRanking: (_) async => [],
          onPlaySongs: (_, _) {},
          onOpenPlaylist: (_) {},
          onOpenPodcast: (_) {},
          onOpenLiked: () {},
          onOpenRecent: () {},
          onOpenFollows: () async {},
          onOpenFolloweds: () async {},
          onOpenAlbum: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('登录'), findsNothing);
  });

  testWidgets('关注动态页: 300dp + 1.25 不溢出', (tester) async {
    narrow(tester);
    await tester.pumpWidget(
      scaled(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async => [
            rust.FeedEventDto(
              id: BigInt.one,
              threadId: 'A_EV_2_1_1',
              userId: BigInt.one,
              kind: 'text',
              userName: '一个名字特别特别长的艺人用户名用于小屏回归测试',
              text: '一条很长很长很长很长很长很长很长很长很长很长的动态正文用于小屏回归测试',
              images: const [],
              title: '',
              timeMs: BigInt.from(1700000000000),
              liked: false,
              likedCount: BigInt.one,
              shareCount: BigInt.zero,
              commentCount: BigInt.zero,
            ),
          ],
          loadSubscribedArtists: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
