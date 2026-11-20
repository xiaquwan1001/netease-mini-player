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
          trailing: _rescanButton(),
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
      ],
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
    return SwitchListTile(
      value: summary.enabled,
      onChanged: canToggle ? (value) => _togglePlugin(summary, value) : null,
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
        ],
      ),
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
