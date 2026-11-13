import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_meta.dart';

/// 版本号只有一个来源: `ui/pubspec.yaml` 的 `version: X.Y.Z+N`。
/// 设置页「关于」显示的是 [kAppVersion], 必须与 pubspec 的 X.Y.Z 一致,
/// 否则用户看到的版本和实际装上的版本会对不上(改版本请走 `tools/bump-version.sh`)。
void main() {
  test('kAppVersion 与 pubspec.yaml version 的 versionName 一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml 的 version 必须是 X.Y.Z+N 形式');
    final versionName = match!.group(1)!;
    final versionCode = int.parse(match.group(2)!);

    expect(
      kAppVersion,
      versionName,
      reason: 'kAppVersion 落后/领先于 pubspec.yaml, 用 tools/bump-version.sh 同步',
    );
    // Android 覆盖安装要求 versionCode 严格递增, 0 或负数不可能合法
    expect(versionCode, greaterThan(0));
  });
}
