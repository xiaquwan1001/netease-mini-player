import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/paged_list_view.dart';

class Item {
  const Item(this.id, this.name);
  final int id;
  final String name;
}

Widget host(Widget child, {Size size = const Size(400, 800)}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(width: size.width, height: size.height, child: child),
  ),
);

PagedListView<Item> list({
  required PagedLoader<Item> loader,
  String emptyText = '暂无内容',
  Object? Function(Item)? keyOf,
  String? endText,
  Widget? header,
  SliverGridDelegate? gridDelegate,
}) {
  return PagedListView<Item>(
    loader: loader,
    keyOf: keyOf,
    emptyText: emptyText,
    endText: endText,
    header: header,
    gridDelegate: gridDelegate,
    itemBuilder: (context, item, index, items) =>
        ListTile(title: Text(item.name)),
  );
}

void main() {
  testWidgets('首屏加载: 先骨架后数据', (tester) async {
    final completer = Completer<PagedPage<Item>>();
    await tester.pumpWidget(host(list(loader: (_) => completer.future)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete(const PagedPage([Item(1, '条目一')], hasMore: false));
    await tester.pumpAndSettle();
    expect(find.text('条目一'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('首屏错误: friendlyError 文案 + 重试后成功', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      host(
        list(
          loader: (_) async {
            attempts++;
            if (attempts == 1) throw Exception('[network] connection reset');
            return const PagedPage([Item(1, '重试后的条目')], hasMore: false);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('网络不稳定'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试后的条目'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('空态: 默认文案与自定义 emptyBuilder', (tester) async {
    await tester.pumpWidget(
      host(
        list(
          loader: (_) async => const PagedPage([], hasMore: false),
          emptyText: '这里什么都没有',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('这里什么都没有'), findsOneWidget);

    await tester.pumpWidget(
      host(
        PagedListView<Item>(
          loader: (_) async => const PagedPage([], hasMore: false),
          emptyText: '不会被用到',
          emptyBuilder: (context, _) => const Text('自定义空态视图'),
          itemBuilder: (_, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('自定义空态视图'), findsOneWidget);
    expect(find.text('不会被用到'), findsNothing);
  });

  testWidgets('触底自动加载下一页, cursor 递增透传', (tester) async {
    final cursors = <int>[];
    await tester.pumpWidget(
      host(
        list(
          loader: (cursor) async {
            cursors.add(cursor);
            return PagedPage([
              for (var i = 0; i < 30; i++) Item(cursor + i, '条目${cursor + i}'),
            ], hasMore: cursor < 30);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(cursors, [0]);

    // 拖到底部: 触底前 300px 自动预取
    await tester.dragUntilVisible(
      find.text('条目30'),
      find.byType(ListView),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(cursors, [0, 30]);
    expect(find.text('条目30'), findsOneWidget);
  });

  testWidgets('加载更多失败: 保留旧数据 + SnackBar 提示', (tester) async {
    await tester.pumpWidget(
      host(
        list(
          loader: (cursor) async {
            if (cursor > 0) throw Exception('[network] boom');
            return PagedPage([
              for (var i = 0; i < 30; i++) Item(i, '条目$i'),
            ], hasMore: true);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(
      find.text('加载更多'),
      find.byType(ListView),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('网络不稳定'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget, reason: '失败后仍可手动重试加载更多');
    // 滚回顶部确认旧数据保留
    await tester.drag(find.byType(ListView), const Offset(0, 10000));
    await tester.pumpAndSettle();
    expect(find.text('条目0'), findsOneWidget, reason: '旧数据保留');
    expect(find.textContaining('条目30'), findsNothing);
  });

  testWidgets('去重: 同 key 不重复入列, nextCursor 按已消费行数推进', (tester) async {
    final cursors = <int>[];
    await tester.pumpWidget(
      host(
        list(
          keyOf: (item) => item.id,
          loader: (cursor) async {
            cursors.add(cursor);
            if (cursor == 0) {
              return const PagedPage(
                [Item(1, '一'), Item(2, '二')],
                hasMore: true,
                nextCursor: 2,
              );
            }
            // 第二页带一个重复 id, 应被去重
            return const PagedPage(
              [Item(2, '二'), Item(3, '三')],
              hasMore: false,
              nextCursor: 4,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('一'), findsOneWidget);

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(cursors, [0, 2]);
    expect(find.text('二'), findsOneWidget, reason: '重复 id 只保留第一条');
    expect(find.text('三'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing, reason: '第二页 hasMore=false');
  });

  testWidgets('300dp + 1.25 字号: 有数据/到底提示不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: Scaffold(
            body: list(
              endText: '没有更多了',
              loader: (_) async => const PagedPage([
                Item(1, '很长很长的条目名称测试中文溢出场景一'),
              ], hasMore: false),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('很长很长的条目名称测试中文溢出场景一'), findsOneWidget);
    expect(find.text('没有更多了'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('网格模式 + 列表头 + 下拉刷新钩子', (tester) async {
    var loads = 0;
    await tester.pumpWidget(
      host(
        list(
          header: const Text('筛选条'),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
          ),
          loader: (_) async {
            loads++;
            return const PagedPage([Item(1, '卡片一')], hasMore: false);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('筛选条'), findsOneWidget);
    expect(find.text('卡片一'), findsOneWidget);
    expect(find.byType(SliverGrid), findsOneWidget);
    expect(loads, 1);
  });
}
