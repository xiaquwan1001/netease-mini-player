// 横向留白与层级栅格(需求 10 / lane-ui-layout)的几何回归。
//
// 栅格定义在 lib/src/layout.dart, 这里断言的是**实际渲染坐标**, 不做源码 grep:
//   · 卡片 / 区块外边缘   = kPagePadding(12)
//   · 区块标题(纯文本)   = kPagePadding(12)
//   · 卡片内行内容        = kPagePadding + kCardRowInset(4) = 16
//   · 整页铺满的歌曲行    = kPageRowPadding(左 12 / 右 4, 与页面标题线共线)
//   · SectionHeader 标题与 trailing 必须同一中心线(差 < 1dp)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/cover_art.dart';
import 'package:minincm/src/layout.dart';
import 'package:minincm/src/mine_view.dart';
import 'package:minincm/src/profile_header.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/section_header.dart';
import 'package:minincm/src/song_tile.dart';

import 'support/fakes.dart';

const _widths = [300.0, 320.0, 360.0, 412.0];
const _scales = [1.0, 1.3, 1.625];

/// 「我的」页: 全部 loader 注入假数据, 不碰 FFI/网络。
Widget _mine() => MineView(
  loggedIn: true,
  onLogin: () {},
  onOpenAccounts: () {},
  onOpenMessages: () {},
  onOpenMedals: () {},
  onOpenVip: () {},
  onOpenLiked: () {},
  onOpenRecent: () {},
  onOpenFollows: () async {},
  onOpenFolloweds: () async {},
  onOpenAlbum: (_) {},
  onOpenPlaylist: (_) {},
  onOpenPodcast: (_) {},

  loadLiked: () async => [fakeSong(id: 1, name: '喜欢的歌')],
  loadPlaylists: () async => [
    rust.Playlist(
      id: BigInt.from(2),
      name: '收藏歌单',
      coverUrl: null,
      trackCount: BigInt.from(5),
      special: false,
      subscribed: false,
    ),
  ],
  loadPodcasts: () async => [],
  loadAlbums: () async => [],
  loadRecent: () async => [fakeSong(id: 7, name: '最近听的歌')],
  loadProfile: () async => rust.ProfileDetail(
    userId: BigInt.one,
    nickname: '测试用户',
    signature: '',
    avatarUrl: null,
    backgroundUrl: null,
    follows: BigInt.from(3),
    followeds: BigInt.from(5),
    level: BigInt.from(6),
    vip: false,
  ),
  loadMessageCounts: () async => const rust.MessageCountsDto(
    private: 1,
    notices: 1,
    comments: 0,
    forwards: 0,
    total: 2,
  ),
  loadRanking: (_) async => [
    rust.PlayRankEntryDto(
      song: fakeSong(id: 8, name: '最常听'),
      playCount: BigInt.from(42),
      score: BigInt.from(420),
    ),
  ],
);

