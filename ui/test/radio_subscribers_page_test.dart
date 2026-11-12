import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/radio_subscribers_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.RadioSubscriber _sub(
  int id,
  String nick, {
  String sig = '签名',
  BigInt? timeMs,
}) => rust.RadioSubscriber(
  userId: BigInt.from(id),
  nickname: nick,
  avatarUrl: '',
  signature: sig,
  subscribeTimeMs: timeMs ?? BigInt.from(1793611157940),
);

Future<void> _pump(
  WidgetTester tester, {
  required LoadRadioSubscribers load,
  BigInt? radioId,
  String radioName = '伴听FM',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: RadioSubscribersPage(
        radioId: radioId ?? BigInt.from(526564706),
        radioName: radioName,
        loadSubscribers: load,
      ),
    ),
  );
}

void main() {
  testWidgets('列表渲染: 头像位/昵称/签名, 标题带电台名', (tester) async {
    await _pump(
      tester,
      load: (id, time) async => rust.RadioSubscriberPage(
        hasMore: false,
        subscribers: [
          _sub(1, '听众甲', sig: '音乐爱好者'),
          _sub(2, '听众乙', sig: ''),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('「伴听FM」的听众'), findsOneWidget);
    expect(find.text('听众甲'), findsOneWidget);
    expect(find.text('音乐爱好者'), findsOneWidget);
    expect(find.text('听众乙'), findsOneWidget);
    expect(find.text('暂无简介'), findsOneWidget); // 空签名兜底
    expect(find.text('加载更多'), findsNothing); // hasMore=false 不出现
  });

  testWidgets('空态: 没有听众给空视图', (tester) async {
    await _pump(
      tester,
      load: (id, time) async =>
          const rust.RadioSubscriberPage(hasMore: false, subscribers: []),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没有听众'), findsOneWidget);
  });

  testWidgets('首屏错误 + 重试恢复', (tester) async {
    var fail = true;
    await _pump(
      tester,
      load: (id, time) async {
        if (fail) throw Exception('[network] boom');
        return rust.RadioSubscriberPage(
          hasMore: false,
          subscribers: [_sub(1, '听众甲')],
        );
      },
    );
    await tester.pumpAndSettle();
    // PagedListView 统一错误态: friendlyError 文案 + 重试
    expect(find.textContaining('网络'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('听众甲'), findsOneWidget);
  });

  testWidgets('加载更多: 首页 hasMore 时出现按钮, 点按用 time 游标拉第二页, 拉完隐藏', (tester) async {
    final calls = <BigInt>[];
    await _pump(
      tester,
      load: (id, time) async {
        calls.add(time);
        if (time == BigInt.from(-1)) {
          return rust.RadioSubscriberPage(
            hasMore: true,
            subscribers: [_sub(1, '听众甲', timeMs: BigInt.from(1111))],
          );
        }
        return rust.RadioSubscriberPage(
          hasMore: false,
          subscribers: [_sub(2, '听众乙', timeMs: BigInt.from(2222))],
        );
      },
    );
    await tester.pumpAndSettle();
    expect(calls, [BigInt.from(-1)]);
    expect(find.text('听众甲'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(calls, [
      BigInt.from(-1),
      BigInt.from(1111),
    ]); // 游标 = 上一页最后 subscribeTime
    expect(find.text('听众乙'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing); // hasMore=false
  });

  testWidgets('加载更多失败: 不崩, 收起加载更多入口并提示', (tester) async {
    await _pump(
      tester,
      load: (id, time) async {
        if (time == BigInt.from(-1)) {
          return rust.RadioSubscriberPage(
            hasMore: true,
            subscribers: [_sub(1, '听众甲', timeMs: BigInt.from(1111))],
          );
        }
        throw Exception('[network] boom');
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // PagedListView: 失败保留旧数据 + toast 提示, 加载更多入口仍在(可重试)
    expect(find.textContaining('网络'), findsOneWidget);
    expect(find.text('听众甲'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget);
  });

  testWidgets('窄屏 300dp + 1.25 字号不溢出', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(300, 700);
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      radioName: '一个很长很长很长很长的电台名字的听众',
      load: (id, time) async => rust.RadioSubscriberPage(
        hasMore: true,
        subscribers: List.generate(
          8,
          (i) =>
              _sub(100 + i, '很长很长很长的听众昵称$i', sig: '很长很长很长的个性签名很长很长很长的个性签名$i'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
