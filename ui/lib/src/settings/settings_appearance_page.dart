import 'dart:async';

import 'package:flutter/material.dart';

import '../adaptive_text.dart';
import '../app_settings.dart';
import '../cover_quality_sheet.dart';
import '../layout.dart';
import '../section_header.dart';
import '../theme.dart' show AccentPalette;
import 'settings_tiles.dart';

/// 「主题模式」的三档(2026-11 用户需求 1: 从四档拆回)。
///
/// 历史: 最早是「跟随/浅色/深色」三档 + 独立的「OLED 纯黑」开关;
/// 2026-11-14 一度把纯黑并成第四档(纯黑 = themeMode.dark + oledDark),
/// 结果「跟随系统」与「纯黑」互斥 —— 跟随系统时想开纯黑只能被迫改成深色。
/// 现在恢复三档 + 独立开关: 两者正交、可同时为真, 持久化字段仍是
/// themeMode(跟随/浅色/深色) 与 oledDark(bool), 旧 settings.json 直接可读
/// (oledDark=true 且 themeMode=dark ⇒ 显示为「深色 + 纯黑开」)。
enum ThemeChoice { system, light, dark }

/// 当前设置 → 三档里的哪一档(只看 themeMode; 纯黑是独立开关, 不参与)。
ThemeChoice themeChoiceOf(AppSettings settings) => switch (settings.themeMode) {
  ThemeMode.light => ThemeChoice.light,
  ThemeMode.dark => ThemeChoice.dark,
  ThemeMode.system => ThemeChoice.system,
};

/// 三档 → 只写回 themeMode。不动 oledDark(纯黑开关独立保存, 可同时开启)。
void applyThemeChoice(AppSettings settings, ThemeChoice choice) {
  unawaited(
    settings.update(
      themeMode: switch (choice) {
        ThemeChoice.system => ThemeMode.system,
        ThemeChoice.light => ThemeMode.light,
        ThemeChoice.dark => ThemeMode.dark,
      },
    ),
  );
}

/// 三档的副标题文案（与分段控件的选项一一对应）。
String themeChoiceLabel(ThemeChoice choice) => switch (choice) {
  ThemeChoice.system => '跟随系统 · 系统深色时用 Material 深灰',
  ThemeChoice.light => '浅色',
  ThemeChoice.dark => '深色 · Material 深灰 #121212',
};

/// 「纯黑 (OLED)」开关此刻是否真的生效: 纯黑只是深色基底的另一种底色,
/// 浅色基底(浅色档, 或跟随系统且系统为浅色)下开关仍可操作但不改变外观。
bool isOledDarkEffective({
  required ThemeMode themeMode,
  required Brightness platformBrightness,
}) => switch (themeMode) {
  ThemeMode.dark => true,
  ThemeMode.light => false,
  ThemeMode.system => platformBrightness == Brightness.dark,
};

/// 「纯黑 (OLED)」开关的副标题: 生效时说清效果, 不生效时说明「仅在深色时生效」
/// (不静默改 themeMode, 也不把开关置灰 —— 用户可以提前开好等切深色)。
String oledDarkLabel({required bool effective}) => effective
    ? '深色基底用 #000000 取代 #121212(OLED 省电, 无灰边)'
    : '仅在深色时生效 · 当前底色不变, 切到深色后自动变纯黑';

/// 设置二级页: 外观与布局(主题 / 字号 / 版面与图片清晰度).
///
/// 从设置首页拆出(2026-11 用户反馈: 设置页平铺内容太乱, 按主题分二级页).
/// 只读写 AppSettings.instance, 不接任何 FFI.
Future<void> showAppearancePage(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => const AppearanceSettingsPage()),
  );
}

