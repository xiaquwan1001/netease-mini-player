import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/song_actions.dart';
import 'package:minincm/src/song_tile.dart';

rust.SongDto song({int id = 1, String name = '晴天', int durationMs = 245000}) =>
    rust.SongDto(
      id: BigInt.from(id),
      name: name,
      artist: '周杰伦',
      artistId: BigInt.one,
      album: '叶惠美',
      albumId: BigInt.one,
      coverUrl: null,
      durationMs: BigInt.from(durationMs),
      fee: 0,
      vip: false,
      paid: false,
      playable: true,
    );

/// 只关心红心回调的假宿主(其余动作在本次改动里不走)
SongActionHost fakeHost({required List<rust.SongDto> liked}) => SongActionHost(
  loggedIn: true,
  isLiked: (id) => liked.any((s) => s.id == id),
  toggleLike: (s) async {
    if (!liked.remove(s)) liked.add(s);
  },
  playNext: (_) async {},
  addToPlaylist: (_) async {},
  share: (_) async {},
  comments: (_) async {},
  openArtist: (_) async {},
  openAlbum: (_) async {},
  download: (_) async {},
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('formatSongDuration: 歌曲行时长统一 mm:ss', () {
    test('245s 这种原始秒数改成 mm:ss', () {
      expect(formatSongDuration(BigInt.from(245000)), '04:05');
      expect(formatSongDuration(BigInt.from(269000)), '04:29');
    });

    test('分钟补零、秒补零, 0 与不足 1 秒都落到 00:00/00:0x', () {
      expect(formatSongDuration(BigInt.zero), '00:00');
      expect(formatSongDuration(BigInt.from(59999)), '00:59');
      expect(formatSongDuration(BigInt.from(60000)), '01:00');
      expect(formatSongDuration(BigInt.from(3599000)), '59:59');
    });

    test('满一小时才带小时位, 用 h:mm:ss', () {
      expect(formatSongDuration(BigInt.from(3600000)), '1:00:00');
      expect(formatSongDuration(BigInt.from(3661000)), '1:01:01');
      expect(formatSongDuration(BigInt.from(36000000)), '10:00:00');
    });

    test('负数(脏数据)不出现负号', () {
      expect(formatSongDuration(BigInt.from(-5000)), '00:00');
    });
  });

  testWidgets('行尾时长不再是 "245s", 而是 04:05', (tester) async {
    await tester.pumpWidget(
      host(
        SongTile(
          song: song(durationMs: 245000),
          active: false,
          liked: false,
          onTap: () {},
        ),
      ),
    );
    expect(find.text('04:05'), findsOneWidget);
    expect(find.text('245s'), findsNothing);
  });

  testWidgets('红心可点: 点红心切收藏, 不会触发整行播放', (tester) async {
    var taps = 0;
    var likes = 0;
    await tester.pumpWidget(
      host(
        SongTile(
          song: song(),
          active: false,
          liked: false,
          onTap: () => taps++,
          onToggleLike: () => likes++,
        ),
      ),
    );

    // 未收藏时是空心红心, 且带可见语义
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(find.byTooltip('喜欢'), findsOneWidget);

    await tester.tap(find.byTooltip('喜欢'));
    expect(likes, 1);
    expect(taps, 0, reason: '点红心不应该开始播放(旧版 bug)');
  });

  testWidgets('已收藏时红心实心 + tooltip 取消喜欢', (tester) async {
    var likes = 0;
    await tester.pumpWidget(
      host(
        SongTile(
          song: song(),
          active: false,
          liked: true,
          onTap: () {},
          onToggleLike: () => likes++,
        ),
      ),
    );
    final heart = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.favorite),
        matching: find.byType(IconButton),
      ),
    );
    expect(heart.tooltip, '取消喜欢');
    await tester.tap(find.byTooltip('取消喜欢'));
    expect(likes, 1);
  });

  testWidgets('没有显式回调时退到 AppActions 宿主(与歌单详情同款)', (tester) async {
    final liked = <rust.SongDto>[];
    final s = song();
    await tester.pumpWidget(
      MaterialApp(
        home: AppActions(
          host: fakeHost(liked: liked),
          child: Scaffold(
            body: SongTile(song: s, active: false, liked: false, onTap: () {}),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('喜欢'));
    await tester.pump();
    expect(liked.single.id, s.id, reason: '红心应走全局 toggleLike');
  });

  // v0.7.2: 用户要求"行尾按钮向右移动、缩小间隔给歌名腾空间"。
  // 取舍: 高度仍 48dp(纵向滑动/点按不易误触), 宽度收到 40dp —— Material 3 的
  // dense 列表最小值, 两枚按钮合计 80dp(原 96dp), 省下的 16dp 给歌名。
  testWidgets('行尾按钮命中区 ≥40x48dp 且两枚合计 ≤88dp(给歌名腾空间)', (tester) async {
    await tester.pumpWidget(
      host(
        SongTile(
          song: song(),
          active: false,
          liked: true,
          onTap: () {},
          onToggleLike: () {},
          onMenu: () {},
        ),
      ),
    );

    var totalWidth = 0.0;
    for (final tooltip in ['取消喜欢', '更多操作']) {
      final size = tester.getSize(find.byTooltip(tooltip));
      // 40 是硬口径: IconButton 默认 tapTargetSize.padded 会把命中区撑到 48,
      // 必须显式 shrinkWrap 才能真的让出横向空间(已踩过)。
      expect(size.width, closeTo(40, 0.5), reason: tooltip);
      expect(size.height, greaterThanOrEqualTo(48), reason: tooltip);
      totalWidth += size.width;
    }
    expect(totalWidth, lessThanOrEqualTo(82));
  });

  // 300dp(用户的 vivo 逻辑宽)+1.25 字号下, 行尾「时长 + 红心 + ...」占满 146dp,
  // 标题区只剩 ~49dp —— 连 VIP 徽标都放不下。现在的取舍: 窄屏先隐藏时长
  // (时长在歌曲"..."菜单/详情页/播放队列里都还有), 把宽度让给歌名与 VIP/无版权徽标。
  // 红心与"..."仍然必须在。
  testWidgets('300dp + 1.25 字号: 窄屏让位给徽标 —— 红心/"..." 在, 时长收起, 不溢出', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(300, 640),
            textScaler: TextScaler.linear(1.25),
          ),
          child: Scaffold(
            body: SongTile(
              song: song(name: '一首名字特别特别长的歌用来挤占标题空间', durationMs: 3661000),
              active: false,
              liked: true,
              onTap: () {},
              onToggleLike: () {},
              onMenu: () {},
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('1:01:01'), findsNothing, reason: '窄屏时长让位给标题/徽标');
    expect(find.byTooltip('取消喜欢'), findsOneWidget);
    expect(find.byTooltip('更多操作'), findsOneWidget);
  });

  testWidgets('没有可点路径时保持只读红心(不假装可点)', (tester) async {
    await tester.pumpWidget(
      host(SongTile(song: song(), active: false, liked: true, onTap: () {})),
    );
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.byType(IconButton), findsNothing);
  });
}
