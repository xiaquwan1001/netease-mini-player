import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/radio_explore_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.RadioCategory _cat(int id, String name) =>
    rust.RadioCategory(id: BigInt.from(id), name: name, coverUrl: '');

rust.PodcastRadio _radio(int id, String name, {String dj = '主播', int progs = 12, BigInt? plays}) =>
    rust.PodcastRadio(
      id: BigInt.from(id),
      name: name,
      coverUrl: '',
      description: '',
      djName: dj,
      programCount: BigInt.from(progs),
      playCount: plays ?? BigInt.from(6555956),
    );

rust.RadioExploreHome _home({int cats = 3, int picks = 2}) => rust.RadioExploreHome(
      categories: List.generate(cats, (i) => _cat(2001 + i, '分类$i')),
      picks: List.generate(
        picks,
        (i) => rust.RadioPick(
          categoryId: BigInt.from(2001 + i),
          categoryName: '分类$i',
          radios: [_radio(526564706 + i, '精选电台$i')],
        ),
      ),
    );

rust.RadioToplistDto _top(String kind) => rust.RadioToplistDto(
      kind: kind,
      radios: kind == 'hot' || kind == 'pay'
          ? [
              rust.RadioRankedRadio(
                rank: 1,
                lastRank: 3,
                radioId: BigInt.from(792868378),
                name: '榜单电台0',
                coverUrl: '',
                djName: '一条小团团OvO',
                category: '创作翻唱',
                playCount: BigInt.from(131838544),
                programCount: BigInt.from(56),
                subCount: BigInt.from(456521),
                score: BigInt.from(116563),
                rcmdText: '可神经可温柔的宝藏女声',
              ),
            ]
          : const [],
      djs: kind == 'popular'
          ? [
              rust.RadioRankedDj(
                rank: 1,
                lastRank: 3,
                userId: BigInt.from(97137413),
                nickname: '薛之谦',
                avatarUrl: '',
                score: BigInt.from(2591496),
                followedCount: BigInt.from(21579876),
              ),
            ]
          : const [],
      programs: kind == 'program'
          ? [
              rust.RadioRankedProgramDto(
                rank: 1,
                lastRank: 3,
                program: _program(9001, '深夜电台第 100 期', hasSong: true),
              ),
              rust.RadioRankedProgramDto(
                rank: 2,
                lastRank: -1,
                program: _program(9002, '无音频的节目', hasSong: false),
              ),
            ]
          : const [],
    );

rust.PodcastProgramDto _program(
  int id,
  String name, {
  required bool hasSong,
}) => rust.PodcastProgramDto(
      id: BigInt.from(id),
      name: name,
      coverUrl: '',
      durationMs: BigInt.from(924000),
      djName: '主播小张',
      radioId: BigInt.from(526564706),
      radioName: '伴听FM',
      description: '',
      song: hasSong
          ? rust.SongDto(
              id: BigInt.from(777001),
              name: 'song-777001',
              artist: '主播小张',
              artistId: BigInt.one,
              album: '伴听FM',
              albumId: BigInt.one,
              coverUrl: null,
              durationMs: BigInt.from(924000),
              fee: 0,
              vip: false,
              paid: false,
              playable: true,
            )
          : null,
    );

