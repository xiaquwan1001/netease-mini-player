import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_meta.dart';
import 'app_settings.dart';
import 'platform.dart';

/// GitHub Release 自动更新检查(纯 Dart, 无新依赖)。
///
/// 任何失败(网络 / 404 / JSON 畸形 / 超时)一律返回 null 且不抛异常 ——
/// 更新检查永远不能干扰正常使用。

/// 仓库 slug(与 kGithubUrl 保持一致, 勿引入第二份真源)。
const String kRepoSlug = 'xiaquwan1001/netease-mini-player';

/// latest release API 地址; 测试用 [checkForUpdate] 的 apiBase 指到本地假 JSON。
const String kLatestReleaseApi =
    'https://api.github.com/repos/$kRepoSlug/releases/latest';

const Duration kUpdateCheckTimeout = Duration(seconds: 8);

/// 启动静默检查的节流窗口: 24h 内不重复请求。
const Duration kUpdateCheckThrottle = Duration(hours: 24);

/// 检查结果。latest 为 tag(去掉 v 前缀保留原样展示), isNewer 由
/// [compareVersions] 判断; downloadUrl 为当前平台资产, 无匹配时回退 html_url。
class UpdateInfo {
  final String latest;
  final String current;
  final String? notes;
  final String? downloadUrl;
  final bool isNewer;

  const UpdateInfo({
    required this.latest,
    required this.current,
    required this.isNewer,
    this.notes,
    this.downloadUrl,
  });
}

/// fetch 注入点: 单测全部走假 fetcher / 假 HttpClient, 绝不真联网。
typedef UpdateFetcher = Future<({int statusCode, String body})> Function(
    Uri url);

/// UI 注入点: 设置页与启动检查通过这里发起检查 / 打开链接,
/// 测试替换成假实现断言调用(见 update_checker_test.dart)。
class UpdateCheckHost {
  /// 生产默认走真实 GitHub API。
  static Future<UpdateInfo?> Function(String currentVersion) check =
      (currentVersion) => checkForUpdate(currentVersion: currentVersion);

  static Future<void> Function(String url) openUrl = PlatformBridge.openUrl;

  /// 启动静默检查发现的新版本(有值时「检查更新」项显示红点)。
  static final ValueNotifier<UpdateInfo?> pendingUpdate =
      ValueNotifier<UpdateInfo?>(null);
}

// ---------------- 版本比较(纯函数) ----------------

/// 逐段数字比较, 返回 a<b ? -1 : a>b ? 1 : 0。
/// 支持 `v` 前缀、`X.Y.Z+N` 的 build 段(`+N` 数字大者新)、semver 预发布
/// 规则(有 prerelease < 无; 数字标识按数值比且 < 字母标识)。任一输入
/// 无法解析时返回 0(视为相等, 不抛异常)。
int compareVersions(String a, String b) {
  final va = _parseVersion(a);
  final vb = _parseVersion(b);
  if (va == null || vb == null) return 0;
  final core = _compareNumList(va.core, vb.core);
  if (core != 0) return core;
  // build 段(+N): 数字大者新
  if (va.build != vb.build) return va.build > vb.build ? 1 : -1;
  // 预发布: 有 < 无
  if (va.pre.isEmpty && vb.pre.isEmpty) return 0;
  if (va.pre.isEmpty) return 1;
  if (vb.pre.isEmpty) return -1;
  for (var i = 0; i < va.pre.length && i < vb.pre.length; i++) {
    final c = _comparePreId(va.pre[i], vb.pre[i]);
    if (c != 0) return c;
  }
  if (va.pre.length != vb.pre.length) {
    return va.pre.length > vb.pre.length ? 1 : -1;
  }
  return 0;
}

class _ParsedVersion {
  final List<int> core;
  final List<String> pre;
  final int build;
  const _ParsedVersion(this.core, this.pre, this.build);
}

_ParsedVersion? _parseVersion(String input) {
  var s = input.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  if (s.isEmpty) return null;
  var build = 0;
  final plus = s.indexOf('+');
  if (plus >= 0) {
    final buildPart = s.substring(plus + 1);
    if (buildPart.isEmpty || int.tryParse(buildPart) == null) return null;
    build = int.parse(buildPart);
    s = s.substring(0, plus);
  }
  List<String> pre = const [];
  final dash = s.indexOf('-');
  if (dash >= 0) {
    pre = s.substring(dash + 1).split('.');
    s = s.substring(0, dash);
  }
  final core = s.split('.');
  if (core.isEmpty || core.any((p) => p.isEmpty || int.tryParse(p) == null)) {
    return null;
  }
  return _ParsedVersion(
      core.map(int.parse).toList(), pre, build);
}

int _compareNumList(List<int> a, List<int> b) {
  final n = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y ? 1 : -1;
  }
  return 0;
}

int _comparePreId(String a, String b) {
  final na = int.tryParse(a);
  final nb = int.tryParse(b);
  if (na != null && nb != null) return na.compareTo(nb);
  if (na != null) return -1; // 数字标识 < 字母标识
  if (nb != null) return 1;
  return a.compareTo(b);
}

