import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;

import '../app_settings.dart';
import '../app_sheet.dart';
import '../desktop_shell.dart';
import '../platform_is.dart' show isAndroidPlatform;
import '../section_header.dart';
import '../toast.dart';
import 'settings_tiles.dart';

/// 设置二级页: 通知与系统(窗口关闭行为 / 通知权限 / 搜索交互 / 自动更新).
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
              // 通知权限只在 Android 有运行时开关(且 13+ 才需要允许); 其它平台没有
              // 「通知被拒绝」这个状态, 不给假行。
              if (isAndroidPlatform) ...[
                const SectionTitle('通知', icon: Icons.notifications_outlined),
                const Card(
                  margin: EdgeInsets.zero,
                  child: _NotificationPermissionTile(),
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

/// 通知权限桥(Android 专用)。
///
/// 通道就是 MainActivity 里那个 `ncm/open` 处理器(打开链接/下载/系统设置都是系统 Intent 出口,
/// 不另开通道); 方法名见 MainActivity 的 `notificationPermissionGranted` /
/// `openNotificationSettings`。
///
/// `@visibleForTesting` 导出只为让回归测试能装假通道 —— 页面上不露出通道名。
@visibleForTesting
const MethodChannel notificationPermissionChannel = MethodChannel('ncm/open');

/// 系统当前是否已授予本应用通知权限(Android 13+ 才有运行时开关; 更早的系统恒为 true,
/// 与 MainActivity.hasNotificationPermission 同一口径)。
///
/// 通道不可用(桌面/测试未装 handler)按「没有权限」处理: 宁可提示用户去系统设置看一眼,
/// 也不要谎报「已开启」。
Future<bool> androidNotificationsGranted() async {
  try {
    final granted = await notificationPermissionChannel.invokeMethod<bool>(
      'notificationPermissionGranted',
    );
    return granted ?? false;
  } catch (_) {
    return false;
  }
}

/// 打开本应用的系统通知设置页(用户在这里把被拒的开关重新打开)。
Future<void> openAndroidNotificationSettings() async {
  try {
    await notificationPermissionChannel.invokeMethod<bool>(
      'openNotificationSettings',
    );
  } catch (_) {
    // 打不开就算了: 页面上的文案已经告诉用户该去哪里点
  }
}

/// 「通知权限」一行: 已开启 → 只说一句; 被拒绝 → 给一个直达系统设置的按钮。
///
/// 为什么要这一行(审计 2026-11-26 P2#7): 冷启动 `ensureNotificationPermission()` 只申请一次,
/// 用户拒过之后 App 里**再没有任何提示或重开入口** —— 通知栏没媒体卡片(无播放控制/进度/封面),
/// 用户既不知道原因也找不到开关。
class _NotificationPermissionTile extends StatefulWidget {
  const _NotificationPermissionTile();

  @override
  State<_NotificationPermissionTile> createState() =>
      _NotificationPermissionTileState();
}

class _NotificationPermissionTileState
    extends State<_NotificationPermissionTile>
    with WidgetsBindingObserver {
  /// null = 还在读(通道是异步的, 先别写「被拒绝」骗人)
  bool? _granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置回来后重读一次: 用户刚点完「去系统设置」允许了权限, 回到这页应该当场变。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final granted = await androidNotificationsGranted();
    if (!mounted) return;
    setState(() => _granted = granted);
  }

  @override
  Widget build(BuildContext context) {
    final granted = _granted;
    final subtitle = switch (granted) {
      null => '正在读取…',
      true => '已开启 · 播放时通知栏会显示封面与播放控制',
      false => '被拒绝 · 通知栏不会显示播放控制, 需要在系统设置里重新允许',
    };
    return ListTile(
      key: const Key('notificationPermissionTile'),
      title: const Text('通知权限'),
      subtitle: Text(subtitle),
      trailing: granted == false
          ? TextButton(
              key: const Key('openNotificationSettings'),
              onPressed: openAndroidNotificationSettings,
              child: const Text('去系统设置'),
            )
          : null,
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
