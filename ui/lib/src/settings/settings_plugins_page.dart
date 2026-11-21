import 'package:flutter/material.dart';

import '../adaptive_text.dart';
import '../app_sheet.dart';
import '../async_view.dart';
import '../layout.dart';
import '../net_retry.dart' show friendlyError;
import '../rust/api_all.dart' as rust;
import '../section_header.dart';
import '../state_views.dart' show LoadingView;
import '../toast.dart' show showToast;

/// 本页展示判定视图的能力标签(与 `ncm_provider::Capability::as_str` 同一份字符串)。
const List<String> _routeCaps = ['songUrl', 'search'];

/// 路由表里的一项: 稳定标签 + 展示名 + 一句解释。
typedef _RouteOption = ({String mode, String title, String? subtitle});

/// 插件二级页(设置 → 关于 → 「插件」).
///
/// 只包一层 FFI(`plugin_status/summaries/failures/rejected/enable/disable/rescan/
/// set_enabled`), 所有决策(缺省不扫描、单插件状态、失败隔离、错误 kind)都在
/// Rust 侧 `PluginHost` 里, 本页**不重复判断**, 只负责呈现与串行调用。
///
/// 并发口径(与 `ncm-ffi/api/plugin.rs` 头注释一致): 这 8 个导出函数共用 `Core`
/// 的唯一一把锁, 重扫/开总开关期间其它域的调用会等待 ⇒ 本页把写操作**串行化**
/// ([_busy] 期间开关与重扫按钮全部禁用), 并且不给后台轮询。
Future<void> showPluginsPage(BuildContext context) {
  return Navigator.of(context)
      .push<void>(MaterialPageRoute<void>(builder: (_) => const PluginsPage()));
}

/// 一次读到的四份视图(状态 + 列表 + 失败 + 拒收).
///
/// 合成一个对象是为了让 [AsyncView] 的**一个** future 覆盖整页四态:
/// 分开取数会出现「状态已回、列表还在转」的混合态, 也会让重扫后的部分刷新看起来
/// 像数据漂了。
class _HostSnapshot {
  const _HostSnapshot({
    required this.status,
    required this.summaries,
    required this.failures,
    required this.rejected,
    this.routeMode,
    this.routePlans = const {},
  });

  final rust.PluginStatusDto status;
  final List<rust.PluginSummaryDto> summaries;
  final List<rust.PluginFailureDto> failures;
  final List<rust.PluginRejectedDto> rejected;

  /// 路由偏好(plugin_route.json); 平台不带插件宿主时为 null, 整段不渲染。
  final rust.PluginRouteModeDto? routeMode;

  /// 能力标签 -> 路由**判定**视图。只取本页展示的两个能力, 纯判定(不发请求、不改状态)。
  final Map<String, rust.PluginRoutePlanDto> routePlans;
}

