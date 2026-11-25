import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/async_view.dart';
import 'package:minincm/src/error_views.dart';
import 'package:minincm/src/state_views.dart';

/// AsyncView(四态唯一实现)的直接单测: 只断言行为口径
/// (哪个态被渲染 / 文案 / 回调次数), 不碰私有字段。

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 失败要"晚一拍"再抛: 重试路径在 setState 里换 future, 下一帧 FutureBuilder 才订阅,
/// 同一微任务内就失败的 future 会被 zone 当「未处理异步错误」报出来(产品侧真实网络
/// 取数天然是晚到的, 只有测试里的同步失败会踩到)。
Future<T> failLater<T>(Object error, {int ms = 20}) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  throw error;
}

void main() {
  group('四态判定', () {
    testWidgets('loading: future 未完成 → 转圈', (tester) async {
      final completer = Completer<List<String>>();
      await tester.pumpWidget(
        host(
          AsyncView<List<String>>(
            future: completer.future,
            builder: (_, data, _) => Text(data.join(',')),
            emptyText: '暂无歌曲',
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('暂无歌曲'), findsNothing);

      // 完成后再 pump 才切到数据态(证明 loading 不是终态)
      completer.complete(const ['青花瓷']);
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('青花瓷'), findsOneWidget);
    });

    testWidgets('data: 非空数据交给 builder', (tester) async {
      await tester.pumpWidget(
        host(
          AsyncView<List<int>>(
            future: Future<List<int>>.value(const [1, 2, 3]),
            builder: (_, data, _) => Text('条数 ${data.length}'),
            emptyText: '暂无数据',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('条数 3'), findsOneWidget);
      expect(find.text('暂无数据'), findsNothing);
    });

    testWidgets('empty: null / 空 List / 空串 都走空态文案', (tester) async {
      // null
      await tester.pumpWidget(
        host(
          AsyncView<String?>(
            future: Future<String?>.value(null),
            builder: (_, data, _) => Text(data!),
            emptyText: '暂无介绍',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂无介绍'), findsOneWidget);

      // 空 List
      await tester.pumpWidget(
        host(
          AsyncView<List<String>>(
            future: Future<List<String>>.value(const <String>[]),
            builder: (_, data, _) => Text(data.join(',')),
            emptyText: '暂无评论',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂无评论'), findsOneWidget);

      // 空串
      await tester.pumpWidget(
        host(
          AsyncView<String>(
            future: Future<String>.value(''),
            builder: (_, data, _) => Text('正文: $data'),
            emptyText: '暂无歌词',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂无歌词'), findsOneWidget);
      expect(find.textContaining('正文:'), findsNothing);
    });

    testWidgets('empty: 自定义 emptyBuilder 顶掉默认文案', (tester) async {
      await tester.pumpWidget(
        host(
          AsyncView<List<String>>(
            future: Future<List<String>>.value(const <String>[]),
            builder: (_, data, _) => Text(data.join(',')),
            emptyText: '暂无评论',
            emptyBuilder: (_) => const EmptyView(title: '还没有评论', hint: '来抢沙发'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('还没有评论'), findsOneWidget);
      expect(find.text('来抢沙发'), findsOneWidget);
      expect(find.text('暂无评论'), findsNothing);
    });

    testWidgets('error: hasError → InlineError, 文案过 friendlyError', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          AsyncView<List<String>>(
            future: failLater<List<String>>(
              Exception('[forbidden] 该用户已设置歌单不可见'),
            ),
            builder: (_, data, _) => Text(data.join(',')),
            emptyText: '暂无歌单',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(InlineError), findsOneWidget);
      // 隐私类错误不把内部 kind 前缀露给用户
      expect(find.text('该用户已设置歌单不可见'), findsOneWidget);
      expect(find.textContaining('[forbidden]'), findsNothing);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('暂无歌单'), findsNothing);
    });

    testWidgets('error: 自定义 errorBuilder 拿到 error 与 retry', (tester) async {
      var loads = 0;
      await tester.pumpWidget(
        host(
          AsyncView<List<String>>(
            load: () {
              loads += 1;
              return failLater<List<String>>(Exception('[auth] 未登录'));
            },
            builder: (_, data, _) => Text(data.join(',')),
            emptyText: '暂无歌单',
            errorBuilder: (_, error, retry) =>
                FullError(message: error.toString(), onRetry: retry),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FullError), findsOneWidget);
      expect(find.textContaining('[auth] 未登录'), findsOneWidget);
      expect(find.byType(InlineError), findsNothing);

      await tester.tap(find.text('重试'));
      await tester.pump(); // 重建一帧, FutureBuilder 才订阅新的 future
      await tester.pump(const Duration(milliseconds: 50)); // 失败落地
      expect(loads, 2);
      expect(find.byType(FullError), findsOneWidget);
    });

    testWidgets('loading: 自定义 loadingBuilder 顶掉默认 spinner', (tester) async {
      final completer = Completer<String>();
      await tester.pumpWidget(
        host(
          AsyncView<String>(
            future: completer.future,
            builder: (_, data, _) => Text(data),
            emptyText: '暂无',
            loadingBuilder: (_) => const LoadingView(message: '正在加载…'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('正在加载…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      completer.complete('好了');
      await tester.pumpAndSettle();
      expect(find.text('好了'), findsOneWidget);
    });
  });

  group('重试 / 刷新', () {
    testWidgets('load 分支: 点「重试」只重新取数一次', (tester) async {
      var loads = 0;
      await tester.pumpWidget(
        host(
          AsyncView<String>(
            load: () {
              loads += 1;
              return failLater<String>(Exception('[auth] 未登录'));
            },
            builder: (_, data, _) => Text(data),
            emptyText: '暂无',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(loads, 1);
      expect(find.byType(InlineError), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pump(); // 重建一帧, FutureBuilder 才订阅新的 future
      await tester.pump(const Duration(milliseconds: 50)); // 失败落地
      expect(loads, 2, reason: '一次点击只应重新取数一次');
      expect(find.byType(InlineError), findsOneWidget);
    });

    testWidgets('load 分支: 网络错误交给 retryNetwork 退避重试', (tester) async {
      var loads = 0;
      await tester.pumpWidget(
        host(
          AsyncView<String>(
            load: () async {
              loads += 1;
              if (loads == 1) throw Exception('[network] os error 104');
              return '重试成功';
            },
            builder: (_, data, _) => Text(data),
            emptyText: '暂无',
          ),
        ),
      );
      // 退避 500ms 后第二次成功
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(loads, 2);
      expect(find.text('重试成功'), findsOneWidget);
    });

    testWidgets('onRetry 优先: 只回调调用方, 不自己取数', (tester) async {
      var loads = 0;
      var retries = 0;
      await tester.pumpWidget(
        host(
          AsyncView<String>(
            load: () async {
              loads += 1;
              throw Exception('[auth] 未登录');
            },
            onRetry: () => retries += 1,
            builder: (_, data, _) => Text(data),
            emptyText: '暂无',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(retries, 1);
      expect(loads, 1, reason: 'onRetry 接管后组件不再自己重新取数');
      expect(find.byType(InlineError), findsOneWidget);
    });

    testWidgets('失败后再成功: 错误态 → 数据态', (tester) async {
      var loads = 0;
      await tester.pumpWidget(
        host(
          AsyncView<List<String>>(
            load: () async {
              loads += 1;
              if (loads == 1) throw Exception('[auth] 登录已过期'); // 文案走中性引导
              return const ['晴天', '以父之名'];
            },
            builder: (_, data, _) => Text(data.join('/')),
            emptyText: '暂无歌曲',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(InlineError), findsOneWidget);
      // auth 类错误不把原文抛给用户(见 net_retry.friendlyError 的 auth 分支)
      expect(find.textContaining('[auth]'), findsNothing);
      expect(find.text('需要登录后才能查看'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(loads, 2);
      expect(find.byType(InlineError), findsNothing);
      expect(find.text('晴天/以父之名'), findsOneWidget);
    });

    testWidgets('future 分支: 父层换 future 就换内容, 不重挂载', (tester) async {
      Widget build(Future<String> future) => host(
        AsyncView<String>(
          future: future,
          builder: (_, data, _) => Text(data),
          emptyText: '暂无',
        ),
      );

      await tester.pumpWidget(build(Future<String>.value('第一版')));
      await tester.pumpAndSettle();
      expect(find.text('第一版'), findsOneWidget);

      // 下拉刷新场景: 父层把新数据包成 future 传下来
      await tester.pumpWidget(build(Future<String>.value('第二版')));
      await tester.pumpAndSettle();
      expect(find.text('第二版'), findsOneWidget);
      expect(find.text('第一版'), findsNothing);
    });

    // 云盘「加载更多」/删除一首的现场: 父层把已完成的 future 换进来,
    // FutureBuilder 仍先给一帧 waiting。若那一帧渲染 LoadingView, 整个 ListView
    // 会被卸载又重建 ⇒ 滚动位置归零(用户翻到第 N 页后每次跳回顶部)。
    // 必须只 pump 一帧才抓得到 —— pumpAndSettle 会跨过这一帧。
    testWidgets('future 分支: 换 future 的那一帧不闪 loading, 滚动位置不丢', (tester) async {
      List<String> rows() => [for (var i = 0; i < 40; i++) '行 $i'];

      Widget build(Future<List<String>> future) => host(
        AsyncView<List<String>>(
          future: future,
          builder: (_, data, _) => ListView(
            key: const ValueKey('list'),
            children: [
              for (final row in data) SizedBox(height: 40, child: Text(row)),
            ],
          ),
          emptyText: '暂无',
        ),
      );

      await tester.pumpWidget(build(Future<List<String>>.value(rows())));
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('list'));
      await tester.drag(list, const Offset(0, -400));
      await tester.pumpAndSettle();
      double offset() => tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .pixels;
      final before = offset();
      expect(before, greaterThan(0), reason: '前置: 列表已滚离顶部');

      // pumpWidget 只泵一帧 = 「换 future 之后的第一帧」
      await tester.pumpWidget(build(Future<List<String>>.value(rows())));
      expect(find.byType(LoadingView), findsNothing, reason: '换 future 不许闪加载态');
      expect(list, findsOneWidget, reason: '旧列表这一帧仍要挂着');

      await tester.pump();
      expect(offset(), before, reason: '列表没被重挂载, 滚动位置保持');
    });

    testWidgets('future 分支: builder 的 reload 在无 onRetry/load 时是空操作', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          AsyncView<String>(
            future: Future<String>.value('稳定'),
            builder: (_, data, reload) =>
                TextButton(onPressed: reload, child: Text(data)),
            emptyText: '暂无',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('稳定'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('稳定'), findsOneWidget);
    });
  });

  group('keepAlive', () {
    Widget list({required bool keepAlive, required VoidCallback onLoad}) =>
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              itemCount: 60,
              itemBuilder: (_, i) {
                if (i != 0) return SizedBox(height: 40, child: Text('行 $i'));
                return SizedBox(
                  height: 40,
                  child: AsyncView<String>(
                    keepAlive: keepAlive,
                    load: () async {
                      onLoad();
                      return '区块内容';
                    },
                    builder: (_, data, _) => Text(data),
                    emptyText: '暂无',
                  ),
                );
              },
            ),
          ),
        );

    testWidgets('keepAlive=true: 滚出视野再回来不重新取数', (tester) async {
      var loads = 0;
      await tester.pumpWidget(list(keepAlive: true, onLoad: () => loads += 1));
      await tester.pumpAndSettle();
      expect(loads, 1);

      await tester.drag(find.byType(ListView), const Offset(0, -1500));
      await tester.pumpAndSettle();
      expect(find.text('区块内容'), findsNothing, reason: '区块已滚出视野');

      await tester.drag(find.byType(ListView), const Offset(0, 1500));
      await tester.pumpAndSettle();
      expect(find.text('区块内容'), findsOneWidget);
      expect(loads, 1, reason: 'keepAlive 下回来不该重新转圈取数');
    });

    testWidgets('keepAlive=false: 滚出视野被回收, 回来重新取数', (tester) async {
      var loads = 0;
      await tester.pumpWidget(list(keepAlive: false, onLoad: () => loads += 1));
      await tester.pumpAndSettle();
      expect(loads, 1);

      await tester.drag(find.byType(ListView), const Offset(0, -1500));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 1500));
      await tester.pumpAndSettle();
      expect(find.text('区块内容'), findsOneWidget);
      expect(loads, 2, reason: '未 keepAlive 时被回收, 回来必须重新取数');
    });
  });
}
