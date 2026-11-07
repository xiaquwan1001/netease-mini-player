import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/radio_explore_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.RadioCategoryDto _cat(int id, String name) =>
    rust.RadioCategoryDto(id: BigInt.from(id), name: name, coverUrl: '');

rust.PodcastRadioDto _radio(int id, String name, {String dj = '主播', int progs = 12, BigInt? plays}) =>
    rust.PodcastRadioDto(
      id: BigInt.from(id),
      name: name,
      coverUrl: '',
      description: '',
      djName: dj,
      programCount: BigInt.from(progs),
      playCount: plays ?? BigInt.from(6555956),
    );

rust.RadioExploreHomeDto _home({int cats = 3, int picks = 2}) => rust.RadioExploreHomeDto(
      categories: List.generate(cats, (i) => _cat(2001 + i, '分类$i')),
      picks: List.generate(
        picks,
        (i) => rust.RadioPickDto(
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
              rust.RadioRankedRadioDto(
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
              rust.RadioRankedDjDto(
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
      programs: const [],
    );

Future<void> _pump(
  WidgetTester tester, {
  Future<rust.RadioExploreHomeDto?> Function()? home,
  Future<List<rust.PodcastRadioDto>> Function(BigInt)? recommend,
  Future<rust.RadioToplistDto?> Function(String)? toplist,
  void Function(BuildContext, rust.PodcastRadioDto)? onOpenRadio,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: RadioExplorePage(
        loadHome: home,
        loadRecommend: recommend,
        loadToplist: toplist,
        onOpenRadio: onOpenRadio,
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
    rust.PodcastRadioDto? opened;
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
