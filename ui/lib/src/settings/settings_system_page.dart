import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../app_sheet.dart';
import '../desktop_shell.dart';
import '../platform_is.dart' show isAndroidPlatform;
import '../section_header.dart';
import '../toast.dart';
import 'settings_tiles.dart';

/// 设置二级页: 通知与系统(窗口关闭行为 / 搜索交互 / 自动更新).
///
/// 从设置首页拆出(2026-11 用户反馈: 设置页平铺内容太乱, 按主题分二级页).
Future<void> showSystemPage(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => const SystemSettingsPage()),
  );
}

class SystemSettingsPage extends StatelessWidget {
  const SystemSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    // Linux: 真开关; Windows: 保留「仅 Linux 生效」说明行;
    // Android: 整块不渲染(用户 2026-11-18 口径)。见谓词注释。
    final showCloseBehavior = shouldShowCloseBehaviorTile(
      isLinux: DesktopShell.isSupportedPlatform,
      isAndroid: isAndroidPlatform,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('通知与系统')),
      // 本页写的是平台/搜索/更新三个域; 拖动音量或改外观不该重建这张列表。
      body: AppSettingsScopedBuilder(
        domains: const {
          AppSettingsDomain.platform,
          AppSettingsDomain.search,
          AppSettingsDomain.update,
        },
        builder: (context) => ListTileTheme(
          // 与其它设置二级页同一口径(页面 12 + 行内 12 = 24)。
          data: const ListTileThemeData(
            contentPadding: EdgeInsets.symmetric(horizontal: 12),
          ),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              12,
              8,
              12,
              24 + MediaQuery.viewPaddingOf(context).bottom,
            ),
            children: [
              if (showCloseBehavior) ...[
                const SectionTitle('窗口', icon: Icons.desktop_windows_outlined),
                Card(
                  margin: EdgeInsets.zero,
                  child: _CloseBehaviorTile(settings: settings),
                ),
                const SizedBox(height: 16),
              ],
              const SectionTitle('搜索', icon: Icons.search),
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
              const SectionTitle('更新', icon: Icons.system_update_outlined),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  title: const Text('自动检查更新'),
                  subtitle: Text(
                    '${settings.updateCheckInterval.label} · 发现新版本时弹窗提示',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showUpdateIntervalSheet(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「关闭主窗口时」这一整块该不该出现在设置页里(纯谓词, 单测见
/// ui/test/close_behavior_tile_visible_test.dart)。
///
/// - Linux: 真开关(直接退出 / 最小化到托盘), 托盘能力由原生探测;
/// - Windows: 没有托盘语义, 但保留一行如实说明「仅 Linux 生效」(不给假开关);
/// - Android: 用户 2026-11-18 口径是「直接省略」—— 手机既没有主窗口关闭按钮,
///   也没有托盘, 整块(含它后面的分隔线)不该占位, 不是置灰、也不是留说明行。
bool shouldShowCloseBehaviorTile({
  required bool isLinux,
  required bool isAndroid,
}) => isLinux || !isAndroid;

/// 「关闭主窗口时」设置项: Linux 桌面可选「直接退出 / 最小化到托盘」。
///
/// 非 Linux(只剩 Windows 会到这里, Android 由 [shouldShowCloseBehaviorTile]
/// 整块省略)不撒谎也不给假开关: 只显示一行说明"仅 Linux 生效"。
/// 托盘是否真的可用由原生 getStatus 决定(见 desktop_shell.dart), 副标题会如实写
/// "将降级为最小化到任务栏"。
class _CloseBehaviorTile extends StatelessWidget {
  const _CloseBehaviorTile({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final linux = DesktopShell.isSupportedPlatform;
    return ValueListenableBuilder<TrayStatus>(
      valueListenable: DesktopShell.instance.status,
      builder: (context, trayStatus, _) {
        final subtitle = closeBehaviorSubtitle(
          behavior: settings.closeBehavior,
          status: trayStatus,
          linux: linux,
        );
        if (!linux) {
          return ListTile(
            title: const Text('关闭主窗口时'),
            subtitle: Text(subtitle),
          );
        }
        return SegmentedSettingTile<CloseBehavior>(
          title: '关闭主窗口时',
          subtitle: subtitle,
          segments: const [
            ButtonSegment(value: CloseBehavior.quit, label: Text('直接退出')),
            ButtonSegment(
              value: CloseBehavior.minimizeToTray,
              label: Text('最小化到托盘'),
            ),
          ],
          selected: settings.closeBehavior,
          onSelectionChanged: (value) {
            settings.update(closeBehavior: value);
            // 选了托盘但这台机器没有托盘宿主: 当场说清会降级, 别让用户以为成功了
            if (value == CloseBehavior.minimizeToTray && trayStatus.degraded) {
              showToast(context, '当前桌面没有托盘, 关闭窗口将最小化到任务栏');
            }
          },
        );
      },
    );
  }
}

/// 「自动检查更新」频率选择: 不自动检查 / 每天 / 每周 / 每月。
Future<void> showUpdateIntervalSheet(BuildContext context) async {
  final settings = AppSettings.instance;
  final current = settings.updateCheckInterval;
  final picked = await showAppSheet<UpdateCheckInterval>(
    context,
    isScrollControlled: false,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '自动检查更新',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          for (final value in UpdateCheckInterval.values)
            ListTile(
              title: Text(value.label),
              subtitle: Text(value.hint),
              trailing: value == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(ctx).pop(value),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (picked == null) return;
  settings.update(updateCheckInterval: picked);
}
