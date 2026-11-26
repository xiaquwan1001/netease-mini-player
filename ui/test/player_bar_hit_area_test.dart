// 播放条的触摸可用性(2026-11-26 两份交互审计):
//   · 安卓 P2#4: 一排 6 个控件(34/38dp)、封面(40dp)、进度条整块(20dp 高)都难点中;
//   · Linux P2#8: 进度条"盲拖"—— 拖动中没有目标时间, 悬停拇指也不变大;
//   · Linux P2#5: 播放条右键没有任何动作(列表行右键会弹「歌曲操作」)。
//
// 口径(取舍写在 player_bar.dart 的 `_barIcon` / `_ProgressSlider` 注释里):
//   命中**高度**一律 >= 48dp(不跟宽度一起提: 300dp 窄屏一排 6 个 48dp 宽会溢出);
//   进度条的 48dp 必须是**真**命中带(点上去真的 seek), 不是 Slider.padding 撑出来的空白;
//   拖动才弹目标时间(常显会遮住上方内容), 悬停时拇指 5 → 8。
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/cover_art.dart';
import 'package:minincm/src/platform_is.dart' show debugForceAndroid;
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/player_bar.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

const String _kName = '歌名甲';
const String _kArtist = '艺人乙';

PlayerBarData _data({double? dragMs}) => PlayerBarData(
  player: PlayerView(
    trackId: BigInt.one,
    playing: true,
    positionMs: BigInt.from(30 * 1000),
    durationMs: BigInt.from(200 * 1000),
    volume: 1.0,
  ),
  current: rust.SongDto(
    id: BigInt.one,
    name: _kName,
    artist: _kArtist,
    artistId: BigInt.one,
    album: '专辑丙',
    albumId: BigInt.one,
    coverUrl: null,
    durationMs: BigInt.from(200 * 1000),
    fee: 0,
    vip: false,
    paid: false,
    playable: true,
  ),
  liked: false,
  queueIndex: 1,
  queueLength: 10,
  dragMax: dragMs == null ? null : 200 * 1000,
  dragMs: dragMs,
);

PlayerBarActions _actions({
  void Function(double ms)? onSeekStart,
  void Function(double ms)? onSeekChanging,
  void Function(double ms)? onSeekEnd,
  VoidCallback? onMenu,
}) => PlayerBarActions(
  onSeekStart: onSeekStart ?? (_) {},
  onSeekChanging: onSeekChanging ?? (_) {},
  onSeekEnd: onSeekEnd ?? (_) {},
  onToggleLyrics: () {},
  onOpenDetail: () {},
  onToggleLike: () {},
  onCycleMode: () {},
  onOpenQueue: () {},
  onToggle: () {},
  onPrevious: () {},
  onNext: () {},
  onMenu: onMenu,
);

/// 模拟 HomePage 对拖动的回写(播放条自己不存拖动状态, 见 PlayerBarData.dragMs):
/// 拖动中把 ms 记下来重建一次, 于是 Slider.label 才是"真正的目标时间"。
class _DragHost extends StatefulWidget {
  const _DragHost({this.onMenu, this.onSeekStart, this.onSeekEnd});

  final VoidCallback? onMenu;
  final void Function(double ms)? onSeekStart;
  final void Function(double ms)? onSeekEnd;

  @override
  State<_DragHost> createState() => _DragHostState();
}

class _DragHostState extends State<_DragHost> {
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    return MiniPlayerBar(
      data: _data(dragMs: _dragMs),
      actions: _actions(
        onSeekStart: widget.onSeekStart,
        onSeekEnd: widget.onSeekEnd,
        onSeekChanging: (ms) => setState(() => _dragMs = ms),
        onMenu: widget.onMenu,
      ),
      absorbBottomInset: false,
    );
  }
}

