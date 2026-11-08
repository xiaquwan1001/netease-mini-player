import 'package:flutter/material.dart';

import 'app_meta.dart';
import 'app_settings.dart';
import 'platform.dart';
import 'rust/api.dart' as rust;
import 'settings_diagnostics_page.dart';

/// 设置页(审查 P1-7.9 瘦身后): 只剩「App 怎么表现」的偏好开关 + 分组入口。
///
/// 搬走的内容:
/// - 账号 / 切换 / 退出登录 → 账号与会员二级页(settings_account_page.dart),
///   入口在「我的」页资料头(全 App 唯一账号面)。
/// - 黑胶会员 → 同上(会员是账号资产)。
/// - Rust 自检 / 设备 ID / 数据目录 → 诊断与数据二级页
///   (settings_diagnostics_page.dart), 从「关于」进入。
/// - 「清空搜索历史」→ 只保留动作发生处(搜索落地页, 审查 P1-7.11)。
class SettingsView extends StatelessWidget {
  const SettingsView({super.key, required this.info});

  /// 诊断二级页要展示设备 ID / 数据目录
  final rust.InitInfo? info;

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => ListView(
        padding: EdgeInsets.fromLTRB(
          12,
          8,
          12,
          24 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          const _SectionTitle('界面'),
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
                // R6: 深色模式下用 OLED 纯黑(#000000)取代 Material 的 #121212.
                // 只在深色/跟随系统时才有意义, 所以浅色态下用文案说明.
                SwitchListTile(
                  title: const Text('OLED 纯黑'),
                  subtitle: Text(
                    settings.themeMode == ThemeMode.light
                        ? '当前是浅色主题, 切到深色后生效'
                        : '深色下用 #000000 取代 #121212(OLED 屏更省电, 无灰边)',
                  ),
                  value: settings.oledDark,
                  onChanged: (value) => settings.update(oledDark: value),
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
          // 「行为」类开关: 搜索/播放原本是两个一级分组, 各只有一个开关时
          // 不必各占一个分区(审查 §5.3 建议并入「通用」)
          const _SectionTitle('通用'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('切到搜索时清空上次结果'),
                  subtitle: const Text('关闭后, 底部切回搜索仍保留上一次的关键词与结果'),
                  value: settings.clearSearchOnTabSwitch,
                  onChanged: (value) {
                    settings.update(clearSearchOnTabSwitch: value);
                  },
                ),
                const Divider(height: 1),
                ListTile(
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
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) settings.update(audioLevel: value);
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const _SectionTitle('关于'),
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
                ListTile(
                  leading: const Icon(Icons.monitor_heart_outlined),
                  title: const Text('诊断与数据'),
                  subtitle: const Text('Rust 通道自检 / 设备 ID / 数据目录'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showDiagnosticsPage(context, info: info),
                ),
              ],
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
