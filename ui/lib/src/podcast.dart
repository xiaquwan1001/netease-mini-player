import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'sheet_header.dart';
import 'song_actions.dart';

typedef RadioLoader = Future<List<rust.PodcastRadioDto>> Function(int limit);
typedef ProgramLoader = Future<List<rust.PodcastProgramDto>> Function(
    BigInt radioId, int limit, int offset);

/// 电台单条详情(详情页打开时刷新最新信息用)
typedef RadioDetailLoader = Future<rust.PodcastRadioDto> Function(BigInt radioId);

String _fmtDuration(BigInt ms) {
  final total = (ms ~/ BigInt.from(1000)).toInt();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// 播客(电台): 热门电台 → 节目列表 → 点单集播放.
/// 一集的音频本体是 program.song, 播放链路和普通歌曲完全一致(取直链 → 播放).
/// loadRadios/loadPrograms/loadRadioDetail 可注入(测试用), 默认走 Rust 接口.
Future<void> showPodcastSheet(
  BuildContext context, {
  required void Function(List<rust.SongDto> songs, int index) onPlay,
  rust.PodcastRadioDto? initialRadio,
  RadioLoader? loadRadios,
  ProgramLoader? loadPrograms,
  RadioDetailLoader? loadRadioDetail,
}) {
  final radios = loadRadios ?? (limit) => rust.podcastHot(limit: limit);
  final programs = loadPrograms ??
      (id, limit, offset) =>
          rust.podcastPrograms(radioId: id, limit: limit, offset: offset);
  final radioDetail = loadRadioDetail ??
      (id) => rust.podcastRadio(radioId: id);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.75,
        child: _PodcastBrowser(
          onPlay: onPlay,
          initialRadio: initialRadio,
          loadRadios: radios,
          loadPrograms: programs,
          loadRadioDetail: radioDetail,
        ),
      ),
    ),
  );
}

class _PodcastBrowser extends StatefulWidget {
  const _PodcastBrowser({
    required this.onPlay,
    required this.loadRadios,
    required this.loadPrograms,
    required this.loadRadioDetail,
    this.initialRadio,
  });

  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final RadioLoader loadRadios;
  final ProgramLoader loadPrograms;
  final RadioDetailLoader loadRadioDetail;
  final rust.PodcastRadioDto? initialRadio;

  @override
  State<_PodcastBrowser> createState() => _PodcastBrowserState();
}

class _PodcastBrowserState extends State<_PodcastBrowser> {
  late rust.PodcastRadioDto? _radio = widget.initialRadio;

  @override
  Widget build(BuildContext context) {
    final radio = _radio;
    return Column(
      children: [
        SheetHeader(
          title: radio == null ? '播客' : radio.name,
          onBack: radio == null ? null : () => setState(() => _radio = null),
          onClose: () => Navigator.pop(context),
        ),
        Expanded(
          child: radio == null
              ? _RadioList(
                  load: widget.loadRadios,
                  onOpen: (r) => setState(() => _radio = r),
                )
              : _ProgramList(
                  radio: radio,
                  load: widget.loadPrograms,
                  loadRadioDetail: widget.loadRadioDetail,
                  onPlay: widget.onPlay,
                  onRadioUpdated: (r) => setState(() => _radio = r),
                ),
        ),
      ],
    );
  }
}

class _RadioList extends StatefulWidget {
  const _RadioList({required this.load, required this.onOpen});

  final RadioLoader load;
  final void Function(rust.PodcastRadioDto radio) onOpen;

  @override
  State<_RadioList> createState() => _RadioListState();
}

class _RadioListState extends State<_RadioList> {
  List<rust.PodcastRadioDto>? _radios;

  /// 致命错误: 一条数据都没有, 整页给重试
  String? _error;

  /// 非致命错误: 已有旧数据, 刷新失败时顶部错误条, 不清空页面
  String? _barError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final radios = await retryNetwork(() => widget.load(30));
      if (!mounted) return;
      setState(() => _radios = radios);
    } catch (e) {
      if (!mounted) return;
      final msg = friendlyError(e);
      setState(() {
        if (_radios == null) {
          _error = msg;
        } else {
          _barError = msg;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _RetryView(message: _error!, onRetry: _load);
    }
    final radios = _radios;
    final list = radios == null
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: radios.length,
              itemBuilder: (context, i) {
                final r = radios[i];
                return ListTile(
                  leading: CoverArt(url: r.coverUrl, size: 52, radius: 8),
                  title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      if (r.djName.isNotEmpty) r.djName,
                      if (r.programCount > BigInt.zero) '${r.programCount} 集',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => widget.onOpen(r),
                );
              },
            ),
          );
    return Column(
      children: [
        if (_barError != null)
          _ErrorBar(
            message: _barError!,
            onRetry: _load,
            onClose: () => setState(() => _barError = null),
          ),
        Expanded(child: list),
      ],
    );
  }
}

