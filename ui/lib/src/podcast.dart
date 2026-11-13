import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'sheet_header.dart';
import 'format.dart' show formatDurationMs;

/// 单集详情加载器. 节目列表里的 description 往往被截断甚至为空,
/// 点开"节目详情"时用 podcast_program 再拉一次完整数据(简介/时长/音频本体).
typedef ProgramDetailLoader = Future<rust.PodcastProgramDto> Function(
  BigInt programId,
);

/// 单集详情弹层(podcast_program).
///
/// 列表项只当**首屏占位**: 列表里的 `description` 经常被截断甚至为空,
/// 打开后立刻用 [loadDetail] 再拉一次完整数据; 拉取失败保留占位 + 顶部错误条可重试,
/// 绝不清空 —— 详情是"有则更好"的数据, 不该因为一次请求失败让用户什么都看不到。
class ProgramDetailSheet extends StatefulWidget {
  const ProgramDetailSheet({
    super.key,
    required this.program,
    required this.loadDetail,
    this.onPlay,
  });

  /// 列表带来的节目数据(占位)
  final rust.PodcastProgramDto program;

  final ProgramDetailLoader loadDetail;

  /// null = 这一集没有音频本体(或调用方不给播放入口), 播放按钮置灰
  final VoidCallback? onPlay;

  @override
  State<ProgramDetailSheet> createState() => _ProgramDetailSheetState();
}

class _ProgramDetailSheetState extends State<ProgramDetailSheet> {
  late rust.PodcastProgramDto _program = widget.program;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await widget.loadDetail(widget.program.id);
      if (!mounted) return;
      setState(() {
        _program = p;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = _program;
    final meta = [
      if (p.djName.isNotEmpty) p.djName,
      if (p.radioName.isNotEmpty) '《${p.radioName}》',
      formatDurationMs(p.durationMs),
    ].join(' · ');
    final desc = p.description.trim();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SheetHeader(
                title: '节目详情',
                onClose: () => Navigator.pop(context),
                trailing: _loading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, size: 16, color: scheme.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _error!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: scheme.error),
                        ),
                      ),
                      TextButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CoverArt(url: p.coverUrl, size: 64, radius: 8),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  p.name,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  meta,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        desc.isEmpty ? '这一集没有文字简介' : desc,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: widget.onPlay,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('播放本集'),
                ),
              ),
              if (widget.onPlay == null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '这一集没有可播放的音频',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
