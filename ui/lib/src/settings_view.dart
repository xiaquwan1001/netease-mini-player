import 'dart:async';

import 'package:flutter/material.dart';

import 'app_meta.dart';
import 'app_settings.dart';
import 'daily_cache.dart';
import 'cover_quality_sheet.dart';
import 'platform.dart';
import 'rust/api.dart' as rust;
import 'section_header.dart';
import 'settings_audio_page.dart';
import 'settings_diagnostics_page.dart';
import 'state_views.dart';
import 'theme.dart' show AccentPalette;
import 'toast.dart';
import 'update_checker.dart';
import 'update_dialog.dart';

/// 设置页: 「App 怎么表现」的偏好开关 + 分组入口。
///
/// 二级页:
/// - 账号管理(账号簿/切换/添加/退出登录/清除凭据)→ settings_account_page.dart。
///   2026-11 用户反馈: 账号入口曾在「我的」页资料头/药丸/按钮三处重复,
///   现在统一收在这里(唯一入口)。
/// - Rust 自检 / 设备 ID / 数据目录 → 诊断与数据二级页
///   (settings_diagnostics_page.dart), 从「关于」进入。
/// - 「清空搜索历史」→ 只保留动作发生处(搜索落地页, 审查 P1-7.11)。
class SettingsView extends StatelessWidget {
  const SettingsView({super.key, required this.info, this.onOpenAccounts});

  /// 诊断二级页要展示设备 ID / 数据目录
  final rust.InitInfo? info;

