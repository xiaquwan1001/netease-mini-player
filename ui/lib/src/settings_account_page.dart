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
  });

  final rust.InitInfo? info;
  final bool isAndroid;
  final VoidCallback onLogin;
  final Future<void> Function() onLogout;
  final VoidCallback? onOpenVip;
  final Future<List<rust.AccountDto>> Function()? loadAccounts;
  final Future<void> Function(rust.AccountDto account)? onSwitchAccount;
  final Future<void> Function(rust.AccountDto account)? onRemoveAccount;

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
                  if (active?.vip == true) const VipBadge(small: true),
                ],
              ),
              subtitle: Text(
                _loggedIn
                    ? '账号与登录凭据保存在本机, 可随时切换'
                    : '登录后可同步收藏/歌单/推荐',
                style: theme.textTheme.bodySmall,
              ),
              trailing: _loggedIn || !widget.isAndroid
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
                leading: Icon(Icons.info_outline),
                title: Text('桌面端暂不支持内嵌登录'),
                subtitle: Text('可用 ncm login-cookie "MUSIC_U=..." 导入登录凭据'),
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
                        if (account.vip) const VipBadge(small: true),
                      ],
                    ),
                    subtitle: Text(account.active ? '当前账号' : '点击切换'),
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