Future<void> _pump(
  WidgetTester tester, {
  double width = 400,
  VoidCallback? onMenu,
  void Function(double ms)? onSeekStart,
  void Function(double ms)? onSeekEnd,
}) async {
  tester.view.physicalSize = Size(width, 240);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 240)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: _DragHost(
              onMenu: onMenu,
              onSeekStart: onSeekStart,
              onSeekEnd: onSeekEnd,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 播放条右侧 6 个控件的点击区矩形(红心/顺序/上一首/播放/下一首/队列)
List<Rect> _controlRects(WidgetTester tester) => [
  for (final e in tester.elementList(find.byType(IconButton)))
    tester.getRect(find.byWidget(e.widget)),
];

/// 进度条当前的主题(取 Slider 最近的那一层, 即播放条自己 copyWith 出来的)
SliderThemeData _sliderTheme(WidgetTester tester) => tester
    .widget<SliderTheme>(
      find
          .ancestor(of: find.byType(Slider), matching: find.byType(SliderTheme))
          .first,
    )
    .data;

double _thumbRadius(WidgetTester tester) =>
    (_sliderTheme(tester).thumbShape! as RoundSliderThumbShape)
        .enabledThumbRadius;

/// 封面的手势命中区(封面本体仍 40dp, 外面那圈 Padding 才是命中带)
Rect _coverHitRect(WidgetTester tester) => tester.getRect(
  find
      .ancestor(
        of: find.byType(CoverArt),
        matching: find.byType(GestureDetector),
      )
      .first,
);

void main() {
  group('命中高度 >= 48dp(宽度保持手机预算)', () {
    testWidgets('6 个控件: 高 48, 宽仍是 34/38', (tester) async {
      await _pump(tester);

      final rects = _controlRects(tester);
      expect(rects.length, 6, reason: '控件数变了(红心/顺序/上一首/播放/下一首/队列)');
      for (final r in rects) {
        expect(r.height, greaterThanOrEqualTo(48), reason: '控件命中高度不足 48dp');
      }
      // 宽度不跟着提到 48: 300dp 窄屏一排 6 个 48 会溢出(见 _barIcon 注释)。
      // 播放键 38, 其余 34 —— 这条是"别顺手把宽度也放大"的护栏。
      expect(rects.map((r) => r.width).toList(), [34, 34, 34, 38, 34, 34]);
    });

    testWidgets('封面: 命中区 48 高, 图形本体仍是 40dp', (tester) async {
      await _pump(tester);

      expect(_coverHitRect(tester).height, greaterThanOrEqualTo(48));
      // 视觉尺寸不变(用户口径: 播放条别再长高太多, 命中靠透明的边)
      expect(tester.getSize(find.byType(CoverArt)), const Size(40, 40));
    });

    testWidgets('进度条: 盒高 = kProgressHitHeight(48), 且紧贴播放条顶部', (tester) async {
      await _pump(tester);

      final bar = tester.getRect(find.byType(MiniPlayerBar));
      final slider = tester.getRect(find.byType(Slider));
      expect(kProgressHitHeight, greaterThanOrEqualTo(48));
      expect(slider.height, kProgressHitHeight);
      expect(
        slider.top - bar.top,
        lessThan(1),
        reason: '进度条盒必须贴播放条顶部(上面不许再长白条)',
      );
      // 播放条总高 = 进度条 48 + 信息行 48 + 尾部 2(信息行的 48 由控件命中高度决定)。
      // 62 → 98 的增高是本次触控修复的代价, 底栏总量仍远低于 bottom_chrome 的 120 上限。
      expect(bar.height, 98);
    });

    testWidgets('300dp 窄屏: 命中高度同样 48, 且整行不溢出', (tester) async {
      await _pump(tester, width: 300);

      for (final r in _controlRects(tester)) {
        expect(r.height, greaterThanOrEqualTo(48));
      }
      expect(_coverHitRect(tester).height, greaterThanOrEqualTo(48));
      expect(tester.getRect(find.byType(Slider)).height, kProgressHitHeight);
      expect(tester.takeException(), isNull, reason: '300dp 下播放条行内溢出');
    });
  });

  group('进度条命中带是"真的"', () {
    testWidgets('点在轨道上下方的空白里也能 seek(命中带不是 Slider.padding 的空洞)', (tester) async {
      final starts = <double>[];
      final ends = <double>[];
      await _pump(tester, onSeekStart: starts.add, onSeekEnd: ends.add);

      final slider = tester.getRect(find.byType(Slider));
      // 轨道只有 2dp、拇指半径 5; 上下各 ~19dp 是纯命中带。各点一次(横向也挪开,
      // 否则第二次点的值没变, Slider 不会回调)。
      for (final offset in const [Offset(-80, -16), Offset(80, 16)]) {
        await tester.tapAt(slider.center + offset);
        await tester.pumpAndSettle();
      }
      expect(starts.length, 2, reason: '命中带内的点击没有触发 seek(命中区还是原来那 2dp/20dp)');
      expect(ends.length, 2);
      expect(starts.every((ms) => ms > 0 && ms < 200 * 1000), isTrue);
    });
  });

  group('拖动时显示目标时间 / 悬停拇指放大', () {
    testWidgets('拖动中 label 跟着目标时间走, 且只在拖动时弹气泡', (tester) async {
      await _pump(tester);

      // 结构口径: 气泡只在拖动中显示, 文案是父层算好的目标时间(mm:ss)
      final theme = _sliderTheme(tester);
      expect(theme.showValueIndicator, ShowValueIndicator.onDrag);
      expect(theme.trackHeight, 2, reason: '轨道视觉高度不变(2dp)');
      expect(tester.widget<Slider>(find.byType(Slider)).label, '00:30');

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Slider)),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump();

      final dragging = tester.widget<Slider>(find.byType(Slider)).label!;
      expect(dragging, isNot('00:30'), reason: '拖动中要显示目标时间(以前全程盲拖)');
      expect(RegExp(r'^\d{2}:\d{2}$').hasMatch(dragging), isTrue);

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('桌面悬停: 拇指半径 5 → 8', (tester) async {
      await _pump(tester);
      expect(_thumbRadius(tester), 5);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(Slider)));
      await tester.pumpAndSettle();
      expect(_thumbRadius(tester), 8, reason: '悬停要给"这条能拖"的可点提示');

      await mouse.moveTo(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(_thumbRadius(tester), 5, reason: '移出后要收回 5');
    });
  });

  group('播放键触感(仅 Android)', () {
    /// 抓 SystemChannels.platform 上我们发的 selectionClick 触感
    List<MethodCall> captureHaptics(WidgetTester tester) {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate' &&
              call.arguments == 'HapticFeedbackType.selectionClick') {
            calls.add(call);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      return calls;
    }

    testWidgets('Android: 点播放键发一次 selectionClick', (tester) async {
      debugForceAndroid = true;
      addTearDown(() => debugForceAndroid = false);
      final haptics = captureHaptics(tester);
      await _pump(tester);

      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();

      expect(haptics.length, 1, reason: '播放/暂停按下要给一次触感确认');
    });

    testWidgets('桌面(Linux/Windows): 点播放键不发触感', (tester) async {
      final haptics = captureHaptics(tester);
      await _pump(tester);

      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();

      expect(haptics, isEmpty, reason: '桌面没有振动器, 不该发触感调用');
    });
  });

  group('桌面右键 = 现有「歌曲操作」(onMenu)', () {
    testWidgets('右键封面 = onMenu', (tester) async {
      var menu = 0;
      await _pump(tester, onMenu: () => menu++);

      await tester.tap(find.byType(CoverArt), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(menu, 1);
    });

    testWidgets('右键信息区(歌名) = onMenu', (tester) async {
      var menu = 0;
      // 700(中档)才有歌名/艺人文字块; 窄档只剩封面, 右键封面那条已单独覆盖
      await _pump(tester, width: 700, onMenu: () => menu++);

      await tester.tapAt(
        tester.getCenter(find.textContaining(_kName)),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(menu, 1, reason: '信息区的右键没接到 onMenu(桌面右键在播放条上是死区)');
    });

    testWidgets('不传 onMenu(既有构造点): 右键什么也不发生, 也不抛', (tester) async {
      await _pump(tester);

      await tester.tap(find.byType(CoverArt), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
