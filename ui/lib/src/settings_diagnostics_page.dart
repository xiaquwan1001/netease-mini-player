import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'debug_report.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'section_header.dart';
import 'state_views.dart';
import 'toast.dart' show showToast;

/// 诊断与数据二级页(审查 P1-7.9: 原是设置页里的「诊断」+「数据」两个一级分组).
///
/// Rust 通道自检 / 设备 ID / 数据目录都是开发者向内容, 不该占设置首页;
/// 现由 设置 → 关于 → 「诊断与数据」进入。
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
  const DiagnosticsPage({super.key, this.info, this.ping});

  final rust.InitInfo? info;
  final Future<String> Function()? ping;

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
          const SectionTitle('诊断'),
          Card(
            margin: EdgeInsets.zero,
            child: ChannelSelfCheckTile(ping: ping),
          ),
          const SizedBox(height: 16),
          const SectionTitle('匿名诊断'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                SwitchListTile(
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
                const Divider(height: 1),
                _AnonymousReportTile(dataDir: info?.dataDir, info: info),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const SectionTitle('数据'),
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
        ],
      ),
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
      showToast(context, '生成失败: $e', isError: true);
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
