/// AutoEQ ParametricEQ.txt 曲线的解析与序列化(纯 Dart, 不依赖 Flutter).
///
/// 事实标准样例(每行一条):
///   Preamp: -6.0 dB
///   Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71
///   Filter 2: ON LS Fc 120 Hz Gain 2.5 dB Q 0.70
///
/// 契约(与 Rust 侧 S4 共享, 见 docs/plan-2026-11-09-settings-and-player.md §2.2):
/// - 类型只支持 PK/LS/HS; LP/HP/NO 等明确报"不支持".
/// - Fc 可带 Hz 单位, 必须 0 < Fc ≤ 48000; Gain 必须在 ±24 dB 内(超范围报错, 不静默裁剪).
/// - Q 必填且 > 0; 最多 20 个 filter(第 21 个报错).
/// - ON/OFF 都能解析(OFF 保留但不生效, 影响导出往返).
/// - Preamp 可选, 缺省 0 dB, 范围 ±24.
/// - 空行与 # / // 注释行忽略(与 Rust 侧 ncm-domain 一致).
library;

/// 单条曲线允许的最大 filter 数(EqualizerAPO 惯例).
const int maxEqFilters = 20;

/// 增益/Preamp 的允许范围(±dB).
const double maxEqGainDb = 24.0;

/// Fc 的物理上限(Hz), 与 Rust 侧 MAX_FREQ_HZ 一致.
const double maxEqFreqHz = 48000.0;

/// 支持的滤波器类型.
enum EqFilterType { pk, ls, hs }

/// 解析失败: 带 1-based 行号 + 原因(不抛裸 Exception 文案).
class EqProfileException implements Exception {
  EqProfileException(this.line, this.reason);

  /// 1-based 行号.
  final int line;

  /// 不含行号前缀的原因(UI 可拼成"第 N 行: 原因").
  final String reason;

  /// UI 直接展示用: "第 N 行: 原因".
  String get message => '第 $line 行: $reason';

  @override
  String toString() => 'EqProfileException: $message';
}

class EqFilter {
  const EqFilter({
    required this.index,
    required this.enabled,
    required this.type,
    required this.freqHz,
    required this.gainDb,
    required this.q,
  });

  /// 原文本里的序号(Filter N), 保留以支持往返一致.
  final int index;

  /// OFF 保留但不生效.
  final bool enabled;

  final EqFilterType type;
  final double freqHz;
  final double gainDb;
  final double q;
}

class ParametricEq {
  const ParametricEq({required this.preampDb, required this.filters});

  final double preampDb;
  final List<EqFilter> filters;

  /// 序列化回 AutoEQ ParametricEQ.txt 格式(Preamp 行 + 每 filter 一行).
  /// 与 [parseParametricEq] 互为往返: parse(text).toParametricEqText() 幂等.
  String toParametricEqText() {
    final preamp = _fmtDb(preampDb);
    final buf = StringBuffer()..writeln('Preamp: $preamp dB');
    for (final f in filters) {
      final index = f.index;
      final onOff = f.enabled ? 'ON' : 'OFF';
      final typeName = f.type.name.toUpperCase();
      final freq = _fmtFreq(f.freqHz);
      final gain = _fmtDb(f.gainDb);
      final q = _fmtQ(f.q);
      buf.writeln('Filter $index: $onOff $typeName Fc $freq Hz Gain $gain dB Q $q');
    }
    return buf.toString();
  }
}

/// 解析 AutoEQ ParametricEQ.txt 文本. 失败抛 [EqProfileException](带行号).
ParametricEq parseParametricEq(String text) {
  final filters = <EqFilter>[];
  double preampDb = 0.0;
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final lineNo = i + 1;
    final line = lines[i].trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) continue;

    final preamp = _preampRe.firstMatch(line);
    if (preamp != null) {
      final value = double.tryParse(preamp.group(1)!);
      if (value == null) throw EqProfileException(lineNo, 'Preamp 不是有效数字');
      if (value.abs() > maxEqGainDb) {
        throw EqProfileException(lineNo, 'Preamp 超出 ±$maxEqGainDb dB');
      }
      preampDb = value;
      continue;
    }

    final filter = _filterRe.firstMatch(line);
    if (filter != null) {
      final typeToken = filter.group(3)!;
      final type = _parseType(typeToken);
      if (type == null) {
        throw EqProfileException(lineNo, '不支持的滤波器类型: $typeToken');
      }
      if (filters.length >= maxEqFilters) {
        throw EqProfileException(lineNo, '最多支持 $maxEqFilters 个 filter');
      }
      final freq = double.tryParse(filter.group(4)!);
      final gain = double.tryParse(filter.group(5)!);
      final qRaw = filter.group(6);
      final q = qRaw == null ? null : double.tryParse(qRaw);
      if (freq == null) throw EqProfileException(lineNo, 'Fc 不是有效数字');
      if (freq <= 0 || freq > maxEqFreqHz) {
        throw EqProfileException(lineNo, 'Fc 必须在 0 < Fc ≤ 48000 Hz');
      }
      if (gain == null) throw EqProfileException(lineNo, 'Gain 不是有效数字');
      if (q == null) throw EqProfileException(lineNo, '缺少 Q 值');
      if (gain.abs() > maxEqGainDb) {
        throw EqProfileException(lineNo, 'Gain $gain 超出 ±$maxEqGainDb dB');
      }
      if (q <= 0) throw EqProfileException(lineNo, 'Q 必须大于 0');
      filters.add(EqFilter(
        index: int.parse(filter.group(1)!),
        enabled: filter.group(2)!.toUpperCase() == 'ON',
        type: type,
        freqHz: freq,
        gainDb: gain,
        q: q,
      ));
      continue;
    }

    // 整行不匹配: 尝试给出更明确的错误(不支持的类型 / 结构缺失).
    final probe = _filterProbeRe.firstMatch(line);
    if (probe != null) {
      final token = probe.group(1)!;
      if (_parseType(token) == null) {
        throw EqProfileException(lineNo, '不支持的滤波器类型: $token');
      }
      throw EqProfileException(lineNo, 'Filter 行格式错误(检查 Fc/Gain/Q)');
    }
    throw EqProfileException(lineNo, '无法识别的行');
  }
  return ParametricEq(preampDb: preampDb, filters: List.unmodifiable(filters));
}

EqFilterType? _parseType(String token) {
  switch (token.toUpperCase()) {
    case 'PK':
      return EqFilterType.pk;
    case 'LS':
      return EqFilterType.ls;
    case 'HS':
      return EqFilterType.hs;
  }
  return null;
}

final RegExp _preampRe = RegExp(
  r'^\s*Preamp\s*:\s*(\S+)\s*(?:dB)?\s*$',
  caseSensitive: false,
);

final RegExp _filterRe = RegExp(
  r'^\s*Filter\s+(\d+)\s*:\s*(\S+)\s+(\S+)\s+Fc\s+(\S+)\s*(?:Hz)?\s+Gain\s+(\S+)\s*(?:dB)?(?:\s+Q\s+(\S+))?\s*$',
  caseSensitive: false,
);

final RegExp _filterProbeRe = RegExp(
  r'^\s*Filter\s+\d+\s*:\s*(?:\S+)\s+(\S+)',
  caseSensitive: false,
);

String _fmtDb(double v) => v.toString();

String _fmtFreq(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toString();

String _fmtQ(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toString();
