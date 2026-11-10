import 'dart:async';

import 'package:flutter/material.dart';

import 'app_meta.dart';
import 'app_settings.dart';
import 'platform.dart';
import 'rust/api.dart' as rust;
import 'settings_audio_page.dart';
import 'settings_diagnostics_page.dart';
import 'toast.dart';
import 'update_checker.dart';

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
                _SegmentedSettingTile<ThemeMode>(
                  title: '主题模式',
                  subtitle: _themeLabel(settings.themeMode),
                  segments: const [
                    ButtonSegment(value: ThemeMode.system, label: Text('跟随')),
                    ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                  ],
                  selected: settings.themeMode,
                  onSelectionChanged: (value) {
                    settings.update(themeMode: value);
                  },
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
                _SegmentedSettingTile<int>(
                  title: '推荐卡片排列',
                  subtitle: settings.coverRows == 1
                      ? '一排: 横向滑动, 一屏看得更多'
                      : '两排: 网格平铺, 少滑动多浏览',
                  segments: const [
                    ButtonSegment(value: 1, label: Text('一排')),
                    ButtonSegment(value: 2, label: Text('两排')),
                  ],
                  selected: settings.coverRows,
                  onSelectionChanged: (value) {
                    settings.update(coverRows: value);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.graphic_eq),
              title: const Text('播放与音质'),
              subtitle: const Text('精细音量 · 响度均衡 · 淡入淡出 · 解码与缓存 · 自定义响度曲线'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showAudioSettingsPage(context),
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
                SwitchListTile(
                  title: const Text('显示热搜建议'),
                  subtitle: const Text('关闭后搜索页不再显示热门搜索榜, 只留搜索历史与猜你想搜'),
                  value: settings.showHotSearch,
                  onChanged: (value) {
                    settings.update(showHotSearch: value);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('启动时检查更新'),
                  subtitle: const Text('连接 GitHub 检查新版本; 关闭后仍可在「关于」里手动检查'),
                  value: settings.updateCheckOnStartup,
                  onChanged: (value) {
                    settings.update(updateCheckOnStartup: value);
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
                const _CheckUpdateTile(),
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

/// 带分段选择器的设置行。
///
/// 之前用 `ListTile(trailing: SegmentedButton(...))`: 窄屏 + 大字号下(例如
/// vivo 真机 1440x3168 @ density 768 ⇒ 300dp 宽, 系统字号 1.25)trailing 被要求
/// 吃掉整行宽度, ListTile 直接抛
/// "Trailing widget consumes the entire tile width", 该 ListTile 及其后的
/// render box 都不再布局 ⇒ 文案竖排、内容越界。
/// 所以分段控件单独占一行, 宽度跟着内容走, 极端字号下退化为横向滚动。
class _SegmentedSettingTile<T> extends StatelessWidget {
  const _SegmentedSettingTile({
    required this.title,
    required this.subtitle,
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
  });

  final String title;
  final String subtitle;
  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 外层 Card 的 Column 是交叉轴 center, 不给满宽就会整行被居中
    // (表现为「主题模式」这行相对上下 ListTile 缩进/不对齐)。
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<T>(
                showSelectedIcon: false,
                segments: segments,
                selected: {selected},
                onSelectionChanged: (value) => onSelectionChanged(value.first),
              ),
            ),
          ],
        ),
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
          title: Row(children: [
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
          ]),
          subtitle: Text(newer ? '发现新版本 ${pending.latest}' : '当前 v$kAppVersion'),
          trailing: _checking
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
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
    // 捕获成非空局部变量: 闭包里不能靠 info 的类型提升(它是可变局部变量), 之前那种 info! 只是绕过去
    final upd = info;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('发现新版本 ${upd.latest}'),
        content: Text(_trimNotes(upd.notes)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('later'),
            child: const Text('稍后'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('download'),
            child: const Text('前往下载'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'later') {
      AppSettings.instance.skipUpdate(info.latest);
      return;
    }
    final url = info.downloadUrl;
    if (url != null && url.isNotEmpty) {
      await UpdateCheckHost.openUrl(url);
    } else {
      await UpdateCheckHost.openUrl(kGithubUrl);
    }
  }

  static String _trimNotes(String? notes) {
    if (notes == null) return '';
    final one = notes.trim();
    return one.length > 200 ? '${one.substring(0, 200)}…' : one;
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
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}
