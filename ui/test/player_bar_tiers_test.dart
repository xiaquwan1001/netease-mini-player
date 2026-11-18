// 常驻播放条的文案分档(2026-11-18 用户反馈「竖屏只留封面 icon, 横屏显示歌名+艺人
// (+空间够时专辑名)」).
//
// 档位口径直接复用 layout.dart 的三档(窄 < kCompactMaxWidth 600 <= 中 < kWideMinWidth 900 <= 宽),
// 不自造阈值:
//   · 窄(360/300): 只渲染封面(无封面时 CoverArt 自带中性占位图标), 没有任何文字;
//   · 中(700): 歌名 + 艺人(单行 ellipsis), 不显示专辑名, 时间/队列序号仍在第二行;
//   · 宽(1200): 歌名 + 艺人 + 专辑名(判据见 playerBarShowsAlbum / kPlayerBarAlbumMinWidth).
// 另外锁两件事: 交互入口不回退(点封面=播放详情, 点信息区=歌词), 大字号不溢出.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/cover_art.dart';
import 'package:minincm/src/layout.dart';
import 'package:minincm/src/player_bar.dart';
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/rust/api.dart' as rust;

const String _kName = '歌名甲很长的名字用来验证省略';
const String _kArtist = '艺人乙';
const String _kAlbum = '专辑丙';

PlayerBarData _data({String? coverUrl, bool hasSong = true}) => PlayerBarData(
  player: PlayerView(
    playing: true,
    positionMs: BigInt.from(30 * 1000),
    durationMs: BigInt.from(200 * 1000),
    volume: 1.0,
  ),
  current: hasSong
      ? rust.SongDto(
          id: BigInt.one,
          name: _kName,
          artist: _kArtist,
          artistId: BigInt.one,
          album: _kAlbum,
          albumId: BigInt.one,
          coverUrl: coverUrl,
          durationMs: BigInt.from(200 * 1000),
          fee: 0,
          vip: false,
          paid: false,
          playable: true,
        )
      : null,
  liked: false,
  queueIndex: 3,
  queueLength: 12,
  dragMax: null,
  dragMs: null,
);

