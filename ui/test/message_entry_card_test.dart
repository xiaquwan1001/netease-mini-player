import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/mine_view.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

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
            forwards: 4,
            total: 10,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('消息中心'), findsOneWidget);
    // 未读数改为文字展示(不再有红色数字角标): 分项写进副标题, @我 也算一项
    expect(find.text('私信 3 · 通知 1 · 评论 2 · @我 4'), findsOneWidget);
    expect(find.text('10'), findsNothing, reason: '不再显示数字角标');

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
    expect(find.text('私信 / 通知 / 评论 / @我'), findsOneWidget);

    await tester.tap(find.text('消息中心'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('从消息中心返回后重取未读数', (tester) async {
    // 用户反馈: 读完消息回到「我的」, 未读数还是旧值(下拉刷新也不变), 要杀进程重开。
    // 入口卡只在 initState 取一次, 消息中心 pop 回来时必须自己再取一次。
    var loads = 0;
    var unread = 3;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => MessageEntryCard(
              onOpen: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const Scaffold(body: Center(child: Text('消息中心页'))),
                ),
              ),
              load: () async {
                loads++;
                return rust.MessageCountsDto(
                  private: unread,
                  notices: 0,
                  comments: 0,
                  forwards: 0,
                  total: unread,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('私信 3'), findsOneWidget);

    unread = 0; // 消息中心里读完了
    await tester.tap(find.text('消息中心'));
    await tester.pumpAndSettle();
    expect(find.text('消息中心页'), findsOneWidget);

    Navigator.of(tester.element(find.text('消息中心页'))).pop();
    await tester.pumpAndSettle();

    expect(loads, 2, reason: '返回后要重取一次未读数');
    expect(find.text('暂无未读'), findsOneWidget);
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
    expect(find.text('私信 3 · 通知 1 · 评论 2'), findsOneWidget);
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
