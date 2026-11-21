import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../app_meta.dart';
import '../app_settings.dart';
import '../app_sheet.dart';
import '../daily_cache.dart';
import '../debug_report.dart';
import '../diag_upload.dart';
import '../net_retry.dart';
import '../rust/api_all.dart' as rust;
import '../section_header.dart';
import '../state_views.dart';
import '../toast.dart' show showToast;

/// 诊断与数据二级页(审查 P1-7.9: 原是设置页里的「诊断」+「数据」两个一级分组).
///
/// Rust 通道自检 / 设备 ID / 数据目录都是开发者向内容, 不该占设置首页;
/// 2026-11 设置页 IA 重组后由**设置首页 → 「数据与诊断」**直接进入(原先还套一层
/// 「关于」), 顺手把「每日推荐缓存」并进来 —— 它也是"本机数据"这件事。
Future<void> showDiagnosticsPage(
  BuildContext context, {
  rust.InitInfo? info,

  /// 测试注入: FFI ping
  Future<String> Function()? ping,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => DiagnosticsPage(info: info, ping: ping),
    ),
  );
}

class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({
    super.key,
    this.info,
    this.ping,
    this.diagEndpoint = kDiagUploadEndpoint,
  });

  final rust.InitInfo? info;
  final Future<String> Function()? ping;

  /// 诊断上传端点。默认取构建期常量; **测试注入**(传空串 = 未配置, 演练禁用分支)。
  final String diagEndpoint;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('诊断与数据')),
      body: ListView(
        // 手势条留白(审查 P1-7.15)
        padding: EdgeInsets.fromLTRB(
          12,
          8,
          12,
          24 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          const SectionTitle('诊断', icon: Icons.bug_report_outlined),
          Card(
            margin: EdgeInsets.zero,
            child: ChannelSelfCheckTile(ping: ping),
          ),
          const SizedBox(height: 16),
          const SectionTitle('匿名诊断', icon: Icons.shield_outlined),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                // AppSettings 是单例; 本页没有外层 AnimatedBuilder,
                // 不监听的话点了开关视觉不动(设置值其实已变)。
                // 只订阅诊断域: 其它域(音量滑块/交互记录)的写入不再重建这一块。
                AppSettingsScopedBuilder(
                  domains: const {AppSettingsDomain.diagnostics},
                  builder: (context) => SwitchListTile(
                    title: const Text('允许匿名发送 debug 数据'),
                    subtitle: const Text(
                      '只收环境与设置(版本/系统/屏幕/开关), 不含昵称、uid、cookie; '
                      '打开后仍需手动点下面一行才会生成',
                    ),
                    value: AppSettings.instance.anonymousDebug,
                    onChanged: (value) {
                      AppSettings.instance.update(anonymousDebug: value);
                    },
                  ),
                ),
                const Divider(height: 1),
                _OneClickDiagTile(
                  dataDir: info?.dataDir,
                  info: info,
                  endpoint: diagEndpoint,
                ),
                const Divider(height: 1),
                _AnonymousReportTile(dataDir: info?.dataDir, info: info),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const SectionTitle('数据', icon: Icons.data_object),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.badge_outlined),
                  title: const Text('设备 ID'),
                  subtitle: SelectableText(
                    info?.deviceId ?? '初始化中…',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('数据目录'),
                  subtitle: SelectableText(
                    info?.dataDir ?? '-',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 每日推荐歌单缓存(2026-11 用户需求; 原先平铺在设置首页, IA 重组后
          // 归「数据与诊断」): 保留天数 + 立即清理 + 上次清理时间。
          const SectionTitle('缓存', icon: Icons.sd_storage_outlined),
          Card(
            margin: EdgeInsets.zero,
            child: _DailyCacheTile(dataDir: info?.dataDir),
          ),
        ],
      ),
    );
  }
}

/// 「一键匿名提交」: 小白点一下 → Worker 代理建 issue → 回一个编号/链接。
///
/// 设计约束(见 tools/diag-worker/README.md):
/// - 用户主动点才发, 开关默认关;
/// - 端点未配置(作者还没部署 Worker)时整行禁用, 只保留本地生成;
/// - GitHub token 只在 Worker 侧, 客户端拿不到, issue 作者也不暴露用户;
/// - 上传失败**一定**留一份本地文件: 小白不会两手空空(`retryable` 只决定提示口径)。
class _OneClickDiagTile extends StatefulWidget {
  const _OneClickDiagTile({
    required this.dataDir,
    this.info,
    required this.endpoint,
  });

  final String? dataDir;
  final rust.InitInfo? info;
  final String endpoint;

  @override
  State<_OneClickDiagTile> createState() => _OneClickDiagTileState();
}

class _OneClickDiagTileState extends State<_OneClickDiagTile> {
  bool _busy = false;

  bool get _configured => widget.endpoint.trim().isNotEmpty;

