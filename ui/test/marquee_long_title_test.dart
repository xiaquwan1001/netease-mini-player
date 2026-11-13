import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/marquee_text.dart';

Widget _host(String text, {bool reduceMotion = false}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(400, 600),
        textScaler: const TextScaler.linear(1.25),
        disableAnimations: reduceMotion,
      ),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 300,
            child: InkWell(
              onTap: () {},
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: MarqueeText(text, style: const TextStyle(fontSize: 16)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 不给 MarqueeText 传 style、只靠 DefaultTextStyle 提供字号(与 AppBar 标题同款).
Widget _hostInherited(
  String text, {
  double fontSize = 20,
  double width = 200,
  String Function(String text)? rebuildWith,
}) {
  Widget build(String t) => MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(
        size: Size(600, 600),
        textScaler: TextScaler.linear(1.25),
      ),
      // 注意: DefaultTextStyle 必须放在 Scaffold/Material 之内 —— Material 会用自己的
      // DefaultTextStyle 覆盖外层, 放在外面测的就不是"继承字号"场景了.
      child: Scaffold(
        body: DefaultTextStyle(
          style: TextStyle(fontSize: fontSize),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: MarqueeText(t)),
          ),
        ),
      ),
    ),
  );
  if (rebuildWith == null) return build(text);
  return StatefulBuilder(
    builder: (context, setState) => build(rebuildWith(text)),
  );
}

