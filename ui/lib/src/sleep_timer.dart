import 'package:flutter/foundation.dart';

/// 定时关闭(睡眠定时)的纯逻辑部分。
///
/// 为什么单独一个文件: 这个功能的核心是"到点/曲末"的判定与一次性触发,
/// 全是可测的状态机; 平台动作(停播放、退出应用)必须**注入**进来
/// (`SleepTimer.onExpire`), 纯逻辑里不碰任何 platform API, 单测用假时钟
/// 就能把六种边界走完(立刻停 / 播完这首 / 已暂停 / 取消 / 改档 / 只触发一次)。
///
/// 口径:
/// - **不跨重启**: 定时只活在当前进程里(应用退出/被杀即失效), 不落盘。
///   睡眠定时的语义是"我这就睡了", 关掉应用后还留着倒计时只会误杀下一次播放。
/// - **档位固定**: 15 / 30 / 45 / 60 / 90 分钟五档。用户场景是"听完这一段/准备睡",
///   固定档位一眼可选; 自定义时长要么加滚轮要么加输入框, 在 300dp + 大字号下
///   还要额外处理宽度与校验, 收益不抵成本(想要更精细可以选最接近的一档再取消重开)。
/// - **改档 = 重新计时**: 任何一次 [SleepTimer.start] 都把截止时间重置成"现在 + 档位",
///   所以中途换档不会出现"剩余 3 分钟 + 换到 60 分钟档却还剩 3 分钟"的怪状态。

/// 到点后的两种停法。
enum SleepTimerMode {
  /// 到点立刻停(不管当前这首播到哪)。
  immediate('立刻停'),

  /// 到点后等当前这首歌播完再停(已暂停/无播放时直接停)。
  finishCurrentSong('播完这首');

  const SleepTimerMode(this.label);

  /// 分段控件的短标签(两档要能在 300dp 一行放下)。
  final String label;

  /// 给副标题/说明用的完整描述。
  String get hint => switch (this) {
    SleepTimerMode.immediate => '到点立刻停止播放并退出应用',
    SleepTimerMode.finishCurrentSong => '到点后等当前这首播完再停止并退出(已暂停则直接停)',
  };
}

/// 可选档位(分钟)。顺序即 UI 顺序: 从短到长。
const List<int> kSleepTimerPresets = <int>[15, 30, 45, 60, 90];

/// 剩余时间文案: 不到 1 小时 `mm:ss`, 超过 1 小时 `h:mm:ss`。
///
/// 单独抽成纯函数便于单测(90 分钟档必须显示 1:30:00 而不是 90:00)。
String sleepTimerRemainingLabel(Duration remaining) {
  final total = remaining.isNegative ? 0 : remaining.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:${two(minutes)}:${two(seconds)}';
  return '${two(minutes)}:${two(seconds)}';
}

