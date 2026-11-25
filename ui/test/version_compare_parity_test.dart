// 版本比较只有一份实现(2026-11-25 审计 D10)。
//
// 改造前: 更新检查用 `update_checker.compareVersions`(semver: `+N` build 段、
// 预发布 < 正式), 公告排序用 `release_notes.compareVersionKeys`(只比数字段) ——
// 同一对 `0.40.0-beta` / `0.40.0` 两个结论。现在后者复用前者, 只保留
// "先剥 v / +N 再比" 的预处理。
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/release_notes.dart' show compareVersionKeys;
import 'package:minincm/src/update_checker.dart' show compareVersions;

void main() {
  group('compareVersionKeys 与 compareVersions 等价', () {
    test('同一批输入两侧结论一致(v 前缀两种写法都归一化)', () {
      const pairs = <List<String>>[
        ['0.39.0', '0.40.0'],
        ['v0.39.0', '0.39.1'],
        ['1.0.0', '1.0.0'],
        ['0.12.2', '0.12.10'],
        ['v0.9.0', '0.10.0'],
        ['0.40.0-beta', '0.40.0'],
        ['0.40.0', '0.40.0-beta'],
        ['1.0.0-rc1', '1.0.0'],
        ['2.0', '2.0.0'],
      ];
      for (final p in pairs) {
        final a = p[0];
        final b = p[1];
        expect(
          compareVersionKeys(a, b),
          compareVersions(a, b),
          reason: '$a vs $b 两个比较器必须同结论',
        );
        expect(
          compareVersionKeys(a, b),
          -compareVersionKeys(b, a),
          reason: '$a vs $b 必须反对称',
        );
      }
    });

    test('预发布 < 正式: 0.40.0-beta 比 0.40.0 旧(旧实现判相等)', () {
      expect(compareVersionKeys('0.40.0-beta', '0.40.0'), -1);
      expect(compareVersionKeys('v0.40.0-beta', 'v0.40.0'), -1);
      expect(compareVersionKeys('0.40.0', '0.40.0-beta'), 1);
    });

    test('公告表 key 带 v: v0.39.0 与 0.39.0 判相等', () {
      expect(compareVersionKeys('v0.39.0', '0.39.0'), 0);
    });

    test('预处理: 公告排序里 `+N` build 段被剥掉(与更新检查的刻意差异)', () {
      // 公告的 key 是 tag(vX.Y.Z), 不含 build 号; 同一个版本的 +4/+5 是同一批公告,
      // 所以这里剥掉再比(旧实现也只比数字段)。更新检查则看 +N: 数字大者新。
      expect(compareVersionKeys('0.2.1+4', '0.2.1+5'), 0);
      expect(compareVersions('0.2.1+4', '0.2.1+5'), -1);
      expect(compareVersionKeys('v0.9.0+90', '0.9.0'), 0);
    });
  });
}