// ---------------- 资产选择(纯函数) ----------------

/// 从 release JSON 里挑当前平台资产: android => `-android-*.apk`,
/// linux => `-linux-*.tar.gz`; 没有匹配资产时回退 `html_url`。
/// [preferAndroid] 供测试注入平台(生产按 Platform.isAndroid)。
String? pickDownloadUrl(
  Map<Object?, Object?> release, {
  bool? preferAndroid,
}) {
  final android = preferAndroid ??
      (!kIsWeb && !Platform.isWindows && !Platform.isMacOS && Platform.isAndroid);
  final suffix = android ? '.apk' : '.tar.gz';
  final marker = android ? '-android-' : '-linux-';
  final assets = release['assets'];
  if (assets is List) {
    for (final raw in assets) {
      if (raw is! Map) continue;
      final name = raw['name'];
      if (name is String &&
          name.contains(marker) &&
          name.toLowerCase().endsWith(suffix)) {
        final url = raw['browser_download_url'];
        if (url is String && url.isNotEmpty) return url;
      }
    }
  }
  final html = release['html_url'];
  return html is String && html.isNotEmpty ? html : null;
}

/// 解析 GitHub release JSON; 结构畸形返回 null。
UpdateInfo? parseReleaseResponse(
  String body, {
  required String currentVersion,
  bool? preferAndroid,
}) {
  Object? raw;
  try {
    raw = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (raw is! Map) return null;
  final tag = raw['tag_name'];
  if (tag is! String || tag.isEmpty) return null;
  final name = raw['name'] is String ? raw['name'] as String : '';
  final notesBody = raw['body'];
  final notes = notesBody is String && notesBody.trim().isNotEmpty
      ? notesBody
      : (name.isNotEmpty ? name : null);
  return UpdateInfo(
    latest: tag,
    current: currentVersion,
    notes: notes,
    isNewer: compareVersions(tag, currentVersion) > 0,
    downloadUrl: pickDownloadUrl(raw, preferAndroid: preferAndroid),
  );
}

// ---------------- 主入口 ----------------

/// 检查 latest release。任何错误返回 null 不抛异常。
/// [client] / [apiBase] / [fetch] 供测试注入(测试绝不真联网);
/// [preferAndroid] 注入平台选择(生产自动判断)。
Future<UpdateInfo?> checkForUpdate({
  required String currentVersion,
  HttpClient? client,
  String? apiBase,
  UpdateFetcher? fetch,
  bool? preferAndroid,
}) async {
  try {
    final uri = Uri.parse(apiBase ?? kLatestReleaseApi);
    ({int statusCode, String body}) result;
    if (fetch != null) {
      result = await fetch(uri).timeout(kUpdateCheckTimeout);
    } else {
      final hc = client ?? HttpClient();
      final ownClient = client == null;
      try {
        final req = await hc.openUrl('GET', uri)
          ..headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
          ..headers.set(HttpHeaders.userAgentHeader, 'MiniNCM-UpdateChecker');
        final res = await req.close().timeout(kUpdateCheckTimeout);
        final body = await res.transform(utf8.decoder).join();
        result = (statusCode: res.statusCode, body: body);
      } finally {
        if (ownClient) hc.close(force: true);
      }
    }
    if (result.statusCode != 200) return null;
    return parseReleaseResponse(
      result.body,
      currentVersion: currentVersion,
      preferAndroid: preferAndroid,
    );
  } on Object {
    return null; // 超时 / SocketException / 任何异常: 静默失败
  }
}

// ---------------- 启动静默检查 + 节流 ----------------

/// 是否允许启动静默检查(纯函数, 注入 nowMs 便于测试):
/// 开关打开且距上次检查 >= 24h。
bool shouldStartupCheck({required AppSettings settings, required int nowMs}) {
  if (!settings.updateCheckOnStartup) return false;
  final last = settings.lastUpdateCheckMs;
  return last == null || nowMs - last >= kUpdateCheckThrottle.inMilliseconds;
}

/// 首帧后 3s 后台静默检查一次(不阻塞 UI, 失败静默):
/// 有新版本且未跳过时, 只点亮「检查更新」项的红点, 不弹窗。
/// [startupDelay] 供测试注入(生产默认 3s)。
Future<void> runStartupUpdateCheck(
  AppSettings settings, {
  Duration startupDelay = const Duration(seconds: 3),
  int Function()? now,
}) async {
  final clock = now ?? () => DateTime.now().millisecondsSinceEpoch;
  if (startupDelay > Duration.zero) {
    await Future<void>.delayed(startupDelay);
  }
  if (!shouldStartupCheck(settings: settings, nowMs: clock())) return;
  settings.recordUpdateCheck(clock());
  final info = await UpdateCheckHost.check(kAppVersion);
  if (info == null) return;
  if (!info.isNewer) return;
  if (info.latest == settings.skippedUpdateVersion) return;
  UpdateCheckHost.pendingUpdate.value = info;
}
