import 'package:flutter/material.dart';

import '../adaptive_text.dart';
import '../layout.dart';
import '../section_header.dart';
import '../sleep_timer.dart';
import '../toast.dart';

/// 设置二级页: 定时关闭(睡眠定时)。
///
/// 只读写 [SleepTimer](生产上是全局 [sleepTimer] 单例): 真正的到点动作由播放侧
/// 接线(停播放 + 退出应用), 本页不碰任何播放/平台 API。
Future<void> showSleepTimerPage(BuildContext context) {
  return Navigator.of(
    context,
  ).push<void>(MaterialPageRoute<void>(builder: (_) => const SleepTimerPage()));
}

class SleepTimerPage extends StatelessWidget {
  const SleepTimerPage({super.key, this.timer});

  /// 测试可注入的状态机; 生产为全局单例。
  final SleepTimer? timer;

  @override
  Widget build(BuildContext context) {
    final state = timer ?? sleepTimer;
    return Scaffold(
      appBar: AppBar(title: const Text('定时关闭')),
      body: AnimatedBuilder(
        animation: state,
        builder: (context, _) => ListView(
          padding: kPageInsets,
          children: [
            const SectionTitle('停法', icon: Icons.pause_circle_outline),
            Card(margin: kCardMargin, child: _modeCard(context, state)),
            const SizedBox(height: kSectionGap),
            const SectionTitle('时长', icon: Icons.timer_outlined),
            Card(margin: kCardMargin, child: _presetCard(context, state)),
            const SizedBox(height: kSectionGap),
            const SectionTitle('当前状态', icon: Icons.hourglass_bottom),
            Card(margin: kCardMargin, child: _statusCard(context, state)),
          ],
        ),
      ),
    );
  }

  Widget _modeCard(BuildContext context, SleepTimer state) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: SegmentedButton<SleepTimerMode>(
            key: const Key('sleepTimerModeSegmented'),
            segments: [
              for (final mode in SleepTimerMode.values)
                ButtonSegment(value: mode, label: Text(mode.label)),
            ],
            selected: {state.mode},
            onSelectionChanged: (selection) => state.setMode(selection.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: AdaptiveText(
            state.mode.hint,
            mode: AdaptiveTextMode.wrap,
            maxLines: 2,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _presetCard(BuildContext context, SleepTimer state) {
    final activeMinutes = state.active || state.pendingFinish
        ? state.duration?.inMinutes
        : null;
    return Column(
      children: [
        for (final minutes in kSleepTimerPresets) ...[
          if (minutes != kSleepTimerPresets.first) const Divider(height: 1),
          ListTile(
            key: Key('sleepTimerPreset$minutes'),
            title: Text('$minutes 分钟'),
            trailing: activeMinutes == minutes ? const Icon(Icons.check) : null,
            onTap: () {
              state.start(duration: Duration(minutes: minutes));
              showToast(context, '已设置 $minutes 分钟后停止播放并退出');
            },
          ),
        ],
      ],
    );
  }

  Widget _statusCard(BuildContext context, SleepTimer state) {
    final theme = Theme.of(context);
    final remaining = state.remaining;
    final String title;
    final String detail;
    if (state.pendingFinish) {
      title = '等当前这首播完';
      detail = '到点后不再续播下一首, 本曲结束即停止播放并退出应用';
    } else if (remaining != null) {
      title = '还剩 ${sleepTimerRemainingLabel(remaining)}';
      detail = '${state.mode.hint} · 关闭应用后不保留';
    } else if (state.fired) {
      title = '定时已到点';
      detail = '已按设置停止播放并退出';
    } else {
      title = '未开启';
      detail = '选一个时长即开始计时; 应用关闭后定时不保留';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Icon(
            remaining == null && !state.pendingFinish
                ? Icons.timer_off_outlined
                : Icons.timer_outlined,
          ),
          title: AdaptiveText(title, mode: AdaptiveTextMode.wrap, maxLines: 1),
          subtitle: AdaptiveText(
            detail,
            mode: AdaptiveTextMode.wrap,
            maxLines: 2,
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (remaining != null || state.pendingFinish)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                key: const Key('sleepTimerCancel'),
                onPressed: () {
                  state.cancel();
                  showToast(context, '已取消定时关闭');
                },
                child: const Text('取消定时'),
              ),
            ),
          ),
      ],
    );
  }
}
