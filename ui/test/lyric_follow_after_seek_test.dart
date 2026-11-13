import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/word_lyric_view.dart';

/// 回归: 歌词跟随(lyric follow)在 seek 之后的行为.
///
/// 对应 main.dart 的三个口径:
/// 1. seek(拖/点进度条)之后 follow 必须恢复为 true 并滚到新当前句;
/// 2. "用户手动滑动歌词"只认歌词列表自身的 DragStart(ScrollStartNotification
///    .dragDetails != null), 自动跟随的 animateTo 不发 dragDetails, 不会误判;
/// 3. follow 恢复(false -> true)时, 即使当前句没变也要立刻滚回当前行
///    (WordLyricView.didUpdateWidget), 不用等下一句.

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(child: SizedBox(height: 400, child: child)),
  ),
);

const double _extent = 56;

List<WordLyricLineData> _lines(int n) => [
  for (var i = 0; i < n; i++)
    WordLyricLineData(
      startMs: i * 1000,
      endMs: i * 1000 + 900,
      words: [
        WordLyricWord(
          startMs: i * 1000,
          endMs: i * 1000 + 900,
          text: 'line-$i',
        ),
      ],
    ),
];

/// 复刻 main.dart 的歌词跟随骨架: NotificationListener 判拖动暂停 +
/// WordLyricView(autoScroll) 自动滚动; seek()/locate() 对应主界面同名路径.
class FollowHarness extends StatefulWidget {
  const FollowHarness({super.key, required this.lines, required this.position});

  final List<WordLyricLineData> lines;
  final ValueNotifier<int> position;

  @override
  State<FollowHarness> createState() => FollowHarnessState();
}

class FollowHarnessState extends State<FollowHarness> {
  bool follow = true;
  final controller = ScrollController();

  // 对应 main._seekTo: seek 后无条件恢复跟随(位置由调用方改 notifier)
  void seek(int ms) {
    setState(() => follow = true);
    widget.position.value = ms;
  }

  // 对应 main._locateCurrentLyric: 点"定位到当前歌词"恢复跟随
  void locate() {
    setState(() => follow = true);
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollStartNotification && n.dragDetails != null) {
          setState(() => follow = false);
        }
        return false;
      },
      child: WordLyricView(
        lines: widget.lines,
        positionMs: widget.position,
        controller: controller,
        itemExtent: _extent,
        autoScroll: follow,
      ),
    );
  }
}

/// 第 [i] 句居中时的目标偏移(与 WordLyricView._scrollTo 同公式)
double _targetOffset(int i, double viewport) {
  final raw = i * _extent - (viewport - _extent) / 2;
  return raw.clamp(0.0, 30 * _extent + 16 - viewport);
}

void main() {
  final lines = _lines(30);

  Future<FollowHarnessState> pump(WidgetTester tester, int initialMs) async {
    final position = ValueNotifier<int>(initialMs);
    await tester.pumpWidget(
      _host(FollowHarness(lines: lines, position: position)),
    );
    await tester.pumpAndSettle();
    return tester.state<FollowHarnessState>(find.byType(FollowHarness));
  }

  testWidgets('seek 后 follow 仍为 true 且滚动到对应句', (tester) async {
    final state = await pump(tester, 500);
    expect(state.follow, isTrue);
    expect(state.controller.offset, 0);

    state.seek(20000); // 对应拖进度条到第 20 句
    await tester.pumpAndSettle();

    expect(state.follow, isTrue, reason: 'seek 之后必须恢复自动跟随');
    expect(
      state.controller.offset,
      _targetOffset(20, 400),
      reason: 'seek 后列表要滚到新当前句',
    );
  });

  testWidgets('歌词区自身拖动后 follow 暂停, 下一句不抢滚动', (tester) async {
    final state = await pump(tester, 500);

    // 手指拖歌词列表(只会是列表自身的 DragStart: animateTo 无 dragDetails)
    await tester.drag(find.byType(WordLyricView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final afterDrag = state.controller.offset;
    expect(afterDrag, greaterThan(0));
    expect(state.follow, isFalse, reason: '用户拖歌词要暂停跟随');

    // 播放到下一句(仅推进位置, 不走 seek 路径): follow 已暂停, 不得把列表拽回去
    state.widget.position.value = 25000;
    await tester.pumpAndSettle();

    expect(state.follow, isFalse);
    expect(state.controller.offset, afterDrag, reason: '暂停后下一句不能抢滚动');
  });

  testWidgets('点"定位到当前歌词"恢复跟随并回到当前句', (tester) async {
    final state = await pump(tester, 500);

    await tester.drag(find.byType(WordLyricView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(state.follow, isFalse);

    // 播放继续推进到第 25 句(暂停期间不滚动), 再点定位
    state.widget.position.value = 25000;
    await tester.pumpAndSettle();
    state.locate();
    await tester.pumpAndSettle();

    expect(state.follow, isTrue);
    expect(
      state.controller.offset,
      _targetOffset(25, 400),
      reason: '定位要恢复跟随并滚回当前句(即使句号没变过)',
    );
  });

  testWidgets('连续两次 seek 都能定位, 不回退成只定位一次', (tester) async {
    final state = await pump(tester, 500);

    state.seek(10000);
    await tester.pumpAndSettle();
    final first = state.controller.offset;
    expect(state.follow, isTrue);
    expect(first, _targetOffset(10, 400));

    state.seek(22000);
    await tester.pumpAndSettle();
    expect(state.follow, isTrue, reason: '第二次 seek 后跟随仍在');
    expect(
      state.controller.offset,
      _targetOffset(22, 400),
      reason: '连续 seek 每次都要重新定位',
    );
  });

  testWidgets('300dp + 1.25 字号: seek 后跟随不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final position = ValueNotifier<int>(500);
    addTearDown(position.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                height: 400,
                child: FollowHarness(lines: lines, position: position),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state<FollowHarnessState>(find.byType(FollowHarness));
    state.seek(20000);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(state.follow, isTrue);
    expect(state.controller.offset, _targetOffset(20, 400));
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
