import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app_meta.dart';
import 'app_settings.dart';
import 'rust/api.dart' as rust;

/// 匿名诊断包: "复现问题必需的环境与状态", **不含任何账号身份**。
///
/// 为什么是"生成文件"而不是"自动上传": 本项目没有自建上报端点, 也不应该偷偷发
/// 用户数据。开关打开后只有用户主动点「生成匿名诊断包」才会落盘一份 JSON,
/// 之后由用户自己决定贴到哪里(issue/私信)。要接自动上报时, 只需要在这里加一步
/// 把同一份 JSON POST 到配置的端点, 采集口径不用改。
class DebugReport {
  DebugReport._();

  /// 生成一份匿名诊断包, 返回落盘路径。
  ///
  /// [dataDir] 来自 rust.InitInfo.dataDir; 为 null 时直接报错(没有落盘位置)。
  /// [info] 只用于 providers 列表与"是否登录"(布尔), 不取昵称/uid/凭据。
  /// [credential] 测试注入: 默认调 rust.credentialStatus()(只取 kind/backend)。
  static Future<String> write({
    required String? dataDir,
    rust.InitInfo? info,
    DateTime Function()? now,
    Future<rust.CredentialStatusDto> Function()? credential,
  }) async {
    final dir = dataDir;
    if (dir == null || dir.isEmpty) {
      throw StateError('数据目录未知, 先让 App 完成初始化');
    }
    final at = (now ?? DateTime.now)();
    final payload = await build(
      info: info,
      now: () => at,
      credential: credential,
    );
    final file = File('$dir/debug/anonymous-report-${_stamp(at)}.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    return file.path;
  }

  /// 只组装 JSON 不落盘: 「一键匿名提交」与「生成诊断包」共用同一份口径,
  /// 避免两条路径的字段集合漂移(客户端脱敏口径只写一次)。
  static Future<Map<String, Object?>> build({
    rust.InitInfo? info,
    DateTime Function()? now,
    Future<rust.CredentialStatusDto> Function()? credential,
  }) async {
    final at = (now ?? DateTime.now)();
    return <String, Object?>{
      'schema': 1,
      'app': kAppVersion,
      'generatedAt': at.toIso8601String(),
      'env': await _env(),
      'settings': _settings(),
      'account': {
        // 只要"有没有账号"和"凭据后端是什么", 不要身份证
        'loggedIn': info?.loggedIn ?? false,
        'vip': info?.vip ?? false,
        // 设备指纹不可逆摘要: 同机多次上报能对上, 但拿不到 device_id 原文
        'deviceTag': _tag(info?.deviceId),
      },
      // 只导 provider 的 id + 能力数(ProviderInfo 本身不可 JSON 编码)
      'providers': [
        for (final p in (info?.providers ?? const []))
          {'id': p.id, 'capabilities': p.capabilities.length},
      ],
      'credential': await _credential(credential),
      'note': '本文件不含账号昵称/uid/cookie, 设备 ID 只保留不可逆摘要。',
    };
  }

  static Future<Map<String, Object?>> _env() async {
    String os = 'unknown';
    try {
      os = Platform.operatingSystemVersion;
    } catch (_) {
      // 某些平台不支持, 不影响其它字段
    }
    final view = WidgetsBinding.instance.platformDispatcher.views.isEmpty
        ? null
        : WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view?.physicalSize;
    return {
      'platform': Platform.operatingSystem,
      'osVersion': os,
      'dart': Platform.version,
      'debug': kDebugMode,
      'physicalSize': size == null
          ? null
          : '${size.width.toInt()}x${size.height.toInt()}',
      'devicePixelRatio': view?.devicePixelRatio,
      'textScale': AppSettings.instance.textScale,
    };
  }

  /// 只导"会影响行为"的设置项; 不导任何路径/凭据/搜索历史。
  static Map<String, Object?> _settings() {
    final s = AppSettings.instance;
    return {
      'themeMode': s.themeMode.name,
      'accent': s.accent.id,
      'textScale': s.textScale,
      'audioLevel': s.audioLevel,
      'coverRows': s.coverRows,
      'gridColumns': s.gridColumns,
      'skipVipSongs': s.skipVipSongs,
      'dailyCacheDays': s.dailyCacheDays,
      'coverQuality': s.coverQuality.id,
      'oledDark': s.oledDark,
      'volumeGainDb': s.volumeGainDb,
      'loudnessNormalize': s.loudnessNormalize,
      'loudnessDynamic': s.loudnessDynamic,
      // EQ 只留曲线名(文件可能带用户名/路径, 不导内容)
      'eqProfileName': s.eqProfileName,
      'fadeMs': s.fadeMs,
      'hardwareDecode': s.hardwareDecode,
      'streamCache': s.streamCache,
      'cacheLimitMb': s.cacheLimitMb,
      'lyricTranslation': s.lyricTranslation,
      'lyricSourcePreference': s.lyricSourcePreference,
    };
  }

  static Future<Map<String, Object?>> _credential(
    Future<rust.CredentialStatusDto> Function()? fetch,
  ) async {
    try {
      final status = await (fetch ?? rust.credentialStatus)();
      return {'kind': status.kind, 'backend': status.backend};
    } catch (e) {
      // 未初始化 Rust / 后端不可用都不该让诊断包生成失败
      return {'error': '${e.runtimeType}'};
    }
  }

  /// 不可逆短摘要(FNV-1a 32 位 + 长度): 只用来区分"是不是同一台机器"。
  static String? _tag(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    var hash = 0x811c9dc5;
    for (final unit in raw.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    final hex = hash.toRadixString(16).padLeft(8, '0');
    return '$hex-${raw.length}';
  }

  static String _stamp(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${at.year}${two(at.month)}${two(at.day)}-'
        '${two(at.hour)}${two(at.minute)}${two(at.second)}';
  }
}
