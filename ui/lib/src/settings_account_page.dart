import 'package:flutter/material.dart';

import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'song_tile.dart' show VipBadge;

/// 账号与会员二级页 —— 全 App **唯一**的账号面(审查 P1-7.9 / P1-7.10)。
///
/// 从设置页搬出来的原因: 「退出登录/切换账号/黑胶会员」都是"我的东西",
/// 用户的心理模型在「我的」而不是「设置」。入口只剩「我的」页资料头
/// (ProfileHeader 整块点击 + 右上角药丸), 见 mine_view.dart。
///
/// 账号簿列表、切换、忘记账号的行为与原 main.dart 的 _showAccountSheet
/// 一致; 网络/FFI 失败不阻塞页面(只影响列表)。
Future<void> showAccountPage(
  BuildContext context, {
  required rust.InitInfo? info,
  required bool isAndroid,
  required VoidCallback onLogin,
  required Future<void> Function() onLogout,
  /// 打开黑胶会员页(不传则不显示入口)
  VoidCallback? onOpenVip,
  /// 测试注入: 账号簿
  Future<List<rust.AccountDto>> Function()? loadAccounts,
  /// 切换账号(缺省只调 rust.accountSwitch)
  Future<void> Function(rust.AccountDto account)? onSwitchAccount,
  /// 忘记账号(缺省只调 rust.accountRemove)
  Future<void> Function(rust.AccountDto account)? onRemoveAccount,
  /// 清除本机全部登录凭据(退出登录 + 忘掉账号簿里所有账号).
  /// 不传则不显示该入口(测试/无凭据时保持页面简洁).
  Future<void> Function()? onPurgeLocal,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => AccountPage(
        info: info,
        isAndroid: isAndroid,
        onLogin: onLogin,
        onLogout: onLogout,
        onOpenVip: onOpenVip,
        loadAccounts: loadAccounts,
        onSwitchAccount: onSwitchAccount,
        onRemoveAccount: onRemoveAccount,
        onPurgeLocal: onPurgeLocal,
      ),
    ),
  );
}

class AccountPage extends StatefulWidget {
  const AccountPage({
    super.key,
    required this.info,
    required this.isAndroid,
    required this.onLogin,
    required this.onLogout,
    this.onOpenVip,
    this.loadAccounts,
    this.onSwitchAccount,
    this.onRemoveAccount,
    this.onPurgeLocal,
  });

  final rust.InitInfo? info;
  final bool isAndroid;
  final VoidCallback onLogin;
  final Future<void> Function() onLogout;
  final VoidCallback? onOpenVip;
  final Future<List<rust.AccountDto>> Function()? loadAccounts;
  final Future<void> Function(rust.AccountDto account)? onSwitchAccount;
  final Future<void> Function(rust.AccountDto account)? onRemoveAccount;
  final Future<void> Function()? onPurgeLocal;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  List<rust.AccountDto> _accounts = const [];

