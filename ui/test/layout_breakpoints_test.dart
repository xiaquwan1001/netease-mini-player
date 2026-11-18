// 布局档位断点(lane/ui-adaptive P1)的纯单测: 边界值锁死, 防止有人「顺手调 1dp」。
//
// 口径(见 lib/src/layout.dart 的「布局档位」小节):
//   窄 < 600 / 中 600 ~ 899 / 宽 >= 900; 只由**实际可用宽度**决定, 不看设备类型。
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/layout.dart';

void main() {
  group('layoutTierFor: 三档边界', () {
    test('599 / 600 是窄与中的分界(600 归中档)', () {
      expect(layoutTierFor(599), LayoutTier.compact);
      expect(layoutTierFor(600), LayoutTier.medium);
    });

    test('899 / 900 是中的与宽的分界(900 归宽档)', () {
      expect(layoutTierFor(899), LayoutTier.medium);
      expect(layoutTierFor(900), LayoutTier.wide);
    });

    test('0 宽(首帧/未布局)按窄档处理', () {
      expect(layoutTierFor(0), LayoutTier.compact);
    });

    test('正无穷按宽档处理(无限宽绝不能落进窄档)', () {
      expect(layoutTierFor(double.infinity), LayoutTier.wide);
    });

    test('NaN(错误约束)退回窄档', () {
      expect(layoutTierFor(double.nan), LayoutTier.compact);
    });
  });

  group('layoutTierFor: 真实参考宽度', () {
    const cases = <(double, LayoutTier)>[
      (300, LayoutTier.compact), // 最严窄屏审计口径
      (360, LayoutTier.compact), // golden 常规视口
      (412, LayoutTier.compact), // Pixel 竖屏
      (540, LayoutTier.compact), // 手机横屏下限
      (720, LayoutTier.medium), // 7" 平板 / 小窗
      (840, LayoutTier.medium), // 内容限宽本身
      (1000, LayoutTier.wide),
      (1280, LayoutTier.wide), // 桌面默认窗口
      (2560, LayoutTier.wide),
    ];
    for (final (width, tier) in cases) {
      test('${width.toInt()} ⇒ ${tier.name}', () {
        expect(layoutTierFor(width), tier);
      });
    }
  });

  test('常量关系: 限宽 < 宽档下界, 且窄档上界 <= 宽档下界', () {
    expect(kContentMaxWidth, lessThan(kWideMinWidth));
    expect(kCompactMaxWidth, lessThanOrEqualTo(kWideMinWidth));
    expect(kRailWidth, greaterThan(0));
  });
}
