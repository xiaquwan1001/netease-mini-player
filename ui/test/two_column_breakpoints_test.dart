// 页内双列断点(lane 宽屏双列 S0)的纯单测: 边界值锁死, 防止有人「顺手调 1dp」。
//
// 口径(见 lib/src/layout.dart 的「页内双列」小节):
//   · 宽 >= kTwoColumnMinWidth(900) 且 高 >= kTwoColumnMinHeight(560) ⇒ 双列;
//   · 判据入参是**窗口逻辑尺寸**(MediaQuery.sizeOf), 不是 body 实测宽(壳层限宽 840);
//   · 无限宽/无限高视为满足该维度; NaN(错误约束)一律 false, 与 layoutTierFor 同口径。
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/layout.dart';

/// 只跑刻画双列断点的 8 例(见任务口径), 不在这里复测 layoutTierFor。
void main() {
  group('twoColumnFor: 8 个锁死口径', () {
    test('1280x720(桌面默认窗口) ⇒ 双列', () {
      expect(twoColumnFor(const Size(1280, 720)), isTrue);
    });

    test('900x560(宽/高两个下界同时取等) ⇒ 双列', () {
      expect(twoColumnFor(const Size(900, 560)), isTrue);
    });

    test('899x720(宽差 1) ⇒ 单列', () {
      expect(twoColumnFor(const Size(899, 720)), isFalse);
    });

    test('900x559(高差 1) ⇒ 单列', () {
      expect(twoColumnFor(const Size(900, 559)), isFalse);
    });

    test('780x360(手机横屏: 高不够, 两列各只看 3 行) ⇒ 单列', () {
      expect(twoColumnFor(const Size(780, 360)), isFalse);
    });

    test('1920x1080(大桌面) ⇒ 双列', () {
      expect(twoColumnFor(const Size(1920, 1080)), isTrue);
    });

    test('840x800(恰好等于内容限宽 kContentMaxWidth) ⇒ 单列', () {
      // 840 是壳层限宽本身: 中档宽度铺满一列就够, 再切两栏会挤坏曲目行。
      expect(twoColumnFor(const Size(kContentMaxWidth, 800)), isFalse);
    });

    test('非有限宽/NaN 的保守口径: 无限视为满足, NaN 一律单列', () {
      // 无限宽/无限高: 被放进横滑/无限高容器, 不该退化(与 layoutTierFor 一致)
      expect(twoColumnFor(const Size(double.infinity, 800)), isTrue);
      expect(twoColumnFor(const Size(1280, double.infinity)), isTrue);
      // NaN 只能来自错误的约束传参: 退回最保守的单列
      expect(twoColumnFor(const Size(double.nan, 800)), isFalse);
      expect(twoColumnFor(const Size(1280, double.nan)), isFalse);
      expect(twoColumnFor(const Size(double.nan, double.nan)), isFalse);
    });
  });

  test('常量关系: 两栏切分正好填满既有 840 内容宽, 且间距是栅格值', () {
    // 左 300 / 间距 12 / 右 528 = 840 —— 双列不需要放宽壳层限宽(方案 C 不做)
    expect(
      kTwoColumnListWidth + kTwoColumnGap,
      lessThan(kContentMaxWidth),
      reason: '两栏必须能在 840 内切开',
    );
    expect(kContentMaxWidth - kTwoColumnListWidth - kTwoColumnGap, 528);
    expect(kTwoColumnGap, kPagePadding, reason: '间距与页面留白同值但具名独立');
    // 双列宽度阈值沿用宽档下界: 不再造第四个宽度阈值
    expect(kTwoColumnMinWidth, kWideMinWidth);
  });
}
