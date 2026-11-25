import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/lyric.dart';

BigInt _ms(int v) => BigInt.from(v);

Future<void> pumpPlain(WidgetTester tester, List<String> lines) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(300, 700);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.25)),
        child: child!,
      ),
      home: const Scaffold(body: PlainLyricView(lines: [])),
    ),
  );
}

void main() {
  group('lyricIndexAt', () {
    final times = [_ms(1000), _ms(5000), _ms(9000), _ms(20000)];

    test('第一句之前返回 -1', () {
      expect(lyricIndexAt(times, _ms(0)), -1);
      expect(lyricIndexAt(times, _ms(999)), -1);
    });

    test('正好等于时间戳时命中该行', () {
      expect(lyricIndexAt(times, _ms(1000)), 0);
      expect(lyricIndexAt(times, _ms(9000)), 2);
    });

    test('落在两行之间取前一行', () {
      expect(lyricIndexAt(times, _ms(4999)), 0);
      expect(lyricIndexAt(times, _ms(12000)), 2);
    });

    test('超过最后一句停在最后一行', () {
      expect(lyricIndexAt(times, _ms(999999)), 3);
    });

    test('空歌词返回 -1', () {
      expect(lyricIndexAt(const [], _ms(5000)), -1);
    });
  });

  group('parseLrc', () {
    test('标准 LRC: 时间轴升序 + 多标签展开 + 两种小数位', () {
      final doc = parseLrc(
        '[ti:标题]\n'
        '[00:02.50]第二句\n'
        '[00:01][00:04]重复句\n'
        '[00:03.250]第三句\n',
      );
      expect(doc.hasTimeline, isTrue);
      expect(doc.plain, isEmpty);
      final times = [for (final l in doc.timed) l.timeMs];
      expect(times, [_ms(1000), _ms(2500), _ms(3250), _ms(4000)]);
      // 多标签展开成两行同样的文本
      expect(doc.timed.where((l) => l.text == '重复句').length, 2);
      // 排序后第一句是 00:01
      expect(doc.timed.first.timeMs, _ms(1000));
      expect(doc.timed.first.text, '重复句');
    });

    test('纯文本(无时间标签)落到 plain, 不进时间轴', () {
      const raw = '第一行\n\n第二行\n';
      final doc = parseLrc(raw);
      expect(doc.hasTimeline, isFalse);
      expect(doc.plain, ['第一行', '第二行']);
    });

    test('空内容: 空串/只有元数据/只有空时间标签行', () {
      expect(parseLrc('').isEmpty, isTrue);
      expect(parseLrc('\n\n').isEmpty, isTrue);
      expect(parseLrc('[ti:歌名][ar:艺人]').isEmpty, isTrue);
      expect(parseLrc('[00:01.00]\n[00:02.00]\n').isEmpty, isTrue);
    });

    test('格式异常不抛异常, 文字尽量保留', () {
      // 坏时间标签 + 元数据 + 截断标签 + 普通文本混排
      const raw =
          '[00:xx]坏标签行\n'
          '[ti:这是元数据]\n'
          '[01:0截断的标签\n'
          '[abc]未知标签行\n'
          '正常纯文本行\n';
      final doc = parseLrc(raw);
      expect(doc.hasTimeline, isFalse);
      expect(doc.plain, containsAll(['坏标签行', '未知标签行', '正常纯文本行']));
      expect(doc.plain, isNot(contains('这是元数据')));
    });

    test('tlyric 缺失时 sub 为 null, 有则按毫秒合并', () {
      const raw = '[00:01.00]一句\n[00:02.00]二句\n';
      final missing = parseLrc(raw);
      expect(missing.timed.every((l) => l.sub == null), isTrue);
      final merged = parseLrc(
        raw,
        translations: {_ms(1000): 'one line', _ms(9999): '对不上的翻译'},
      );
      expect(merged.timed[0].sub, 'one line');
      expect(merged.timed[1].sub, isNull); // 缺失不崩
    });
  });

  // 与权威实现 Rust `core/crates/ncm-domain/src/lrc.rs` 的**对等断言**。
  //
  // 兜底路径(Rust 逐行接口失败时用 `parseLrc`)与权威路径必须给出同一条时间轴,
  // 否则兜底一回歌词就整体错位。期望值抄自 `lrc.rs` 的 tests:
  // `offset_dedup_and_extra_fraction_digits` / `ignores_metadata_and_applies_offset` /
  // `drops_unparsable_lines` / `merges_translation_by_timestamp`。改一边必须同步改另一边。
  group('parseLrc 与 Rust lrc.rs 对等', () {
    test('[offset:-500] 整体延后, 位移在去重之前生效, 不出负时间', () {
      // Rust `offset_dedup_and_extra_fraction_digits` 的 shifted 用例: 期望 [700, 1500]
      final doc = parseLrc(
        '[offset:-500]\n'
        '[00:01.00]同\n'
        '[00:01.00]同\n'
        '[00:00.20]起句\n',
      );
      final times = [for (final l in doc.timed) l.timeMs];
      expect(times, [_ms(700), _ms(1500)]);
      expect([for (final l in doc.timed) l.text], ['起句', '同']);
      expect(times.every((t) => !t.isNegative), isTrue);
    });

    test('正 offset = 歌词提前, 负数时间钳到 0', () {
      // Rust `ignores_metadata_and_applies_offset` 的口径; 200ms 那行减 500 后出负数
      final doc = parseLrc(
        '[offset:500]\n'
        '[00:00.20]甲\n'
        '[00:02.00]乙\n',
      );
      expect([for (final l in doc.timed) l.timeMs], [_ms(0), _ms(1500)]);
    });

    test('4 位小数只取前 3 位: .1234 → 1123ms', () {
      expect(parseLrc('[00:01.1234]x').timed.single.timeMs, _ms(1123));
      // 顺带钉住其余位宽(抄 Rust `fractional_precision_variants`)
      expect(parseLrc('[00:01.5]x').timed.single.timeMs, _ms(1500));
      expect(parseLrc('[00:01.125]x').timed.single.timeMs, _ms(1125));
    });

    test('同时间同文本去重, 同时刻不同文本都保留', () {
      // Rust: dup => [(1000, "同"), (1000, "异")]
      final doc = parseLrc('[00:01.00]同\n[00:01.00]同\n[00:01.00]异\n');
      expect(
        [for (final l in doc.timed) (l.timeMs, l.text)],
        [(_ms(1000), '同'), (_ms(1000), '异')],
      );
    });

    test('[00:99.00] 不是合法时间标签(秒 ≥ 60), 不进时间轴', () {
      // Rust `drops_unparsable_lines`: 只留 [00:01.00]。Dart 刻意差异: 坏标签行的文字
      // 落到 plain(兜底路径要能展示纯文本), 但**绝不能**猜成 1 分 39 秒混进时间轴。
      final doc = parseLrc('[00:01.00]保留\n[00:99.00]非法\n');
      expect([for (final l in doc.timed) l.timeMs], [_ms(1000)]);
      expect([for (final l in doc.timed) l.text], ['保留']);
      expect(doc.plain, ['非法']);
    });

    test('无时间标签的行进 plain, 不污染时间轴', () {
      // Rust 直接丢掉这类行(它的歌词接口只回时间轴); Dart 兜底路径刻意保留成纯文本。
      final doc = parseLrc('第一行\n[00:01.00]甲\n第二行\n');
      expect([for (final l in doc.timed) l.text], ['甲']);
      expect(doc.plain, ['第一行', '第二行']);
    });

    test('翻译表的键是**位移后**的毫秒(Rust 按 time_ms 精确匹配)', () {
      // offset 500(提前) + 原 00:02.00 ⇒ 1500ms; 用原时间戳当键就匹配不上
      const raw = '[offset:500]\n[00:02.00]甲\n';
      final shifted = parseLrc(raw, translations: {_ms(1500): '译'});
      expect(shifted.timed.single.timeMs, _ms(1500));
      expect(shifted.timed.single.sub, '译');
      final unshiftedKey = parseLrc(raw, translations: {_ms(2000): '译'});
      expect(unshiftedKey.timed.single.sub, isNull);
    });
  });

  group('PlainLyricView', () {
    testWidgets('纯文本按行展示', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: PlainLyricView(lines: ['第一行', '第二行'])),
        ),
      );
      expect(find.text('第一行'), findsOneWidget);
      expect(find.text('第二行'), findsOneWidget);
    });

    testWidgets('空内容显示空态文案', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: PlainLyricView(lines: [])),
        ),
      );
      expect(find.text('暂无歌词'), findsOneWidget);
    });

    testWidgets('格式异常解析出的纯文本也能显示', (tester) async {
      final doc = parseLrc('[00:xx]坏标签行\n[ti:元数据]\n正常行\n');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PlainLyricView(lines: doc.plain)),
        ),
      );
      expect(find.text('坏标签行'), findsOneWidget);
      expect(find.text('正常行'), findsOneWidget);
      expect(find.text('元数据'), findsNothing);
    });

    testWidgets('300dp 窄屏 + 1.25 字号不溢出', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(300, 700);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.25)),
            child: child!,
          ),
          home: Scaffold(
            body: PlainLyricView(
              lines: ['这是一段特别特别特别长的纯文本歌词, 用来验证窄屏大字号下软换行不溢出', '', '短行'],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
