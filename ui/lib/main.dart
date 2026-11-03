import 'dart:async';

import 'package:flutter/material.dart';

import 'src/playback.dart';
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
  rust.InitInfo? _info;
  rust.SearchResultDto? _result;
  PlayerView? _player;
  rust.SongDto? _current;
  String? _error;
  bool _busy = false;
  Timer? _ticker;

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
    try {
      final state = await _playback.state();
      if (!mounted) return;
      if (state.trackId != null || state.playing != (_player?.playing ?? false)) {
        setState(() => _player = state);
      }
    } catch (_) {
      // 播放后端未就绪(MediaController 连接中)时忽略
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

  Future<void> _play(rust.SongDto song) async {
    setState(() => _current = song);
    try {
      final stream = await rust.songUrl(trackId: song.id, level: 'exhigh');
      final url = stream.url;
      if (url == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可用直链(会员曲目需先导入登录 cookie)')),
        );
        return;
      }
      final state = await _playback.play(
        trackId: song.id,
        url: url,
        title: song.name,
        artist: song.artist,
      );
      if (!mounted) return;
      setState(() => _player = state);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _toggle() async {
    final playing = _player?.playing ?? false;
    final state = playing ? await _playback.pause() : await _playback.resume();
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
                        onTap: () => _play(s),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: player == null
          ? null
          : Material(
              elevation: 8,
              child: SafeArea(
                child: SizedBox(
                  height: 64,
                  child: Row(
                    children: [
                      IconButton(
                        iconSize: 36,
                        icon: Icon(player.playing ? Icons.pause_circle : Icons.play_circle),
                        onPressed: _toggle,
                      ),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              current?.name ?? '播放中',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${_fmt(player.positionMs)} / ${_fmt(player.durationMs)}'
                              '  ${current?.artist ?? ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.stop),
                        onPressed: () async {
                          final state = await _playback.stop();
                          if (!mounted) return;
                          setState(() => _player = state);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
