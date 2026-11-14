import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/feed_media.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.FeedEventDto event({
  String kind = 'text',
  String? coverUrl,
  rust.SongDto? song,
  List<String> images = const [],
}) => rust.FeedEventDto(
  id: BigInt.from(1),
  threadId: 'A_EV_1',
  userId: BigInt.from(2),
  kind: kind,
  userName: '小红',
  avatarUrl: null,
  text: '',
  song: song,
  coverUrl: coverUrl,
  images: images,
  videoUrl: null,
  title: '',
  timeMs: BigInt.from(1700000000000),
  liked: false,
  likedCount: BigInt.zero,
  shareCount: BigInt.zero,
  commentCount: BigInt.zero,
);

rust.SongDto song({String? coverUrl}) => rust.SongDto(
  id: BigInt.from(9),
  name: '晴天',
  artist: '周杰伦',
  artistId: BigInt.from(6452),
  album: '叶惠美',
  albumId: BigInt.from(1),
  coverUrl: coverUrl,
  durationMs: BigInt.from(200000),
  fee: 0,
  vip: false,
  paid: false,
  playable: true,
);

Future<void> pumpGrid(WidgetTester tester, List<String> images) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 300, child: FeedImageGrid(images: images)),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  // 需求 12: 只分享歌曲的动态不再重复附带专辑/歌曲封面
  test('feedAttachedImages 剔除内容自身的封面', () {
    const cover = 'https://p1.music.126.net/a.jpg';
    expect(
      feedAttachedImages(
        event(
          kind: 'song',
          coverUrl: cover,
          song: song(coverUrl: cover),
        ),
      ),
      isEmpty,
    );
    // 只有 images 里带着内容封面(没有 coverUrl 字段)时也算"内容封面"
    expect(
      feedAttachedImages(
        event(
          kind: 'song',
          coverUrl: cover,
          song: song(coverUrl: cover),
          images: const [cover],
        ),
      ),
      isEmpty,
    );
    final mixed = feedAttachedImages(
      event(
        kind: 'song',
        coverUrl: cover,
        images: const [cover, 'https://p2.music.126.net/b.jpg'],
      ),
    );
    expect(mixed, ['https://p2.music.126.net/b.jpg']);
    // http → https 统一
    expect(
      feedAttachedImages(
        event(images: const ['http://p3.music.126.net/c.jpg']),
      ),
      ['https://p3.music.126.net/c.jpg'],
    );
  });

  // 需求 13: 预览图大小随附图数量排版(1 张大图 / 2 两列 / 3+ 三列)
  testWidgets('单图铺满可用宽度(不是 64dp 缩略图)', (tester) async {
    await pumpGrid(tester, ['https://p/x1.jpg']);
    final size = tester.getSize(find.byType(GestureDetector).first);
    expect(size.width, 300);
    // 4:3 裁切
    expect(size.height, closeTo(225, 1));
  });

  testWidgets('两张图按两列排', (tester) async {
    await pumpGrid(tester, ['https://p/x1.jpg', 'https://p/x2.jpg']);
    final rects = tester
        .widgetList<GestureDetector>(find.byType(GestureDetector))
        .map((_) => 0)
        .length;
    expect(rects, 2);
    final first = tester.getRect(find.byType(GestureDetector).at(0));
    final second = tester.getRect(find.byType(GestureDetector).at(1));
    expect(first.top, second.top);
    expect(second.left, greaterThan(first.left));
    // 每张约半宽
    expect(first.width, closeTo((300 - 6) / 2, 1));
  });

  testWidgets('三张及以上按三列排(每行 3 张)', (tester) async {
    await pumpGrid(tester, [
      'https://p/x1.jpg',
      'https://p/x2.jpg',
      'https://p/x3.jpg',
      'https://p/x4.jpg',
    ]);
    final a = tester.getRect(find.byType(GestureDetector).at(0));
    final b = tester.getRect(find.byType(GestureDetector).at(1));
    final c = tester.getRect(find.byType(GestureDetector).at(2));
    final d = tester.getRect(find.byType(GestureDetector).at(3));
    expect(a.top, b.top);
    expect(b.top, c.top);
    expect(d.top, greaterThan(a.top));
    expect(a.width, closeTo((300 - 12) / 3, 1));
  });
}
