import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/mine_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SigninStatus status({
  required bool signed,
  int total = 13,
  int continuous = 1,
  int week = 5,
  int point = 0,
}) =>
    rust.SigninStatus(
      signedToday: signed,
      totalDays: total,
      continuousDays: continuous,
      weekDays: week,
      recent: const [],
      todayPoint: point,
    );

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('签到卡片: 未签到显示按钮, 点签到后变已签到并提示云贝', (tester) async {
    var signed = 0;
    await tester.pumpWidget(host(SigninCard(
      load: () async => status(signed: false),
      sign: () async {
        signed++;
        return status(signed: true, total: 14, point: 2);
      },
    )));
    await tester.pumpAndSettle();

    expect(find.text('今天还没签到'), findsOneWidget);
    expect(find.text('累计 13 天 · 连续 1 天 · 本周 5 天'), findsOneWidget);

    await tester.tap(find.text('签到'));
    await tester.pumpAndSettle();

    expect(signed, 1);
    expect(find.text('今日已签到'), findsOneWidget);
    expect(find.text('已签'), findsOneWidget);
    expect(find.textContaining('云贝 +2'), findsOneWidget);
  });

  testWidgets('300dp + 1.25 字号不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
        child: Scaffold(
          body: SigninCard(
            load: () async => status(signed: false),
            sign: () async => status(signed: true, total: 14, point: 2),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('今天还没签到'), findsOneWidget);
  });

  testWidgets('签到卡片: 已签到不显示按钮', (tester) async {
    await tester.pumpWidget(host(SigninCard(
      load: () async => status(signed: true),
    )));
    await tester.pumpAndSettle();

    expect(find.text('今日已签到'), findsOneWidget);
    expect(find.text('签到'), findsNothing);
  });

  testWidgets('签到卡片: 载入失败整块不显示', (tester) async {
    await tester.pumpWidget(host(SigninCard(
      load: () async => throw Exception('[auth] 未登录'),
    )));
    await tester.pumpAndSettle();

    expect(find.text('今天还没签到'), findsNothing);
    expect(find.text('今日已签到'), findsNothing);
  });
}