Future<void> _pump(
  WidgetTester tester, {
  Future<rust.RadioExploreHome?> Function()? home,
  Future<List<rust.PodcastRadio>> Function(BigInt)? recommend,
  Future<rust.RadioToplistDto?> Function(String)? toplist,
  void Function(BuildContext, rust.PodcastRadio)? onOpenRadio,
  void Function(List<rust.SongDto>, int)? onPlaySongs,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: RadioExplorePage(
        loadHome: home,
        loadRecommend: recommend,
        loadToplist: toplist,
        onOpenRadio: onOpenRadio,
        onPlaySongs: onPlaySongs,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('首页: 分类胶囊 + 精选分组 + 榜单', (tester) async {
    await _pump(
      tester,
      home: () async => _home(),
      toplist: (kind) async => _top(kind),
    );
    expect(find.text('精选'), findsOneWidget);
    expect(find.text('分类0'), findsWidgets); // 胶囊 + 分组标题
    expect(find.text('精选电台0'), findsOneWidget);
    expect(find.text('电台榜单'), findsOneWidget);
    expect(find.text('榜单电台0'), findsOneWidget); // hot 榜电台
  });

  testWidgets('分类切换: 点分类拉推荐电台, 切回精选恢复分组', (tester) async {
    var recommendCalls = 0;
    await _pump(
      tester,
      home: () async => _home(),
      recommend: (cateId) async {
        recommendCalls++;
        expect(cateId, BigInt.from(2001));
        return [_radio(980333710, '分类推荐电台', dj: '音乐疗愈研究所', plays: BigInt.zero)];
      },
      toplist: (kind) async => _top(kind),
    );
    expect(recommendCalls, 0);
    await tester.tap(find.text('分类0').first); // 胶囊
    await tester.pumpAndSettle();
    expect(recommendCalls, 1);
    expect(find.text('「分类0」推荐电台'), findsOneWidget);
    expect(find.text('分类推荐电台'), findsOneWidget);
    // 切回精选
    await tester.tap(find.text('精选'));
    await tester.pumpAndSettle();
    expect(recommendCalls, 1);
    expect(find.text('精选电台0'), findsOneWidget);
  });

  testWidgets('推荐空态 + 榜单切换到主播榜', (tester) async {
    await _pump(
      tester,
      home: () async => _home(),
      recommend: (cateId) async => const [],
      toplist: (kind) async => _top(kind),
    );
    await tester.tap(find.text('分类1').first);
    await tester.pumpAndSettle();
    expect(find.text('该分类暂无推荐电台'), findsOneWidget);
    // 切主播榜: djs 行显示昵称与粉丝
    await tester.tap(find.text('主播'));
    await tester.pumpAndSettle();
    expect(find.text('薛之谦'), findsOneWidget);
    expect(find.textContaining('粉丝'), findsOneWidget);
  });

  testWidgets('错误态可重试: 首页失败给重试, 点击后恢复', (tester) async {
    var fail = true;
    await _pump(
      tester,
      home: () async {
        if (fail) throw Exception('[network] boom');
        return _home();
      },
      toplist: (kind) async => _top(kind),
    );
    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('精选电台0'), findsOneWidget);
  });

  testWidgets('行点击回调携带电台 DTO', (tester) async {
    rust.PodcastRadio? opened;
    await _pump(
      tester,
      home: () async => _home(),
      toplist: (kind) async => _top(kind),
      onOpenRadio: (ctx, radio) => opened = radio,
    );
    await tester.tap(find.text('精选电台0'));
    expect(opened?.id, BigInt.from(526564706));
    // 榜单行也能打开(把榜单电台转成 PodcastRadioDto)
    await tester.tap(find.text('榜单电台0'));
    expect(opened?.id, BigInt.from(792868378));
    expect(opened?.name, '榜单电台0');
  });

  testWidgets('节目榜页签: 渲染排名/节目名/电台/主播/时长, 点行直接播放', (tester) async {
    List<rust.SongDto>? played;
    var playIndex = -1;
    rust.PodcastRadio? opened;
    await _pump(
      tester,
      home: () async => _home(),
      toplist: (kind) async => _top(kind),
      onOpenRadio: (ctx, radio) => opened = radio,
      onPlaySongs: (songs, i) {
        played = songs;
        playIndex = i;
      },
    );
    await tester.tap(find.text('节目'));
    await tester.pumpAndSettle();
    expect(find.text('深夜电台第 100 期'), findsOneWidget);
    expect(find.textContaining('伴听FM'), findsWidgets); // 两条节目同电台
    expect(find.textContaining('主播小张'), findsWidgets);
    expect(find.textContaining('15:24'), findsWidgets); // 924000ms
    // 有音频的节目直接走播放回调链
    await tester.tap(find.text('深夜电台第 100 期'));
    expect(played?.single.id, BigInt.from(777001));
    expect(playIndex, 0);
    // 无音频本体回落打开电台详情(复用 onOpenRadio 链)
    await tester.tap(find.text('无音频的节目'));
    expect(opened?.id, BigInt.from(526564706));
    expect(opened?.name, '伴听FM');
  });

  testWidgets('未注入播放回调时节目行回落打开电台详情', (tester) async {
    rust.PodcastRadio? opened;
    await _pump(
      tester,
      home: () async => _home(),
      toplist: (kind) async => _top(kind),
      onOpenRadio: (ctx, radio) => opened = radio,
    );
    await tester.tap(find.text('节目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深夜电台第 100 期'));
    expect(opened?.id, BigInt.from(526564706));
  });

  testWidgets('窄屏 300dp + 1.25 字号不溢出', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(300, 700);
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      home: () async => _home(cats: 8, picks: 3),
      recommend: (cateId) async => [_radio(1, '很长的电台名字很长很长很长很长很长')],
      toplist: (kind) async => _top(kind),
    );
    await tester.tap(find.text('分类0').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('主播'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
