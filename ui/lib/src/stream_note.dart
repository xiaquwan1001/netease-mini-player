import 'package:flutter/foundation.dart';

import 'format.dart' show formatDurationClock;
import 'rust/api_all.dart' as rust;

/// 取链结果里"信息无损"那一半的只读展示摘要(方案 A)。
///
/// 为什么单独一个文件: 上游响应里的 `freeTrialInfo`/`level` 以前被整块丢掉,
/// 于是「45 秒试听片段」被当成整曲播(播完跳下一首), 「请求无损被降级成 320k」
/// 用户也看不见。这里只把 Rust 侧已经解析好的事实整理成一句短文案,
/// **不参与任何播放控制**(播完怎么走仍由播放器/队列决定)。
@immutable
class StreamNote {
  const StreamNote({
    this.isTrial = false,
    this.trialLenMs,
    this.actualLevel,
    this.requestedLevel,
  });

  /// 这条直链是不是试听片段(上游 `freeTrialInfo` 非空)。
  ///
  /// 哪怕拿不到起止也照实标出来 —— "只有一小段"这件事本身就是要告诉用户的。
  final bool isTrial;

  /// 试听片段长度(毫秒)。null = 是试听但上游没给起止, 或不是试听。
  final int? trialLenMs;

  /// 服务端实际给的档位(上游响应 `level`); null = 上游没给, 无从判断。
  final String? actualLevel;

  /// 我们请求的档位(设置里的音质)。
  final String? requestedLevel;

  /// 从取链结果构造; 没有任何可提示的信息时返回 null(播放条什么都不加)。
  static StreamNote? fromStream(rust.StreamUrl stream) {
    final end = stream.trialEndMs?.toInt();
    final start = stream.trialStartMs?.toInt() ?? 0;
    final len = (end != null && end > start) ? end - start : null;
    final note = StreamNote(
      isTrial: stream.isTrial,
      trialLenMs: stream.isTrial ? len : null,
      actualLevel: stream.actualLevel,
      requestedLevel: stream.quality,
    );
    return note.isEmpty ? null : note;
  }

  /// 上游静默降级: 实际档位与请求档位不一致(不算错误, 但要可见)。
  bool get isDegraded =>
      actualLevel != null &&
      requestedLevel != null &&
      actualLevel != requestedLevel;

  bool get isEmpty => !isTrial && !isDegraded;

  /// 播放条信息行的前缀文案(与「已排队→mm:ss」同风格: 短句 + 双空格分隔)。
  String? get label {
    final parts = <String>[];
    if (isTrial) {
      parts.add(
        trialLenMs == null
            ? '试听'
            : '试听 ${formatDurationClock(BigInt.from(trialLenMs!))}',
      );
    }
    if (isDegraded) {
      parts.add('已降级 ${audioLevelLabel(actualLevel)}');
    }
    if (parts.isEmpty) return null;
    return '${parts.join(' · ')}  ';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamNote &&
          other.isTrial == isTrial &&
          other.trialLenMs == trialLenMs &&
          other.actualLevel == actualLevel &&
          other.requestedLevel == requestedLevel;

  @override
  int get hashCode =>
      Object.hash(isTrial, trialLenMs, actualLevel, requestedLevel);
}

/// 音质档位的中文短名(只在提示里用; 设置页仍显示英文档位名)。
String audioLevelLabel(String? level) => switch (level) {
  'standard' => '标准',
  'higher' => '较高',
  'exhigh' => '极高',
  'lossless' => '无损',
  'hires' => 'Hi-Res',
  _ => level ?? '未知',
};

/// 当前播放曲目的取链提示(null = 整曲且没降级, 播放条不加任何东西)。
///
/// 为什么用全局 ValueNotifier 而不塞进 `PlayerBarData`: 播放条快照的相等性是
/// 逐字段手写的(player_bar_data_test.dart 锁着这个契约), 为一条纯展示文案去扩
/// 快照会让"数据没变不重建"的判据变复杂; 这里与 `nowPlayingSongId` 同思路 ——
/// 一处投递、播放条自己按 trackId 命中。
final ValueNotifier<({BigInt trackId, StreamNote note})?> currentStreamNote =
    ValueNotifier<({BigInt trackId, StreamNote note})?>(null);

/// 取链提示的投递入口(播放协调器每次取链后调用; null = 清掉)。
void publishStreamNote(BigInt? trackId, StreamNote? note) {
  final next = (trackId == null || note == null || note.isEmpty)
      ? null
      : (trackId: trackId, note: note);
  if (currentStreamNote.value == next) return;
  currentStreamNote.value = next;
}
