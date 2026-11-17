import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/play_queue_sheet.dart';
import 'package:minincm/src/queue.dart';
import 'package:minincm/src/rust/api.dart' as rust;

import 'support/fakes.dart';

// 共享工厂 + 按 id 派生的艺人/专辑(队列断言会读这些字段)口径。
rust.SongDto song(int id, String name) => fakeSong(
  id: id,
  name: name,
  artist: '艺人$id',
  artistId: 900 + id,
  album: '专辑$id',
  albumId: 800 + id,
  durationMs: 200000,
);

/// 模拟 HomePage 的接线: 面板 + 真 PlayQueue, 记录"跳播/删当前项"的副作用
class QueueHarness extends StatefulWidget {
  const QueueHarness({super.key, required this.names, this.startAt = 0});

  final List<String> names;
  final int startAt;

  @override
  State<QueueHarness> createState() => QueueHarnessState();
}

class QueueHarnessState extends State<QueueHarness> {
  late final PlayQueue<rust.SongDto> queue = PlayQueue<rust.SongDto>()
    ..setAll([
      for (var i = 0; i < widget.names.length; i++)
        song(i + 1, widget.names[i]),
    ], startAt: widget.startAt);

  /// "换歌"记录(点项跳播 / 删当前项后自动播下一首)
  final List<String> played = [];

  /// 队列被删空 / 被清空 → 停播
  final List<String> stopped = [];

  /// 拖拽排序回调记录
  final List<(int, int)> moved = [];

  /// 「清空」回调次数
  int cleared = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PlayQueueSheet(
      items: queue.items,
      index: queue.index,
      onSelect: (s) {
        queue.jumpToItem(s);
        played.add(s.name);
        setState(() {});
      },
      onMove: (from, to) {
        moved.add((from, to));
        setState(() => queue.moveTo(from, to));
      },
      onClear: () {
        cleared += 1;
        setState(() => queue.clear());
        stopped.add('stop');
      },
      onRemove: (s, wasCurrent) {
        final i = queue.items.indexOf(s);
        if (i < 0) return;
        setState(() => queue.removeAt(i));
        if (!wasCurrent) return;
        final next = queue.current;
        if (next == null) {
          stopped.add('stop');
        } else {
          played.add(next.name);
        }
        setState(() {});
      },
    ),
  );
}

QueueHarnessState harness(WidgetTester tester) =>
    tester.state<QueueHarnessState>(find.byType(QueueHarness));

/// 当前项: 面板里 high-light 的那一行(带 volume_up 图标)
String? currentTitle(WidgetTester tester) {
  final icon = find.byIcon(Icons.volume_up);
  if (icon.evaluate().isEmpty) return null;
  final tile = find.ancestor(of: icon, matching: find.byType(ListTile));
  final text = find.descendant(of: tile, matching: find.byType(Text)).first;
  return tester.widget<Text>(text).data;
}

