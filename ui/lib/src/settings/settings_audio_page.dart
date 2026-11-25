import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_settings.dart';
import '../app_sheet.dart';
import '../eq_curve_chart.dart';
import '../eq_import.dart';
import '../eq_profile.dart';
import '../platform_is.dart' show isAndroidPlatform;
import '../section_header.dart';
import '../toast.dart';
import 'settings_sleep_timer_page.dart';

/// 设置二级页: 播放与音质(R2 / R2b / R5 / R7 的设置 UI 部分).
///
/// 只读写 AppSettings.instance; 真正在播放侧应用这些值由
/// S3(Android Media3)/ S4(Rust rodio) 车道负责, 本页不接任何 FFI.
Future<void> showAudioSettingsPage(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => const AudioSettingsPage()),
  );
}

class AudioSettingsPage extends StatefulWidget {
  const AudioSettingsPage({super.key});

  @override
  State<AudioSettingsPage> createState() => _AudioSettingsPageState();
}

class _AudioSettingsPageState extends State<AudioSettingsPage> {
  @override
  void initState() {
    super.initState();
    _ensureDefaultCurve();
  }

  /// 无 profile 时首次生成默认曲线(10 段全 0 dB, 等价旁路)并生效.
  /// 已有内容(默认或用户导入/拖动过的)一律不覆盖.
  void _ensureDefaultCurve() {
    final settings = AppSettings.instance;
    final text = settings.eqProfileText;
    if (text != null && text.trim().isNotEmpty) return;
    settings.update(
      eqProfileText: defaultEqProfileText(),
      eqProfileName: '默认曲线',
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('播放与音质')),
      // 本页只显示播放/音质域; 外观/交互域的写入不该重建这张列表。
      body: AppSettingsScopedBuilder(
        domains: const {AppSettingsDomain.playback},
        builder: (context) => ListView(
          padding: EdgeInsets.fromLTRB(
            12,
            8,
            12,
            24 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
            // 播放行为: 定时关闭 / 跳过 VIP / 歌单内点歌原本平铺在设置首页,
            // 按主题并进「播放与音质」(2026-11 设置页 IA 重组)。
            const SectionTitle('播放行为', icon: Icons.play_circle_outline),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  // 定时关闭(睡眠定时): 到点停止播放并退出, 可等当前这首播完。
                  // 状态活在 SleepTimer 单例里, 与播放协调器共用同一份。
                  ListTile(
                    leading: const Icon(Icons.bedtime_outlined),
                    title: const Text('定时关闭'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showSleepTimerPage(context),
                  ),
                  const Divider(height: 1),
                  // 播放策略(2026-11 用户需求): 不想听会员曲目时, 切歌/续播直接跳过。
                  SwitchListTile(
                    title: const Text('播放跳过 VIP 歌曲'),
                    subtitle: const Text('切歌与自动续播时跳过需要黑胶会员的曲目(列表里仍然显示)'),
                    value: settings.skipVipSongs,
                    onChanged: (v) => settings.update(skipVipSongs: v),
                  ),
                  const Divider(height: 1),
                  // 被其他媒体抢占时的行为(2026-11 用户需求): 以前只有系统默认
                  // (被抢即暂停、短暂失去后自动续播), 没有任何设置项能改。
                  ListTile(
                    leading: const Icon(Icons.headphones_outlined),
                    title: const Text('被其他 App 抢占时'),
                    subtitle: Text(
                      '${settings.audioFocus.label} · ${settings.audioFocus.hint}'
                      // 桌面(Linux/Windows)由系统混音、没有"焦点被抢占"这回事,
                      // 设置项仍然落盘(换到手机/平板时同一份配置直接带走), 只是不生效。
                      '${defaultTargetPlatform == TargetPlatform.android ? '' : ' · 桌面端由系统混音, 此项只在 Android 生效'}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showAudioFocusSheet(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    title: const Text('歌单内搜索后点歌'),
                    subtitle: Text(
                      '${settings.librarySearchPlayAction.label} · '
                      '${settings.librarySearchPlayAction.hint}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showLibrarySearchPlaySheet(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // 取链音质: 请求的音质档位(与本页的音效链路相互独立)。
            const SectionTitle('音质', icon: Icons.high_quality_outlined),
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
            ),
            const SizedBox(height: 16),
            const SectionTitle('精细音量', icon: Icons.volume_up_outlined),
            Card(
              margin: EdgeInsets.zero,
              child: _volumeCard(context, settings),
            ),
            const SizedBox(height: 16),
            const SectionTitle('响度均衡', icon: Icons.graphic_eq),
            Card(margin: EdgeInsets.zero, child: _loudnessCard(settings)),
            const SizedBox(height: 16),
            const SectionTitle('播放过渡', icon: Icons.waves),
            Card(margin: EdgeInsets.zero, child: _fadeCard(settings)),
            const SizedBox(height: 16),
            const SectionTitle('解码与缓存', icon: Icons.memory),
            Card(margin: EdgeInsets.zero, child: _decodeCacheCard(settings)),
            const SizedBox(height: 16),
            const SectionTitle('歌词来源', icon: Icons.lyrics_outlined),
            Card(margin: EdgeInsets.zero, child: _lyricSourceCard(settings)),
            const SizedBox(height: 16),
            const SectionTitle('自定义响度曲线', icon: Icons.show_chart),
            Card(margin: EdgeInsets.zero, child: _eqCard(context, settings)),
          ],
        ),
      ),
    );
  }

  Widget _lyricSourceCard(AppSettings settings) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Text('逐字歌词来源', style: theme.textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: SegmentedButton<String>(
            key: const Key('lyricSourcePrefSegmented'),
            segments: [
              for (final e in AppSettings.lyricSourceOptions.entries)
                ButtonSegment(value: e.key, label: Text(e.value)),
            ],
            selected: {settings.lyricSourcePreference},
            onSelectionChanged: (sel) =>
                settings.update(lyricSourcePreference: sel.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Text(
            AppSettings.lyricSourceDescription(settings.lyricSourcePreference),
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _volumeCard(BuildContext context, AppSettings settings) {
    final gain = _snapHalf(settings.volumeGainDb);
    final gainText = gain.toStringAsFixed(1);
    final label = gain == 0 ? '不变' : '$gainText dB';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('精细音量', style: Theme.of(context).textTheme.titleMedium),
              Text(label, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
        Slider(
          key: const Key('volumeGainSlider'),
          value: gain,
          min: -40,
          max: 0,
          divisions: 80,
          label: label,
          onChanged: (v) => settings.update(volumeGainDb: v),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Text(
            '与系统音量相乘, 不影响系统音量本身。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _loudnessCard(AppSettings settings) {
    final target =
        AppSettings.loudnessTargets.containsKey(settings.loudnessTargetLufs)
        ? settings.loudnessTargetLufs
        : -16.0;
    return Column(
      children: [
        SwitchListTile(
          key: const Key('loudnessNormalizeSwitch'),
          title: const Text('响度均衡'),
          subtitle: const Text('不同歌曲之间音量趋于一致(EBU R128 测量)'),
          value: settings.loudnessNormalize,
          onChanged: (v) => settings.update(loudnessNormalize: v),
        ),
        const Divider(height: 1),
        ListTile(
          title: const Text('目标电平'),
          subtitle: const Text('默认静态 ReplayGain 2.0, 无 pumping'),
          // 窄屏(300dp + 1.25 字号)下不约束宽度会触发
          // "Trailing widget consumes the entire tile width": DropdownButton 默认按最宽
          // 菜单项撑开, 而 ListTile 的 trailing 必须给标题留位置。限宽 + 单行省略即可。
          trailing: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 124),
            child: DropdownButton<double>(
              key: const Key('loudnessTargetDropdown'),
              value: target,
              isDense: true,
              // 必须 isExpanded: 否则选中项拿到的是松约束, maxLines/ellipsis 不生效,
              // DropdownButton 内部 Row 在限宽后会溢出(实测 94px)
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final entry in AppSettings.loudnessTargets.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(
                      entry.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) settings.update(loudnessTargetLufs: v);
              },
            ),
          ),
        ),
        const Divider(height: 1),
        SwitchListTile(
          key: const Key('loudnessDynamicSwitch'),
          title: const Text('动态(AGC)'),
          subtitle: const Text('默认关闭 = 静态 ReplayGain 2.0(无 pumping); 开启后动态压缩'),
          value: settings.loudnessDynamic,
          onChanged: settings.loudnessNormalize
              ? (v) => settings.update(loudnessDynamic: v)
              : null,
        ),
      ],
    );
  }

  Widget _fadeCard(AppSettings settings) {
    final fade = AppSettings.fadeOptions.containsKey(settings.fadeMs)
        ? settings.fadeMs
        : 0;
    final text = fadeCardText(isAndroid: isAndroidPlatform);
    return ListTile(
      key: const Key('fadeTile'),
      title: Text(text.title),
      subtitle: Text(text.subtitle),
      trailing: DropdownButton<int>(
        key: const Key('fadeDropdown'),
        value: fade,
        underline: const SizedBox.shrink(),
        items: [
          for (final entry in AppSettings.fadeOptions.entries)
            DropdownMenuItem(value: entry.key, child: Text(entry.value)),
        ],
        onChanged: (v) {
          if (v != null) settings.update(fadeMs: v);
        },
      ),
    );
  }

  Widget _decodeCacheCard(AppSettings settings) {
    final limit = AppSettings.cacheLimits.contains(settings.cacheLimitMb)
        ? settings.cacheLimitMb
        : 512;
    // 桌面分支根本没把 streamCache 传下去(见 streamCachePlatformNote), 所以那里只能
    // 显示如实说明; Android 才是有真实开关的平台。
    final streamCacheNote = streamCachePlatformNote(defaultTargetPlatform);
    return Column(
      children: [
        if (defaultTargetPlatform == TargetPlatform.android)
          SwitchListTile(
            key: const Key('hardwareDecodeSwitch'),
            title: const Text('优先硬件解码'),
            subtitle: const Text('关闭后强制软解'),
            value: settings.hardwareDecode,
            onChanged: (v) => settings.update(hardwareDecode: v),
          )
        else
          ListTile(
            key: const Key('hardwareDecodeNote'),
            leading: const Icon(Icons.info_outline),
            title: const Text('硬件解码'),
            // 平台名不能写死: 这条分支同时是 Linux 与 Windows(之前写「Linux 端」
            // 糊到了 Windows 版上, 用户看到自相矛盾的说明)
            subtitle: Text(hardwareDecodePlatformNote(defaultTargetPlatform)),
          ),
        const Divider(height: 1),
        if (streamCacheNote == null)
          SwitchListTile(
            key: const Key('streamCacheSwitch'),
            title: const Text('边听边存'),
            subtitle: const Text('流式缓存落盘, 二次播放不重复下载'),
            value: settings.streamCache,
            onChanged: (v) => settings.update(streamCache: v),
          )
        else
          ListTile(
            key: const Key('streamCacheNote'),
            leading: const Icon(Icons.info_outline),
            title: const Text('边听边存'),
            subtitle: Text(streamCacheNote),
          ),
        const Divider(height: 1),
        ListTile(
          title: const Text('缓存上限'),
          subtitle: const Text('达到上限按 LRU 淘汰, 不删正在播放的文件'),
          trailing: DropdownButton<int>(
            key: const Key('cacheLimitDropdown'),
            value: limit,
            underline: const SizedBox.shrink(),
            items: [
              for (final mb in AppSettings.cacheLimits)
                DropdownMenuItem(value: mb, child: Text('$mb MB')),
            ],
            onChanged: (v) {
              if (v != null) settings.update(cacheLimitMb: v);
            },
          ),
        ),
      ],
    );
  }

  Widget _eqCard(BuildContext context, AppSettings settings) {
    final theme = Theme.of(context);
    final isDefault =
        settings.eqProfileText?.trim() == defaultEqProfileText().trim();
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.graphic_eq),
          title: const Text('生效曲线'),
          subtitle: Text(
            isDefault
                ? '默认曲线(10 段, 全 0 dB)'
                : (settings.eqProfileName ?? '自定义曲线'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('拖动柱子即可调整, 无需导入', style: theme.textTheme.bodySmall),
          ),
        ),
        // D08: 图表走的是 eq_biquad.dart 的近似系数(LS/HS 用 S=1 简化、忽略 Q),
        // 实听由 Rust/Kotlin 的 Q 形式滤波器决定 —— 用户在这里看图调音, 得先知道
        // 图上与听感会有细微差异, 否则会当成 bug 报上来。
        Padding(
          key: const Key('eqCurveApproxNote'),
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '曲线为近似示意, 实际听感由播放端滤波器决定',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
        SizedBox(
          // 曲线图/柱状图同一比例放大, 见 kEqPanelHeight
          height: kEqPanelHeight,
          child: EqCurvePanel(
            text: settings.eqProfileText,
            onChanged: (text) => settings.update(
              eqProfileText: text,
              eqProfileName: text.trim() == defaultEqProfileText().trim()
                  ? '默认曲线'
                  : '自定义曲线',
            ),
          ),
        ),
        const Divider(height: 1),
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () => _importEq(context),
                child: const Text('导入曲线'),
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: () => _exportEq(context),
                child: const Text('导出曲线'),
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: () => _resetEq(context),
                child: const Text('重置为默认'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 导入曲线: 弹窗里已校验一次, 这里是**落盘的唯一入口**(以后"从文件读取"也走它),
  /// 所以落盘前再校验一次 —— 不通过只提示, 绝不写 AppSettings。
  Future<void> _importEq(BuildContext context) async {
    final text = await showAppDialog<String>(
      context,
      builder: (_) => const _ImportEqDialog(),
    );
    if (text == null || !context.mounted) return;
    final check = await checkEqImportText(text);
    if (!context.mounted) return;
    if (!check.ok) {
      showToast(context, '曲线未导入: ${check.error}', isError: true);
      return;
    }
    await AppSettings.instance.update(
      eqProfileText: text,
      eqProfileName: '自定义曲线',
    );
    if (!context.mounted) return;
    final active = check.validation?.activeFilters;
    showToast(
      context,
      active == null ? '已导入自定义响度曲线' : '已导入自定义响度曲线(生效 $active 个滤波器)',
    );
  }

  Future<void> _exportEq(BuildContext context) async {
    final settings = AppSettings.instance;
    final text = settings.eqProfileText;
    if (text == null || text.trim().isEmpty) {
      showToast(context, '当前未启用自定义曲线');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    final lines = text.trim().split('\n').length;
    if (context.mounted) showToast(context, '已复制 $lines 行');
  }

  /// 重置为默认曲线(10 段全 0 dB, 等价旁路): 不删除文本, 因此 EQ 仍处于
  /// "启用但全 0" 状态, 对音质无影响.
  Future<void> _resetEq(BuildContext context) async {
    await AppSettings.instance.update(
      eqProfileText: defaultEqProfileText(),
      eqProfileName: '默认曲线',
    );
    if (context.mounted) showToast(context, '已重置为默认曲线(全 0 dB)');
  }
}

/// 桌面「边听边存」的真实行为说明: null = 该平台有真实开关(Android)。
///
/// P-04: 桌面分支从来没把 streamCache 传给 Rust —— Linux 恒走 start_progressive
/// (渐进下载 + 落盘, core/crates/ncm-ffi/src/api.rs 的 #[cfg(not(windows))] 分支),
/// Windows 恒 cache.fetch 整首下载(#[cfg(windows)] 分支)。桌面上留一个点了没用的
/// 开关等于"设置说谎", 所以只在桌面显示这句只读说明; 缓存上限桌面上是真生效的
/// (enforceCacheLimit → cache_enforce_limit), 仍然保留可调。
String? streamCachePlatformNote(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.android:
      return null;
    case TargetPlatform.windows:
      return '不可用(整首下载后播放)';
    default:
      return '恒开(渐进下载 + 落盘)';
  }
}

/// 桌面「硬件解码」的说明: 桌面播放器是纯软解(rodio + symphonia), 没有硬解开关。
///
/// 与 [streamCachePlatformNote] 同一写法: 按平台给文案, 不把「Linux 端」
/// 糊到 Windows 版上。
String hardwareDecodePlatformNote(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.windows:
      return 'Windows 端为纯软解(rodio + symphonia), 无硬件解码选项';
    case TargetPlatform.macOS:
      return 'macOS 端为纯软解(rodio + symphonia), 无硬件解码选项';
    default:
      return 'Linux 端为纯软解(rodio + symphonia), 无硬件解码选项';
  }
}

/// 「播放过渡」的标题与说明: 两端的淡入淡出语义不同, 文案必须分开写(D09)。
///
/// - Android(`FadePolicy.kt`): 从暂停恢复淡入、暂停/停止淡出, 曲线还是等响感知
///   曲线 `1-(1-t)^3` —— 叫「淡入淡出」名副其实;
/// - 桌面(`ncm-playback` 的 `ramp_scale`): **只有**从暂停恢复才淡入, 且是线性;
///   暂停/停止没有淡出(音量直接交给系统混音) —— 再叫「淡入淡出」就是设置页说谎。
///
/// 与 [streamCachePlatformNote] 同一写法: 按平台给文案, 测试直接盯这一对返回值。
/// 平台判据用 [isAndroidPlatform](唯一入口, 测试置 `debugForceAndroid`)。
({String title, String subtitle}) fadeCardText({required bool isAndroid}) {
  if (isAndroid) {
    return (title: '淡入淡出', subtitle: '暂停恢复时的淡入时长, 0 = 关闭(切歌始终不淡入)');
  }
  return (title: '恢复淡入', subtitle: '只有从暂停恢复才淡入; 桌面端切歌与暂停不做淡出(系统混音)');
}

double _snapHalf(double v) {
  final clamped = v.clamp(-40.0, 0.0);
  return (clamped * 2).roundToDouble() / 2.0;
}

class _ImportEqDialog extends StatefulWidget {
  const _ImportEqDialog();

  @override
  State<_ImportEqDialog> createState() => _ImportEqDialogState();
}

class _ImportEqDialogState extends State<_ImportEqDialog> {
  final _controller = TextEditingController();
  String? _error;

  /// 校验要过一次 FFI(异步), 期间禁用「导入」按钮防连点。
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 校验通过才 pop 文本回去落盘; 不通过就在对话框内回显"第 N 行: 原因"。
  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final check = await checkEqImportText(_controller.text);
    if (!mounted) return;
    if (!check.ok) {
      setState(() {
        _busy = false;
        _error = check.error;
      });
      return;
    }
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入响度曲线'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '粘贴 AutoEQ ParametricEQ.txt 内容(最多 20 个 filter)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            maxLines: 8,
            minLines: 4,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText:
                  'Preamp: -6.0 dB\n'
                  'Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('导入'),
        ),
      ],
    );
  }
}

/// 「歌单内搜索后点歌」行为选择。
///
/// 原在设置首页(2026-11 设置页 IA 重组后归「播放与音质」): 它决定在歌单里搜到
/// 一首歌后是"整张歌单入队"还是"只加当前这首", 属于播放行为而不是界面偏好。
Future<void> showLibrarySearchPlaySheet(BuildContext context) async {
  final settings = AppSettings.instance;
  final current = settings.librarySearchPlayAction;
  final picked = await showAppSheet<LibrarySearchPlayAction>(
    context,
    // 几行档位列表, 一直不超半屏(迁移前就没写 isScrollControlled)
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

/// 「被其他 App 抢占时」策略选择(2026-11 用户需求)。
///
/// 三档的语义与代价都写在 [AudioFocusPolicy] 的 doc 上; 这里只做选择 + 落盘,
/// 平台侧(Android Media3 / MV 独立 Activity)在下次 `configure` 时生效 ——
/// 改完立刻生效是因为 `AudioTuningRequest` 带上了这一项, 设置域的变更会重调
/// `applyAudioTuning()`(见 `home/startup.dart` 的 onAudioSettingsChanged)。
Future<void> showAudioFocusSheet(BuildContext context) async {
  final settings = AppSettings.instance;
  final current = settings.audioFocus;
  final picked = await showAppSheet<AudioFocusPolicy>(
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
              '被其他 App 抢占时',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          for (final value in AudioFocusPolicy.values)
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
  if (picked == null || picked == current) return;
  settings.update(audioFocus: picked);
}
