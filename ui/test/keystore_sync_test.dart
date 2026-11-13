import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/keystore.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    KeystoreChannel.debugForceAndroid = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ncm/keystore'), null);
  });

  /// 装一个内存版 Keystore 假通道, 返回句柄供断言.
  ({Map<String, String> store, List<String> calls}) installFakeKeystore() {
    KeystoreChannel.debugForceAndroid = true; // host 上强制走 Android 分支
    final store = <String, String>{};
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ncm/keystore'), (
          call,
        ) async {
          calls.add(call.method);
          switch (call.method) {
            case 'available':
              return true;
            case 'list':
              return store.keys.toList();
            case 'put':
              store[call.arguments['key'] as String] =
                  call.arguments['value'] as String;
              return true;
            case 'get':
              return store[call.arguments['key'] as String];
            case 'remove':
              store.remove(call.arguments['key'] as String);
              return true; // 删除幂等: 不存在也算成功
          }
          return null;
        });
    return (store: store, calls: calls);
  }

  group('KeystoreChannel', () {
    test('list 返回现存 key, put/get/remove roundtrip', () async {
      final ks = installFakeKeystore();
      final channel = KeystoreChannel();
      expect(await channel.list(), isEmpty);
      expect(await channel.put('session', 'MUSIC_U=abc'), isTrue);
      expect(await channel.get('session'), 'MUSIC_U=abc');
      expect(await channel.list(), ['session']);
      expect(await channel.remove('session'), isTrue);
      expect(await channel.get('session'), isNull);
      expect(ks.calls, containsAll(['list', 'put', 'get', 'remove']));
    });

    test('非 Android 平台 list/put 恒空/恒 false, 不打通道', () async {
      final channel = KeystoreChannel();
      expect(await channel.list(), isEmpty);
      expect(await channel.put('k', 'v'), isFalse);
    });

    test('通道 MissingPluginException 按空/失败处理', () async {
      KeystoreChannel.debugForceAndroid = true; // 无 handler ⇒ MissingPlugin
      final channel = KeystoreChannel();
      expect(await channel.list(), isEmpty);
      expect(await channel.put('k', 'v'), isFalse);
      expect(await channel.get('k'), isNull);
    });
  });

  group('CredentialSync', () {
    test('ensureRestored: available→list→get→restore(幂等可重复调用)', () async {
      final ks = installFakeKeystore();
      ks.store['session'] = 'MUSIC_U=restored';
      ks.store['account:7'] = 'MUSIC_U=acc7';

      final restores = <List<CredEntry>>[];
      final sync = CredentialSync(
        restore: (entries) async => restores.add(entries),
        fetchPending: () async => const [],
      );
      await sync.ensureRestored();
      await sync.ensureRestored();
      expect(restores, hasLength(2));
      final map = {for (final e in restores[1]) e.key: e.value};
      expect(map, {'session': 'MUSIC_U=restored', 'account:7': 'MUSIC_U=acc7'});
    });

    test('ensureRestored: Keystore 不可用就不 restore', () async {
      KeystoreChannel.debugForceAndroid = false; // 非 Android ⇒ available=false
      var restored = false;
      final sync = CredentialSync(
        restore: (_) async => restored = true,
        fetchPending: () async => const [],
      );
      await sync.ensureRestored();
      expect(restored, isFalse);
    });

    test('drainPending: put/remove 落 Keystore, 失败条目不计入', () async {
      final ks = installFakeKeystore();
      final sync = CredentialSync(
        fetchPending: () async => const [
          CredOp('put', 'session', 'MUSIC_U=new'),
          CredOp('remove', 'account:3', ''),
        ],
      );
      expect(await sync.drainPending(), 2);
      expect(ks.store['session'], 'MUSIC_U=new');
      expect(ks.store.containsKey('account:3'), isFalse);

      // put 失败(非 Android 通道)不计数、不抛
      KeystoreChannel.debugForceAndroid = false;
      final failing = CredentialSync(
        fetchPending: () async => const [CredOp('put', 'session', 'v')],
      );
      expect(await failing.drainPending(), 0);
    });

    test('drainPending: fetch 异常安静返回 0', () async {
      final sync = CredentialSync(
        fetchPending: () => throw Exception('ffi down'),
      );
      expect(await sync.drainPending(), 0);
    });

    test('ensureRestored 中 get 返回 null 的 key 不进 restore', () async {
      installFakeKeystore(); // 空 store: list 空
      KeystoreChannel.debugForceAndroid = true;
      final restores = <List<CredEntry>>[];
      final sync = CredentialSync(
        restore: (entries) async => restores.add(entries),
        fetchPending: () async => const [],
      );
      await sync.ensureRestored();
      expect(restores, hasLength(1));
      expect(restores[0], isEmpty);
    });
  });
}
