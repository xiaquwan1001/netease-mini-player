import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/search_landing.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

SearchLanding landing({
  List<String> history = const ['七里香', '稻香'],
  VoidCallback? onClear,
}) => SearchLanding(
  history: history,
  hot: const [],
  recommended: null,
  onSelected: (_) {},
  onClearHistory: onClear ?? () {},
);

void main() {
  // C2: 清空搜索历史是不可恢复的破坏性操作, 必须有二次确认.
  testWidgets('点「清空」弹确认框, 文案带条数', (tester) async {
    await tester.pumpWidget(host(landing()));
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('清空搜索历史'), findsOneWidget);
    expect(find.text('将删除全部 2 条搜索历史。'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '清空'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('取消不清空, 且对话框关闭', (tester) async {
    var cleared = 0;
    await tester.pumpWidget(host(landing(onClear: () => cleared++)));
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(cleared, 0);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('确认后只调用一次, 对话框关闭', (tester) async {
    var cleared = 0;
    await tester.pumpWidget(host(landing(onClear: () => cleared++)));
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '清空'),
      ),
    );
    await tester.pumpAndSettle();

    expect(cleared, 1);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('单条历史文案用单数', (tester) async {
    await tester.pumpWidget(host(landing(history: const ['七里香'])));
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('将删除这 1 条搜索历史。'), findsOneWidget);
  });

  testWidgets('300dp + 1.25 字号: 确认框不溢出', (tester) async {
    await pumpNarrow(
      tester,
      Scaffold(
        body: landing(
          history: const ['七里香', '稻香', '晴天', '一条特别特别长的历史搜索词用于窄屏回归测试'],
        ),
      ),
    );
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('将删除全部 4 条搜索历史。'), findsOneWidget);
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
