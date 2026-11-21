import 'package:flutter/material.dart';

import '../rust/api_all.dart' as rust;
import 'settings_about_page.dart';
import 'settings_appearance_page.dart';
import 'settings_audio_page.dart';
import 'settings_diagnostics_page.dart';
import 'settings_plugins_page.dart';
import 'settings_system_page.dart';

// 旧调用点与既有测试是从本文件拿这些符号的(主题三档 / 纯黑口径 / 关闭行为谓词)。
// 实体已按主题搬进各自二级页, 这里只做**再导出**, 不重复实现 —— 门禁脚本与
// 单测的 import 因此零改动。
export 'settings_about_page.dart' show AboutSettingsPage, showAboutPage;
export 'settings_appearance_page.dart'
    show
        AppearanceSettingsPage,
        ThemeChoice,
        applyThemeChoice,
        isOledDarkEffective,
        oledDarkLabel,
        showAppearancePage,
        themeChoiceLabel,
        themeChoiceOf;
export 'settings_system_page.dart'
    show
        SystemSettingsPage,
        shouldShowCloseBehaviorTile,
        showSystemPage,
        showUpdateIntervalSheet;

/// 设置首页: **只有主题入口**, 每项进一个二级页(2026-11 用户反馈:
/// 「设置页面内容很乱, 需要整改为按照不同主题划分二级页面」)。
///
/// 分组与落点(旧位置 → 新位置见 docs 内的 IA 表):
/// - 账号与同步 → settings_account_page.dart(账号簿/切换/添加/退出登录/清除凭据;
///   入口由宿主通过 [onOpenAccounts] 注入, 仍是全 App 唯一的账号面)。
/// - 播放与音质 → settings_audio_page.dart(精细音量/响度/淡入淡出/解码缓存/
///   歌词来源/自定义响度曲线 + 本轮的取链音质、跳过 VIP、歌单内点歌、定时关闭)。
/// - 外观与布局 → settings_appearance_page.dart(主题/纯黑/主题色/字号/卡片排列/
///   网格列数/封面清晰度)。
/// - 通知与系统 → settings_system_page.dart(关闭主窗口时/切到搜索清空/自动检查更新)。
/// - 插件与音源 → settings_plugins_page.dart(总开关/插件清单/音源路由)。
/// - 数据与诊断 → settings_diagnostics_page.dart(日推缓存/匿名诊断/设备 ID/数据目录)。
/// - 关于 → settings_about_page.dart(版本与许可/开源仓库/检查更新/凭据存储)。
///
/// 「清空搜索历史」仍然只在动作发生处(搜索落地页, 审查 P1-7.11), 不进设置。
class SettingsView extends StatelessWidget {
  const SettingsView({super.key, required this.info, this.onOpenAccounts});

  /// 诊断二级页要展示设备 ID / 数据目录
  final rust.InitInfo? info;

  /// 打开账号管理二级页(不传则不显示入口, 测试/无宿主时用)
  final VoidCallback? onOpenAccounts;

  @override
  Widget build(BuildContext context) {
    final loggedIn = info?.loggedIn == true;
    final entries = <Widget>[
      if (onOpenAccounts != null)
        _SettingsEntry(
          icon: Icons.manage_accounts_outlined,
          title: '账号与同步',
          subtitle: loggedIn ? '已登录 · 切换账号 / 添加账号 / 退出登录' : '未登录 · 登录后可同步收藏与歌单',
          onTap: onOpenAccounts!,
        ),
      _SettingsEntry(
        icon: Icons.graphic_eq,
        title: '播放与音质',
        subtitle: '精细音量 · 响度均衡 · 淡入淡出 · 音质与歌词来源 · 定时关闭',
        onTap: () => showAudioSettingsPage(context),
      ),
      _SettingsEntry(
        icon: Icons.palette_outlined,
        title: '外观与布局',
        subtitle: '主题模式 · 主题色 · 界面字号 · 卡片排列 · 网格列数 · 封面清晰度',
        onTap: () => showAppearancePage(context),
      ),
      _SettingsEntry(
        icon: Icons.desktop_windows_outlined,
        title: '通知与系统',
        subtitle: '关闭主窗口行为 · 切到搜索时清空 · 自动检查更新',
        onTap: () => showSystemPage(context),
      ),
      _SettingsEntry(
        icon: Icons.extension_outlined,
        title: '插件与音源',
        subtitle: '总开关 / 已装载插件 / 音源路由 / 导入与日志',
        onTap: () => showPluginsPage(context),
      ),
      _SettingsEntry(
        icon: Icons.monitor_heart_outlined,
        title: '数据与诊断',
        subtitle: '每日推荐缓存 · 匿名诊断 · 设备 ID · 数据目录',
        onTap: () => showDiagnosticsPage(context, info: info),
      ),
      _SettingsEntry(
        icon: Icons.info_outline,
        title: '关于',
        subtitle: '版本与许可 · 检查更新 · 凭据存储 · 开源仓库',
        onTap: () => showAboutPage(context),
      ),
    ];
    return ListTileTheme(
      // 页面本身已有 12dp 横向留白; ListTile 默认再吃 16dp → 文字距屏 28dp。
      // 统一收紧到 12(叠后 24), 与列表类内容的基线一致(2026-11 布局审计 #1)。
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
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < entries.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  entries[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 首页的主题入口行: 图标 + 标题 + 一句"这一页里有什么" + 右侧箭头。
///
/// 副标题用 [Text] 的 maxLines 2 + ellipsis(窄屏/大字号下长副标题必须收住,
/// 与设置二级页里的入口行同一口径)。
class _SettingsEntry extends StatelessWidget {
  const _SettingsEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
