import 'package:flutter/material.dart';

import 'net_retry.dart';
import 'rust/api.dart' as rust;

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
          const _SectionTitle('诊断'),
          Card(
            margin: EdgeInsets.zero,
            child: ChannelSelfCheckTile(ping: ping),
          ),
          const SizedBox(height: 16),
          const _SectionTitle('数据'),
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
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}
