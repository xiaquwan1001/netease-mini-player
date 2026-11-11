import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/keystore.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KeystoreChannel ks;
  final stored = <String, String>{};
  var nativeAvailable = true;
  Object? nativeError;

  Future<Object?> handler(MethodCall call) async {
    if (nativeError != null) throw nativeError!;
    switch (call.method) {
      case 'available':
        return nativeAvailable;
      case 'put':
        stored[call.arguments['key'] as String] = call.arguments['value'] as String;
        return true;
      case 'get':
        return stored[call.arguments['key'] as String];
      case 'remove':
        return stored.remove(call.arguments['key'] as String) != null;
    }
    throw PlatformException(code: 'unimplemented');
  }

  setUp(() {
    stored.clear();
    nativeAvailable = true;
    nativeError = null;
    KeystoreChannel.debugForceAndroid = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ncm/keystore'), handler);
    ks = KeystoreChannel();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ncm/keystore'), null);
    KeystoreChannel.debugForceAndroid = false;
  });

  test('put/get/remove 正常往返', () async {
    expect(await ks.available(), isTrue);
    expect(await ks.put('cookie', 'MUSIC_U=abc'), isTrue);
    expect(await ks.get('cookie'), 'MUSIC_U=abc');
    expect(await ks.remove('cookie'), isTrue);
    expect(await ks.get('cookie'), isNull);
    expect(await ks.remove('cookie'), isFalse);
  });

  test('非 Android: available=false, put 返回 false, get 返回 null, 不写明文', () async {
    KeystoreChannel.debugForceAndroid = false;
    expect(await ks.available(), isFalse);
    expect(await ks.put('cookie', 'MUSIC_U=abc'), isFalse);
    expect(await ks.get('cookie'), isNull);
    expect(await ks.remove('cookie'), isFalse);
    expect(stored, isEmpty);
  });

  test('Android 上 handler 回 available=false', () async {
    nativeAvailable = false;
    expect(await ks.available(), isFalse);
  });

  test('PlatformException 不崩溃, 按约定返回', () async {
    nativeError = PlatformException(code: 'keystore_error', message: 'invalidated');
    expect(await ks.available(), isFalse);
    expect(await ks.put('k', 'v'), isFalse);
    expect(await ks.get('k'), isNull);
    expect(await ks.remove('k'), isFalse);
  });

  test('中文/emoji/超长字符串往返', () async {
    final long = '♫' * 5000 + '云音乐·🎵' * 200;
    for (final v in ['中文密码', '🎵🎶🀄', long]) {
      expect(await ks.put('k', v), isTrue);
      expect(await ks.get('k'), v);
    }
  });

  test('missing/null 返回走 ?? 兜底', () async {
    expect(await ks.get('不存在'), isNull);
  });
}