void main() {
  testWidgets('超长歌名: textScale 1.25 下单行渲染, 不溢出不抛错', (tester) async {
    await tester.pumpWidget(_host('一首非常非常非常长的歌名' * 6));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
    expect(box.size.height, lessThan(40), reason: '必须是单行(竖排会远高于行高)');
    expect(tester.takeException(), isNull);
  });

  testWidgets('短歌名: 不启动动画(无 Transform, settle 后无新帧)', (tester) async {
    await tester.pumpWidget(_host('短名'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_marqueeTransform(tester), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('长歌名: 若干帧后文本发生位移(marquee 生效)', (tester) async {
    await tester.pumpWidget(_host('一首非常非常非常长的歌名' * 6));
    await tester.pump();
    // 动画在 post-frame 创建, 先跨过创建帧再观察位移
    await tester.pump(const Duration(milliseconds: 1100));
    final p1 = _marqueeOffset(tester);
    await tester.pump(const Duration(milliseconds: 400));
    final p2 = _marqueeOffset(tester);
    expect(p2, isNotNull);
    expect(p2!, lessThan(p1 ?? 0), reason: '文本应向左滚动');
  });

  testWidgets('textScaler 回归: 缩放后恰好放不下的文本必须滚动(测量须含 textScaler)', (
    tester,
  ) async {
    // 视口 300 - 左右 padding 8 = 284; 文本未缩放宽 256(放得下),
    // 1.25 缩放后 320(放不下). 旧实现 _measure 用 noScaling 测得 260,
    // 误判 fits 不滚动 => 歌名被 ellipsis 截断且临界时撑破约束.
    await tester.pumpWidget(_host('超长歌名' * 4));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(_marqueeTransform(tester), findsOneWidget, reason: '1.25 缩放下应启动跑马灯');
  });

  testWidgets('textScaler 回归: 同文本在 1.0 缩放下放得下, 不滚动', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(400, 600),
            textScaler: TextScaler.noScaling,
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: InkWell(
                  onTap: () {},
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: MarqueeText(
                      '超长歌名' * 4,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(_marqueeTransform(tester), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  // v0.7.2: 用户反馈"明明一次性放得下的歌名也在滚"。根因是 textWidth 与视口宽
  // 亚像素级相等时被判成放不下, 于是为了 24px 尾部空隙白白滚起来。现在有 1px 容差。
  testWidgets('恰好放得下(文本宽 == 视口宽): 不滚动', (tester) async {
    const style = TextStyle(fontSize: 16);
    const scaler = TextScaler.linear(1.25);
    final tp = TextPainter(
      text: const TextSpan(text: '刚好放得下的歌名', style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final textWidth = tp.width;
    tp.dispose();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(400, 600), textScaler: scaler),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                // 视口宽 = 文本宽(加 padding 16 抵消), 即"恰好放得下"
                width: textWidth + 16,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: MarqueeText('刚好放得下的歌名', style: style),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(_marqueeTransform(tester), findsNothing, reason: '放得下就不该滚');
  });

  // 用户反馈原实现是"滚到底再反向滚回"的往复, 视觉上同时有向左/向右位移。
  // 现在改成单向: 滚到尾部停一下 → 瞬跳回起点。断言: 采样窗口内所有"正向"位移
  // 都必须是回跳(幅度大), 不允许出现连续小幅正向移动。
  testWidgets('单向跑马灯: 只有回跳, 没有反向缓慢回滚', (tester) async {
    await tester.pumpWidget(_host('一二三四五六七八九十一二三四五六七'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    final samples = <double>[];
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final o = _marqueeOffset(tester);
      if (o != null) samples.add(o);
    }
    expect(samples.length, greaterThan(50), reason: '应当一直在滚动');
    var jumps = 0;
    for (var i = 1; i < samples.length; i++) {
      final d = samples[i] - samples[i - 1];
      if (d > 1.0) {
        jumps++;
        expect(d, greaterThan(20), reason: '正向位移只能是回跳(瞬跳), 不能是缓慢回滚');
      }
    }
    expect(jumps, greaterThanOrEqualTo(1), reason: '6s 窗口内应至少循环一次(证明会回到起点)');
  });

  // v0.7.2 根因修复: 测量没合并 DefaultTextStyle。AppBar 标题不传 style、靠继承 20sp,
  // 而 TextPainter 默认按 14sp 量 => 判成"放得下"但真实渲染溢出, 被 ellipsis 截掉。
  testWidgets('继承字号(DefaultTextStyle 20sp): 真实溢出必须滚(旧实现按 14sp 误判放得下)', (
    tester,
  ) async {
    // 10 个汉字 * 20sp * 1.25 = 250px > 200px 视口; 按 14sp 量只有 175px(会误判放得下)
    await tester.pumpWidget(_hostInherited('一二三四五六七八九十'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(_marqueeTransform(tester), findsOneWidget);
  });

  testWidgets('继承字号: 真的放得下时仍不滚', (tester) async {
    await tester.pumpWidget(_hostInherited('一二三四五六七八九十', width: 400));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(_marqueeTransform(tester), findsNothing);
  });

  // 溢出死区: 溢出 4px < minMarqueeOverflow(8) 不该滚(否则"明明放得下却在动")
  testWidgets('溢出小于死区(8px): 不滚', (tester) async {
    await tester.pumpWidget(_hostInherited('一二三四五六七八九十', width: 246));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(_marqueeTransform(tester), findsNothing);
  });

  // 父级每帧重建(文本用插值字符串 => 每帧新实例)时, 动画 key 不能跟着变,
  // 否则 _start 会反复把 offset 拉回 0 —— 视觉是"一直在滚但总停在开头"。
  testWidgets('父级每帧重建: 滚动位置继续前进, 不回到起点', (tester) async {
    await tester.pumpWidget(
      _hostInherited('长歌名占位', width: 120, rebuildWith: (t) => '一首非常非常长的歌名' * 3),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1200));
    final p1 = _marqueeOffset(tester);
    await tester.pump(const Duration(milliseconds: 400));
    final p2 = _marqueeOffset(tester);
    expect(p1, isNotNull);
    expect(p2, isNotNull);
    expect(p2!, lessThan(p1!), reason: '滚动应当继续向左, 不应被重建重置回起点');
  });

  testWidgets('reduce motion: 不打动画, 单行不溢出', (tester) async {
    await tester.pumpWidget(_host('一首非常非常非常长的歌名' * 6, reduceMotion: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_marqueeTransform(tester), findsNothing);
    final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
    expect(box.size.height, lessThan(40));
    await tester.pump(const Duration(seconds: 5));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  // 防回退: 详情页(歌词页)标题必须是 titleLarge 级别,
  // 防回退: 详情页(歌词页)标题必须是 titleLarge 级别,
  // 歌单详情头卡标题必须是 headlineSmall 级别(之前被钉在 titleMedium 导致字号特别小).
  //
  // 这里读源码而不是 pump 页面: 两处标题都在 AppBar / 头卡里, 起一个完整页面成本太高.
  // 为了不被 dart format 的重排(缩进/换行/声明顺序)打挂, 一律用正则定位 + 窗口断言,
  // 不再用 indexOf(...) 之间的 substring 切片(上一次 CI RangeError 就是这么来的).
  test('详情页标题字号防回退: main 用 titleLarge, detail_page 用 headlineSmall', () {
    String window(
      String src,
      RegExp anchor, {
      int before = 1200,
      int after = 400,
    }) {
      final m = anchor.firstMatch(src);
      expect(m, isNotNull, reason: '锚点 ${anchor.pattern} 不见了');
      final start = (m!.start - before).clamp(0, src.length);
      final end = (m.start + after).clamp(0, src.length);
      return src.substring(start, end);
    }

    // 源码注释里也会出现 "之前 titleMedium 显得特别小" 这类关键字, 断言前先剥掉行注释.
    String stripComments(String block) => block
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    final mainSrc = File('lib/main.dart').readAsStringSync();
    final detailSrc = File('lib/src/detail_page.dart').readAsStringSync();

    // 歌词页 AppBar: 取「紧挨着 title: MarqueeText 之前的那个 titleTextStyle:」到 MarqueeText
    // 之间的一小段, 既不看别的组件的样式, 也不依赖两者之间的行数.
    final titleAnchor = RegExp(r'title:\s*MarqueeText\(').firstMatch(mainSrc);
    expect(titleAnchor, isNotNull, reason: '歌词页 AppBar 的 MarqueeText 标题不见了');
    final styleIdx = mainSrc.lastIndexOf('titleTextStyle:', titleAnchor!.start);
    expect(styleIdx, isNonNegative, reason: '歌词页 AppBar 的 titleTextStyle 不见了');
    final appBarBlock = stripComments(
      mainSrc.substring(
        styleIdx,
        (titleAnchor.start + 60).clamp(0, mainSrc.length),
      ),
    );
    expect(appBarBlock.contains('titleLarge'), isTrue);
    expect(appBarBlock.contains('titleMedium'), isFalse);
    // 22sp 默认行高在 56dp AppBar 里会裁掉中文歌名下半段(用户反馈), 显式 20sp+height
    expect(appBarBlock.contains('fontSize: 20'), isTrue);
    expect(appBarBlock.contains('height: 1.25'), isTrue);

    // 歌单详情头卡: MarqueeText(d?.name ...) 窗口里必须是 headlineSmall, 不能是 titleMedium
    final headerBlock = stripComments(
      window(
        detailSrc,
        RegExp(r'MarqueeText\(\s*d\?\.name'),
        before: 200,
        after: 320,
      ),
    );
    expect(headerBlock.contains('headlineSmall'), isTrue);
    expect(headerBlock.contains('titleMedium'), isFalse);
  });
}

/// 只看 MarqueeText 子树里的 Transform(框架其它地方也可能有 Transform).
Finder _marqueeTransform(WidgetTester tester) => find.descendant(
  of: find.byType(MarqueeText),
  matching: find.byType(Transform),
);

double? _marqueeOffset(WidgetTester tester) {
  final transforms = tester.widgetList<Transform>(_marqueeTransform(tester));
  if (transforms.isEmpty) return null;
  return transforms.last.transform.getTranslation().x;
}
