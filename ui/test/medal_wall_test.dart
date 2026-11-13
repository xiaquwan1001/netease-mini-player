import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/medal_wall.dart';

UserLevelView level({
  int lvl = 8,
  String name = '音乐达人',
  int progress = 30,
  int target = 100,
  bool isVip = false,
}) => UserLevelView(
  level: lvl,
  levelName: name,
  progress: progress,
  target: target,
  isVip: isVip,
);

MedalView medal(int id, String name, {bool obtained = true}) => MedalView(
  id: id,
  name: name,
  imageUrl: null,
  description: '$name 说明',
  obtained: obtained,
);

Widget host(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('加载失败 -> friendlyError 文案 + 点重试再调 loader', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        MedalWallPage(
          load: () async {
            calls += 1;
            if (calls == 1) throw StateError('boom');
            return MedalWallData(level: level(), medals: [medal(1, '首枚勋章')]);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, 1);
    // friendlyError 对非网络错误原样透出
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('首枚勋章'), findsOneWidget);
  });

  testWidgets('网络错误 -> 中文友好文案', (tester) async {
    await tester.pumpWidget(
      host(
        MedalWallPage(
          load: () async => throw Exception('[network] connection reset'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('网络不稳定, 已自动重试仍失败, 请稍后重试'), findsOneWidget);
  });

  testWidgets('空勋章 -> 还没有勋章, 等级卡仍在', (tester) async {
    await tester.pumpWidget(
      host(
        MedalWallPage(
          load: () async => MedalWallData(level: level(), medals: const []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有勋章'), findsOneWidget);
    // 等级卡: 等级名(badge + 卡片标题各一处) + 进度文字
    expect(find.text('音乐达人'), findsNWidgets(2));
    expect(find.text('30/100'), findsOneWidget);
    expect(find.byType(LevelBadge), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsOneWidget);
  });

  testWidgets('level 为 null 时不显示等级卡', (tester) async {
    await tester.pumpWidget(
      host(MedalWallPage(load: () async => const MedalWallData(medals: []))),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有勋章'), findsOneWidget);
    expect(find.byType(LevelBadge), findsNothing);
  });

  testWidgets('正常态 -> 名称显示, 未获得勋章灰显(差异可断言)', (tester) async {
    await tester.pumpWidget(
      host(
        MedalWallPage(
          load: () async => MedalWallData(
            level: level(),
            medals: [
              medal(1, '听歌达人'),
              medal(2, '未解锁勋章', obtained: false),
              medal(3, '分享达人'),
              medal(4, '夜猫子'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('听歌达人'), findsOneWidget);
    expect(find.text('未解锁勋章'), findsOneWidget);
    expect(find.text('夜猫子'), findsOneWidget);

    // 未获得: 有 Opacity(0.45) 包裹, 已获得的没有
    final opacities = tester
        .widgetList<Opacity>(find.byType(Opacity))
        .where((o) => o.opacity < 1.0)
        .toList();
    expect(opacities.length, 1);
    expect(opacities.first.opacity, 0.45);

    // 未获得落在 Opacity 子树里, 已获得的落在外面
    expect(
      find.descendant(of: find.byType(Opacity), matching: find.text('未解锁勋章')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byType(Opacity), matching: find.text('听歌达人')),
      findsNothing,
    );

    // 图标也不同(锁 / 奖章), 已获得用主色
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.byIcon(Icons.military_tech), findsNWidgets(3));
  });

  testWidgets('下拉刷新再次调用 loader', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        MedalWallPage(
          load: () async {
            calls += 1;
            return MedalWallData(
              level: level(),
              medals: [medal(1, '第$calls次')],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('第1次'), findsOneWidget);

    await tester.fling(find.byType(ListView), const Offset(0, 320), 1000);
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('第2次'), findsOneWidget);
  });

  testWidgets('LevelBadge: Lv.8 + 等级名, target>0 有进度条', (tester) async {
    await tester.pumpWidget(
      host(
        Scaffold(
          body: Center(child: LevelBadge(view: level())),
        ),
      ),
    );

    expect(find.text('Lv.8'), findsOneWidget);
    expect(find.text('音乐达人'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.3, 1e-9));
    expect(bar.minHeight, 3);

    // 高度不超过 32dp
    expect(
      tester.getSize(find.byType(LevelBadge)).height,
      lessThanOrEqualTo(32.0),
    );
  });

  testWidgets('LevelBadge: target==0 无进度条; 点击回调', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      host(
        Scaffold(
          body: Center(
            child: LevelBadge(
              view: level(lvl: 12, name: '', progress: 0, target: 0),
              onTap: () => taps += 1,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Lv.12'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.tap(find.byType(LevelBadge));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('UserLevelView.fraction 边界', (tester) async {
    expect(level(progress: 30, target: 100).fraction, closeTo(0.3, 1e-9));
    expect(level(progress: 300, target: 100).fraction, 1.0);
    expect(level(progress: -5, target: 100).fraction, 0.0);
    expect(level(progress: 5, target: 0).fraction, 0.0);
  });

  testWidgets('300dp + 1.25 字号: 勋章墙不溢出', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(300, 700);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.25)),
          child: child!,
        ),
        home: MedalWallPage(
          load: () async => MedalWallData(
            level: level(lvl: 8, name: '资深音乐探索者等级名很长', isVip: true),
            medals: [
              medal(1, '连续听歌一百天特别纪念勋章'),
              medal(2, '评论小能手', obtained: false),
              medal(3, '分享达人'),
              medal(4, '夜猫子'),
              medal(5, '首枚勋章'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('分享达人'), findsOneWidget);
  });

  testWidgets('300dp + 1.25 字号: LevelBadge 不溢出且 <=32dp', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(300, 700);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Flexible(
                  child: LevelBadge(
                    view: level(lvl: 28, name: '资深音乐探索者等级名很长很长', isVip: true),
                  ),
                ),
                const SizedBox(width: 8),
                const Text('其他内容'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(LevelBadge)).height,
      lessThanOrEqualTo(32.0),
    );
  });
}