void main() {
  testWidgets('打开面板渲染当前项: 高亮当前项 + 曲目数 + 顺序', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: QueueHarness(names: ['第一首', '第二首', '第三首'], startAt: 1),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('当前播放队列'), findsOneWidget);
    expect(find.text('3 首'), findsOneWidget);
    expect(find.text('第一首'), findsOneWidget);
    expect(find.text('第二首'), findsOneWidget);
    expect(find.text('第三首'), findsOneWidget);

    // 当前项(index=1)高亮且有 playing 图标
    expect(currentTitle(tester), '第二首');
    final tile = tester.widget<ListTile>(find.widgetWithText(ListTile, '第二首'));
    expect(tile.selected, isTrue);
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, '第一首')).selected,
      isFalse,
    );
  });

  testWidgets('点项切歌: 回调选中曲目并成为当前项', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: QueueHarness(names: ['第一首', '第二首', '第三首'], startAt: 0),
      ),
    );
    await tester.pumpAndSettle();
    expect(currentTitle(tester), '第一首');

    await tester.tap(find.text('第三首'));
    await tester.pumpAndSettle();

    expect(harness(tester).played, ['第三首']);
    expect(harness(tester).queue.current!.name, '第三首');
    expect(currentTitle(tester), '第三首');
  });

  testWidgets('删除非当前项: 列表移除且不换歌, 当前项下标跟着修正', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: QueueHarness(names: ['第一首', '第二首', '第三首'], startAt: 1),
      ),
    );
    await tester.pumpAndSettle();

    // 滑删(左滑)第一条
    await tester.drag(find.text('第一首'), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(find.text('第一首'), findsNothing);
    expect(find.text('2 首'), findsOneWidget);
    expect(harness(tester).played, isEmpty, reason: '删的不是当前项, 不换歌');
    expect(harness(tester).queue.index, 0, reason: '当前下标左移一位');
    expect(harness(tester).queue.current!.name, '第二首');
    expect(currentTitle(tester), '第二首');
  });

  testWidgets('删除当前项: 顶上来的下一首成为当前并开始播放', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: QueueHarness(names: ['第一首', '第二首', '第三首'], startAt: 1),
      ),
    );
    await tester.pumpAndSettle();

    // 长按当前项 → 确认移除
    await tester.longPress(find.text('第二首'));
    await tester.pumpAndSettle();
    expect(find.text('从播放队列移除?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '移除'));
    await tester.pumpAndSettle();

    expect(find.text('第二首'), findsNothing);
    expect(harness(tester).queue.current!.name, '第三首');
    expect(harness(tester).played, ['第三首'], reason: '删当前项要明确换播下一首');
    expect(harness(tester).stopped, isEmpty);
    expect(currentTitle(tester), '第三首');
  });

  testWidgets('删光队列: 空态文案 + 停播', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: QueueHarness(names: ['唯一一首'], startAt: 0)),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('唯一一首'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '移除'));
    await tester.pumpAndSettle();

    expect(harness(tester).stopped, ['stop']);
    expect(harness(tester).queue.isEmpty, isTrue);
    expect(harness(tester).queue.current, isNull);
    expect(find.textContaining('播放队列是空的'), findsOneWidget);
    expect(find.text('0 首'), findsOneWidget);
  });

  testWidgets('拖拽手柄排序: 顺序改变, 当前曲目不变且不换歌', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: QueueHarness(names: ['第一首', '第二首', '第三首'], startAt: 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(currentTitle(tester), '第二首');

    // 把第一首拖到队列末尾
    final handle = find.descendant(
      of: find.widgetWithText(ListTile, '第一首'),
      matching: find.byIcon(Icons.drag_handle),
    );
    expect(handle, findsOneWidget, reason: '每行都要有拖拽手柄');
    // 拖拽距离按**实测行高**算(列表行纵向 pitch 统一到 rowExtentFor 后不再是 64,
    // 写死 60+60 只会跨一行): 每次推进 1.5 行, 共 3 行。
    final rowH = tester.getSize(find.byType(ListTile).first).height;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    // 分多次小步移动: ReorderableListView 只在跨过行的中点时换位, 一次跳 2 行会被
    // 当成"还没跨过相邻行"。
    for (var i = 0; i < 24; i++) {
      await gesture.moveBy(Offset(0, rowH * 0.1));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(harness(tester).queue.items.map((s) => s.name).toList(), [
      '第二首',
      '第三首',
      '第一首',
    ]);
    expect(harness(tester).moved, isNotEmpty);
    expect(harness(tester).played, isEmpty, reason: '只排序不换歌');
    expect(harness(tester).queue.current!.name, '第二首');
    expect(currentTitle(tester), '第二首');
    expect(harness(tester).queue.index, 0, reason: '当前下标跟着左移到 0');
  });

  testWidgets('清空队列: 二次确认后清空并停播', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: QueueHarness(names: ['第一首', '第二首'], startAt: 0)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();
    expect(find.text('清空播放队列?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();

    expect(harness(tester).cleared, 1);
    expect(harness(tester).queue.isEmpty, isTrue);
    expect(harness(tester).stopped, ['stop']);
    expect(find.text('0 首'), findsOneWidget);
    expect(find.textContaining('播放队列是空的'), findsOneWidget);
  });

  testWidgets('清空队列: 点取消什么都不做', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: QueueHarness(names: ['第一首', '第二首'], startAt: 0)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(harness(tester).cleared, 0);
    expect(harness(tester).queue.items.length, 2);
    expect(find.text('2 首'), findsOneWidget);
  });

  testWidgets('空队列: 直接显示空态文案, 不渲染列表', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: QueueHarness(names: [], startAt: 0)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('播放队列是空的'), findsOneWidget);
    expect(find.text('0 首'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('300dp + 1.25 字号: 队列面板不溢出且当前项高亮', (tester) async {
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
        home: const QueueHarness(
          names: ['第一首', '一首名字特别特别长的歌用于窄屏回归测试', '第三首'],
          startAt: 0,
        ),
      ),
    );
    // 长歌名会触发 marquee 无限滚动, 不能 pumpAndSettle, 分步 pump
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.text('当前播放队列'), findsOneWidget);
    expect(currentTitle(tester), '第一首');
  });

  // A7 回归: 行尾「移除」原先用默认 IconButton(命中区 48dp), 与 leading 序号列
  // 叠加后 300dp 下标题被压到个位数宽度。现在宽度收到 40dp, 高度仍 48 保命中区。
  testWidgets('300dp x1.625: 行尾移除按钮宽 40dp(高仍 48), 不横向溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.625;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: QueueHarness(
          names: ['第一首', '一首名字特别特别长的歌用于窄屏回归测试', '第三首'],
          startAt: 0,
        ),
      ),
    );
    // 长歌名会触发 marquee 无限滚动, 不能 pumpAndSettle
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull, reason: '队列行不允许 overflow');
    final button = tester.getSize(
      find.widgetWithIcon(IconButton, Icons.delete_outline).first,
    );
    expect(button.width, 40, reason: '默认 48dp 会吃掉标题区, 必须收到 40dp');
    expect(button.height, greaterThanOrEqualTo(48), reason: '命中区高度不能缩');
  });

  // 用户 2026-11-15 截图: 队列面板标题被行尾挤成「当前播…」, 且行内序号/操作
  // 把中间的歌名压得很窄。这两条用例锁住排版口径: 标题整句可见 + 序号贴左、
  // 删除/拖拽贴右、中间留出空间(只改其中一处就会退回旧问题)。
  testWidgets('360dp + 1.5 字号: 标题「当前播放队列」完整显示, 不被行尾挤断', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: const QueueHarness(
          names: ['第一首', '第二首', '第三首', '第四首', '第五首'],
          startAt: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final title = find.text('当前播放队列');
    expect(title, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(title);
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: '标题不允许 ellipsis: 行尾只能留计数 + 两个 40dp 动作按钮',
    );
    expect(find.text('5 首'), findsOneWidget, reason: '计数仍在标题行右侧');
  });

  testWidgets('360dp: 序号贴左 / 删除与拖拽贴右 / 中间给歌名', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: QueueHarness(names: ['第一首', '第二首'], startAt: 0)),
    );
    await tester.pumpAndSettle();

    final row = tester.getRect(find.byType(ListTile).first);
    // 序号列: 4dp 行留白 + 28dp 序号列 ⇒ 标题从 ~40dp 起(旧口径 60dp)
    final titleRect = tester.getRect(find.text('第一首').first);
    expect(titleRect.left, lessThanOrEqualTo(44), reason: '序号左移, 歌名起点跟着左移');
    final del = tester.getRect(
      find.widgetWithIcon(IconButton, Icons.delete_outline).first,
    );
    final handle = tester.getRect(find.byIcon(Icons.drag_handle).first);
    expect(del.left, greaterThan(row.width * 0.78), reason: '删除按钮贴右');
    expect(handle.right, greaterThan(row.width - 12), reason: '拖拽手柄贴到右边缘');
    // 中间可用宽度 = 歌名起点 → 删除按钮左边缘, 必须比旧的 ~210dp 明显宽
    expect(
      del.left - titleRect.left,
      greaterThan(240),
      reason: '中间内容(歌名+徽标)要拿到 ≥240dp',
    );
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