Future<List<String>> _pump(
  WidgetTester tester,
  Widget child, {
  required double width,
  double scale = 1.0,
  // 「我的」页首屏放不下全部区块(ListView 惰性构建), 该用例给更高的视口,
  // 让所有区块一次性建出来 —— 断言的是横向几何, 与视口高度无关。
  double height = 900,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  tester.view.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (d) => errors.add(d);
  try {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
  } finally {
    FlutterError.onError = previous;
  }
  return [for (final e in errors) e.exception.toString()];
}

void _expectNoOverflow(List<String> errors, String tag) {
  expect(
    errors.where((e) => e.contains('overflowed')).toList(),
    isEmpty,
    reason: tag,
  );
}

void main() {
  testWidgets('歌曲行左右贴边: 左 kPageRowPadding.left / 右侧不吃通行尾', (tester) async {
    for (final width in _widths) {
      final tag = 'SongTile w=$width';
      final errors = await _pump(
        tester,
        SongTile(
          song: fakeSong(id: 1, name: '晴天'),
          active: false,
          liked: false,
          onTap: () {},
          onMenu: () {},
          onToggleLike: () {},
        ),
        width: width,
      );
      _expectNoOverflow(errors, tag);
      // 封面就是行内容左边缘
      final cover = tester.getRect(find.byType(CoverArt).first);
      expect(
        cover.left,
        moreOrLessEquals(kPageRowPadding.left, epsilon: 0.5),
        reason: '$tag 行左留白',
      );
      // 行尾按钮右边缘不越过 kPageRowPadding.right
      final more = tester.getRect(find.byTooltip('更多操作'));
      expect(
        more.right,
        lessThanOrEqualTo(width - kPageRowPadding.right + 0.5),
        reason: '$tag 行右留白',
      );
    }
  });

  testWidgets('SectionHeader: 标题与 trailing 同一中心线 + 左右贴齐页面留白', (tester) async {
    // 现口径的横向栅格几何(原 kPageHorizontalPadding 常量已删, 这里用关系断言替代):
    // 页面留白只有一个数 kPagePadding, kPageInsets 左右都等于它、合计 2 倍,
    // 整页铺满的行(左 12 / 右 4)与页面标题线共线。
    expect(kPageInsets.left, kPagePadding);
    expect(kPageInsets.right, kPagePadding);
    expect(kPageInsets.horizontal, kPagePadding * 2);
    expect(kPageInsets.vertical, 8 + 24);
    expect(kPageRowPadding.left, kPagePadding);
    expect(kPageRowPadding.right, kCardRowInset);
    expect(kCardRowPadding.horizontal, kCardRowInset * 2);

    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = 'SectionHeader w=$width s=$scale';
        final errors = await _pump(
          tester,
          const Padding(
            // 只左右留白 = 页面栅格线(Math 与已删的 kPageHorizontalPadding 一致)
            padding: EdgeInsets.symmetric(horizontal: kPagePadding),
            child: SectionHeader(
              title: '我喜欢的音乐',
              trailing: SectionSeeAllButton(label: '查看全部', onTap: _noop),
            ),
          ),
          width: width,
          scale: scale,
        );
        _expectNoOverflow(errors, tag);
        final titleRect = tester.getRect(find.text('我喜欢的音乐'));
        expect(
          titleRect.left,
          moreOrLessEquals(kPagePadding, epsilon: 0.5),
          reason: '$tag 标题左贴 12',
        );
        final actionRect = tester.getRect(find.byType(SectionSeeAllButton));
        expect(
          actionRect.right,
          lessThanOrEqualTo(width - kPagePadding + 0.5),
          reason: '$tag trailing 不出页面留白',
        );
        // 需求 10 的错位回归: 标题与「查看全部」中心线差 < 1dp
        final dy = tester.getCenter(find.text('我喜欢的音乐')).dy;
        final trailDy = tester.getCenter(find.text('查看全部')).dy;
        expect(
          (dy - trailDy).abs(),
          lessThan(1.0),
          reason: '$tag 标题/trailing 中心线',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('「我的」页: 卡片距屏 12 / 卡片内行 16 / 无 overflow', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = 'MineView w=$width s=$scale';
        final errors = await _pump(
          tester,
          _mine(),
          width: width,
          scale: scale,
          // 「我的」页顶部新增了「我的主页 / 简介 / 我的动态」(需求 1/2),
          // 1.625 字号下整体更高, 视口给足才能一次性建出全部区块
          height: 2600,
        );
        await tester.pump(const Duration(milliseconds: 200));
        _expectNoOverflow(errors, tag);

        // 个人资料卡: 唯一一块曾经叠了 Card(margin: all(12)) 的卡片 → 距屏 24
        final headerSurface = tester.getRect(
          find
              .descendant(
                of: find.byType(ProfileHeader),
                matching: find.byType(InkWell),
              )
              .first,
        );
        expect(
          headerSurface.left,
          moreOrLessEquals(kPagePadding, epsilon: 0.5),
          reason: '$tag 资料卡左边缘',
        );
        expect(
          headerSurface.right,
          moreOrLessEquals(width - kPagePadding, epsilon: 0.5),
          reason: '$tag 资料卡右边缘',
        );

        // 消息中心卡: 卡片距屏 12, 行内容(图标)距屏 12+4
        final messageCard = tester.getRect(
          find
              .ancestor(of: find.text('消息中心'), matching: find.byType(Card))
              .first,
        );
        expect(
          messageCard.left,
          moreOrLessEquals(kPagePadding, epsilon: 0.5),
          reason: '$tag 消息卡左边缘',
        );
        final icon = tester.getRect(find.byIcon(Icons.forum_outlined));
        expect(
          icon.left,
          moreOrLessEquals(kPagePadding + kCardRowInset, epsilon: 0.5),
          reason: '$tag 消息卡行内容左边缘',
        );

        // 区块标题(图标 + 文字)距屏 12。2026-11-20 起栏目标题左侧带图标,
        // 所以量的是标题行(Row)的左边缘, 而不是文字本身(文字右移「图标 + 6」)。
        expect(
          tester
              .getRect(
                find
                    .ancestor(
                      of: find.text('我喜欢的音乐'),
                      matching: find.byType(Row),
                    )
                    .first,
              )
              .left,
          moreOrLessEquals(kPagePadding, epsilon: 0.5),
          reason: '$tag 区块标题左边缘',
        );

        // 卡片内歌曲行: 封面距屏 16, 标题不超过「封面 + kRowTitleGap」
        final likedCover = tester.getRect(
          find.descendant(
            of: find.ancestor(
              of: find.text('喜欢的歌'),
              matching: find.byType(ListTile),
            ),
            matching: find.byType(CoverArt),
          ),
        );
        expect(
          likedCover.left,
          moreOrLessEquals(kPagePadding + kCardRowInset, epsilon: 0.5),
          reason: '$tag 歌曲行封面左边缘',
        );
        final likedTitle = tester.getRect(find.text('喜欢的歌'));
        expect(
          likedTitle.left,
          greaterThanOrEqualTo(kPagePadding + kCardRowInset),
          reason: '$tag 歌曲行标题不被额外推右',
        );
        expect(
          likedTitle.left,
          lessThanOrEqualTo(likedCover.right + kRowTitleGap + 0.5),
          reason: '$tag 歌曲行标题与封面间距 <= kRowTitleGap',
        );
        expect(
          likedTitle.right,
          lessThanOrEqualTo(width - kPagePadding),
          reason: '$tag 歌曲行标题不出右留白',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('「我的」页听歌排行: 名次与卡片同栅格(12+4)', (tester) async {
    for (final width in _widths) {
      final tag = 'MineRank w=$width';
      await _pump(tester, _mine(), width: width);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.scrollUntilVisible(
        find.text('听歌排行'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final rank = tester.getRect(find.text('1'));
      expect(
        rank.left,
        moreOrLessEquals(kPagePadding + kCardRowInset, epsilon: 0.5),
        reason: '$tag 排行名次左边缘',
      );
      expect(
        tester.getRect(find.text('最常听')).left,
        lessThan(width * 0.45),
        reason: '$tag 排行行标题不被推到 1/2 屏宽',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  // 纵向 pitch(列表行审计 C 级 · 2026-11-17): 行高只由 rowExtentFor 决定。
  //
  // 为什么是**渲染断言**而不是 grep 门: 行高不是源码里写出来的数值, 而是
  // ListTile 的 dense / minHeight / minVerticalPadding / visualDensity 四条隐式
  // 规则叠加出来的结果 —— 同一套 SongRow 在改动前实测落在 53 / 64 / 76 三个高度
  // (以及自绘臂 40)。改源码里任何一个开关都会变, 只有量渲染出来的 rect 才算判据。
  // 源码侧只额外拦「行留白写了非 0/6 的纵向值」(tools/check-row-padding.sh)。
  testWidgets('列表行纵向 pitch: 行高 = rowExtentFor(124/56 口径), 预览行同高', (
    tester,
  ) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = 'SongRow w=$width s=$scale';
        final song = fakeSong(id: 3, name: '晴天');
        final cases = <String, SongRow>{
          'tile 臂(默认真实列表行)': SongRow(
            song: song,
            layout: SongRowLayout.tile,
            coverSize: 40,
            subtitle: SongRowSubtitle.artist,
            showDuration: true,
          ),
          'tile 臂 + 卡片留白': SongRow(
            song: song,
            layout: SongRowLayout.tile,
            coverSize: 40,
            subtitle: SongRowSubtitle.artist,
            padding: kCardRowPadding,
          ),
          'plain 臂(带序号, 无 itemExtent)': SongRow(
            song: song,
            indexText: '${1}',
            coverSize: 40,
            subtitle: SongRowSubtitle.artist,
          ),
          'plain 臂 + 预览行 6/6': SongRow(
            song: song,
            indexText: '${1}',
            coverSize: 40,
            subtitle: SongRowSubtitle.artist,
            padding: kPreviewRowPadding,
          ),
        };
        for (final entry in cases.entries) {
          final errors = await _pump(
            tester,
            ListView(children: [entry.value]),
            width: width,
            scale: scale,
          );
          _expectNoOverflow(errors, '$tag ${entry.key}');
          final h = tester.getSize(find.byType(SongRow)).height;
          expect(
            h,
            moreOrLessEquals(
              rowExtentFor(tester.element(find.byType(SongRow))),
              epsilon: 0.5,
            ),
            reason: '$tag ${entry.key} 行高必须等于 rowExtentFor(56 × 字号)',
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
  });

  // 行留白口径: 只有三个具名口径(歌曲行与其它整页行同一条
  // 12 线, 原 kSongRowPadding 已删), 这里锁住它们的**几何关系**: 改数值可以, 但不能
  // 改成"叠起来不是 16"或"整页行不贴页面线"。
  // 用法侧(哪个文件用了哪个常量)由 tools/check-row-padding.sh --strict 守。
  test('行留白口径: 两级栅格 + 预览行', () {
    // 整页铺满、行首非缩略图: 左边缘严格等于页面线
    expect(kPageRowPadding.left, kPagePadding);
    expect(kPageRowPadding.right, kCardRowInset);
    // 父容器已内缩 12 时再缩 4 => 内容距屏 16(与卡片内行内容同一档)
    expect(kCardRowPadding.left, kCardRowInset);
    expect(kPagePadding + kCardRowPadding.left, 16);
    // 整页行的左右都不是 Material 默认的 16/16(那是白吃宽度的老口径)
    expect(kPageRowPadding.left, lessThan(16));
    expect(kPageRowPadding.right, lessThan(16));
    // 预览行水平不再加边(父容器已内缩), 只留上下呼吸
    expect(kPreviewRowPadding.left, 0);
    expect(kPreviewRowPadding.right, 0);
    expect(kPreviewRowPadding.top, kPreviewRowPadding.bottom);
  });
}

void _noop() {}
