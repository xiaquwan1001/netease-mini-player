import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/discover.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

import 'support/fakes.dart';

/// 未登录进「每日推荐 → 推荐歌单」时的死路回归(2026-11-26 审查 P1)。
///
/// 以前这一页只有「需要登录后才能查看」+「重试」: 重试拿的是同一份未登录身份,
/// 后端永远回 auth —— 用户只能退出去自己找登录入口。现在 auth 错误把主按钮换成
/// 「去登录」, 走首页带下来的登录回调(`AccountActions.login`)。

/// 失败要晚一拍再抛, 免得同一微任务内失败的 future 被 zone 当未处理异步错误
/// (与 async_view_test 的 failLater 同款理由)。
Future<List<rust.Playlist>> failLater(Object error) async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
  throw error;
}

Widget host(VoidCallback onTap) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (ctx) => TextButton(onPressed: onTap, child: const Text('open')),
    ),
  ),
);

void main() {
  testWidgets('auth 错误: 主按钮是「去登录」并能调到登录入口', (tester) async {
    var loginCalls = 0;
    await tester.pumpWidget(
      host(() {
        showDiscoverPage(
          tester.element(find.text('open')),

          initialTab: 1,
          onOpenPlaylist: (_) {},
          onLogin: () => loginCalls += 1,
          loadSongs: () async => [fakeSong(id: 1, name: '晴天')],
          loadPlaylists: () => failLater(Exception('[auth] Unknown error')),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // friendlyError 的统一 auth 文案(不再叠"需要登录后才能获取"那一句)
    expect(find.text('需要登录后才能查看'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '去登录'), findsOneWidget);
    // 未登录时「重试」是永远失败的死路, 不该再出现在主按钮上
    expect(find.text('重试'), findsNothing);

    await tester.tap(find.text('去登录'));
    await tester.pump();
    expect(loginCalls, 1);
  });

  testWidgets('非 auth 错误: 仍然只有「重试」(登录救不了网络错误)', (tester) async {
    var loginCalls = 0;
    await tester.pumpWidget(
      host(() {
        showDiscoverPage(
          tester.element(find.text('open')),

          initialTab: 1,
          onOpenPlaylist: (_) {},
          onLogin: () => loginCalls += 1,
          loadSongs: () async => [fakeSong(id: 1, name: '晴天')],
          loadPlaylists: () => failLater(Exception('[network] boom')),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
    expect(find.text('去登录'), findsNothing);
    expect(loginCalls, 0);
  });
}
