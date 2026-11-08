import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_settings.dart';
import 'eq_profile.dart';
import 'toast.dart';

/// 设置二级页: 播放与音质(R2 / R2b / R5 / R7 的设置 UI 部分).
///
/// 只读写 AppSettings.instance; 真正在播放侧应用这些值由
/// S3(Android Media3)/ S4(Rust rodio) 车道负责, 本页不接任何 FFI.
Future<void> showAudioSettingsPage(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => const AudioSettingsPage()),
  );
}

class AudioSettingsPage extends StatelessWidget {
  const AudioSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('播放与音质')),
      body: AnimatedBuilder(
        animation: settings,
        builder: (context, _) => ListView(
          padding: EdgeInsets.fromLTRB(
            12,
            8,
            12,
            24 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
            const _SectionTitle('精细音量'),
            Card(margin: EdgeInsets.zero, child: _volumeCard(context, settings)),
            const SizedBox(height: 16),
            const _SectionTitle('响度均衡'),
            Card(margin: EdgeInsets.zero, child: _loudnessCard(settings)),
            const SizedBox(height: 16),
            const _SectionTitle('播放过渡'),
            Card(margin: EdgeInsets.zero, child: _fadeCard(settings)),
            const SizedBox(height: 16),
            const _SectionTitle('解码与缓存'),
            Card(margin: EdgeInsets.zero, child: _decodeCacheCard(settings)),
            const SizedBox(height: 16),
            const _SectionTitle('自定义响度曲线'),
            Card(margin: EdgeInsets.zero, child: _eqCard(context, settings)),
          ],
        ),
      ),
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
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            '与系统音量相乘, 不影响系统音量本身。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _loudnessCard(AppSettings settings) {
    final target = AppSettings.loudnessTargets.containsKey(settings.loudnessTargetLufs)
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
          trailing: DropdownButton<double>(
            key: const Key('loudnessTargetDropdown'),
            value: target,
            underline: const SizedBox.shrink(),
            items: [
              for (final entry in AppSettings.loudnessTargets.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (v) {
              if (v != null) settings.update(loudnessTargetLufs: v);
            },
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
    return ListTile(
      title: const Text('淡入淡出'),
      subtitle: const Text('切歌时的过渡时长, 0 = 关闭'),
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
    return Column(
      children: [
        if (Platform.isAndroid)
          SwitchListTile(
            key: const Key('hardwareDecodeSwitch'),
            title: const Text('优先硬件解码'),
            subtitle: const Text('关闭后强制软解'),
            value: settings.hardwareDecode,
            onChanged: (v) => settings.update(hardwareDecode: v),
          )
        else
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('硬件解码'),
            subtitle: Text('Linux 端为纯软解(rodio + symphonia), 无硬件解码选项'),
          ),
        const Divider(height: 1),
        SwitchListTile(
          key: const Key('streamCacheSwitch'),
          title: const Text('边听边存'),
          subtitle: const Text('流式缓存落盘, 二次播放不重复下载'),
          value: settings.streamCache,
          onChanged: (v) => settings.update(streamCache: v),
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
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.graphic_eq),
          title: const Text('生效曲线'),
          subtitle: Text(settings.eqProfileName ?? '未启用'),
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
                onPressed: () => _clearEq(context),
                child: const Text('清除'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _importEq(BuildContext context) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const _ImportEqDialog(),
    );
    if (text == null || !context.mounted) return;
    await AppSettings.instance
        .update(eqProfileText: text, eqProfileName: '自定义曲线');
    if (context.mounted) showToast(context, '已导入自定义响度曲线');
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

  Future<void> _clearEq(BuildContext context) async {
    final settings = AppSettings.instance;
    // update() 的 String? 参数无法用 null 表达"置空", 这里直接置空字段后
    // 用无参 update() 触发 notifyListeners + 落盘(把两个 null 写回 settings.json).
    settings.eqProfileName = null;
    settings.eqProfileText = null;
    await settings.update();
    if (context.mounted) showToast(context, '已清除自定义响度曲线');
  }
}

double _snapHalf(double v) {
  final clamped = v.clamp(-40.0, 0.0);
  return (clamped * 2).roundToDouble() / 2.0;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _ImportEqDialog extends StatefulWidget {
  const _ImportEqDialog();

  @override
  State<_ImportEqDialog> createState() => _ImportEqDialogState();
}

class _ImportEqDialogState extends State<_ImportEqDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '请输入曲线文本');
      return;
    }
    try {
      parseParametricEq(text);
    } on EqProfileException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    Navigator.of(context).pop(text);
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
              hintText: 'Preamp: -6.0 dB\n'
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
        FilledButton(onPressed: _submit, child: const Text('导入')),
      ],
    );
  }
}
