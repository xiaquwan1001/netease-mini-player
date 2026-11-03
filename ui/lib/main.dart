import 'dart:async';

import 'package:flutter/material.dart';

import 'src/playback.dart';
import 'src/queue.dart';
import 'src/rust/api.dart' as rust;
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MiniNcmApp());
}

String _fmt(BigInt ms) {
  final total = (ms ~/ BigInt.from(1000)).toInt();
  final m = (total ~/ 60).toString().padLeft(2, '0');
  final s = (total % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

const _modeIcons = {
  PlayMode.repeatAll: Icons.repeat,
  PlayMode.repeatOne: Icons.repeat_one,
  PlayMode.sequence: Icons.playlist_play,
};

const _modeLabels = {
  PlayMode.repeatAll: '列表循环',
  PlayMode.repeatOne: '单曲循环',
  PlayMode.sequence: '顺序播放',
};

class MiniNcmApp extends StatelessWidget {
  const MiniNcmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '轻音 MiniNCM',
      theme: ThemeData(colorSchemeSeed: const Color(0xFFE60026), useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _controller = TextEditingController(text: '晴天');
  final _playback = Playback();
  final _queue = PlayQueue<rust.SongDto>();
  rust.InitInfo? _info;
  rust.SearchResultDto? _result;
  PlayerView? _player;
  String? _error;
  bool _busy = false;
  Timer? _ticker;

  /// 用户主动停止后不再自动续播
  bool _userStopped = false;

  /// 拖动进度条时的临时值(避免每帧都 seek); _dragMax 在拖动开始时冻结,
  /// 否则自动续播换曲会让滑杆量程突跳, 把新曲目 seek 到末尾。
  double? _dragMs;
  double? _dragMax;

  /// 续播临界区: 防止一次结束被处理两遍(轮询 500ms + 异步取链)
  bool _advancing = false;

  rust.SongDto? get _current => _queue.current;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _pollPlayer());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final dir = await _playback.dataDir();
      final info = await rust.init(dataDir: dir);
      setState(() => _info = info);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _pollPlayer() async {
    PlayerView state;
    try {
      state = await _playback.state();
    } catch (_) {
      return; // 播放后端未就绪(MediaController 连接中)时忽略
    }
    if (!mounted) return;
    final wasPlaying = _player?.playing ?? false;
    setState(() => _player = state);
    if (_looksEnded(wasPlaying, state)) {
      await _onTrackEnded();
    }
  }

  /// 播完判定: 从播放态落到非播放态, 且位置已在末尾附近.
  /// Media3/rodio 都不保证把 "ENDED" 送到 UI 层, 所以用轮询兜底.
  bool _looksEnded(bool wasPlaying, PlayerView s) {
    if (_userStopped || _advancing || _dragMs != null || !wasPlaying || s.playing) return false;
    if (s.durationMs == BigInt.zero) return false;
    return s.positionMs + BigInt.from(800) >= s.durationMs;
  }

  Future<void> _onTrackEnded() async {
    if (_advancing) return;
    _advancing = true;
    try {
      final next = _queue.onEnded();
      if (next == null) {
        setState(() {}); // 顺序播放到队尾: 停在最后一首
        return;
      }
      await _playSong(next);
    } finally {
      _advancing = false;
    }
  }

  Future<void> _search() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await rust.search(keywords: _controller.text, limit: 20);
      setState(() => _result = result);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  /// 点列表: 用当前搜索结果重置队列, 从被点那首开始
  Future<void> _playFromList(rust.SongDto song) async {
    final songs = _result?.songs ?? const <rust.SongDto>[];
    final start = songs.indexWhere((s) => s.id == song.id);
    _queue.setAll(songs, startAt: start < 0 ? 0 : start);
    _userStopped = false;
    await _playSong(song);
  }

  /// 跳过取不到直链的曲目(会员/版权限制), 最多绕队列一圈
  Future<void> _playSong(rust.SongDto song) async {
    _userStopped = false;
    var attempts = 0;
    var target = song;
    while (true) {
      if (await _resolveAndPlay(target)) return;
      attempts += 1;
      if (attempts >= _queue.items.length) {
        if (mounted) setState(() {});
        return;
      }
      final next = _queue.next();
      if (next == null) return;
      target = next;
    }
  }

  Future<bool> _resolveAndPlay(rust.SongDto song) async {
    try {
      final stream = await rust.songUrl(trackId: song.id, level: 'exhigh');
      final url = stream.url;
      if (url == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('《${song.name}》没有可用直链(会员曲目需先登录), 已跳过')),
          );
        }
        return false;
      }
      final state = await _playback.play(
        trackId: song.id,
        url: url,
        title: song.name,
        artist: song.artist,
      );
      if (!mounted) return true;
      setState(() => _player = state);
      return true;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return false;
    }
  }

  Future<void> _toggle() async {
    final playing = _player?.playing ?? false;
    final state = playing ? await _playback.pause() : await _playback.resume();
    if (!mounted) return;
    setState(() => _player = state);
  }

  Future<void> _next() async {
    final next = _queue.next();
    if (next == null) return;
    await _playSong(next);
  }

  Future<void> _previous() async {
    final prev = _queue.previous();
    if (prev == null) return;
    await _playSong(prev);
  }

  Future<void> _stop() async {
    _userStopped = true;
    final state = await _playback.stop();
    if (!mounted) return;
    setState(() => _player = state);
  }

  void _cycleMode() {
    setState(() {
      final modes = PlayMode.values;
      final i = (modes.indexOf(_queue.mode) + 1) % modes.length;
      _queue.mode = modes[i];
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(_modeLabels[_queue.mode]!),
          duration: const Duration(milliseconds: 900),
        ));
    });
  }

  Future<void> _seekTo(double ms) async {
    final target = ms.round();
    setState(() {
      _dragMs = null;
      _dragMax = null;
    });
    final state = await _playback.seek(BigInt.from(target));
    if (!mounted) return;
    setState(() => _player = state);
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final player = _player;
    final current = _current;
    return Scaffold(
      appBar: AppBar(title: const Text('轻音 MiniNCM')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      labelText: '搜索',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _search,
                  child: Text(_busy ? '搜索中' : '搜索'),
                ),
              ],
            ),
          ),
          if (info != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'device=${info.deviceId.substring(0, 8)}  logged_in=${info.loggedIn}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: _result == null
                ? const Center(child: Text('输入关键词后搜索'))
                : ListView.builder(
                    itemCount: _result!.songs.length,
                    itemBuilder: (context, i) {
                      final s = _result!.songs[i];
                      final active = current?.id == s.id;
                      return ListTile(
                        dense: true,
                        selected: active,
                        title: Text(s.name),
                        subtitle: Text('${s.artist} · ${s.album}'),
                        trailing: Text('${s.durationMs ~/ BigInt.from(1000)}s'),
                        onTap: () => _playFromList(s),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: player == null ? null : _buildPlayerBar(context, player, current),
    );
  }

  Widget _buildPlayerBar(BuildContext context, PlayerView player, rust.SongDto? current) {
    final dur = player.durationMs.toDouble();
    // 拖动中冻结量程: 自动续播会让 duration 突跳
    final maxMs = _dragMax ?? (dur <= 0 ? 1.0 : dur);
    final pos = (_dragMs ?? player.positionMs.toDouble()).clamp(0.0, maxMs);
    final inQueue = _queue.isEmpty ? 1 : _queue.index + 1;
    return Material(
      elevation: 8,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Slider(
                value: pos,
                max: maxMs,
                onChangeStart: dur <= 0 ? null : (v) => setState(() { _dragMax = dur; _dragMs = v; }),
                onChanged: dur <= 0 ? null : (v) => setState(() => _dragMs = v),
                onChangeEnd: dur <= 0 ? null : (v) => _seekTo(v),
              ),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          current?.name ?? '未在播放',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${_fmt(player.positionMs)} / ${_fmt(player.durationMs)}'
                          '  ${current?.artist ?? ''}'
                          '  $inQueue/${_queue.items.length}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: _modeLabels[_queue.mode],
                    icon: Icon(_modeIcons[_queue.mode]),
                    onPressed: _cycleMode,
                  ),
                  IconButton(icon: const Icon(Icons.skip_previous), onPressed: _previous),
                  IconButton(
                    iconSize: 36,
                    icon: Icon(player.playing ? Icons.pause_circle : Icons.play_circle),
                    onPressed: _toggle,
                  ),
                  IconButton(icon: const Icon(Icons.skip_next), onPressed: _next),
                  IconButton(icon: const Icon(Icons.stop), onPressed: _stop),
                ],
              ),
              // 手势导航条会吞掉最底部约 20dp 的点击, 留一点安全边距
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
