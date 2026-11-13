import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/album_preview.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song(int id, String name) => rust.SongDto(
  id: BigInt.from(id),
  name: name,
  artist: '周杰伦',
  artistId: BigInt.one,
  album: '叶惠美',
  albumId: BigInt.from(9),
  coverUrl: null,
  durationMs: BigInt.from(1000),
  fee: 0,
  vip: false,
  paid: false,
  playable: true,
);

rust.AlbumDetailDto album() => rust.AlbumDetailDto(
  id: BigInt.from(9),
  name: '叶惠美',
  coverUrl: null,
  artist: '周杰伦',
  description: '经典专辑',
  songs: [song(1, '以父之名'), song(2, '晴天')],
);

Widget host(VoidCallback onTap) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (ctx) => TextButton(onPressed: onTap, child: const Text('open')),
    ),
  ),
);

void main() {
  testWidgets('专辑预览: 展示封面/信息/曲目, 点曲目回调整张专辑', (tester) async {
    List<rust.SongDto>? played;
    int? playedIndex;
    await tester.pumpWidget(
      host(() {
        showAlbumPreview(
          tester.element(find.text('open')),
          albumId: BigInt.from(9),
          onPlay: (songs, index) {
            played = songs;
            playedIndex = index;
          },
          loadAlbum: (_) async => album(),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('叶惠美'), findsOneWidget);
    expect(find.text('周杰伦'), findsWidgets);
    expect(find.text('共 2 首'), findsOneWidget);
    expect(find.text('以父之名'), findsOneWidget);

    await tester.tap(find.text('晴天'));
    await tester.pumpAndSettle();
    expect(played?.length, 2);
    expect(playedIndex, 1);
  });

  testWidgets('专辑预览: 收藏按钮切换收藏/取消', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      host(() {
        showAlbumPreview(
          tester.element(find.text('open')),
          albumId: BigInt.from(9),
          onPlay: (_, _) {},
          loadAlbum: (_) async => album(),
          setSubscribed: (id, subscribed) async {
            calls.add('$id:$subscribed');
            return true;
          },
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('收藏专辑'), findsOneWidget);
    await tester.tap(find.text('收藏专辑'));
    await tester.pumpAndSettle();
    expect(calls, ['9:true']);
    expect(find.text('已收藏'), findsOneWidget);

    await tester.tap(find.text('已收藏'));
    await tester.pumpAndSettle();
    expect(calls, ['9:true', '9:false']);
    expect(find.text('收藏专辑'), findsOneWidget);
  });

  testWidgets('专辑预览: albumId 为 0 时只显示封面标题(无网络请求)', (tester) async {
    var called = false;
    await tester.pumpWidget(
      host(() {
        showAlbumPreview(
          tester.element(find.text('open')),
          albumId: BigInt.zero,
          albumName: '未知专辑',
          onPlay: (_, _) {},
          loadAlbum: (_) async {
            called = true;
            return album();
          },
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('未知专辑'), findsOneWidget);
    expect(called, false);
  });

  testWidgets('专辑无曲目时显示空态提示', (tester) async {
    final empty = rust.AlbumDetailDto(
      id: BigInt.from(9),
      name: '空专辑',
      coverUrl: null,
      artist: '某人',
      description: '',
      songs: const [],
    );
    await tester.pumpWidget(
      host(() {
        showAlbumPreview(
          tester.element(find.text('open')),
          albumId: BigInt.from(9),
          onPlay: (_, _) {},
          loadAlbum: (_) async => empty,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂无曲目'), findsOneWidget);
  });

  testWidgets('加载失败显示 friendlyError + 重试后成功', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      host(() {
        showAlbumPreview(
          tester.element(find.text('open')),
          albumId: BigInt.from(9),
          onPlay: (_, _) {},
          loadAlbum: (_) async {
            attempts++;
            if (attempts <= 3) throw Exception('[network] timeout');
            return album();
          },
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('网络不稳定'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('以父之名'), findsOneWidget);
    expect(attempts, 4);
  });

  testWidgets('艺人可点: 单艺人用曲目 artistId 直接进主页', (tester) async {
    BigInt? openedId;
    String? openedName;
    await tester.pumpWidget(
      host(() {
        showAlbumPreview(
          tester.element(find.text('open')),
          albumId: BigInt.from(9),
          onPlay: (_, _) {},
          loadAlbum: (_) async => album(),
          onOpenArtist: (id, name) {
            openedId = id;
            openedName = name;
          },
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('周杰伦').first);
    await tester.pumpAndSettle();
    expect(openedId, BigInt.one);
    expect(openedName, '周杰伦');
  });

  testWidgets('多艺人: 弹窗选择后进对应艺人主页', (tester) async {
    BigInt? openedId;
    String? openedName;
    final multi = rust.AlbumDetailDto(
      id: BigInt.from(9),
      name: '合唱专辑',
      coverUrl: null,
      artist: '周杰伦 / 方文山',
      description: '',
      songs: [song(1, '以父之名')],
    );
    await tester.pumpWidget(
      host(() {
        showAlbumPreview(
          tester.element(find.text('open')),
          albumId: BigInt.from(9),
          onPlay: (_, _) {},
          loadAlbum: (_) async => multi,
          resolveArtistId: (name) async =>
              name == '方文山' ? BigInt.from(7) : BigInt.one,
          onOpenArtist: (id, name) {
            openedId = id;
            openedName = name;
          },
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('周杰伦 / 方文山').first);
    await tester.pumpAndSettle();
    expect(find.text('选择艺人'), findsOneWidget);

    await tester.tap(find.text('方文山').first);
    await tester.pumpAndSettle();
    expect(openedId, BigInt.from(7));
    expect(openedName, '方文山');
  });

  testWidgets('300dp + 1.25 字号不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => showAlbumPreview(
                  ctx,
                  albumId: BigInt.from(9),
                  albumName: '一个特别特别长的专辑名称用来测试小屏溢出情况',
                  onPlay: (_, _) {},
                  loadAlbum: (_) async => album(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('以父之名'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
