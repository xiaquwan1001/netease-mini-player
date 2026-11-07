import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/search_landing.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

SearchLanding landing({List<String> history = const ['七里香', '稻香'], VoidCallback? onClear}) =>
    SearchLanding(
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
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, '清空'),
    ));
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
}
