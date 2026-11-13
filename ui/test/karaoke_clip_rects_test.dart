import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/word_lyric_view.dart';

/// karaoke_clip_rects 纯逻辑单测: 「每词状态+进度」+「每词矩形」→ 裁切矩形。
///
/// 判据(与 painter 的绘制口径一致):
/// - upcoming 不裁;
/// - sung 整词宽;
/// - current 左起 progress×词宽;
/// - 水平相邻的矩形合并成一段(已唱并集连续)。
WordSpanStyle _s(WordHighlightState st, [double p = 0, String t = '']) =>
    WordSpanStyle(st, p, t);

Rect _box(double left, double width) => Rect.fromLTWH(left, 100, width, 20);

void main() {
  test('progress=0.5 → 当前词裁切宽 = 词宽/2', () {
    final rects = karaokeClipRects(
      [_s(WordHighlightState.current, 0.5)],
      [_box(40, 100)],
    );
    expect(rects.length, 1);
    expect(rects.single.width, closeTo(50, 0.5));
    expect(rects.single.left, closeTo(40, 0.5));
  });

  test('progress=1 → 当前词整词宽; progress=0 → 不产生矩形', () {
    final full = karaokeClipRects(
      [_s(WordHighlightState.current, 1)],
      [_box(40, 100)],
    );
    expect(full.single.width, closeTo(100, 0.5));

    final zero = karaokeClipRects(
      [_s(WordHighlightState.current, 0)],
      [_box(40, 100)],
    );
    expect(zero, isEmpty);
  });

  test('upcoming 不裁 / sung 整词宽', () {
    expect(
      karaokeClipRects([_s(WordHighlightState.upcoming)], [_box(0, 100)]),
      isEmpty,
    );
    final sung = karaokeClipRects(
      [_s(WordHighlightState.sung, 1)],
      [_box(0, 100)],
    );
    expect(sung.single.width, closeTo(100, 0.5));
  });

  test('多词已唱并集连续(相邻矩形合并成一段)', () {
    final rects = karaokeClipRects(
      [
        _s(WordHighlightState.sung, 1),
        _s(WordHighlightState.sung, 1),
        _s(WordHighlightState.sung, 1),
      ],
      [_box(0, 100), _box(100, 100), _box(200, 60)],
    );
    expect(rects.length, 1, reason: '三个相邻已唱词应合并成一段');
    expect(rects.single.left, closeTo(0, 0.5));
    expect(rects.single.width, closeTo(260, 0.5));
  });

  test('已唱 + 当前词半亮: 合并成一段且右缘落在 progress 处', () {
    final rects = karaokeClipRects(
      [
        _s(WordHighlightState.sung, 1),
        _s(WordHighlightState.current, 0.5),
        _s(WordHighlightState.upcoming),
      ],
      [_box(0, 100), _box(100, 100), _box(200, 100)],
    );
    expect(rects.length, 1);
    expect(rects.single.left, closeTo(0, 0.5));
    expect(rects.single.right, closeTo(150, 0.5));
  });

  test('中间有未唱词时不跨空隙合并', () {
    final rects = karaokeClipRects(
      [
        _s(WordHighlightState.sung, 1),
        _s(WordHighlightState.upcoming),
        _s(WordHighlightState.sung, 1),
      ],
      [_box(0, 100), _box(100, 100), _box(200, 100)],
    );
    expect(rects.length, 2);
    expect(rects[0].right, closeTo(100, 0.5));
    expect(rects[1].left, closeTo(200, 0.5));
  });

  test('被 ellipsis 截掉的词(null / 空矩形)跳过, 长度不一致不崩', () {
    final rects = karaokeClipRects(
      [
        _s(WordHighlightState.sung, 1),
        _s(WordHighlightState.sung, 1),
        _s(WordHighlightState.sung, 1),
      ],
      [null, Rect.zero, _box(0, 40)],
    );
    expect(rects.single.width, closeTo(40, 0.5));

    // boxes 比 styles 短 / 长都不应抛错
    expect(
      karaokeClipRects([_s(WordHighlightState.sung, 1)], const []),
      isEmpty,
    );
    expect(karaokeClipRects(const [], [_box(0, 10)]), isEmpty);
  });

  test('非法 progress 夹到 [0,1]', () {
    final nan = karaokeClipRects(
      [_s(WordHighlightState.current, double.nan)],
      [_box(0, 100)],
    );
    expect(nan, isEmpty, reason: 'NaN 进度按 0 处理');
    final over = karaokeClipRects(
      [_s(WordHighlightState.current, 3)],
      [_box(0, 100)],
    );
    expect(over.single.width, closeTo(100, 0.5));
  });
}