  /// UUIDv4(幂等键): 不引 uuid 依赖, 用 Random.secure 拼 16 字节。
  /// 同一次点击内复用同一个 id, Worker 据此不会重复建单。
  static String _clientId() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final h = bytes.map(hex).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!AppSettings.instance.anonymousDebug) {
      showToast(context, '先在上面打开「允许匿名发送 debug 数据」', isError: true);
      return;
    }
    setState(() => _busy = true);
    // 先落盘: 无论上传成败, 用户手里都有那份 JSON(失败时这就是兜底)
    String? localPath;
    try {
      localPath = await DebugReport.write(
        dataDir: widget.dataDir,
        info: widget.info,
      );
      final payload = await DebugReport.build(info: widget.info);
      final result = await DiagUploader(endpoint: widget.endpoint)
          .upload(payload, clientId: _clientId());
      if (!mounted) return;
      await _showSubmitted(result);
    } on DiagUploadError catch (e) {
      if (!mounted) return;
      showToast(
        context,
        e.retryable
            ? '上传失败(${e.code}), 诊断包已存本地: ${localPath ?? '-'}'
            : '提交被拒绝(${e.code}): ${e.message}',
        isError: true,
      );
    } catch (e) {
      if (!mounted) return;
      showToast(context, '生成失败: ${describeError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 提交成功后给"编号 + 链接 + 复制"三件套: 用户不需要知道 GitHub 存在。
  Future<void> _showSubmitted(DiagUploadResult result) async {
    final url = result.url;
    await showAppDialog<void>(
      context,
      builder: (ctx) => AlertDialog(
        title: const Text('已提交'),
        content: Text(
          '诊断编号 #${result.number}\n\n'
          '作者会在 GitHub 上处理这条反馈; 想跟踪进度可以复制下面的链接:\n$url',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: '#${result.number} $url'),
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (mounted) showToast(context, '已复制编号与链接');
            },
            child: const Text('复制'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _configured && !_busy;
    return ListTile(
      leading: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.cloud_upload_outlined),
      title: const Text('一键匿名提交'),
      subtitle: Text(
        _configured ? '不用账号、不用填表: 点一下就提交给作者(失败会留在本地)' : '作者还没配置接收端, 先只支持本地生成',
      ),
      trailing: const Icon(Icons.chevron_right),
      enabled: enabled,
      onTap: enabled ? _submit : null,
    );
  }
}

/// 「生成匿名诊断包」: 落盘一份不含账号身份的 JSON, 交给用户自己贴到 issue。
///
/// 不做自动上传: 没有自建端点, 也不该偷偷发数据(见 DebugReport 的注释)。
class _AnonymousReportTile extends StatelessWidget {
  const _AnonymousReportTile({required this.dataDir, this.info});

  final String? dataDir;
  final rust.InitInfo? info;

  Future<void> _generate(BuildContext context) async {
    if (!AppSettings.instance.anonymousDebug) {
      showToast(context, '先在上一行打开「允许匿名发送 debug 数据」', isError: true);
      return;
    }
    try {
      final path = await DebugReport.write(dataDir: dataDir, info: info);
      if (!context.mounted) return;
      showToast(context, '已生成匿名诊断包: $path');
    } catch (e) {
      if (!context.mounted) return;
      showToast(context, '生成失败: ${describeError(e)}', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.description_outlined),
      title: const Text('生成匿名诊断包'),
      subtitle: const Text('保存到数据目录的 debug/ 下, 由你自己决定发给谁'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _generate(context),
    );
  }
}

/// 「Rust 通道自检」: 调用 FFI ping, 展示返回值与耗时. 可注入 ping 便于测试.
class ChannelSelfCheckTile extends StatefulWidget {
  const ChannelSelfCheckTile({super.key, this.ping});

  /// 默认走 rust.ping(name: 'selftest')
  final Future<String> Function()? ping;

  @override
  State<ChannelSelfCheckTile> createState() => _ChannelSelfCheckTileState();
}

class _ChannelSelfCheckTileState extends State<ChannelSelfCheckTile> {
  bool _running = false;
  String? _result;
  String? _error;
  int _elapsedMs = 0;

  Future<void> _run() async {
    if (_running) return; // 防重入: 连点只跑一次
    setState(() {
      _running = true;
      _result = null;
      _error = null;
    });
    final sw = Stopwatch()..start();
    try {
      final value = await (widget.ping ?? () => rust.ping(name: 'selftest'))();
      sw.stop();
      if (!mounted) return;
      setState(() {
        _result = value;
        _elapsedMs = sw.elapsedMilliseconds;
      });
    } catch (e) {
      sw.stop();
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _elapsedMs = sw.elapsedMilliseconds;
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _running
        ? '正在自检…'
        : _result != null
        ? '通道正常 ($_elapsedMs ms): $_result'
        : _error != null
        ? '通道异常 ($_elapsedMs ms): $_error'
        : '调用 Rust FFI ping 验证 Dart⇄Rust 通道';
    return ListTile(
      leading: _running
          ? const LoadingView.inline(size: 22)
          : Icon(
              _result != null
                  ? Icons.check_circle_outline
                  : _error != null
                  ? Icons.error_outline
                  : Icons.monitor_heart_outlined,
              color: _result != null
                  ? Theme.of(context).colorScheme.primary
                  : _error != null
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
      title: const Text('Rust 通道自检'),
      subtitle: Text(subtitle),
      onTap: _running ? null : _run,
    );
  }
}

/// 每日推荐缓存(歌单 + 单曲): 保留天数 + 立即清理 + 上次清理时间。
///
/// 缓存本身在 `daily_cache.dart`(按天`<账号键>/YYYY-MM-DD.json` 落文件, 当天的
/// 推荐**歌单**与推荐**单曲**在同一个文件里);
/// 这里只做展示与"什么时候清"。**清理只清当前账号的那个子目录** —— 日推缓存按账号
/// 分区, 顺手清别人账号的缓存既没必要也会让那个账号多拉一次。
/// 上次清理时间从缓存目录读, 所以点完「立即清理」要重读一次才好看见变化。
class _DailyCacheTile extends StatefulWidget {
  const _DailyCacheTile({required this.dataDir});

  final String? dataDir;

  @override
  State<_DailyCacheTile> createState() => _DailyCacheTileState();
}

class _DailyCacheTileState extends State<_DailyCacheTile> {
  DateTime? _lastCleanup;
  bool _cleaning = false;

  /// 当前账号的缓存分区键; null = 还没解析出来(此时按钮不可用, 不会误清别的账号)。
  String? _accountKey;

  DailyPlaylistCache? get _cache {
    final dir = widget.dataDir;
    final key = _accountKey;
    if (dir == null || dir.isEmpty || key == null) return null;
    return DailyPlaylistCache(dataDir: dir, accountKey: key);
  }

  @override
  void initState() {
    super.initState();
    _resolveAccount();
  }

  Future<void> _resolveAccount() async {
    final key = await DailyPlaylistCache.resolveAccountKey();
    if (!mounted) return;
    setState(() => _accountKey = key);
    await _loadLastCleanup();
  }

  Future<void> _loadLastCleanup() async {
    final at = await _cache?.lastCleanup();
    if (!mounted) return;
    setState(() => _lastCleanup = at);
  }

  /// 保留天数一变就顺手按新口径清一次: 否则用户把 30 天改成 3 天,
  /// 旧文件要等到下次手动清理才消失。
  Future<void> _setDays(int days) async {
    await AppSettings.instance.update(dailyCacheDays: days);
    if (mounted) setState(() {});
    await _cleanup();
  }

  Future<void> _cleanup() async {
    if (_cleaning) return;
    // 账号键通常 initState 就解析完了; 万一用户手比 FFI 快, 这里补一次,
    // 否则按钮会"点了没反应"。
    if (_accountKey == null) await _resolveAccount();
    final cache = _cache;
    if (cache == null) return;
    setState(() => _cleaning = true);
    try {
      final removed = await cache.cleanup(
        keepDays: AppSettings.instance.dailyCacheDays,
      );
      await _loadLastCleanup();
      if (!mounted) return;
      showToast(
        context,
        removed == 0 ? '没有需要清理的缓存' : '已清理 $removed 天的缓存(歌单 + 单曲)',
      );
    } catch (e) {
      if (!mounted) return;
      showToast(context, '清理失败: ${describeError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  String get _cleanupLabel {
    final at = _lastCleanup;
    if (at == null) return '还没有清理过';
    String two(int v) => v.toString().padLeft(2, '0');
    return '上次清理: ${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return Column(
      children: [
        ListTile(
          title: const Text('每日推荐缓存'),
          subtitle: Text(
            settings.dailyCacheDays <= 0
                ? '已关闭: 每次进推荐页都联网拉取'
                : '歌单 + 单曲, 同一天只拉一次, 保留 ${settings.dailyCacheDays} 天',
          ),
          trailing: DropdownButton<int>(
            value: settings.dailyCacheDays,
            underline: const SizedBox.shrink(),
            items: [
              for (final days in AppSettings.dailyCacheOptions)
                DropdownMenuItem(
                  value: days,
                  child: Text(AppSettings.dailyCacheLabel(days)),
                ),
            ],
            onChanged: (value) {
              if (value != null) _setDays(value);
            },
          ),
        ),
        const Divider(height: 1),
        ListTile(
          leading: _cleaning
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cleaning_services_outlined),
          title: const Text('立即清理'),
          subtitle: Text(_cleanupLabel),
          onTap: _cleaning ? null : _cleanup,
        ),
      ],
    );
  }
}