/// 定时关闭状态机。
///
/// 由播放侧驱动(**不自己起轮询**):
/// - 每次播放态轮询调 [onPlaybackTick](生产上是 `PlaybackCoordinator.poll`,
///   本来就每 500ms 读一次播放器);
/// - 曲末(`trackEnded` / 播完兜底)调 [onTrackEnded]。
///
/// 两个入口都只做"到点判定", 真正的退出动作交给注入的 [onExpire], 且**最多一次**。
class SleepTimer extends ChangeNotifier {
  SleepTimer({DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// 可注入的时钟(单测用假时间, 避免真的等 15 分钟)。
  final DateTime Function() _now;

  /// 到点动作: 停止播放 + 退出应用。生产实现在 `home_page` 里接线
  /// (Android 停服务并退出界面, Linux 走桌面壳退出, Windows 直接退出进程)。
  ///
  /// null 时只做状态变更(测试/未接线的场景), 不会崩。
  void Function()? onExpire;

  DateTime? _deadline;
  Duration? _duration;
  SleepTimerMode _mode = SleepTimerMode.immediate;
  bool _fired = false;
  bool _pendingFinish = false;
  int _lastRemainingSeconds = -1;

  /// 是否还有效(未到点且未被取消)。到点触发后变 false。
  bool get active => _deadline != null && !_fired;

  /// 是否已经触发过到点动作(同一轮只可能 true 一次; [start] 会重置)。
  bool get fired => _fired;

  /// 当前档位时长(未开启为 null)。
  Duration? get duration => _duration;

  SleepTimerMode get mode => _mode;

  /// 到点已过但在等当前这首播完(仅 [SleepTimerMode.finishCurrentSong])。
  bool get pendingFinish => _pendingFinish;

  /// 剩余时间(未开启为 null; 已到点钳到 0)。
  Duration? get remaining {
    final deadline = _deadline;
    if (deadline == null) return null;
    final left = deadline.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// 开始/重新开始计时。[mode] 不传则沿用上一次的选择。
  ///
  /// 重复调用 = 改档重置(见文件头口径)。
  void start({required Duration duration, SleepTimerMode? mode}) {
    if (duration <= Duration.zero) return;
    _duration = duration;
    _mode = mode ?? _mode;
    _deadline = _now().add(duration);
    _fired = false;
    _pendingFinish = false;
    _lastRemainingSeconds = duration.inSeconds;
    notifyListeners();
  }

  /// 切换停法。已经开着定时时按"改档重置"处理(重新从当前档位计时),
  /// 未开启时只记住这次选择, 等 [start] 生效。
  void setMode(SleepTimerMode mode) {
    if (_mode == mode) return;
    if (active) {
      start(duration: _duration ?? Duration.zero, mode: mode);
      return;
    }
    _mode = mode;
    notifyListeners();
  }

  /// 取消定时(不到点不触发任何动作)。
  void cancel() {
    if (_deadline == null && !_fired && !_pendingFinish) return;
    _deadline = null;
    _duration = null;
    _fired = false;
    _pendingFinish = false;
    _lastRemainingSeconds = -1;
    notifyListeners();
  }

  /// 播放态轮询喂进来的心跳: 更新剩余时间展示, 到点按模式决定停/等。
  ///
  /// [playing] = 当前是否在播(已暂停/无播放时「播完这首」也必须直接停)。
  void onPlaybackTick({required bool playing}) {
    final deadline = _deadline;
    if (deadline == null || _fired) return;
    final left = deadline.difference(_now());
    if (left > Duration.zero) {
      // 只在展示用的"秒"变化时通知, 避免 500ms 轮询带来每帧重建
      final seconds = left.inSeconds;
      if (seconds != _lastRemainingSeconds) {
        _lastRemainingSeconds = seconds;
        notifyListeners();
      }
      return;
    }
    if (_mode == SleepTimerMode.immediate || !playing) {
      _fire();
      return;
    }
    // 「播完这首」且仍在播: 打上待停标记, 等曲末([onTrackEnded])
    if (!_pendingFinish) {
      _pendingFinish = true;
      notifyListeners();
    }
  }

  /// 当前这首播完了。
  ///
  /// 只有「播完这首」+ 已经到点才触发; 没到点的曲末是正常续播, 什么都不做。
  void onTrackEnded() {
    final deadline = _deadline;
    if (deadline == null || _fired) return;
    if (_mode != SleepTimerMode.finishCurrentSong) return;
    if (_now().isBefore(deadline)) return;
    _fire();
  }

  /// 触发到点动作(幂等: 同一轮只调一次 [onExpire])。
  void _fire() {
    if (_fired) return;
    _fired = true;
    _deadline = null;
    _pendingFinish = false;
    notifyListeners();
    onExpire?.call();
  }
}

/// 生产用的单例: 设置页与播放协调器共用同一个状态机。
///
/// 进程内唯一即可 —— 定时不跨重启(见文件头), 也不需要持久化。
final SleepTimer sleepTimer = SleepTimer();
