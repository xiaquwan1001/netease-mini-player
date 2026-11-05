import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'sheet_header.dart';
import 'song_actions.dart';

typedef RadioLoader = Future<List<rust.PodcastRadioDto>> Function(int limit);
typedef ProgramLoader = Future<List<rust.PodcastProgramDto>> Function(
    BigInt radioId, int limit, int offset);

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
/// loadRadios/loadPrograms 可注入(测试用), 默认走 Rust 接口.
Future<void> showPodcastSheet(
  BuildContext context, {
  required void Function(List<rust.SongDto> songs, int index) onPlay,
  rust.PodcastRadioDto? initialRadio,
  RadioLoader? loadRadios,
  ProgramLoader? loadPrograms,
}) {
  final radios = loadRadios ?? (limit) => rust.podcastHot(limit: limit);
  final programs = loadPrograms ??
      (id, limit, offset) =>
          rust.podcastPrograms(radioId: id, limit: limit, offset: offset);
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
    this.initialRadio,
  });

  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final RadioLoader loadRadios;
  final ProgramLoader loadPrograms;
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
                  onPlay: widget.onPlay,
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
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final radios = await retryNetwork(() => widget.load(30));
      if (!mounted) return;
      setState(() => _radios = radios);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final radios = _radios;
    if (_error != null) {
      return _RetryView(message: _error!, onRetry: _load);
    }
    if (radios == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (radios.isEmpty) {
      return const Center(child: Text('暂无热门播客'));
    }
    return ListView.builder(
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
    );
  }
}

class _ProgramList extends StatefulWidget {
  const _ProgramList({
    required this.radio,
    required this.load,
    required this.onPlay,
  });

  final rust.PodcastRadioDto radio;
  final ProgramLoader load;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  @override
  State<_ProgramList> createState() => _ProgramListState();
}

class _ProgramListState extends State<_ProgramList> {
  List<rust.PodcastProgramDto>? _programs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final programs = await retryNetwork(
        () => widget.load(widget.radio.id, 50, 0),
      );
      if (!mounted) return;
      setState(() => _programs = programs);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final programs = _programs;
    if (_error != null) {
      return _RetryView(message: _error!, onRetry: _load);
    }
    if (programs == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (programs.isEmpty) {
      return const Center(child: Text('这个电台还没有节目'));
    }
    final playable = programs.where((p) => p.song != null).toList();
    return ListView.builder(
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
          trailing: song == null ? null : SongOverflowButton(song: song, size: 20),
          onTap: song == null
              ? null
              : () {
                  final songs = [
                    for (final x in playable)
                      if (x.song != null) x.song!,
                  ];
                  final index = playable.indexWhere((x) => x.id == p.id);
                  Navigator.pop(context);
                  widget.onPlay(songs, index < 0 ? 0 : index);
                },
        );
      },
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
