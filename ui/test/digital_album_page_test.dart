import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/digital_album_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.DigitalAlbumPurchased _albums({int n = 2}) => rust.DigitalAlbumPurchased(
  total: BigInt.from(n),
  albums: List.generate(
    n,
    (i) => rust.DigitalAlbumPurchasedEntry(
      albumId: BigInt.from(120605500 + i),
      albumName: '专辑$i',
      artistId: BigInt.one,
      artistName: '歌手$i',
      coverUrl: '',
      paidTimeMs: BigInt.from(1638063971559),
      boughtCount: BigInt.one,
    ),
  ),
);

rust.SongPurchasedPage _songs({int n = 1}) => rust.SongPurchasedPage(
  count: BigInt.from(n),
  hasMore: false,
  songs: List.generate(
    n,
    (i) => rust.PurchasedSongEntry(
      songId: BigInt.from(186016 + i),
      name: '歌曲$i',
      artistName: '歌手$i',
      coverUrl: '',
      paidTimeMs: BigInt.from(1638063971559),
    ),
  ),
);

Future<void> _pump(
  WidgetTester tester, {
  Future<rust.DigitalAlbumPurchased?> Function()? albums,
  Future<rust.SongPurchasedPage?> Function()? songs,
  Future<rust.DigitalAlbumDetail?> Function(BigInt)? detail,
  Future<List<rust.DigitalAlbumSalesEntry>?> Function(String)? sales,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: DigitalAlbumPage(
        loadAlbums: albums,
        loadSongs: songs,
        loadDetail: detail,
        loadSales: sales,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('空态: 无已购专辑/单曲时给空态文案', (tester) async {
    await _pump(
      tester,
      albums: () async =>
          rust.DigitalAlbumPurchased(total: BigInt.zero, albums: const []),
      songs: () async => rust.SongPurchasedPage(
        count: BigInt.zero,
        hasMore: false,
        songs: const [],
      ),
    );
    expect(find.textContaining('还没有已购'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('列表渲染: 已购专辑 + 单曲, 行含标题/歌手/日期', (tester) async {
    await _pump(
      tester,
      albums: () async => _albums(n: 2),
      songs: () async => _songs(n: 1),
    );
    expect(find.text('已购数字专辑(2)'), findsOneWidget);
    expect(find.text('专辑0'), findsOneWidget);
    expect(find.text('专辑1'), findsOneWidget);
    expect(find.text('歌曲0'), findsOneWidget);
    expect(find.textContaining('歌手0'), findsWidgets);
    expect(find.textContaining('2021-11-28'), findsWidgets);
  });

  testWidgets('错误态: 加载失败给文案 + 重试按钮', (tester) async {
    await _pump(
      tester,
      albums: () async => throw Exception('[network] boom'),
      songs: () async => _songs(),
    );
    // 迁移 PagedListView 后错误文案直接用 friendlyError(不再带 "加载失败:" 前缀)
    expect(find.textContaining('网络不稳定'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('详情 BottomSheet: 点专辑行展开详情与销量', (tester) async {
    await _pump(
      tester,
      albums: () async => _albums(n: 1),
      songs: () async => _songs(n: 0),
      detail: (id) async => rust.DigitalAlbumDetail(
        albumId: id,
        name: '专辑0',
        artistId: BigInt.one,
        artistName: '歌手0',
        coverUrl: '',
        hasAlbum: true,
        price: 22.0,
        pubTimeMs: BigInt.zero,
        saleNum: BigInt.zero,
        tags: const ['独家'],
        description: '简介内容',
      ),
      sales: (ids) async => [
        rust.DigitalAlbumSalesEntry(albumId: ids, sales: BigInt.from(1300052)),
      ],
    );
    await tester.tap(find.text('专辑0'));
    await tester.pumpAndSettle();
    expect(find.textContaining('销量'), findsOneWidget);
    expect(find.textContaining('价格'), findsOneWidget);
  });

  testWidgets('窄屏 300dp + 1.25 字号不溢出', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(300, 700);
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      albums: () async => _albums(n: 3),
      songs: () async => _songs(n: 2),
    );
    expect(tester.takeException(), isNull);
  });
}