class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('外观与布局')),
      // 只有外观域的写入才重建本页(播放/搜索等域的写入不重排这张列表)。
      body: AppSettingsScopedBuilder(
        domains: const {AppSettingsDomain.appearance},
        builder: (context) => ListTileTheme(
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
              const SectionTitle('主题', icon: Icons.palette_outlined),
              Card(
                margin: EdgeInsets.zero,
                child: Column(
                  children: [
                    // 2026-11 用户需求 1: 主题模式回到三档, 「纯黑 (OLED)」
                    // 拆成下面的独立开关 —— 「跟随系统 + 纯黑」可以同时成立。
                    SegmentedSettingTile<ThemeChoice>(
                      title: '主题模式',
                      subtitle: themeChoiceLabel(themeChoiceOf(settings)),
                      segments: const [
                        ButtonSegment(
                          value: ThemeChoice.system,
                          label: Text('跟随'),
                        ),
                        ButtonSegment(
                          value: ThemeChoice.light,
                          label: Text('浅色'),
                        ),
                        ButtonSegment(
                          value: ThemeChoice.dark,
                          label: Text('深色'),
                        ),
                      ],
                      selected: themeChoiceOf(settings),
                      onSelectionChanged: (value) =>
                          applyThemeChoice(settings, value),
                    ),
                    const Divider(height: 1),
                    // 纯黑是深色基底的底色选项(不是第四个主题档): 与三档正交,
                    // 浅色/跟随浅色下开关仍可操作, 副标题说明「仅在深色时生效」。
                    SwitchListTile(
                      title: const Text('纯黑 (OLED)'),
                      subtitle: Text(
                        oledDarkLabel(
                          effective: isOledDarkEffective(
                            themeMode: settings.themeMode,
                            platformBrightness: MediaQuery.platformBrightnessOf(
                              context,
                            ),
                          ),
                        ),
                      ),
                      value: settings.oledDark,
                      onChanged: (value) => settings.update(oledDark: value),
                    ),
                    const Divider(height: 1),
                    // 视觉风格: 同一色板同时决定浅色/深色两套配色(不是两套独立开关)
                    _AccentSettingTile(
                      selected: settings.accent,
                      onSelected: (value) => settings.update(accent: value),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const SectionTitle('字号', icon: Icons.text_fields),
              Card(
                margin: EdgeInsets.zero,
                child: _TextScaleSetting(settings: settings),
              ),
              const SizedBox(height: 16),
              const SectionTitle('版面与图片', icon: Icons.grid_view_outlined),
              Card(
                margin: EdgeInsets.zero,
                child: Column(
                  children: [
                    SegmentedSettingTile<int>(
                      title: '卡片排列(一排 / 两排)',
                      // 用户反馈 16: 这一项不只作用于推荐页 —— 我的页与他人主页的
                      // 歌单/播客/专辑横滑区块同样跟着变(统一走 CoverRow(rows: ...))
                      subtitle: settings.coverRows == 1
                          ? '一排: 横向滑动, 推荐/我的/他人主页的歌单播客都用'
                          : '两排: 网格平铺, 推荐/我的/他人主页的歌单播客都用',
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
                    SegmentedSettingTile<int>(
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
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「界面字号」设置项: 0.80~1.50 步长 0.05 的滑块。
///
/// 为什么不再用 `DropdownButton<double>`: 它的 `value` 必须**恰好等于** items 里的
/// 某一项(命中不了会 assert), 与"字号是可精细调节的连续值"天然冲突。
/// 为什么也没有「小/标准/大/特大」档位 chip: 滑块已经是唯一的可调入口, 档位 chip
/// 只是重复入口, 用户 2026-11-14 反馈要求去掉(见 [AppSettings.textScaleLabel])。
///
/// 实时预览: MaterialApp.builder 的 scaledMediaQuery 直接读 AppSettings, 所以拖动
/// 滑块时**整页**(含本行)立刻按新倍率重排, 下面的预览行是同倍率的实例说明。
class _TextScaleSetting extends StatelessWidget {
  const _TextScaleSetting({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = settings.textScale;
    // 端内缩: thumb 半径取当前 SliderTheme(可能被外层主题替换), 其余由
    // layout.dart 的常量给出 —— 与下面 SliderTheme 里写死的轨道/overlay 同一来源。
    final ambient = SliderTheme.of(context);
    final thumbRadius =
        (ambient.thumbShape?.getPreferredSize(true, true).width ?? 0) / 2;
    final endInset = textScaleSliderEndInset(thumbRadius);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: const Text('界面字号'),
          subtitle: Text(AppSettings.textScaleHint(scale)),
        ),
        // 滑块与两端 'A' 叠在同一个 Stack 里, 而不是并排的 Row:
        //
        // Slider 的轨道两端本来就被 overlay/thumb 内缩(默认 24 + 半轨高 = 26dp),
        // Row 里的文本标签永远对不上极端落点(2026-11-18 实测差 33.7 / 36.1dp)。
        // 现在标签盒宽 = 2 × 端内缩、文本居中 ⇒ 标签中心 == value=min/max 时
        // thumb 的中心; 盒宽是常量, 系统字号变大只改文本自身宽度, 中心不会跑。
        Stack(
          children: [
            SliderTheme(
              // 显式写死这一年的轨道口径(trackHeight 4 / 圆角轨道 / overlay 24):
              // 端内缩 = max(overlay 半径, thumb 半径) + 半轨高 才可推导, 不随
              // Flutter 改默认值把落点挪走(常量见 layout.dart)。
              data: ambient.copyWith(
                year2023: true,
                trackHeight: kTextScaleSliderTrackHeight,
                trackShape: const RoundedRectSliderTrackShape(),
                overlayShape: const RoundSliderOverlayShape(
                  overlayRadius: kTextScaleSliderOverlayRadius,
                ),
              ),
              child: Slider(
                value: scale,
                min: AppSettings.kTextScaleMin,
                max: AppSettings.kTextScaleMax,
                divisions: AppSettings.textScaleDivisions,
                label: AppSettings.textScaleLabel(scale),
                onChanged: (value) => settings.update(
                  textScale: AppSettings.snapTextScale(value),
                ),
              ),
            ),
            // 两端的尺寸提示(A 小 / A 大), 走 bodySmall / titleMedium。
            // IgnorePointer: 标签压在轨道端点上, 不能让这两条 52dp 变成拖动死区。
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: endInset * 2,
              child: IgnorePointer(
                child: Center(
                  child: Text('A', style: theme.textTheme.bodySmall),
                ),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: endInset * 2,
              child: IgnorePointer(
                child: Center(
                  child: Text('A', style: theme.textTheme.titleMedium),
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          // 预览行: 长文字走 AdaptiveText(2 行截断), 2.0 字号 + 320dp 也不溢出
          child: AdaptiveText(
            '预览: 歌单 · 播客 · 动态都会按这个字号显示',
            mode: AdaptiveTextMode.wrap,
            maxLines: 2,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
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
    // 缩进/字重与同卡的 SegmentedSettingTile、ListTile 对齐(2026-11-14 用户反馈):
    // - SizedBox(width: infinity): 外层 Card 的 Column 交叉轴是 center, 不铺满就会
    //   整块被居中, 表现为「主题色」比上下行多缩进一截;
    // - 标题 bodyLarge / 副标题 bodyMedium: 之前是 titleMedium + bodySmall,
    //   比同卡其它行更粗更小, 层级看着乱。
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('主题色', style: theme.textTheme.bodyLarge),
            const SizedBox(height: 2),
            Text(
              '${selected.label} · 浅色/深色通用',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
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
