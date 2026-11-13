import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/mine_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('消息入口: 未读分项摘要 + 角标 + 点击回调', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      host(
        MessageEntryCard(
          onOpen: () => opened++,
          load: () async => const rust.MessageCountsDto(
            private: 3,
            notices: 1,
            comments: 2,
            forwards: 0,
            total: 6,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('消息中心'), findsOneWidget);
    expect(find.text('私信 3 · 通知 1 · 评论 2'), findsOneWidget);
    expect(find.text('6'), findsOneWidget, reason: '角标显示合计');

    await tester.tap(find.text('消息中心'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('消息入口: 计数失败仍可点开', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      host(
        MessageEntryCard(
          onOpen: () => opened++,
          load: () async => throw Exception('[auth] 未登录'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('消息中心'), findsOneWidget);
    expect(find.text('私信 / 通知 / 评论'), findsOneWidget);

    await tester.tap(find.text('消息中心'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('300dp + 1.25 字号: 卡片不溢出且关键文案可见', (tester) async {
    await pumpNarrow(
      tester,
      Scaffold(
        body: MessageEntryCard(
          onOpen: () {},
          load: () async => const rust.MessageCountsDto(
            private: 3,
            notices: 1,
            comments: 2,
            forwards: 0,
            total: 6,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('消息中心'), findsOneWidget);
    expect(find.text('6'), findsOneWidget, reason: '角标显示合计');
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
