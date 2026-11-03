import 'package:flutter/material.dart';

import 'src/rust/api.dart' as rust;
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MiniNcmApp());
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
  rust.InitInfo? _info;
  rust.SearchResultDto? _result;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final info = await rust.init();
      setState(() => _info = info);
    } catch (e) {
      setState(() => _error = '$e');
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
    try {
      final stream = await rust.songUrl(trackId: song.id, level: 'exhigh');
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(song.name),
          content: SelectableText(
            stream.url == null
                ? '没有可用直链(可能需要在设置里导入登录 cookie)'
                : stream.url!,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      appBar: AppBar(title: const Text('轻音 MiniNCM (M0)')),
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
              child: Text(
                'device=${info.deviceId.substring(0, 8)} '
                'logged_in=${info.loggedIn} '
                'providers=${info.providers.map((p) => p.id).join(",")}',
                style: Theme.of(context).textTheme.bodySmall,
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
                      return ListTile(
                        dense: true,
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
    );
  }
}
