import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/toast.dart';

/// 可撤销横条(2026-11 用户需求 7): 取消喜欢/取消收藏歌单/取消关注后给几秒撤销窗口.
void main() {
  testWidgets('点「撤销」执行回调', (tester) async {
    var undone = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showUndoToast(
                context,
                message: '已取消喜欢《晴天》',
                onUndo: () => undone++,
              ),
              child: const Text('trigger'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('trigger'));
    // 等横条完全进场(进场动画结束后按钮才可命中)
    await tester.pumpAndSettle();
    expect(find.text('已取消喜欢《晴天》'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(undone, 1);
  });

  testWidgets('默认给 4 秒撤销窗口, 之后自动回落', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showUndoToast(context, message: '已取消收藏歌单', onUndo: () {}),
              child: const Text('trigger'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();
    expect(find.text('已取消收藏歌单'), findsOneWidget);

    // 不依赖框架的定时器实现: 直接锁"横条给的时长是 4 秒"(用户反馈
    // 「弹窗不会自动回落, 遮挡内容」⇒ 从 5s 收紧, 且改成悬浮不贴底)
    final bar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(bar.duration, const Duration(seconds: 4));
    expect(bar.action?.label, '撤销');
    expect(bar.behavior, SnackBarBehavior.floating);
  });
}
