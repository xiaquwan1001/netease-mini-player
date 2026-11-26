/// 「精细音量」增益的**唯一数值口径**(播放条音量入口与设置页滑条共用)。
///
/// 2026-11-26 引入: 播放条宽档音量入口与设置页「播放与音质 → 精细音量」调的是同一个
/// `AppSettings.volumeGainDb`(-40..0 dB)。量程/步进/文案/对齐规则只存一份 —— 否则
/// 两处各写一份, 迟早出现"设置页 80 格、播放条 100 格"这种漂移。
library;

import 'package:flutter/material.dart' show IconData, Icons;

/// 增益量程与步进: 与设置页「精细音量」同口径(-40..0 dB, 0.5 dB 一步)。
const double kVolumeGainMinDb = -40;
const double kVolumeGainMaxDb = 0;

/// 格数 = (0 - (-40)) / 0.5。与设置页同值, 改一边必须改另一边。
const int kVolumeGainDivisions = 80;

/// 静音档 = 增益拉到最低(-40 dB 与系统音量相乘后基本听不见)。
const double kVolumeGainMuteDb = kVolumeGainMinDb;

/// 半 dB 对齐(与设置页 `_snapHalf` 同口径)。
///
/// 滑条 80 格本来就是 0.5 dB 一步, 但对齐仍然必要: 落盘值可能来自老配置/其他写入
/// 路径(任意小数), 不对齐会让滑条值与显示互相打架(滑块落在两格之间)。
double volumeGainSnapHalf(double value) =>
    (value.clamp(kVolumeGainMinDb, kVolumeGainMaxDb) * 2).roundToDouble() / 2;

/// 增益文案: 0 dB = 「不变」(旁路), 其余 `x.x dB`。设置页同一份口径。
String volumeGainLabel(double gain) =>
    gain == 0 ? '不变' : '${gain.toStringAsFixed(1)} dB';

/// 图标随增益切换: 0 dB 满格 / 拉到最低是静音 / 中间是衰减。
IconData volumeGainIcon(double gain) {
  if (gain >= kVolumeGainMaxDb) return Icons.volume_up;
  if (gain <= kVolumeGainMuteDb) return Icons.volume_off;
  return Icons.volume_down;
}