class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key});

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  late Future<_HostSnapshot> _future;

  /// 有写操作在飞(单插件启停 / 重扫 / 总开关). 期间禁用所有写入口。
  bool _busy = false;

  /// 正在重扫(重扫按钮换成行内 spinner, 不换整页加载态)。
  bool _rescanning = false;

  /// 最近一次拉到的日志(`null` = 还没拉过)。**取走语义**: 每次拉取只给新日志。
  List<rust.PluginLogDto>? _logs;

  /// 日志拉取在飞(按钮换行内 spinner)。
  bool _pullingLogs = false;

  @override
  void initState() {
    super.initState();
    _future = _loadHost();
  }

  /// 读四份视图。`supported == false`(Android)时读类返回空视图, 这里直接短路,
  /// 不再多发三次无意义调用。
  Future<_HostSnapshot> _loadHost() async {
    final status = await rust.pluginStatus();
    if (!status.supported) {
      return _HostSnapshot(
        status: status,
        summaries: const [],
        failures: const [],
        rejected: const [],
      );
    }
    // 三个读类同时发起(Rust 侧串行持锁, 但省掉三次往返的排队开销)。
    final summariesFuture = rust.pluginSummaries();
    final failuresFuture = rust.pluginFailures();
    final rejectedFuture = rust.pluginRejected();
    final routeModeFuture = rust.pluginRouteMode();
    // 判定视图是"这次会走谁"的只读诊断, 与路由偏好同批取, 不额外多一轮往返。
    final planFutures = <String, Future<rust.PluginRoutePlanDto>>{
      for (final cap in _routeCaps) cap: rust.pluginRoutePlan(cap: cap),
    };
    return _HostSnapshot(
      status: status,
      summaries: await summariesFuture,
      failures: await failuresFuture,
      rejected: await rejectedFuture,
      routeMode: await routeModeFuture,
      routePlans: {
        for (final entry in planFutures.entries) entry.key: await entry.value,
      },
    );
  }

  /// 首屏失败后的重试(换 future, 由 [AsyncView] 走它自己的错误态)。
  void _retryInitial() {
    setState(() {
      _future = _loadHost();
    });
  }

  /// 写操作统一壳: 置忙 → 执行 → **重新取数** → 提示。
  ///
  /// 返回值非 null 时作为成功提示; 失败一律 [friendlyError](错误词表与其它域同一份,
  /// 这里不按文本猜)。取数失败时保留旧内容(只弹提示), 不让页面闪回错误态。
  Future<void> _run(
    Future<String?> Function() action, {
    bool rescan = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _rescanning = rescan;
    });
    try {
      final message = await action();
      final snapshot = await _loadHost();
      if (!mounted) return;
      // Future.value: 换数据但**不重挂载** [AsyncView], 已渲染的内容不闪回加载态。
      setState(() {
        _future = Future<_HostSnapshot>.value(snapshot);
      });
      if (message != null) showToast(context, message);
    } catch (e) {
      if (!mounted) return;
      showToast(context, friendlyError(e), isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _rescanning = false;
        });
      }
    }
  }

  /// 总开关: 二次确认 + 风险文案(打开会**真的执行**本机插件目录里的脚本)。
  Future<void> _toggleHost(bool enable) async {
    final confirmed = await showAppDialog<bool>(
      context,
      builder: (ctx) => AlertDialog(
        title: Text(enable ? '打开插件宿主?' : '关闭插件宿主?'),
        content: Text(
          enable
              ? '插件是放在本机插件目录里的脚本, 打开总开关后会真的执行它们。\n'
                    '只打开你信任的插件; 插件能访问的域名受清单白名单限制'
                    '(清单没写 = 所有出站请求都被拒绝)。'
              : '关闭后会立即摘掉已装载的插件, 插件目录与单个插件的启用状态都会保留, '
                    '下次打开时按原状态重新装载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(enable ? '打开' : '关闭'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await rust.pluginSetEnabled(enabled: enable);
      return enable ? '插件宿主已打开' : '插件宿主已关闭';
    });
  }

  /// 单插件启停(宿主总开关没开时 Rust 回 `forbidden`, 这里提前禁掉入口)。
  Future<void> _togglePlugin(rust.PluginSummaryDto summary, bool enable) {
    return _run(() async {
      if (enable) {
        await rust.pluginEnable(id: summary.id);
      } else {
        await rust.pluginDisable(id: summary.id);
      }
      return enable ? '已启用 ${summary.id}' : '已停用 ${summary.id}';
    });
  }

  /// 路由偏好: `auto` / `builtin` / `plugin:<id>`。
  ///
  /// 落盘与校验都在 Rust 侧(plugin_set_route_mode); 本页只回传稳定标签。
  /// 选中的 id 后来不存在**不算错误** —— 判定按 selectionMissing 回内置, 并显示在判定行里。
  Future<void> _setRoute(String mode) {
    return _run(() async {
      final applied = await rust.pluginSetRouteMode(mode: mode);
      return '音源路由已切到 ${_routeModeLabel(applied)}';
    });
  }

  /// 拉取插件日志(`lx.log` / `console.*`)。
  ///
  /// **取走语义**: 拉一次清一次, 页面只显示最近一批; 不后台轮询(拉取要拿 `Core` 的
  /// 唯一一把锁, 轮询会拖慢别的域调用)。
  Future<void> _pullLogs() async {
    if (_busy || _pullingLogs) return;
    setState(() => _pullingLogs = true);
    try {
      final logs = await rust.pluginLogs();
      if (!mounted) return;
      setState(() => _logs = logs);
    } catch (e) {
      if (!mounted) return;
      showToast(context, friendlyError(e), isError: true);
    } finally {
      if (mounted) setState(() => _pullingLogs = false);
    }
  }

  /// 导入一个插件: 弹层收 id/名称/版本/白名单/事件 + **三种来源之一**
  /// (粘贴文本 / 本机文件绝对路径 / URL)。
  ///
  /// 三条入口在 Rust 侧各自收口(`plugin_install_script` / `plugin_install_file` /
  /// `plugin_install_url`), 落盘与校验全在那边: 本页只收集字段、串行调用、重取数。
  /// 导入**不**自动启用 —— 装进来后单插件开关仍默认关闭(与目录导入同一套纪律)。
  Future<void> _importPlugin() async {
    final spec = await showAppDialog<_ImportSpec>(
      context,
      builder: (_) => const _ImportPluginDialog(),
    );
    if (spec == null || !mounted) return;
    await _run(rescan: true, () async {
      // 三选一: Rust 侧三条入口同一套落盘/校验纪律, 本页只负责选入口。
      final result = switch (spec.kind) {
        _ImportKind.paste => await rust.pluginInstallScript(
          id: spec.id,
          name: spec.name,
          version: spec.version,
          source: spec.text,
          lxEvents: spec.lxEvents,
          requestDomains: spec.requestDomains,
        ),
        _ImportKind.file => await rust.pluginInstallFile(
          id: spec.id,
          name: spec.name,
          version: spec.version,
          path: spec.text,
          lxEvents: spec.lxEvents,
          requestDomains: spec.requestDomains,
        ),
        _ImportKind.url => await rust.pluginInstallUrl(
          id: spec.id,
          name: spec.name,
          version: spec.version,
          url: spec.text,
          lxEvents: spec.lxEvents,
          requestDomains: spec.requestDomains,
        ),
      };
      return '已导入 ${spec.id}(${_importKindLabel(spec.kind)}): '
          '装载 ${result.loaded.length} · 未启用 ${result.skipped.length} · '
          '失败 ${result.failed.length}';
    });
  }

  /// 卸载一个插件: **二次确认**(删的是盘上真东西, 不可撤销)。
  ///
  /// 文案把边界说完整: 删插件目录(脚本/清单/它自己的 `data/`), 路由选择回「自动」,
  /// 内置音源不受影响。成功后重取数(列表里就没有它了)。
  Future<void> _uninstall(rust.PluginSummaryDto summary) async {
    final confirmed = await showAppDialog<bool>(
      context,
      builder: (ctx) => AlertDialog(
        title: Text('卸载 ${summary.id}?'),
        content: Text(
          '会从插件目录删除「${summary.id}」这个子目录: 脚本、清单, '
          '以及它自己的本地数据 data/。\n'
          '如果音源路由正指向它, 会自动回到「自动」; 内置音源不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      final result = await rust.pluginUninstall(id: summary.id);
      return '已卸载 ${summary.id}: 装载 ${result.loaded.length} · '
          '未启用 ${result.skipped.length}';
    });
  }

  /// 重扫: 扫盘 + 全量重建 provider 视图(没有热重载)。
  Future<void> _rescan() {
    return _run(rescan: true, () async {
      final result = await rust.pluginRescan();
      return '重扫完成: 装载 ${result.loaded.length} · '
          '未启用 ${result.skipped.length} · 失败 ${result.failed.length}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('插件')),
      body: ListView(
        padding: kPageInsets,
        children: [
          AsyncView<_HostSnapshot>(
            future: _future,
            onRetry: _retryInitial,
            emptyText: '没有插件数据',
            builder: (context, snapshot, _) => _body(context, snapshot),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, _HostSnapshot snapshot) {
    final status = snapshot.status;
    if (!status.supported) return _unsupported(context, status.error);
    final theme = Theme.of(context);
    final bodySmall = theme.textTheme.bodySmall;
    final routeOptions = _routeOptions(snapshot);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: '宿主', icon: Icons.extension_outlined),
        Card(
          margin: kCardMargin,
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('启用插件宿主'),
                subtitle: const Text('关闭时不扫描插件目录; 打开后会执行目录里的本地脚本'),
                value: status.enabled,
                onChanged: _busy ? null : _toggleHost,
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  status.active
                      ? Icons.check_circle_outline
                      : Icons.pause_circle_outline,
                ),
                title: const Text('运行状态'),
                subtitle: AdaptiveText(
                  _hostStateText(status),
                  mode: AdaptiveTextMode.wrap,
                  maxLines: 2,
                  style: bodySmall,
                ),
              ),
              if (status.root.isNotEmpty) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('插件目录'),
                  subtitle: SelectableText(status.root, style: bodySmall),
                ),
              ],
              if (status.error != null) ...[
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    Icons.error_outline,
                    color: theme.colorScheme.error,
                  ),
                  title: const Text('宿主失败原因'),
                  subtitle: AdaptiveText(
                    status.error!,
                    mode: AdaptiveTextMode.wrap,
                    maxLines: 3,
                    style: bodySmall?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (snapshot.routeMode != null) ...[
          const SizedBox(height: kSectionGap),
          const SectionHeader(title: '音源路由', icon: Icons.alt_route),
          AdaptiveText(
            '取直链/搜索时优先用谁。这里只改本机偏好 —— 判定、回落与失败切换都在 Rust 侧, 页面不重复判断。',
            mode: AdaptiveTextMode.wrap,
            maxLines: 2,
            style: bodySmall,
          ),
          const SizedBox(height: kSectionHeaderGap),
          Card(
            margin: kCardMargin,
            child: Column(
              children: [
                for (var i = 0; i < routeOptions.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _routeTile(
                    context,
                    routeOptions[i],
                    snapshot.routeMode!.mode,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: kSectionGap),
          Card(
            margin: kCardMargin,
            child: Column(
              children: [
                for (var i = 0; i < _routeCaps.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _planTile(
                    context,
                    _routeCaps[i],
                    snapshot.routePlans[_routeCaps[i]],
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: kSectionGap),
        SectionHeader(
          title: '插件',
          icon: Icons.widgets_outlined,
          trailing: _pluginActions(status),
        ),
        AdaptiveText(
          '重扫会扫盘并装载插件, 期间其它后台调用要排队, 完成前按钮不可再点。',
          mode: AdaptiveTextMode.wrap,
          maxLines: 2,
          style: bodySmall,
        ),
        const SizedBox(height: kSectionHeaderGap),
        if (snapshot.summaries.isEmpty)
          _emptyPlugins(context, status)
        else
          Card(
            margin: kCardMargin,
            child: Column(
              children: [
                for (var i = 0; i < snapshot.summaries.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _pluginTile(context, snapshot.summaries[i], status),
                ],
              ],
            ),
          ),
        if (snapshot.failures.isNotEmpty) ...[
          const SizedBox(height: kSectionGap),
          const SectionHeader(title: '失败', icon: Icons.report_outlined),
          Card(
            margin: kCardMargin,
            child: Column(
              children: [
                for (var i = 0; i < snapshot.failures.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _detailTile(
                    context,
                    title: snapshot.failures[i].id,
                    detail: snapshot.failures[i].detail,
                  ),
                ],
              ],
            ),
          ),
        ],
        if (snapshot.rejected.isNotEmpty) ...[
          const SizedBox(height: kSectionGap),
          const SectionHeader(title: '被拒收', icon: Icons.block_outlined),
          Card(
            margin: kCardMargin,
            child: Column(
              children: [
                for (var i = 0; i < snapshot.rejected.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _detailTile(
                    context,
                    title: snapshot.rejected[i].entry,
                    detail: snapshot.rejected[i].detail,
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: kSectionGap),
        SectionHeader(
          title: '日志',
          icon: Icons.article_outlined,
          trailing: _pullLogsButton(),
        ),
        AdaptiveText(
          '脚本的 lx.log / console.* 按需拉取; 拉一次清一次(取走语义), 不做后台轮询。',
          mode: AdaptiveTextMode.wrap,
          maxLines: 2,
          style: bodySmall,
        ),
        const SizedBox(height: kSectionHeaderGap),
        _logsCard(context),
      ],
    );
  }

  /// 拉取按钮: 在飞换行内 spinner; 与其它写入口共用 `_busy` 闸门。
  Widget _pullLogsButton() {
    if (_pullingLogs) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: LoadingView.inline(size: 16),
      );
    }
    return TextButton(
      onPressed: _busy ? null : _pullLogs,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        minimumSize: Size.zero,
      ),
      child: const Text('拉取日志'),
    );
  }

  /// 日志卡片: 一插件一条, 多行等宽显示(`lx.log` 原文, 不再加工)。
  Widget _logsCard(BuildContext context) {
    final theme = Theme.of(context);
    final logs = _logs;
    if (logs == null) {
      return AdaptiveText(
        '还没拉取过。',
        mode: AdaptiveTextMode.wrap,
        maxLines: 2,
        style: theme.textTheme.bodySmall,
      );
    }
    if (logs.isEmpty) {
      return AdaptiveText(
        '暂时没有新日志。',
        mode: AdaptiveTextMode.wrap,
        maxLines: 2,
        style: theme.textTheme.bodySmall,
      );
    }
    return Card(
      margin: kCardMargin,
      child: Column(
        children: [
          for (var i = 0; i < logs.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.terminal_outlined),
              title: AdaptiveText(logs[i].id, mode: AdaptiveTextMode.ellipsis),
              subtitle: SelectableText(
                logs[i].lines.join('\n'),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 当前平台不带插件宿主(Android): 只解释原因, 不摆任何写入口。
  Widget _unsupported(BuildContext context, String? reason) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(
            Icons.extension_off_outlined,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          Text('当前平台不支持插件', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          AdaptiveText(
            reason ?? '插件宿主只在桌面端编译, 本机版本没有这条通道。',
            mode: AdaptiveTextMode.wrap,
            maxLines: 3,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _emptyPlugins(BuildContext context, rust.PluginStatusDto status) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        status.enabled
            ? '插件目录里还没有插件: 放一个带清单的插件目录后点「重扫」。'
            : '总开关未打开, 打开后才会扫描插件目录。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  /// 「导入 + 重扫」两个入口(标题行 trailing; 在飞/写操作期间整体禁用)。
  Widget _pluginActions(rust.PluginStatusDto status) {
    // 导入要写插件目录并重扫: 总开关没开(<顺>没有注册表)时入口禁用, 与其它写操作一致。
    final canImport = status.enabled && !_busy && !_rescanning;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          onPressed: canImport ? _importPlugin : null,
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: Size.zero,
          ),
          child: const Text('导入'),
        ),
        const SizedBox(width: 4),
        _rescanButton(),
      ],
    );
  }

  /// 重扫入口: 在飞时换成行内 spinner(按钮不可再点, 避免重复扫盘叠锁)。
  Widget _rescanButton() {
    if (_rescanning) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: LoadingView.inline(size: 16),
      );
    }
    return TextButton(
      onPressed: _busy ? null : _rescan,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        minimumSize: Size.zero,
      ),
      child: const Text('重扫'),
    );
  }

  Widget _pluginTile(
    BuildContext context,
    rust.PluginSummaryDto summary,
    rust.PluginStatusDto status,
  ) {
    final theme = Theme.of(context);
    final bodySmall = theme.textTheme.bodySmall;
    final hasError = summary.error != null;
    // 宿主没开 / 条目本身坏 / 有写操作在飞 ⇒ 不可切换。
    final canToggle = status.enabled && !hasError && !_busy;
    final domainsText = summary.requestDomains.isEmpty
        ? '出站: 全部拒绝(清单没有白名单)'
        : '出站: ${summary.requestDomains.join(', ')}';
    // 脚本 inited 握手自报的平台代号(空 = 未声明/没声明 sources); 只展示, 不参与路由。
    final sourcesText = summary.sources.isEmpty
        ? '平台: 未声明'
        : '平台: ${summary.sources.join(', ')}';
    // 卸载入口与启停同排: 坏条目(error != null)也允许卸载(这是清垃圾的唯一入口),
    // 但宿主总开关没开或有写操作在飞时禁用(与其它写入口同口径)。
    final canUninstall = status.enabled && !_busy;
    return Row(
      children: [
        Expanded(
          child: SwitchListTile(
            value: summary.enabled,
            onChanged: canToggle
                ? (value) => _togglePlugin(summary, value)
                : null,
            isThreeLine: true,
            title: AdaptiveText(summary.name, mode: AdaptiveTextMode.ellipsis),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AdaptiveText(
                  '${summary.id} · v${summary.version}',
                  mode: AdaptiveTextMode.ellipsis,
                  style: bodySmall,
                ),
                const SizedBox(height: 2),
                AdaptiveText(
                  hasError ? '未能装载: ${summary.error}' : domainsText,
                  mode: AdaptiveTextMode.wrap,
                  maxLines: 2,
                  style: hasError
                      ? bodySmall?.copyWith(color: theme.colorScheme.error)
                      : bodySmall,
                ),
                if (!hasError) ...[
                  const SizedBox(height: 2),
                  AdaptiveText(
                    sourcesText,
                    mode: AdaptiveTextMode.wrap,
                    maxLines: 2,
                    style: bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
        IconButton(
          onPressed: canUninstall ? () => _uninstall(summary) : null,
          icon: const Icon(Icons.delete_outline),
          tooltip: '卸载',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  /// 失败 / 拒收的只读行: 键(id 或目录名) + 原因。
  Widget _detailTile(
    BuildContext context, {
    required String title,
    required String detail,
  }) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
      title: AdaptiveText(title, mode: AdaptiveTextMode.ellipsis),
      subtitle: AdaptiveText(
        detail,
        mode: AdaptiveTextMode.wrap,
        maxLines: 3,
        style: theme.textTheme.bodySmall,
      ),
    );
  }

  /// 可选项: 自动 / 只用内置 / 每个**能装载**的插件(坏条目不进列表 —— 它本来就跑不起来)。
  List<_RouteOption> _routeOptions(_HostSnapshot snapshot) => [
    (mode: 'auto', title: '自动', subtitle: '只有一个可用插件时用它; 多个候选不一致时回落内置'),
    (mode: 'builtin', title: '只用内置', subtitle: '始终走网易云官方接口, 不使用插件'),
    // 选项标题只用 id 形态(与上面「插件」分区的名称不重名, 免得同一页出现两条同名行)。
    for (final summary in snapshot.summaries)
      if (summary.error == null)
        (
          mode: 'plugin:${summary.id}',
          title: '优先用 ${summary.id}',
          subtitle: null,
        ),
  ];

  Widget _routeTile(
    BuildContext context,
    _RouteOption option,
    String selected,
  ) {
    final theme = Theme.of(context);
    final isSelected = selected == option.mode;
    final subtitle = option.subtitle;
    return ListTile(
      title: AdaptiveText(option.title, mode: AdaptiveTextMode.ellipsis),
      subtitle: subtitle == null
          ? null
          : AdaptiveText(
              subtitle,
              mode: AdaptiveTextMode.wrap,
              maxLines: 2,
              style: theme.textTheme.bodySmall,
            ),
      trailing: Icon(
        isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: isSelected ? theme.colorScheme.primary : null,
      ),
      onTap: (_busy || isSelected) ? null : () => _setRoute(option.mode),
    );
  }

  /// 判定行: 纯只读(判定 = "会走谁", 实际走了谁看日志/诊断)。
  Widget _planTile(
    BuildContext context,
    String cap,
    rust.PluginRoutePlanDto? plan,
  ) {
    final text = plan == null
        ? '判定不可用'
        : '${plan.target} · ${plan.reason} — ${plan.detail}';
    return ListTile(
      leading: const Icon(Icons.alt_route),
      title: Text('当前判定 · ${_capLabel(cap)}'),
      subtitle: AdaptiveText(
        text,
        mode: AdaptiveTextMode.wrap,
        maxLines: 2,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  String _routeModeLabel(rust.PluginRouteModeDto mode) {
    if (mode.mode == 'auto') return '自动';
    if (mode.mode == 'builtin') return '只用内置';
    final id = mode.pluginId;
    return id == null ? mode.mode : '插件 $id';
  }

  String _capLabel(String cap) => switch (cap) {
    'songUrl' => '取直链',
    'search' => '搜索',
    _ => cap,
  };

  /// 一句话回答「插件现在能不能用、为什么不能用」。
  String _hostStateText(rust.PluginStatusDto status) {
    final loaded = status.loaded.isEmpty
        ? '没有已装载的插件'
        : '已装载 ${status.loaded.length} 个: ${status.loaded.join(', ')}';
    if (status.active) {
      return status.failed == 0 ? loaded : '$loaded; 另有 ${status.failed} 条失败';
    }
    if (!status.enabled) return '总开关未打开 —— 不扫描插件目录';
    return '总开关已打开, 但宿主没有跑起来(见下面的失败原因)';
  }
}

/// 导入来源: 与 Rust 侧三条入口一一对应(粘贴文本 / 本机文件 / URL)。
enum _ImportKind { paste, file, url }

String _importKindLabel(_ImportKind kind) => switch (kind) {
  _ImportKind.paste => '粘贴文本',
  _ImportKind.file => '本机文件',
  _ImportKind.url => 'URL',
};

/// 来源字段的展示名(用于校验文案与标签)。
String _payloadLabel(_ImportKind kind) => switch (kind) {
  _ImportKind.paste => '脚本正文',
  _ImportKind.file => '文件路径',
  _ImportKind.url => 'URL',
};

/// 浅层形态校验(真正的规则与落盘都在 Rust 侧): 协议必须是 https 且带主机名。
bool _looksHttpsUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
}

/// 导入弹层收集到的字段(全部是用户输入; 校验与落盘都在 Rust 侧)。
class _ImportSpec {
  const _ImportSpec({
    required this.kind,
    required this.id,
    required this.name,
    required this.version,
    required this.text,
    required this.lxEvents,
    required this.requestDomains,
  });

  /// 来源种类(决定调哪条 FFI)。
  final _ImportKind kind;
  final String id;
  final String name;
  final String version;

  /// 按 [kind] 解释: 粘贴时的脚本正文 / 文件的绝对路径 / 抓取 URL。
  final String text;
  final List<String> lxEvents;
  final List<String> requestDomains;
}

/// 导入弹层: id / 名称 / 版本 / 事件 / 出站白名单 + 脚本正文。
///
/// 只做**必填**与形态的浅校验(空串直接拦下, 不发给 Rust 换一个错误);
/// 真正的规则(id 字符集/版本/白名单/事件名)由 `PluginManifest::validate` 判, 错误按
/// `friendlyError` 回显 —— 页面不复制一份清单规则。
class _ImportPluginDialog extends StatefulWidget {
  const _ImportPluginDialog();

  @override
  State<_ImportPluginDialog> createState() => _ImportPluginDialogState();
}

class _ImportPluginDialogState extends State<_ImportPluginDialog> {
  final _id = TextEditingController();
  final _name = TextEditingController();
  final _version = TextEditingController(text: '1.0.0');
  final _events = TextEditingController(text: 'musicUrl');
  final _domains = TextEditingController();

  /// 三种来源共用一个输入框(按 [_kind] 解释内容), 切换来源时内容保留。
  final _payload = TextEditingController();

  /// 当前选中的来源(缺省粘贴文本, 与历史行为一致)。
  _ImportKind _kind = _ImportKind.paste;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _version.dispose();
    _events.dispose();
    _domains.dispose();
    _payload.dispose();
    super.dispose();
  }

  static List<String> _splitCsv(String text) => text
      .split(RegExp(r'[,，\s]+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();

  void _submit() {
    final id = _id.text.trim();
    final name = _name.text.trim();
    final version = _version.text.trim();
    final payload = _payload.text;
    if (id.isEmpty || name.isEmpty || version.isEmpty) {
      setState(() => _error = 'id / 名称 / 版本都不能为空');
      return;
    }
    if (payload.trim().isEmpty) {
      setState(() => _error = '${_payloadLabel(_kind)}不能为空');
      return;
    }
    // URL 的形态在这里先拦一道(省一次往返): Rust 侧在抓取之前也会再判一次。
    if (_kind == _ImportKind.url && !_looksHttpsUrl(payload)) {
      setState(() => _error = '只接受 https:// 开头的链接');
      return;
    }
    Navigator.of(context).pop(
      _ImportSpec(
        kind: _kind,
        id: id,
        name: name,
        version: version,
        text: payload,
        lxEvents: _splitCsv(_events.text),
        requestDomains: _splitCsv(_domains.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('导入音源插件'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 来源三选一: 粘贴正文 / 本机文件绝对路径 / URL(没有文件选择器依赖, 所以收路径)。
            SegmentedButton<_ImportKind>(
              segments: const [
                ButtonSegment(
                  value: _ImportKind.paste,
                  label: Text('粘贴文本'),
                  icon: Icon(Icons.edit_note),
                ),
                ButtonSegment(
                  value: _ImportKind.file,
                  label: Text('本机文件'),
                  icon: Icon(Icons.folder_open),
                ),
                ButtonSegment(
                  value: _ImportKind.url,
                  label: Text('URL'),
                  icon: Icon(Icons.link),
                ),
              ],
              selected: {_kind},
              showSelectedIcon: false,
              onSelectionChanged: (selection) => setState(() {
                _kind = selection.first;
                _error = null;
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _id,
              decoration: const InputDecoration(
                labelText: 'id',
                helperText: '小写字母/数字/下划线/短横, 全区唯一',
              ),
            ),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            TextField(
              controller: _version,
              decoration: const InputDecoration(labelText: '版本'),
            ),
            TextField(
              controller: _events,
              decoration: const InputDecoration(
                labelText: '注册事件',
                helperText: '逗号分隔(musicUrl / request / search)',
              ),
            ),
            TextField(
              controller: _domains,
              decoration: const InputDecoration(
                labelText: '出站白名单',
                helperText: '逗号分隔(api.example.com / *.example.com); 留空 = 全部拒绝',
              ),
            ),
            if (_kind == _ImportKind.paste)
              TextField(
                controller: _payload,
                minLines: 6,
                maxLines: 12,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
                decoration: const InputDecoration(
                  labelText: '脚本正文',
                  alignLabelWithHint: true,
                  helperText: '粘贴 LX 兼容脚本(lx.on / lx.request ...)',
                ),
              )
            else if (_kind == _ImportKind.file)
              TextField(
                controller: _payload,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
                decoration: const InputDecoration(
                  labelText: '文件绝对路径',
                  helperText: '本机 .js 文件的绝对路径(UTF-8, ≤ 2 MiB)',
                ),
              )
            else
              TextField(
                controller: _payload,
                style: theme.textTheme.bodySmall,
                decoration: const InputDecoration(
                  labelText: '脚本 URL',
                  helperText: '只接受 https:// 直链(≤ 2 MiB, 最多跟随 3 次重定向)',
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('导入')),
      ],
    );
  }
}
