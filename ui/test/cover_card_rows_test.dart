// B3b 回归(2026-11-19 用户反馈): 推荐播客卡片「只给两行文字, 但占了三行高度」。
//
// 根因: CoverCard 标题最多 2 行 + 副标题 1 行(省略号), 而 CoverRow 的高度口径是
// 硬编码的三行文字(203 = 封面 118 + 4 + 3×27)。播客副标题是「作者 · 集数」,
// 300dp/1.25 下 1 行放不下, 被截成「四十只烤翅 · 3…」, 卡片下方空着整行。
// 修法: CoverCard/CoverRow 参数化 titleMaxLines/subtitleMaxLines, 高度跟着实际
// 行数走; 播客区块传 subtitleMaxLines: 2。默认参数(2/1)像素零变化。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/cover_row.dart';
import 'package:minincm/src/recommend_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

const _dj = '四十只烤翅的电台主播名很长很长很长继续加长一点直到折行为止';
const _subtitle = '$_dj · 1234 集';

void narrow125(WidgetTester tester) {
  tester.view.physicalSize = const Size(300, 640);
  tester.view.devicePixelRatio = 1;
  tester.view.platformDispatcher.textScaleFactorTestValue = 1.25;
  addTearDown(tester.view.reset);
}

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

CoverCard card({int titleMaxLines = 2, int subtitleMaxLines = 1}) => CoverCard(
  coverUrl: null,
  title: '一个名字很长的播客标题',
  subtitle: _subtitle,
  titleMaxLines: titleMaxLines,
  subtitleMaxLines: subtitleMaxLines,
  onTap: () {},
);

/// 段落行数: 用实测高度 / 单行高度(同一份 span + 同一个 textScaler)反推。
int lineCountOf(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final scaler = MediaQuery.textScalerOf(tester.element(finder));
  final oneLine = TextPainter(
    text: paragraph.text,
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  return (paragraph.size.height / oneLine.height).round();
}

void main() {
  testWidgets('默认参数(CoverCard 2/1 + CoverRow 默认)高度与旧公式逐像素一致', (tester) async {
    // textScale 1.0: 203 = 封面 118 + 4 + 3×27
    await tester.pumpWidget(host(CoverRow(children: [card(), card()])));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(CoverRow)).height, kCoverCardHeight);
    final c = tester.widget<CoverCard>(find.byType(CoverCard).first);
    expect(c.titleMaxLines, 2);
    expect(c.subtitleMaxLines, 1);
    // 默认副标题仍是单行省略号
    expect(lineCountOf(tester, find.text(_subtitle).first), 1);

    // textScale 1.25: 旧公式 203 + (27×1.25×3 − 81) = 223.25, 默认调用点必须不变
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(host(CoverRow(children: [card(), card()])));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(CoverRow)).height,
      closeTo(223.25, 0.01),
      reason: '默认参数下高度口径不能变(否则「我的」页/搜索页/榜单一起漂)',
    );
  });

  testWidgets('300dp + 1.25: 两行副标题完整显示, 无 overflow, 高度按行数走', (tester) async {
    narrow125(tester);
    await tester.pumpWidget(
      host(
        CoverRow(
          subtitleMaxLines: 2,
          children: [card(subtitleMaxLines: 2), card(subtitleMaxLines: 2)],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 没有 RenderFlex overflow / 任何布局异常
    expect(tester.takeException(), isNull);
    // 副标题真的换了行(2 行), 不再被截成一行省略号
    expect(lineCountOf(tester, find.text(_subtitle).first), 2);
    // 高度口径跟着行数走: 203 + (27×1.25×4 − 81) = 257(旧口径只有 223.25)
    expect(tester.getSize(find.byType(CoverRow)).height, closeTo(257.0, 0.01));
    // 内容确实落在容器内(没溢出到卡片外面)
    final rowRect = tester.getRect(find.byType(CoverRow));
    final subtitleRect = tester.getRect(find.text(_subtitle).first);
    expect(subtitleRect.bottom, lessThanOrEqualTo(rowRect.bottom + 0.01));
  });

  testWidgets('推荐播客区块: 300dp + 1.25 副标题两行可见且不溢出(接线口径)', (tester) async {
    narrow125(tester);
    await tester.pumpWidget(
      host(
        RecommendView(
          loggedIn: true,
          loadDailySongs: () async => const <rust.SongDto>[],
          loadDailyPlaylists: () async => const <rust.Playlist>[],
          loadPodcasts: () async => [
            rust.PodcastRadio(
              id: BigInt.from(20),
              name: '一个名字很长的播客标题',
              coverUrl: null,
              description: '',
              djName: _dj,
              programCount: BigInt.from(1234),
              playCount: BigInt.zero,
            ),
          ],
          loadFm: () async => const <rust.SongDto>[],
          loadStyles: () async => const <rust.StyleTag>[],
          loadNewSongs: () async => const <rust.SongDto>[],
          loadNewAlbums: () async => const <rust.AlbumItem>[],
          onOpenPlaylist: (_) {},
          onOpenPodcast: (_) {},
          onHeartMode: () {},
          onOpenDaily: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 播客卡就是唯一那张传了 subtitleMaxLines: 2 的卡
    final podcastCard = tester.widget<CoverCard>(find.byType(CoverCard).first);
    expect(podcastCard.subtitleMaxLines, 2);
    final finder = find.textContaining('· 1234 集');
    expect(finder, findsOneWidget);
    expect(lineCountOf(tester, finder), 2, reason: '「作者 · 集数」必须两行完整显示');
  });
}