  /// 打开账号管理二级页(不传则不显示入口, 测试/无宿主时用)
  final VoidCallback? onOpenAccounts;

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return AnimatedBuilder(
      animation: settings,
      // 页面本身已有 12dp 横向留白; ListTile 默认再吃 16dp → 文字距屏 28dp。
      // 统一收紧到 12(叠后 24), 与列表类内容的基线一致(2026-11 布局审计 #1)。
      builder: (context, _) => ListTileTheme(
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
            if (onOpenAccounts != null) ...[
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.manage_accounts_outlined),
                  title: const Text('账号管理'),
                  subtitle: Text(
                    info?.loggedIn == true
                        ? '已登录 · 切换账号 / 添加账号 / 退出登录'
                        : '未登录 · 登录后可同步收藏与歌单',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: onOpenAccounts,
                ),
              ),
              const SizedBox(height: 16),
            ],
            const SectionTitle('界面'),
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
                  // 视觉风格: 同一色板同时决定浅色/深色两套配色(不是两套独立开关)
                  _AccentSettingTile(
                    selected: settings.accent,
                    onSelected: (value) => settings.update(accent: value),
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
                  const Divider(height: 1),
                  _SegmentedSettingTile<int>(
                    title: '方格网格列数',
                    subtitle: '艺人专辑 / 精选新碟 / 歌单广场每行几张(均分, 不留空隙)',
                    segments: const [
                      ButtonSegment(value: 2, label: Text('2')),
                      ButtonSegment(value: 3, label: Text('3')),
                      ButtonSegment(value: 4, label: Text('4')),
                    ],
                    selected: settings.gridColumns,
                    onSelectionChanged: (value) {
                      settings.update(gridColumns: value);
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
            const SectionTitle('通用'),
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
                  // 播放策略(2026-11 用户需求): 不想听会员曲目时, 切歌/续播直接跳过。
                  SwitchListTile(
                    title: const Text('播放跳过 VIP 歌曲'),
                    subtitle: const Text('切歌与自动续播时跳过需要黑胶会员的曲目(列表里仍然显示)'),
                    value: settings.skipVipSongs,
                    onChanged: (value) {
                      settings.update(skipVipSongs: value);
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    title: const Text('歌单内搜索后点歌'),
                    subtitle: Text(
                      '${settings.librarySearchPlayAction.label} · ${settings.librarySearchPlayAction.hint}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showLibrarySearchPlaySheet(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    title: const Text('自动检查更新'),
                    subtitle: Text(
                      '${settings.updateCheckInterval.label} · 发现新版本时弹窗提示',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showUpdateIntervalSheet(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    title: const Text('封面与图片清晰度'),
                    subtitle: Text(
                      '${settings.coverQuality.label} · ${settings.coverQuality.hint}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showCoverQualitySheet(context),
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
            // 每日推荐歌单缓存(2026-11 用户需求): 保留天数 + 立即清理 + 上次清理时间
            const SectionTitle('缓存'),
            Card(
              margin: EdgeInsets.zero,
              child: _DailyCacheTile(dataDir: info?.dataDir),
            ),
            const SizedBox(height: 16),
            const SectionTitle('关于'),
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
                  const Divider(height: 1),
                  // 凭据后端(Android Keystore / Windows DPAPI / 明文回退)属于
                  // "这台机器怎么存东西", 从账号页的隐私栏搬到这里展示(2026-11 需求)。
                  const _CredentialStorageTile(),
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

/// 每日推荐歌单缓存: 保留天数 + 立即清理 + 上次清理时间。
///
/// 缓存本身在 `daily_cache.dart`(按天明文件); 这里只做展示与"什么时候清"。
/// 上次清理时间从缓存目录读, 所以点完「立即清理」要重读一次才好看见变化。
class _DailyCacheTile extends StatefulWidget {
  const _DailyCacheTile({required this.dataDir});

  final String? dataDir;

  @override
  State<_DailyCacheTile> createState() => _DailyCacheTileState();
}

class _DailyCacheTileState extends State<_DailyCacheTile> {
  DateTime? _lastCleanup;
  bool _cleaning = false;

  DailyPlaylistCache? get _cache {
    final dir = widget.dataDir;
    if (dir == null || dir.isEmpty) return null;
    return DailyPlaylistCache(dataDir: dir);
  }

  @override
  void initState() {
    super.initState();
    _loadLastCleanup();
  }

  Future<void> _loadLastCleanup() async {
    final at = await _cache?.lastCleanup();
    if (!mounted) return;
    setState(() => _lastCleanup = at);
  }

  /// 保留天数一变就顺手按新口径清一次: 否则用户把 30 天改成 3 天,
  /// 旧文件要等到下次手动清理才消失。
  Future<void> _setDays(int days) async {
    await AppSettings.instance.update(dailyCacheDays: days);
    if (mounted) setState(() {});
    await _cleanup();
  }

  Future<void> _cleanup() async {
    final cache = _cache;
    if (cache == null || _cleaning) return;
    setState(() => _cleaning = true);
    try {
      final removed = await cache.cleanup(
        keepDays: AppSettings.instance.dailyCacheDays,
      );
      await _loadLastCleanup();
      if (!mounted) return;
      showToast(context, removed == 0 ? '没有需要清理的缓存' : '已清理 $removed 份旧缓存');
    } catch (e) {
      if (!mounted) return;
      showToast(context, '清理失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  String get _cleanupLabel {
    final at = _lastCleanup;
    if (at == null) return '还没有清理过';
    String two(int v) => v.toString().padLeft(2, '0');
    return '上次清理: ${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return Column(
      children: [
        ListTile(
          title: const Text('每日推荐歌单缓存'),
          subtitle: Text(
            settings.dailyCacheDays <= 0
                ? '已关闭: 每次进推荐页都联网拉取'
                : '同一天只拉一次, 保留 ${settings.dailyCacheDays} 天',
          ),
          trailing: DropdownButton<int>(
            value: settings.dailyCacheDays,
            underline: const SizedBox.shrink(),
            items: [
              for (final days in AppSettings.dailyCacheOptions)
                DropdownMenuItem(
                  value: days,
                  child: Text(AppSettings.dailyCacheLabel(days)),
                ),
            ],
            onChanged: (value) {
              if (value != null) _setDays(value);
            },
          ),
        ),
        const Divider(height: 1),
        ListTile(
          leading: _cleaning
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cleaning_services_outlined),
          title: const Text('立即清理'),
          subtitle: Text(_cleanupLabel),
          onTap: _cleaning ? null : _cleanup,
        ),
      ],
    );
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
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
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

/// 「歌单内搜索后点歌」行为选择。
Future<void> showLibrarySearchPlaySheet(BuildContext context) async {
  final settings = AppSettings.instance;
  final current = settings.librarySearchPlayAction;
  final picked = await showModalBottomSheet<LibrarySearchPlayAction>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '歌单内搜索后点歌',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          for (final value in LibrarySearchPlayAction.values)
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
  settings.update(librarySearchPlayAction: picked);
}

/// 「自动检查更新」频率选择: 不自动检查 / 每天 / 每周 / 每月。
Future<void> showUpdateIntervalSheet(BuildContext context) async {
  final settings = AppSettings.instance;
  final current = settings.updateCheckInterval;
  final picked = await showModalBottomSheet<UpdateCheckInterval>(
    context: context,
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

/// 主题色(视觉风格)选择器: 一行色点, 选中项带对勾与描边.
///
/// 不塞进 SegmentedButton: 5 个色板在 300dp + 1.25 字号下会把分段控件挤爆
/// (与「界面字号」同样的窄屏约束, 见 test/settings_narrow_overflow_test.dart),
/// 这里用 Wrap + 纯色圆点, 换行即可, 不依赖文字宽度。
class _AccentSettingTile extends StatelessWidget {
  const _AccentSettingTile({required this.selected, required this.onSelected});

  final AccentPalette selected;
  final ValueChanged<AccentPalette> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('主题色', style: theme.textTheme.titleMedium),
          const SizedBox(height: 2),
          Text('${selected.label} · 浅色/深色通用', style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              for (final palette in AccentPalette.values)
                _dot(context, palette),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dot(BuildContext context, AccentPalette palette) {
    final theme = Theme.of(context);
    final isSelected = palette == selected;
    return Tooltip(
      message: palette.label,
      child: InkWell(
        key: ValueKey('accent-${palette.id}'),
        borderRadius: BorderRadius.circular(22),
        onTap: () => onSelected(palette),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: palette.seed,
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected
                  ? theme.colorScheme.onSurface
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: isSelected
              ? const Icon(Icons.check, size: 20, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}
