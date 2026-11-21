import 'package:flutter/material.dart';

import '../app_meta.dart';
import '../platform.dart';
import '../rust/api_all.dart' as rust;
import '../section_header.dart';
import '../state_views.dart';
import '../toast.dart';
import '../update_checker.dart';
import '../update_dialog.dart';

/// 设置二级页: 关于(版本/许可 / 开源仓库 / 检查更新 / 凭据存储).
///
/// 从设置首页拆出(2026-11 用户反馈: 设置页平铺内容太乱, 按主题分二级页).
/// 纯展示 + 两个主动作(检查更新、打开仓库), 不写任何设置项。
Future<void> showAboutPage(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => const AboutSettingsPage()),
  );
}

class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          12,
          8,
          12,
          24 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          const SectionTitle('关于', icon: Icons.info_outline),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('轻音 MiniNCM'),
                  subtitle: Text(
                    'Rust core + Flutter UI · 协议/加解密由 vendor 库负责\n'
                    '登录凭据与设备指纹只保存在本机数据目录',
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.code),
                  title: const Text('开源仓库'),
                  subtitle: const Text(
                    kGithubUrl,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => PlatformBridge.openUrl(kGithubUrl),
                ),
                const Divider(height: 1),
                const ListTile(
                  leading: Icon(Icons.description_outlined),
                  title: Text('版本与许可'),
                  subtitle: Text(
                    'v$kAppVersion · $kLicenseSummary',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Divider(height: 1),
                const _CheckUpdateTile(),
                const Divider(height: 1),
                // 凭据后端(Android Keystore / Windows DPAPI / 明文回退)属于
                // "这台机器怎么存东西", 从账号页的隐私栏搬到这里展示(2026-11 需求)。
                const _CredentialStorageTile(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 「检查更新」项: 点击手动检查(loading), 有新版本弹窗引导下载;
/// 启动静默检查发现新版本时在 trailing 显示红点(不弹窗打扰)。
class _CheckUpdateTile extends StatefulWidget {
  const _CheckUpdateTile();

  @override
  State<_CheckUpdateTile> createState() => _CheckUpdateTileState();
}

class _CheckUpdateTileState extends State<_CheckUpdateTile> {
  bool _checking = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateInfo?>(
      valueListenable: UpdateCheckHost.pendingUpdate,
      builder: (context, pending, _) {
        final newer = pending != null && pending.isNewer;
        return ListTile(
          leading: const Icon(Icons.system_update_outlined),
          title: Row(
            children: [
              const Text('检查更新'),
              if (newer) ...[
                const SizedBox(width: 8),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.error,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
          subtitle: Text(
            newer ? '发现新版本 ${pending.latest}' : '当前 v$kAppVersion',
          ),
          trailing: _checking
              ? const LoadingView.inline(size: 20)
              : const Icon(Icons.refresh),
          onTap: _checking ? null : _check,
        );
      },
    );
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    UpdateInfo? info;
    try {
      info = await UpdateCheckHost.check(kAppVersion);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
    if (!mounted) return;
    if (info == null) {
      showToast(context, '检查更新失败, 请检查网络后重试', isError: true);
      return;
    }
    if (!info.isNewer) {
      showToast(context, '已是最新版本 v${info.current}');
      return;
    }
    UpdateCheckHost.pendingUpdate.value = info;
    // 弹窗与启动自动检查共用一份实现(见 update_dialog.dart)
    await showUpdateDialog(context, info);
  }
}

/// 凭据后端状态行(Android Keystore / Windows DPAPI / 明文回退).
///
/// 2026-11 用户要求: 「隐私」栏目里的 Android Keystore 加密说明搬到设置 → 关于。
/// 只读展示, 失败不影响设置页其余部分(点一下可重试)。
class _CredentialStorageTile extends StatefulWidget {
  const _CredentialStorageTile();

  @override
  State<_CredentialStorageTile> createState() => _CredentialStorageTileState();
}

class _CredentialStorageTileState extends State<_CredentialStorageTile> {
  rust.CredentialStatusDto? _status;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final status = await rust.credentialStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return ListTile(
      leading: const Icon(Icons.enhanced_encryption_outlined),
      title: const Text('凭据存储'),
      subtitle: Text(
        status?.note ?? (_failed ? '凭据后端状态不可用, 点击重试' : '正在读取…'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      // 右侧原来还显示一遍后端名("android-keystore"), 与下方说明文案重复
      // (用户反馈: 凭据存储右边有一个重复的 android keystore 文本框)。
      onTap: _failed ? _load : null,
    );
  }
}
