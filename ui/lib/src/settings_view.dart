import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'song_tile.dart';

/// 设置页: 账号凭据(登录/切换/退出/设备指纹) + 界面与播放偏好.
class SettingsView extends StatelessWidget {
  const SettingsView({
    super.key,
    required this.info,
    required this.isAndroid,
    required this.onLogin,
    required this.onLogout,
    required this.onShowAccounts,
    required this.onClearSearchHistory,
    this.onOpenVip,
  });

  final rust.InitInfo? info;
  final bool isAndroid;
  final VoidCallback onLogin;
  final Future<void> Function() onLogout;
  final VoidCallback onShowAccounts;
  final VoidCallback onClearSearchHistory;

  /// 打开黑胶会员页(不传则不显示入口)
  final VoidCallback? onOpenVip;

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => ListView(
        padding: EdgeInsets.fromLTRB(12, 8, 12, 24 + MediaQuery.viewPaddingOf(context).bottom),
        children: [
          _SectionTitle('账号'),
          _AccountCard(
            info: info,
            isAndroid: isAndroid,
            onLogin: onLogin,
            onLogout: onLogout,
            onShowAccounts: onShowAccounts,
          ),
          if (onOpenVip != null) ...[
            const SizedBox(height: 16),
            _SectionTitle('会员'),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.workspace_premium_outlined),
                title: const Text('黑胶会员'),
                subtitle: const Text('签到/任务/成长值(只读)'),
                trailing: const Icon(Icons.chevron_right),
                onTap: onOpenVip,
              ),
            ),
          ],
          const SizedBox(height: 16),
          _SectionTitle('界面'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  title: const Text('主题模式'),
                  subtitle: Text(_themeLabel(settings.themeMode)),
                  trailing: SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.brightness_auto),
                        label: Text('跟随'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode),
                        label: Text('浅色'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode),
                        label: Text('深色'),
                      ),
                    ],
                    selected: {settings.themeMode},
                    onSelectionChanged: (value) {
                      settings.update(themeMode: value.first);
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('界面字号'),
                  subtitle: Text(_scaleLabel(settings.textScale)),
                  trailing: DropdownButton<double>(
                    value: settings.textScale,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final entry in AppSettings.textScales.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) settings.update(textScale: value);
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('推荐卡片排列'),
                  subtitle: Text(
                    settings.coverRows == 1
                        ? '一排: 横向滑动, 一屏看得更多'
                        : '两排: 网格平铺, 少滑动多浏览',
                  ),
                  trailing: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 1, label: Text('一排')),
                      ButtonSegment(value: 2, label: Text('两排')),
                    ],
                    selected: {settings.coverRows},
                    onSelectionChanged: (value) {
                      settings.update(coverRows: value.first);
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle('搜索'),
          Card(
            margin: EdgeInsets.zero,
            child: SwitchListTile(
              title: const Text('切到搜索时清空上次结果'),
              subtitle: const Text('关闭后, 底部切回搜索仍保留上一次的关键词与结果'),
              value: settings.clearSearchOnTabSwitch,
              onChanged: (value) {
                settings.update(clearSearchOnTabSwitch: value);
              },
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle('播放'),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              title: const Text('取链音质'),
              subtitle: Text(
                '${AppSettings.audioLevels[settings.audioLevel] ?? settings.audioLevel}'
                ' · 需要会员的音质会自动回落到可用档位',
              ),
              trailing: DropdownButton<String>(
                value: settings.audioLevel,
                underline: const SizedBox.shrink(),
                items: [
                  for (final entry in AppSettings.audioLevels.entries)
                    DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                ],
                onChanged: (value) {
                  if (value != null) settings.update(audioLevel: value);
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle('诊断'),
          const Card(
            margin: EdgeInsets.zero,
            child: ChannelSelfCheckTile(),
          ),
          const SizedBox(height: 16),
          _SectionTitle('数据'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.search_off),
                  title: const Text('清空搜索历史'),
                  onTap: onClearSearchHistory,
                ),
                const Divider(height: 1),
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
          _SectionTitle('关于'),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('轻音 MiniNCM'),
              subtitle: const Text(
                'Rust core + Flutter UI · 协议/加解密由 vendor 库负责\n'
                '登录凭据与设备指纹只保存在本机数据目录',
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _themeLabel(ThemeMode mode) => switch (mode) {
        ThemeMode.light => '浅色',
        ThemeMode.dark => '深色',
        ThemeMode.system => '跟随系统',
      };

  static String _scaleLabel(double scale) {
    for (final entry in AppSettings.textScales.entries) {
      if ((entry.key - scale).abs() < 0.01) return entry.value;
    }
    return scale.toStringAsFixed(2);
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
                  ? Colors.green
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

class _AccountCard extends StatefulWidget {
  const _AccountCard({
    required this.info,
    required this.isAndroid,
    required this.onLogin,
    required this.onLogout,
    required this.onShowAccounts,
  });

  final rust.InitInfo? info;
  final bool isAndroid;
  final VoidCallback onLogin;
  final Future<void> Function() onLogout;
  final VoidCallback onShowAccounts;

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  late final Future<List<rust.AccountDto>> _accounts = rust.accounts();

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final loggedIn = info?.loggedIn == true;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          FutureBuilder<List<rust.AccountDto>>(
            future: _accounts,
            builder: (context, snap) {
              final accounts = snap.data ?? const <rust.AccountDto>[];
              final active = accounts.where((a) => a.active).firstOrNull;
              final nickname = active?.nickname;
              return ListTile(
                leading: CircleAvatar(
                  child: Icon(loggedIn ? Icons.person : Icons.person_outline),
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        loggedIn
                            ? (nickname == null || nickname.isEmpty
                                ? '已登录'
                                : nickname)
                            : '未登录',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (active?.vip == true) const VipBadge(small: true),
                  ],
                ),
                subtitle: Text(
                  loggedIn
                      ? '账号与登录凭据保存在本机, 可随时切换'
                      : '登录后可同步收藏/歌单/推荐',
                ),
                trailing: loggedIn
                    ? TextButton(
                        onPressed: widget.onShowAccounts,
                        child: const Text('账号管理'),
                      )
                    : (widget.isAndroid
                        ? FilledButton(
                            onPressed: widget.onLogin,
                            child: const Text('登录'),
                          )
                        : null),
              );
            },
          ),
          if (loggedIn) ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.switch_account),
              title: const Text('切换 / 管理账号'),
              subtitle: const Text('记住的账号可一键切换, 不需要重新扫码'),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onShowAccounts,
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('退出登录'),
              subtitle: const Text('账号仍留在账号簿, 下次可一键切回'),
              onTap: () async {
                await widget.onLogout();
              },
            ),
          ],
          if (!widget.isAndroid && !loggedIn)
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('桌面端暂不支持内嵌登录'),
              subtitle: Text('可用 ncm login-cookie "MUSIC_U=..." 导入登录凭据'),
            ),
        ],
      ),
    );
  }
}
