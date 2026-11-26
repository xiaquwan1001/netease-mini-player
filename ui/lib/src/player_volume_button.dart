/// 播放条上的音量入口(只在**宽档**渲染, 见 `player_bar.dart` 里的放置与宽度预算)。
///
/// 用户口径(2026-11-26): 桌面/平板等宽屏设备要能在播放条上直接调音量。
/// 它与设置页「精细音量」(`settings/settings_audio_page.dart` 的 `_volumeCard`)
/// **是同一个值**: 这里只读写 [AppSettings.volumeGainDb](-40..0 dB, 与系统音量
/// 相乘, 不影响系统音量本身), 由 `audio_tuning.dart` 的 `AudioTuningRequest.gainDb`
/// 落地。本控件**不持有**任何音量状态, 也不碰 `Playback.setVolume` —— 没有第二份
/// 增益可同步, 设置页滑条与这里的滑条天然是同一根。
library;

import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'volume_gain.dart';

/// 播放条最右端的音量入口: 图标 + 点击弹出的小面板(滑条 + 静音/恢复)。
class PlayerVolumeButton extends StatelessWidget {
  const PlayerVolumeButton({super.key});

  /// 图标按钮 / 面板滑条 / 静音按钮的测试锚点。
  static const Key buttonKey = Key('playerVolumeButton');
  static const Key sliderKey = Key('playerVolumeSlider');
  static const Key muteToggleKey = Key('playerVolumeMuteToggle');

  @override
  Widget build(BuildContext context) {
    // 只订阅「播放与音质」域(照 settings_audio_page 的写法): 音量属于 playback,
    // 外观/交互域的写入不该重建播放条上的按钮。
    return AppSettingsScopedBuilder(
      domains: const {AppSettingsDomain.playback},
      builder: (context) {
        final gain = volumeGainSnapHalf(AppSettings.instance.volumeGainDb);
        return MenuAnchor(
          // 播放条贴在窗口最底部, 往下没空间: MenuAnchor 发现下方放不下会自动翻到
          // 按钮上方(见 _MenuLayout), 这里的 -6 只是让面板不粘着按钮顶边。
          alignmentOffset: const Offset(0, -6),
          menuChildren: [_panel(context, gain)],
          builder: (context, controller, _) =>
              _iconButton(gain: gain, controller: controller),
        );
      },
    );
  }

  Widget _iconButton({
    required double gain,
    required MenuController controller,
  }) {
    return IconButton(
      key: buttonKey,
      // 与播放条其他图标按钮同一口径(见 player_bar.dart 的 MiniPlayerBar._barIcon):
      // 零内边距 + 34 宽 × 48 高命中区, 关掉 padded tapTarget 与 compact visualDensity,
      // 免得命中区被撑成 48 宽(宽档一排 7 个按钮, 宽度按 34 算的预算)。
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.standard,
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      constraints: const BoxConstraints(minWidth: 34, minHeight: 48),
      tooltip: '音量 ${volumeGainLabel(gain)}',
      icon: Icon(volumeGainIcon(gain), size: 22),
      onPressed: () =>
          controller.isOpen ? controller.close() : controller.open(),
    );
  }

  Widget _panel(BuildContext context, double gain) {
    final theme = Theme.of(context);
    final label = volumeGainLabel(gain);
    final muted = gain <= kVolumeGainMuteDb;
    return SizedBox(
      // 宽度写死: MenuAnchor 横向排布会给子项套 IntrinsicWidth, Slider 在无界宽下
      // 算不出固有宽度; 220 够放「音量 -12.0 dB」这一行与一条 196 宽的滑条。
      width: 220,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('音量', style: theme.textTheme.titleSmall),
                Text(label, style: theme.textTheme.titleSmall),
              ],
            ),
            Slider(
              key: sliderKey,
              value: gain,
              min: kVolumeGainMinDb,
              max: kVolumeGainMaxDb,
              divisions: kVolumeGainDivisions,
              label: label,
              // 走 update() 而不是裸 setter: 与设置页同一条写入路径
              // (同一批通知 + 同一份落盘), 双向同步靠订阅, 不靠这里回写状态。
              onChanged: (v) => AppSettings.instance.update(volumeGainDb: v),
            ),
            // 静音 ⇄ 恢复。**恢复固定回 0 dB(「不变」)**, 不回「上一个非静音值」:
            // AppSettings 里没有这一项, 在控件里记一份就等于悄悄长出第二份音量状态
            // (播放条重建/设置页同时改动时会分叉), 而 0 dB 正好是「不改变」的中性档。
            // 想要别的值拖上面的滑条。
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: muteToggleKey,
                onPressed: () => AppSettings.instance.update(
                  volumeGainDb: muted ? kVolumeGainMaxDb : kVolumeGainMuteDb,
                ),
                child: Text(muted ? '恢复' : '静音'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
