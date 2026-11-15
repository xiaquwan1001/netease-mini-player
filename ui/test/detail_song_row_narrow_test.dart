// 歌单详情页曲目行窄宽回归: 300dp + font_scale 1.25/1.625 下,
// 超长曲名 + VIP/付费/无版权徽标不再出现 Flexible(Text) 被压到 0 宽/竖排的问题
// (修复后走共享组件 AdaptiveTextRow: Expanded + 单行).
//
// 直接跑**真实页面组件** `PlaylistSongsSliver`(曲目行就是共享 `SongRow` + 页面参数),
// 不再维护一份"同构排版"的镜像代码, 也不再复制 detail 页的行参数。
// 行尾最坏情况按真机接线: 红心 + `SongOverflowButton`(装 `AppActions` 后是 48dp IconButton)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/detail/playlist_songs_sliver.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/song_actions.dart' show AppActions, SongActionHost;
import 'package:minincm/src/song_tile.dart';

import 'support/fakes.dart';

const _longName = '魔法未来2019主题歌Magia[Quartet]Live.Ver超长歌名继续加长再加长一点直到溢出为止啊';
const _longArtist = '一条超级超级长的艺人名组合名称';
const _longAlbum = '一张同样很长的专辑名称Magia Album Deluxe Edition 豪华版';

/// 共享工厂 + 本文件的长歌名/长专辑口径(徽标三态由调用方给)。
rust.SongDto song({
  required bool vip,
  required bool paid,
  required bool playable,
}) => fakeSong(
  name: _longName,
  artist: _longArtist,
  artistId: 9,
  album: _longAlbum,
  albumId: 8,
  durationMs: 269000,
  fee: vip ? 1 : 0,
  vip: vip,
  paid: paid,
  playable: playable,
);

/// 最小动作宿主: 只为让行尾 "..." 真正渲染出来(最坏情况的宽度)。
SongActionHost _host() => SongActionHost(
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

/// 页面级装配: 与 `playlist_detail_page._buildSongs` 一致(单首曲目的定高 sliver)。
Widget pageOf(rust.SongDto song) => AppActions(
  host: _host(),
  child: CustomScrollView(
    slivers: [
      PlaylistSongsSliver(
        songs: [song],
        error: null,
        display: [song],
        filter: '',
        special: false,
        hiddenCount: 0,
        playingId: null,
        liked: const {},
        listKey: GlobalKey(),
        onRetry: () {},
        onToggleLike: (_) {},
        onTapSong: (_, _) {},
      ),
    ],
  ),
);

Future<void> pumpCase(
  WidgetTester tester, {
  required double width,
  required double scale,
  required rust.SongDto song,
}) async {
  tester.view.physicalSize = Size(width, 700);
  tester.view.devicePixelRatio = 1;
  tester.view.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 700),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(body: pageOf(song)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
}

void main() {
  final cases = <(String, rust.SongDto)>[
    ('VIP', song(vip: true, paid: false, playable: true)),
    ('付费', song(vip: false, paid: true, playable: true)),
    ('无版权', song(vip: false, paid: false, playable: false)),
  ];

  // A6 回归: 300dp 下的两档字号(1.25 与 1.625)都跑, 后者是审计里未覆盖的一档
  for (final scale in const [1.25, 1.625]) {
    for (final (label, s) in cases) {
      testWidgets('300dp×$scale $label 超长曲名: 无 overflow、单行、行尾封顶', (
        tester,
      ) async {
        await pumpCase(tester, width: 300, scale: scale, song: s);
        expect(tester.takeException(), isNull, reason: '不允许 overflow/布局异常');
        // 曲目行确实是共享实现(不是各页一份私有 Row)
        expect(find.byType(SongRow), findsOneWidget);

        final title = find.text(_longName).first;
        expect(title, findsOneWidget);
        final box = tester.renderObject<RenderBox>(title);
        expect(box.size.width, greaterThan(0), reason: '曲名被徽标压到 0 宽(竖排根因)');
        // 单行阈随字号放大(1.25 档为 30dp, 与修复前的断言同值):
        // 竖排(每字一行)会远超这个高度
        expect(
          box.size.height,
          lessThan(24 * scale),
          reason: '曲名必须单行(竖排会远高于行高)',
        );

        // 行尾整组(时长 + 红心 + 更多)必须封顶在可用宽的 45%: 不封顶时
        // 标题区在 300dp 下只剩 ~117dp, 大字号下更少。
        // 行宽 = 300 - 行内留白(左 12 + 右 4, 见 SongRow.padding)
        const rowWidth = 300.0 - 12 - 4;
        // 时长文案走全 App 统一口径 formatSongDuration(mm:ss 补零) 且是弹性项
        final duration = tester.getRect(find.text('04:29'));
        const durationPad = 4.0;
        expect(
          duration.left - durationPad,
          greaterThanOrEqualTo(rowWidth * 0.55 - 0.5),
          reason: '行尾整组超出版面 45% 上限, 标题区被吃窄',
        );
        expect(duration.width, greaterThan(0), reason: '时长被压到 0 宽');

        // 徽标在副标题行: 300dp 窄屏也必须看得见(用户反馈"歌曲没有 VIP 标记")
        expect(
          find.byType(VipBadge),
          label == 'VIP' ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(PaidBadge),
          label == '付费' ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(UnplayableBadge),
          label == '无版权' ? findsOneWidget : findsNothing,
        );
      });
    }
  }

  testWidgets('400dp 宽屏 VIP 曲目: 徽标照常显示(未被误隐藏)', (tester) async {
    await pumpCase(
      tester,
      width: 400,
      scale: 1.25,
      song: song(vip: true, paid: false, playable: true),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(VipBadge), findsOneWidget);
    final box = tester.renderObject<RenderBox>(find.text(_longName).first);
    expect(box.size.width, greaterThan(0));
  });

  testWidgets('400dp 宽屏无版权曲目: 无版权徽标照常显示', (tester) async {
    await pumpCase(
      tester,
      width: 400,
      scale: 1.25,
      song: song(vip: false, paid: false, playable: false),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(UnplayableBadge), findsOneWidget);
  });

  testWidgets('300dp×1.25 无徽标曲目: 曲名单行正常', (tester) async {
    await pumpCase(
      tester,
      width: 300,
      scale: 1.25,
      song: song(vip: false, paid: false, playable: true),
    );
    expect(tester.takeException(), isNull);
    final box = tester.renderObject<RenderBox>(find.text(_longName).first);
    expect(box.size.width, greaterThan(0));
    expect(box.size.height, lessThan(30));
  });
}
