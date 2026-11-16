/// RBJ biquad 系数(纯数学, 不依赖 Flutter/平台).
///
/// 与 Rust `ncm-playback::Biquad`、Kotlin `EqProfileParser.kt` 里的 `Biquad` 是同一套公式
/// (RBJ Audio EQ Cookbook; 归一化掉 a0, 只保留 b0/b1/b2/a1/a2), 三端共享夹具
/// `ui/test/fixtures/eq_profile_cases.json` 会逐条比对首/尾 filter 的系数。
///
/// 已知与 Rust/Kotlin 不同的一处(**本次只记录、不修改**):
/// LS/HS 的 alpha 这里用 RBJ 的 S=1 简化形式 `sin(w0)/2*sqrt(2)`(忽略 Q),
/// Rust/Kotlin 用 Q 形式 `sin(w0)/(2*Q)`。AutoEQ 曲线里的 shelf Q 通常是 0.7~1.0,
/// 量化差异不大, 但"曲线图"与"实际听到的"因此不一致 —— 改它等于改用户看到的曲线,
/// 要单独立项(见 arch-audit-platform-2026-11-16 §P-05)。
library;

import 'dart:math' as math;

import 'eq_profile.dart';

/// 曲线求值/biquad 系数使用的采样率(与 Rust/Kotlin 侧一致的物理上限推导).
const double defaultEqSampleRateHz = 48000.0;

/// 归一化(a0 = 1)的二阶节系数. [coefficients] 的顺序与共享夹具一致: b0, b1, b2, a1, a2.
class EqBiquad {
  const EqBiquad({
    required this.b0,
    required this.b1,
    required this.b2,
    required this.a1,
    required this.a2,
  });

  /// 由解析出的 filter 描述构造(采样率相关). OFF 的 filter 也能算系数(求值方自行过滤).
  factory EqBiquad.fromFilter(
    EqFilter filter, {
    double sampleRate = defaultEqSampleRateHz,
  }) {
    switch (filter.type) {
      case EqFilterType.pk:
        return EqBiquad.peaking(
          sampleRate,
          filter.freqHz,
          filter.gainDb,
          filter.q,
        );
      case EqFilterType.ls:
        return EqBiquad.lowShelf(
          sampleRate,
          filter.freqHz,
          filter.gainDb,
          filter.q,
        );
      case EqFilterType.hs:
        return EqBiquad.highShelf(
          sampleRate,
          filter.freqHz,
          filter.gainDb,
          filter.q,
        );
    }
  }

  /// 峰值滤波器: 在 f0 处抬升/下压 gainDb, Q 控制带宽.
  factory EqBiquad.peaking(
    double sampleRate,
    double freqHz,
    double gainDb,
    double q,
  ) {
    final a = math.pow(10.0, gainDb / 40.0).toDouble();
    final w0 = 2 * math.pi * freqHz / sampleRate;
    final cw = math.cos(w0);
    final sw = math.sin(w0);
    final alpha = sw / (2 * q);
    final a0 = 1 + alpha / a;
    return EqBiquad(
      b0: (1 + alpha * a) / a0,
      b1: (-2 * cw) / a0,
      b2: (1 - alpha * a) / a0,
      a1: (-2 * cw) / a0,
      a2: (1 - alpha / a) / a0,
    );
  }

  /// 低架: f0 以下整体抬升/下压 gainDb.
  factory EqBiquad.lowShelf(
    double sampleRate,
    double freqHz,
    double gainDb,
    double q,
  ) => _shelf(sampleRate, freqHz, gainDb, q, low: true);

  /// 高架: f0 以上整体抬升/下压 gainDb.
  factory EqBiquad.highShelf(
    double sampleRate,
    double freqHz,
    double gainDb,
    double q,
  ) => _shelf(sampleRate, freqHz, gainDb, q, low: false);

  final double b0;
  final double b1;
  final double b2;
  final double a1;
  final double a2;

  /// 与共享夹具对齐的系数顺序: [b0, b1, b2, a1, a2].
  List<double> get coefficients => [b0, b1, b2, a1, a2];

  /// 线性幅频响应(已归一化, 分母的 a0 视为 1).
  double magnitudeAt(
    double freqHz, {
    double sampleRate = defaultEqSampleRateHz,
  }) {
    final w = 2 * math.pi * freqHz / sampleRate;
    final c1 = math.cos(w);
    final s1 = math.sin(w);
    final c2 = math.cos(2 * w);
    final s2 = math.sin(2 * w);
    final numB = b0 + b1 * c1 + b2 * c2;
    final numI = b1 * s1 + b2 * s2;
    final denB = 1 + a1 * c1 + a2 * c2;
    final denI = a1 * s1 + a2 * s2;
    final num = math.sqrt(numB * numB + numI * numI);
    final den = math.sqrt(denB * denB + denI * denI);
    return num / den;
  }

  /// RBJ shelf(S 固定为 1 的简化形式, 见文件头"已知差异").
  static EqBiquad _shelf(
    double sampleRate,
    double freqHz,
    double gainDb,
    double q, {
    required bool low,
  }) {
    final a = math.pow(10.0, gainDb / 40.0).toDouble();
    final w0 = 2 * math.pi * freqHz / sampleRate;
    final cw = math.cos(w0);
    final sw = math.sin(w0);
    final alpha = sw / 2 * math.sqrt((a + 1 / a) * 2);
    final twoSqrtAalpha = 2 * math.sqrt(a) * alpha;
    final double b0;
    final double b1;
    final double b2;
    final double a0;
    final double a1;
    final double a2;
    if (low) {
      b0 = a * ((a + 1) - (a - 1) * cw + twoSqrtAalpha);
      b1 = 2 * a * ((a - 1) - (a + 1) * cw);
      b2 = a * ((a + 1) - (a - 1) * cw - twoSqrtAalpha);
      a0 = (a + 1) + (a - 1) * cw + twoSqrtAalpha;
      a1 = -2 * ((a - 1) + (a + 1) * cw);
      a2 = (a + 1) + (a - 1) * cw - twoSqrtAalpha;
    } else {
      b0 = a * ((a + 1) + (a - 1) * cw + twoSqrtAalpha);
      b1 = -2 * a * ((a - 1) + (a + 1) * cw);
      b2 = a * ((a + 1) + (a - 1) * cw - twoSqrtAalpha);
      a0 = (a + 1) - (a - 1) * cw + twoSqrtAalpha;
      a1 = 2 * ((a - 1) - (a + 1) * cw);
      a2 = (a + 1) - (a - 1) * cw - twoSqrtAalpha;
    }
    return EqBiquad(
      b0: b0 / a0,
      b1: b1 / a0,
      b2: b2 / a0,
      a1: a1 / a0,
      a2: a2 / a0,
    );
  }
}
