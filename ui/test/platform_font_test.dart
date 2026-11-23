import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/platform_font.dart';
import 'package:minincm/src/theme.dart';

/// arm64 Linux 的 CJK 兜底(2026-11-23): 判据必须**只在**那个平台开,
/// 而且开了以后主题必须真的把字体家族挂进 fallback —— 两件事都在这条用例里钉住。
void main() {
  test('兜底只在 arm64 Linux 启用', () {
    final isLinuxArm64 = Platform.isLinux && Abi.current() == Abi.linuxArm64;
    expect(needsBundledCjkFallback, isLinuxArm64);
    if (needsBundledCjkFallback) {
      expect(bundledCjkFallback, [kBundledCjkFamily]);
    } else {
      expect(bundledCjkFallback, isEmpty);
    }
  });

  testWidgets('主题真的把兜底字体挂到了 textTheme 上(仅在启用时)', (tester) async {
    for (final theme in [buildLightTheme(), buildDarkTheme(oled: true)]) {
      final style = theme.textTheme.bodyMedium!;
      final families = style.fontFamilyFallback ?? const [];
      if (needsBundledCjkFallback) {
        // 主字体必须是随包字体: 引擎没有 fontconfig 时默认字体解析不出来,
        // 只挂 fallback 会让拉丁字符(如「私人FM」的 FM)变豆腐块。
        expect(
          style.fontFamily,
          kBundledCjkFamily,
          reason: 'arm64 Linux 上必须用随包的拉丁+CJK 字体当主字体',
        );
        expect(families, contains(kBundledCjkFamily));
      } else {
        expect(
          style.fontFamily,
          isNot(kBundledCjkFamily),
          reason: '其它平台不该换主字体(会影响排版与金标)',
        );
        expect(
          families,
          isNot(contains(kBundledCjkFamily)),
          reason: '其它平台不该改字体链(会影响排版与金标)',
        );
      }
    }
  });
}