class _ProgramList extends StatefulWidget {
  const _ProgramList({
    required this.radio,
    required this.load,
    required this.loadRadioDetail,
    required this.onPlay,
    this.onRadioUpdated,
  });

  final rust.PodcastRadioDto radio;
  final ProgramLoader load;
  final RadioDetailLoader loadRadioDetail;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  /// 详情刷新拿到更新的电台信息后回报(标题栏同步更新)
  final void Function(rust.PodcastRadioDto radio)? onRadioUpdated;

  @override
  State<_ProgramList> createState() => _ProgramListState();
}

class _ProgramListState extends State<_ProgramList> {
  /// 列表带来的电台信息只作首屏占位, 打开后用后端最新数据覆盖
  late rust.PodcastRadioDto _radio = widget.radio;
  List<rust.PodcastProgramDto>? _programs;

  /// 致命错误: 节目列表一条都没有
  String? _error;

  /// 非致命错误: 已有占位/旧数据, 刷新失败时顶部错误条, 不清空页面
  String? _barError;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  /// 打开详情页/下拉刷新: 电台信息(podcastRadio)与节目列表(podcastPrograms)
  /// 并行拉后端最新; 任一失败都不清空已有数据。
  Future<void> _loadAll() async {
    setState(() => _barError = null);
    await Future.wait([_loadPrograms(), _loadRadio()]);
  }

  Future<void> _loadPrograms() async {
    try {
      final programs = await retryNetwork(
        () => widget.load(_radio.id, 50, 0),
      );
      if (!mounted) return;
      setState(() => _programs = programs);
    } catch (e) {
      if (!mounted) return;
      final msg = friendlyError(e);
      setState(() {
        if (_programs == null) {
          _error = msg;
        } else {
          _barError = msg;
        }
      });
    }
  }

  Future<void> _loadRadio() async {
    try {
      final radio = await retryNetwork(() => widget.loadRadioDetail(_radio.id));
      if (!mounted) return;
      setState(() => _radio = radio);
      widget.onRadioUpdated?.call(radio);
    } catch (e) {
      // 电台信息刷新失败不致命: 保留占位数据, 挂到顶部错误条
      if (!mounted) return;
      setState(() => _barError ??= friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _RetryView(
        message: _error!,
        onRetry: () {
          setState(() => _error = null);
          _loadAll();
        },
      );
    }
    final programs = _programs;
    Widget body;
    if (programs == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = RefreshIndicator(
        onRefresh: _loadAll,
        child: programs.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 120),
                  Center(child: Text('这个电台还没有节目')),
                ],
              )
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: programs.length,
                itemBuilder: (context, i) {
                  final p = programs[i];
                  final song = p.song;
                  return ListTile(
                    leading: CoverArt(url: p.coverUrl, size: 48, radius: 6),
                    title: Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [
                        if (p.djName.isNotEmpty) p.djName,
                        _fmtDuration(p.durationMs),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    enabled: song != null,
                    trailing:
                        song == null ? null : SongOverflowButton(song: song, size: 20),
                    onTap: song == null
                        ? null
                        : () {
                            final songs = [
                              for (final x in programs)
                                if (x.song != null) x.song!,
                            ];
                            final index = programs.indexWhere((x) => x.id == p.id);
                            Navigator.pop(context);
                            widget.onPlay(songs, index < 0 ? 0 : index);
                          },
                  );
                },
              ),
      );
    }
    return Column(
      children: [
        if (_barError != null)
          _ErrorBar(
            message: _barError!,
            onRetry: _loadAll,
            onClose: () => setState(() => _barError = null),
          ),
        Expanded(child: body),
      ],
    );
  }
}

/// 顶部非致命错误条: 保留旧数据时提示 + 可重试/关闭, 不清空页面。
class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message, required this.onRetry, this.onClose});

  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 4, 4),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 16, color: scheme.onErrorContainer),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
              ),
            ),
            const SizedBox(width: 6),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: scheme.onErrorContainer,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('重试'),
            ),
            if (onClose != null)
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                color: scheme.onErrorContainer,
                visualDensity: VisualDensity.compact,
                tooltip: '关闭',
                onPressed: onClose,
              ),
          ],
        ),
      ),
    );
  }
}

class _RetryView extends StatelessWidget {
  const _RetryView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
