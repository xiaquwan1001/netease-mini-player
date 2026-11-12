import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'rust/api.dart' as rust;

/// Android Keystore 凭据后端的 Dart 封装(通道层).
///
/// 原生侧见 `ui/android/app/src/main/kotlin/**/KeystoreChannel.kt`:
/// AES-256-GCM 密钥(alias `minincm-cred-v1`)加密后落到 `filesDir/cred/<key>.bin`.
/// Rust identity 侧尚未接线, 这里只提供能被上层调用的通道.
///
/// 平台差异: 非 Android 上 `available()` 恒为 false, `put()` 返回 false,
/// 绝不在非 Android 平台偷偷写明文; 上层据此决定回退方案.
class KeystoreChannel {
  KeystoreChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('ncm/keystore');

  final MethodChannel _channel;

  /// 测试专用: host 上 Platform.isAndroid 恒为 false, 置 true 可强制走 Android 分支.
  @visibleForTesting
  static bool debugForceAndroid = false;

  bool get _isAndroid => !kIsWeb && Platform.isAndroid || debugForceAndroid;

  /// Keystore 是否可用(能取到/能创建密钥就 true).
  /// 非 Android 恒为 false; 通道异常按不可用处理.
  Future<bool> available() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 写入凭据 [key] -> [value](原生侧加密落盘).
  /// 返回 false 表示平台不支持或原生失败, 不抛异常, 由上层决定回退.
  Future<bool> put(String key, String value) async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'put',
            {'key': key, 'value': value},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 读取凭据; 不存在/密钥失效(清数据、备份恢复)/通道异常一律返回 null.
  Future<String?> get(String key) async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('get', {'key': key});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 现存凭据 key 列表(lane p1 restore 用); 通道异常按空表处理.
  Future<List<String>> list() async {
    if (!_isAndroid) return const [];
    try {
      final keys = await _channel.invokeMethod<List<Object?>>('list');
      return keys?.cast<String>() ?? const [];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// 删除凭据; 返回是否确实删掉了文件. 通道异常按 false 处理.
  Future<bool> remove(String key) async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('remove', {'key': key}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// ---------------- lane p1: Rust 桥接(restore / pending drain) ----------------

/// 启动 restore + 关键点 drain 的编排层.
///
/// Rust 侧(credential_channel::ChannelStore)是内存权威; 这里的职责:
/// - 启动时(rust.init 之前)把 Keystore 现存条目灌给 Rust([ensureRestored]);
/// - 登录/登出/切号后把 Rust 的 pending 落进 Keystore([drainPending]).
/// 设计见 docs/android-keystore-wiring-design.md.
///
/// rust 调用点做成可注入, 单测不碰 FFI。
class CredentialSync {
  CredentialSync({KeystoreChannel? keystore, this.restore, this.fetchPending})
      : _keystore = keystore ?? KeystoreChannel();

  final KeystoreChannel _keystore;
  /// 测试注入点: 不传则走 rust.credentialRestore / rust.credentialPendingWrites.
  final Future<void> Function(List<CredEntry> entries)? restore;
  final Future<List<CredOp>> Function()? fetchPending;

  /// Android 启动序: available → list → 逐条 get → restore(幂等).
  /// 任何一步不可用都安静跳过 —— Rust 侧会走既有同意门, 不阻塞启动.
  Future<void> ensureRestored() async {
    if (!await _keystore.available()) return;
    try {
      final keys = await _keystore.list();
      final entries = <CredEntry>[];
      for (final key in keys) {
        final value = await _keystore.get(key);
        if (value != null) entries.add(CredEntry(key, value));
      }
      await _restoreImpl(entries);
    } catch (_) {
      // restore 失败 = 当未登录启动, 与"清数据"语义一致
    }
  }

  /// 拉 Rust pending 并落 Keystore; 单条失败丢弃(=该凭据下次重登).
  /// 返回成功落盘的条数(测试/排障用).
  Future<int> drainPending() async {
    List<CredOp> ops;
    try {
      ops = await _fetchImpl();
    } catch (_) {
      return 0;
    }
    var applied = 0;
    for (final op in ops) {
      final ok = op.isRemove
          ? await _keystore.remove(op.key)
          : await _keystore.put(op.key, op.value);
      if (ok) applied++;
    }
    return applied;
  }

  Future<void> _restoreImpl(List<CredEntry> entries) {
    final handler = restore;
    if (handler != null) return handler(entries);
    return rust.credentialRestore(
      entries: entries
          .map((e) => rust.CredentialEntryDto(key: e.key, value: e.value))
          .toList(),
    );
  }

  Future<List<CredOp>> _fetchImpl() async {
    final fetch = fetchPending;
    if (fetch != null) return fetch();
    final dtos = await rust.credentialPendingWrites();
    return dtos.map((d) => CredOp(d.op, d.key, d.value)).toList(growable: false);
  }
}

/// restore 用的键值对(key 形如 "session" / "account:uid").
class CredEntry {
  const CredEntry(this.key, this.value);
  final String key;
  final String value;
}

/// drain 拉到的一条操作: op = "put" | "remove".
class CredOp {
  const CredOp(this.op, this.key, this.value);
  final String op;
  final String key;
  final String value;
  bool get isRemove => op == 'remove';
}

/// 全局单例: bootstrap 与登录链路共用, 注入点留给测试.
final CredentialSync credentialSync = CredentialSync();