  /// 登录态以入参为初值, 页面内退出后就地翻转(父层 push 时捕获的是快照)
  late bool _loggedIn = widget.info?.loggedIn == true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    try {
      final list = await retryNetwork(widget.loadAccounts ?? rust.accounts);
      if (!mounted) return;
      setState(() => _accounts = list);
    } catch (_) {
      // 账号簿读不出来不影响登录态: 页面里仍有"添加账号"
    }
  }

  rust.AccountDto? get _active {
    for (final a in _accounts) {
      if (a.active) return a;
    }
    return null;
  }

  Future<void> _switch(rust.AccountDto account) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final handler = widget.onSwitchAccount;
      if (handler != null) {
        await handler(account);
      } else {
        await rust.accountSwitch(userId: account.userId);
      }
    } catch (_) {
      // 上层已 toast; 这里只保证 UI 不卡
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _loadAccounts();
  }

  Future<void> _remove(rust.AccountDto account) async {
    try {
      final handler = widget.onRemoveAccount;
      if (handler != null) {
        await handler(account);
      } else {
        await rust.accountRemove(userId: account.userId);
      }
    } catch (_) {
      // 同上
    } finally {
      if (mounted) await _loadAccounts();
    }
  }

  Future<void> _logout() async {
    await widget.onLogout();
    if (!mounted) return;
    setState(() => _loggedIn = false);
  }

  /// 清除本机凭据(隐私用途): 退出登录 + 忘掉账号簿里的每个账号.
  /// 二次确认, 因为不可撤销(要重新扫码).
  Future<void> _purge() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除本机登录凭据?'),
        content: const Text(
          '会退出登录并删除本机保存的全部账号凭据(MUSIC_U), 之后需要重新扫码。\n'
          '设备指纹(device_id)会保留, 以免下次登录看起来像换了一台设备。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final handler = widget.onPurgeLocal;
    if (handler != null) {
      await handler();
    } else {
      if (_loggedIn) await widget.onLogout();
      for (final a in List<rust.AccountDto>.of(_accounts)) {
        await rust.accountRemove(userId: a.userId);
      }
    }
    if (!mounted) return;
    setState(() => _loggedIn = false);
    await _loadAccounts();
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    final nickname = active?.nickname;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('账号与会员')),
      body: ListView(
        // 手势条留白(审查 P1-7.15)
        padding: EdgeInsets.fromLTRB(
          12,
          8,
          12,
          24 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: CircleAvatar(
                child: Icon(_loggedIn ? Icons.person : Icons.person_outline),
              ),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      _loggedIn
                          ? (nickname == null || nickname.isEmpty
                              ? '已登录'
                              : nickname)
                          : '未登录',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // 未登录时绝不显示账号簿里的会员标识: 那是上一个登录态留下的缓存,
                  // 会被误读成"当前账号是会员"(2026-11-10 用户报的占位泄露问题).
                  if (_loggedIn && active?.vip == true)
                    const VipBadge(small: true),
                ],
              ),
              subtitle: Text(
                _loggedIn
                    ? '账号与登录凭据保存在本机, 可随时切换'
                    : '登录后可同步收藏/歌单/推荐',
                style: theme.textTheme.bodySmall,
              ),
              trailing: _loggedIn
                  ? null
                  : FilledButton(
                      onPressed: widget.onLogin,
                      child: const Text('登录'),
                    ),
            ),
          ),
          if (!widget.isAndroid && !_loggedIn)
            const Card(
              margin: EdgeInsets.only(top: 8),
              child: ListTile(
                leading: Icon(Icons.qr_code_2),
                title: Text('桌面端用官方扫码登录'),
                subtitle: Text('点「登录」用手机网易云 App 扫码; 也可以导入浏览器里的 MUSIC_U'),
              ),
            ),
          if (widget.onOpenVip != null) ...[
            const SizedBox(height: 16),
            const _SectionTitle('会员'),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.workspace_premium_outlined),
                title: const Text('黑胶会员'),
                subtitle: const Text('签到/任务/成长值(只读)'),
                trailing: const Icon(Icons.chevron_right),
                onTap: widget.onOpenVip,
              ),
            ),
          ],
          const SizedBox(height: 16),
          const _SectionTitle('账号簿'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                if (_accounts.isEmpty)
                  const ListTile(
                    dense: true,
                    title: Text('还没有记住的账号'),
                    subtitle: Text('登录一次后会自动记住, 之后可直接切换'),
                  ),
                for (final account in _accounts)
                  ListTile(
                    leading: Icon(
                      account.active
                          ? Icons.check_circle
                          : Icons.person_outline,
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            account.nickname.isEmpty
                                ? '账号 ${account.userId}'
                                : account.nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // 只有"已登录 + 当前账号"才显示会员标, 否则是过期的缓存
                        if (_loggedIn && account.active && account.vip)
                          const VipBadge(small: true),
                      ],
                    ),
                    subtitle: Text(
                      account.active
                          ? (_loggedIn ? '当前账号' : '上次登录的账号(当前未登录)')
                          : '点击切换',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '忘记这个账号',
                      onPressed: () => _remove(account),
                    ),
                    onTap: account.active ? null : () => _switch(account),
                  ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('添加账号'),
                  subtitle: const Text('打开官方登录页'),
                  onTap: widget.onLogin,
                ),
              ],
            ),
          ),
          if (_loggedIn) ...[
            const SizedBox(height: 16),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('退出登录'),
                subtitle: const Text('账号仍留在账号簿, 下次可一键切回'),
                onTap: _logout,
              ),
            ),
          ],
          if (_accounts.isNotEmpty) ...[
            const SizedBox(height: 16),
            const _SectionTitle('隐私'),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: Icon(
                  Icons.delete_forever_outlined,
                  color: theme.colorScheme.error,
                ),
                title: const Text('清除本机登录凭据'),
                subtitle: const Text('退出登录并删掉账号簿里的 MUSIC_U(共用电脑/出二手前用)'),
                onTap: _purge,
              ),
            ),
          ],
        ],
      ),
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