PlayerBarActions _actions({
  VoidCallback? onOpenDetail,
  VoidCallback? onToggleLyrics,
}) => PlayerBarActions(
  onSeekStart: (_) {},
  onSeekChanging: (_) {},
  onSeekEnd: (_) {},
  onToggleLyrics: onToggleLyrics ?? () {},
  onOpenDetail: onOpenDetail ?? () {},
  onToggleLike: () {},
  onCycleMode: () {},
  onOpenQueue: () {},
  onToggle: () {},
  onPrevious: () {},
  onNext: () {},
);

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  double textScale = 1.0,
  PlayerBarData? data,
  PlayerBarActions? actions,
}) async {
  tester.view.physicalSize = Size(width, 240);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 240),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MiniPlayerBar(
              data: data ?? _data(),
              actions: actions ?? _actions(),
              absorbBottomInset: false,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 播放条里的全部可见文字(富文本按 toPlainText 拍平), 拼成一段便于 contains 断言。
String _barText(WidgetTester tester) {
  final buf = StringBuffer();
  for (final t in tester.widgetList<Text>(
    find.descendant(
      of: find.byType(MiniPlayerBar),
      matching: find.byType(Text),
    ),
  )) {
    buf.write(t.data ?? t.textSpan?.toPlainText() ?? '');
    buf.write('\n');
  }
  return buf.toString();
}

Finder _barTexts() => find.descendant(
  of: find.byType(MiniPlayerBar),
  matching: find.byType(Text),
);

void main() {
  testWidgets('窄档(360): 只有封面 icon, 没有任何文字', (tester) async {
    await _pump(tester, width: 360);

    expect(find.byType(CoverArt), findsOneWidget);
    // 无封面(coverUrl=null)时给的是中性占位图标, 不是空白
    expect(
      find.descendant(
        of: find.byType(CoverArt),
        matching: find.byIcon(Icons.music_note),
      ),
      findsOneWidget,
      reason: '无封面时要有中性占位图标',
    );
    expect(_barTexts(), findsNothing, reason: '窄档不该有歌名/艺人文字');
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄档: 点封面仍然进播放详情, 进度条与控件齐全', (tester) async {
    var detail = 0;
    await _pump(
      tester,
      width: 360,
      actions: _actions(onOpenDetail: () => detail++),
    );

    await tester.tap(find.byType(CoverArt));
    await tester.pump();
    expect(detail, 1, reason: '点封面进详情是既有交互, 分档不能弄丢');
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byTooltip('喜欢'), findsOneWidget);
    expect(find.byTooltip('播放队列'), findsOneWidget);
    expect(find.byTooltip('上一首'), findsOneWidget);
    expect(find.byTooltip('下一首'), findsOneWidget);
  });

  testWidgets('中档(700): 歌名 + 艺人, 不带专辑名', (tester) async {
    await _pump(tester, width: 700);

    final text = _barText(tester);
    expect(text, contains(_kName), reason: '中档要显示完整歌名');
    expect(text, contains(_kArtist), reason: '中档要显示艺人');
    expect(text, isNot(contains(_kAlbum)), reason: '专辑名只属于宽档');
    // 既有信息不丢: 位置/时长与队列序号
    expect(text, contains('3/12'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('中档: 点信息区仍然是打开歌词(既有交互)', (tester) async {
    var lyrics = 0;
    await _pump(
      tester,
      width: 700,
      actions: _actions(onToggleLyrics: () => lyrics++),
    );

    await tester.tap(find.textContaining(_kName));
    await tester.pump();
    expect(lyrics, 1);
  });

  testWidgets('宽档(1200): 歌名 + 艺人 + 专辑名', (tester) async {
    await _pump(tester, width: 1200);

    final text = _barText(tester);
    expect(text, contains(_kName));
    expect(text, contains(_kArtist));
    expect(text, contains(_kAlbum), reason: '宽档空间够时要带专辑名');
    expect(text, contains('3/12'));
    expect(tester.takeException(), isNull);
  });

  for (final width in const [700.0, 1200.0]) {
    testWidgets('大字号(textScale 1.25) $width 宽: 不溢出且文案仍在', (tester) async {
      await _pump(tester, width: width, textScale: 1.25);

      expect(tester.takeException(), isNull, reason: '$width 宽 × 1.25 字号下不许溢出');
      final text = _barText(tester);
      expect(text, contains(_kName));
      expect(text, contains(_kArtist));
    });
  }

  testWidgets('中/宽档无曲目: 第一行给「未在播放」而不是空白', (tester) async {
    await _pump(tester, width: 700, data: _data(hasSong: false));

    expect(_barText(tester), contains('未在播放'));
    expect(tester.takeException(), isNull);
  });

  group('专辑名的「空间还有」判据(playerBarShowsAlbum)', () {
    test('只有宽档才可能加专辑名', () {
      expect(
        playerBarShowsAlbum(tier: LayoutTier.compact, infoWidth: 800),
        isFalse,
      );
      expect(
        playerBarShowsAlbum(tier: LayoutTier.medium, infoWidth: 800),
        isFalse,
      );
      expect(
        playerBarShowsAlbum(tier: LayoutTier.wide, infoWidth: 800),
        isTrue,
      );
    });

    test('宽档但信息块被挤到阈值以下: 不加', () {
      expect(
        playerBarShowsAlbum(
          tier: LayoutTier.wide,
          infoWidth: kPlayerBarAlbumMinWidth - 1,
        ),
        isFalse,
      );
      expect(
        playerBarShowsAlbum(
          tier: LayoutTier.wide,
          infoWidth: kPlayerBarAlbumMinWidth,
        ),
        isTrue,
        reason: '阈值取「含等于」, 与 kCompactMaxWidth/kWideMinWidth 同口径',
      );
    });
  });
}
