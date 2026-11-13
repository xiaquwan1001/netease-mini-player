// 匿名诊断包的隐私口径: 只导环境/设置, 不含昵称、uid、cookie;
// 设备 ID 只留不可逆摘要(能对同机, 拿不到原文)。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/debug_report.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.InitInfo info({String deviceId = 'device-raw-1234'}) => rust.InitInfo(
  dataDir: '/tmp/minincm',
  deviceId: deviceId,
  loggedIn: true,
  vip: false,
  providers: const [
    rust.ProviderInfo(id: 'netease', name: '网易云', capabilities: ['search']),
  ],
);

void main() {
  // 注意: 真 IO(临时目录/落盘)在 testWidgets 的 FakeAsync 里**永远不会完成**
  // (会卡到超时), 所以这里用普通 test + 先初始化 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('生成匿名包: 有环境与设置, 无账号身份', () async {
    final dir = await Directory.systemTemp.createTemp('anon_report');
    addTearDown(() => dir.delete(recursive: true));
    await AppSettings.instance.load(dir.path);
    await AppSettings.instance.update(skipVipSongs: true, dailyCacheDays: 3);

    final path = await DebugReport.write(
      dataDir: dir.path,
      info: info(),
      // 注入假凭据状态: 不初始化 Rust, 避免测试里触发 FFI
      credential: () async => const rust.CredentialStatusDto(
        kind: 'secure',
        backend: 'android-keystore',
        migrated: true,
        note: 'n',
      ),
    );
    final file = File(path);
    expect(await file.exists(), isTrue, reason: '必须真的落盘');

    final text = await file.readAsString();
    final json = jsonDecode(text) as Map<String, dynamic>;
    expect(json['schema'], 1);
    expect(json['settings'], containsPair('skipVipSongs', true));
    expect(json['settings'], containsPair('dailyCacheDays', 3));
    expect(json['account'], containsPair('loggedIn', true));

    // 隐私: 不出现设备 ID 原文 / 凭据 / 昵称字段
    expect(text.contains('device-raw-1234'), isFalse);
    expect(text.contains('MUSIC_U'), isFalse);
    expect(json['account'], isNot(contains('nickname')));
    expect(json['account'], isNot(contains('userId')));
    // 但同机可比对: 摘要存在
    expect(json['account']['deviceTag'], isA<String>());
  });

  test('没有数据目录时明确报错, 不静默写出', () async {
    await expectLater(
      DebugReport.write(
        dataDir: null,
        info: info(),
        credential: () => throw StateError('不该被调用'),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
