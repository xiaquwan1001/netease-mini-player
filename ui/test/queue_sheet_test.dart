import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/queue.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song(int id, String name) => rust.SongDto(
      id: BigInt.from(id),
      name: name,
      artist: '歌手$id',
      artistId: BigInt.from(900 + id),
      album: '专辑$id',
      albumId: BigInt.from(800 + id),
      coverUrl: null,
      durationMs: BigInt.from(200000),
      fee: 0,
      vip: false,
      paid: false,
      playable: true,
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
    ..setAll([for (var i = 0; i < widget.names.length; i++) song(i + 1, widget.names[i])],
        startAt: widget.startAt);

  /// "换歌"记录(点项跳播 / 删当前项后自动播下一首)
  final List<String> played = [];

  /// 队列被删空 → 停播
  final List<String> stopped = [];

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
    await tester.pumpWidget(const MaterialApp(
      home: QueueHarness(names: ['第一首', '第二首', '第三首'], startAt: 1),
    ));
    await tester.pumpAndSettle();

    expect(find.text('当前播放队列'), findsOneWidget);
    expect(find.text('共 3 首'), findsOneWidget);
    expect(find.text('第一首'), findsOneWidget);
    expect(find.text('第二首'), findsOneWidget);
    expect(find.text('第三首'), findsOneWidget);

    // 当前项(index=1)高亮且有 playing 图标
    expect(currentTitle(tester), '第二首');
    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '第二首'),
    );
    expect(tile.selected, isTrue);
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, '第一首')).selected,
      isFalse,
    );
  });

  testWidgets('点项切歌: 回调选中曲目并成为当前项', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: QueueHarness(names: ['第一首', '第二首', '第三首'], startAt: 0),
    ));
    await tester.pumpAndSettle();
    expect(currentTitle(tester), '第一首');

    await tester.tap(find.text('第三首'));
    await tester.pumpAndSettle();

    expect(harness(tester).played, ['第三首']);
    expect(harness(tester).queue.current!.name, '第三首');
    expect(currentTitle(tester), '第三首');
  });

  testWidgets('删除非当前项: 列表移除且不换歌, 当前项下标跟着修正', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: QueueHarness(names: ['第一首', '第二首', '第三首'], startAt: 1),
    ));
    await tester.pumpAndSettle();

    // 滑删(左滑)第一条
    await tester.drag(find.text('第一首'), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(find.text('第一首'), findsNothing);
    expect(find.text('共 2 首'), findsOneWidget);
    expect(harness(tester).played, isEmpty, reason: '删的不是当前项, 不换歌');
    expect(harness(tester).queue.index, 0, reason: '当前下标左移一位');
    expect(harness(tester).queue.current!.name, '第二首');
    expect(currentTitle(tester), '第二首');
  });

  testWidgets('删除当前项: 顶上来的下一首成为当前并开始播放', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: QueueHarness(names: ['第一首', '第二首', '第三首'], startAt: 1),
    ));
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
    await tester.pumpWidget(const MaterialApp(
      home: QueueHarness(names: ['唯一一首'], startAt: 0),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('唯一一首'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '移除'));
    await tester.pumpAndSettle();

    expect(harness(tester).stopped, ['stop']);
    expect(harness(tester).queue.isEmpty, isTrue);
    expect(harness(tester).queue.current, isNull);
    expect(find.textContaining('播放队列是空的'), findsOneWidget);
    expect(find.text('共 0 首'), findsOneWidget);
  });

  testWidgets('空队列: 直接显示空态文案, 不渲染列表', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: QueueHarness(names: [], startAt: 0),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('播放队列是空的'), findsOneWidget);
    expect(find.text('共 0 首'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });
}
