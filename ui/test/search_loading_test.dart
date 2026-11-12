import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/search_loading.dart';

void main() {
  testWidgets('搜索中显示加载动画与关键词, 不再显示"输入关键词后搜索"', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SearchLoading('晴天')),
    ));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('正在搜索'), findsOneWidget);
    expect(find.textContaining('晴天'), findsOneWidget);
    expect(find.text('输入关键词后搜索'), findsNothing);
  });

  testWidgets('空关键词时用通用加载文案', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SearchLoading('')),
    ));
    expect(find.text('正在搜索…'), findsOneWidget);
  });
}
