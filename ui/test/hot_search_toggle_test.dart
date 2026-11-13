import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/search_landing.dart';

rust.HotSearchTerm hot(int rank, String keyword) =>
    rust.HotSearchTerm(rank: rank, keyword: keyword);

// 与 main.dart 的 SettingsScope 等价: notifyListeners 时重建子树.
// builder 里要重新构造 child —— 复用同一 widget 实例会被
// updateChild 的 identical 短路跳过, 不会重跑 build.
Widget host(SearchLanding Function() make) => MaterialApp(
  home: AnimatedBuilder(
    animation: AppSettings.instance,
    builder: (_, _) => Scaffold(body: make()),
  ),
);

SearchLanding landing() => SearchLanding(
  history: const ['七里香'],
  hot: [hot(1, '晴天'), hot(2, '稻香')],
  recommended: '周杰伦',
  onSelected: (_) {},
  onClearHistory: () {},
);

void main() {
  setUp(() {
    // 每例恢复默认, 避免用例间串状态(单例)
    AppSettings.instance.showHotSearch = true;
  });

  testWidgets('默认(未设置)可见热门搜索', (tester) async {
    await tester.pumpWidget(host(landing));
    expect(find.text('热门搜索'), findsOneWidget);
    expect(find.text('晴天'), findsOneWidget);
  });

  testWidgets('showHotSearch=false: 栏目标题常驻, 只收起内容, 历史/猜你想搜仍在', (tester) async {
    AppSettings.instance.showHotSearch = false;
    await tester.pumpWidget(host(landing));
    // 开关从设置页搬到搜索页后: 栏目不再整块消失, 而是显示「已关闭 + 开启」
    expect(find.text('热门搜索'), findsOneWidget);
    expect(find.text('晴天'), findsNothing);
    expect(find.text('稻香'), findsNothing);
    expect(find.textContaining('热门搜索已关闭'), findsOneWidget);
    expect(find.text('开启'), findsOneWidget);
    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.text('七里香'), findsOneWidget);
    expect(find.text('猜你想搜'), findsOneWidget);
    expect(find.text('周杰伦'), findsOneWidget);
  });

  testWidgets('只有一个开关按钮: 「开启」/「关闭」直接改设置, 不再有重复的 ❌', (tester) async {
    AppSettings.instance.showHotSearch = false;
    await tester.pumpWidget(host(landing));
    expect(find.byIcon(Icons.close), findsNothing, reason: '右侧 ❌ 与开关功能重复, 已删除');
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    expect(AppSettings.instance.showHotSearch, isTrue);
    expect(find.text('晴天'), findsOneWidget);

    // 关闭 = 收起内容 + 记住(落盘), 一个按钮完成
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(AppSettings.instance.showHotSearch, isFalse);
    expect(find.text('晴天'), findsNothing);
    expect(find.textContaining('热门搜索已关闭'), findsOneWidget);
  });

  testWidgets('隐藏后无历史无猜你想搜时显示占位提示; 打开开关后立即出现', (tester) async {
    AppSettings.instance.showHotSearch = false;
    await tester.pumpWidget(
      host(
        () => SearchLanding(
          history: const [],
          hot: [hot(1, '晴天')],
          recommended: null,
          onSelected: (_) {},
          onClearHistory: () {},
        ),
      ),
    );
    // 空历史 + 无推荐 + 热词关闭: 仍是「栏目 + 关闭提示」, 不再有设置页文案
    expect(find.text('热门搜索'), findsOneWidget);
    expect(find.textContaining('热门搜索已关闭'), findsOneWidget);
    expect(find.textContaining('显示热搜建议'), findsNothing);

    // 页内按钮开启: notifyListeners 驱动重建, build 内读取最新值
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    expect(find.text('热门搜索'), findsOneWidget);
    expect(find.text('晴天'), findsOneWidget);
  });

  // 真 IO(落盘/读回)在 testWidgets 的 FakeAsync 里不会完成, 用普通 test
  test('设置项持久化: update 落盘, 旧 settings.json 缺字段默认 true', () async {
    final dir = await Directory.systemTemp.createTemp('hot_search_settings');
    addTearDown(() => dir.delete(recursive: true));
    final settings = AppSettings.instance;
    await settings.load(dir.path);

    expect(settings.showHotSearch, isTrue, reason: '新字段缺省为 true');
    await settings.update(showHotSearch: false);
    final saved = jsonDecode(
      File('${dir.path}/settings.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(saved['showHotSearch'], isFalse);

    // 旧配置(缺字段)读进来应回落 true —— 先复位字段模拟新进程默认值
    settings.showHotSearch = true;
    File(
      '${dir.path}/settings.json',
    ).writeAsStringSync(jsonEncode({'themeMode': 'system', 'textScale': 1.0}));
    await settings.load(dir.path);
    expect(settings.showHotSearch, isTrue);
    expect(settings.clearSearchOnTabSwitch, isTrue);
  });

  testWidgets('300dp + 1.25 字号: 长热词/长推荐不溢出', (tester) async {
    AppSettings.instance.showHotSearch = true;
    await pumpNarrow(
      tester,
      Scaffold(
        body: SearchLanding(
          history: const ['一条特别特别长的历史搜索词用于窄屏回归测试'],
          hot: [hot(1, '一个特别特别长不会有人搜的热词窄屏回归'), hot(2, '稻香')],
          recommended: '一个特别特别长的推荐艺人名用于窄屏回归测试',
          onSelected: (_) {},
          onClearHistory: () {},
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('热门搜索'), findsOneWidget);
    expect(find.text('稻香'), findsOneWidget);
  });
}

/// 窄屏 + 大字号回归宿主: 300dp 宽 + 1.25 字号(builder 层注入, 对弹层也生效).
Future<void> pumpNarrow(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(300, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.25)),
        child: child!,
      ),
      home: home,
    ),
  );
}
