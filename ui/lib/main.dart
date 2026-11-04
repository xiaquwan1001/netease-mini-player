import 'dart:async';

import 'package:flutter/material.dart';

import 'src/auth.dart';
import 'src/lyric.dart';
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
  final _auth = Auth();
  final _queue = PlayQueue<rust.SongDto>();
  final _lyricScroll = ScrollController();
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

  // ---- 歌词 ----
  static const double _lyricItemExtent = 56;
  List<rust.LyricLineDto> _lyricLines = const [];
  List<BigInt> _lyricTimes = const [];
  BigInt? _lyricTrackId;
  String? _lyricError;
  int _lyricIndex = -1;
  bool _showLyrics = false;

  /// 当前账号是否会员(来自 /api/nuser/account/get 的 vipType)
  bool _vip = false;

  /// "我喜欢的音乐"里的曲目 id: 红心状态的唯一真相
  Set<BigInt> _liked = <BigInt>{};

  /// 歌单浏览态: 非空时列表显示这个歌单而不是搜索结果
  List<rust.SongDto> _library = const [];
  String? _libraryTitle;

  rust.SongDto? get _current => _queue.current;

  /// 当前列表要显示/播放的曲目(歌单浏览优先)
  List<rust.SongDto> get _visibleSongs =>
      _libraryTitle != null ? _library : (_result?.songs ?? const <rust.SongDto>[]);

  @override
  void initState() {
    super.initState();
    // 通知栏/耳机键的上一首·下一首 → Dart 队列
    Playback.setSkipHandlers(onNext: _next, onPrevious: _previous);
    _bootstrap();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _pollPlayer());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _lyricScroll.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final dir = await _playback.dataDir();
      final info = await rust.init(dataDir: dir);
      setState(() {
        _info = info;
        _vip = info.vip;
      });
      // 已登录就把账号记进账号簿(老版本登录过的账号也能被记住)
      if (info.loggedIn) {
        unawaited(_syncAccount());
        unawaited(_loadLiked());
      }
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
    _syncLyricIndex(state);
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
      // 搜索即离开歌单浏览态, 结果列表要保持"这一屏是什么"的唯一来源
      _library = const [];
      _libraryTitle = null;
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

  /// 点列表: 用当前可见列表(搜索/歌单)重置队列, 从被点那首开始
  Future<void> _playFromList(rust.SongDto song) async {
    final songs = _visibleSongs;
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
      unawaited(_loadLyric(song.id));
      return true;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return false;
    }
  }

  // ---------------- 歌词 ----------------

  Future<void> _loadLyric(BigInt trackId) async {
    if (_lyricTrackId == trackId) return;
    _lyricTrackId = trackId;
    if (mounted) {
      setState(() {
        _lyricLines = const [];
        _lyricTimes = const [];
        _lyricIndex = -1;
        _lyricError = null;
      });
    }
    try {
      final lines = await rust.lyricLinesI18N(trackId: trackId);
      if (!mounted || _lyricTrackId != trackId) return;
      setState(() {
        _lyricLines = lines;
        _lyricTimes = [for (final l in lines) l.timeMs];
      });
      _syncLyricIndex(_player ?? PlayerView.empty);
    } catch (e) {
      if (!mounted || _lyricTrackId != trackId) return;
      setState(() => _lyricError = '$e');
    }
  }

  void _syncLyricIndex(PlayerView state) {
    if (!_showLyrics || _lyricTimes.isEmpty) return;
    final idx = lyricIndexAt(_lyricTimes, state.positionMs);
    if (idx == _lyricIndex) return;
    setState(() => _lyricIndex = idx);
    _scrollLyricTo(idx);
  }

  void _scrollLyricTo(int idx) {
    if (!_lyricScroll.hasClients || idx < 0) return;
    final position = _lyricScroll.position;
    final target = idx * _lyricItemExtent - (position.viewportDimension - _lyricItemExtent) / 2;
    final clamped = target.clamp(0.0, position.maxScrollExtent);
    _lyricScroll.animateTo(
      clamped,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
    );
  }

  void _toggleLyrics() {
    setState(() => _showLyrics = !_showLyrics);
    if (_showLyrics && _player != null) {
      _syncLyricIndex(_player!);
    }
  }

  // ---------------- 登录 ----------------

  Future<void> _login() async {
    try {
      final cookie = await _auth.loginWeb();
      if (cookie == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未获取到登录态')));
        return;
      }
      final ok = await _auth.commitCookie(cookie);
      if (ok) {
        // 记住这个账号(昵称/uid) 并设为当前账号, 下次可直接切换
        await _syncAccount();
      }
      await _refreshInfo();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '登录成功, 账号已记住' : 'cookie 里没有 MUSIC_U, 登录未生效')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// 账号面板: 账号簿(记住的账号可一键切换) + 添加账号 + 退出登录
  /// 弹出式菜单在 AppBar 里不好点, 用底部面板; 切换账号不需要重新扫码,
  /// 因为账号簿只存"登录凭据", 设备指纹始终是同一套。
  Future<void> _showAccountSheet() async {
    var saved = const <rust.AccountDto>[];
    try {
      saved = await rust.accounts();
    } catch (_) {
      // 账号簿读不出来不影响登录态, 面板里只显示"添加账号"
    }
    if (!mounted) return;
    final loggedIn = _info?.loggedIn == true;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              title: const Text('账号'),
              subtitle: Text(loggedIn ? '退出只清登录凭据, 设备指纹保持不变' : '未登录'),
            ),
            const Divider(height: 1),
            if (saved.isEmpty)
              const ListTile(
                dense: true,
                title: Text('还没有记住的账号'),
                subtitle: Text('登录一次后会自动记住, 之后可直接切换'),
              ),
            for (final account in saved)
              ListTile(
                leading: Icon(account.active ? Icons.check_circle : Icons.person_outline),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        account.nickname.isEmpty ? '账号 ${account.userId}' : account.nickname,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (account.vip) _vipBadge(sheetContext, small: true),
                  ],
                ),
                subtitle: Text(account.active ? '当前账号' : '点击切换'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '忘记这个账号',
                  onPressed: () async {
                    Navigator.pop(sheetContext);
                    await rust.accountRemove(userId: account.userId);
                    await _refreshInfo();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已从账号簿移除')),
                    );
                  },
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _switchAccount(account);
                },
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('添加账号'),
              subtitle: const Text('打开官方登录页'),
              onTap: () {
                Navigator.pop(sheetContext);
                _login();
              },
            ),
            if (loggedIn)
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('退出登录'),
                subtitle: const Text('账号仍留在账号簿, 下次一键切回'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _logout();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _switchAccount(rust.AccountDto account) async {
    final name = account.nickname.isEmpty ? account.userId.toString() : account.nickname;
    try {
      final ok = await rust.accountSwitch(userId: account.userId);
      await _refreshInfo();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '已切换到 $name' : '这个账号没存过凭据, 请重新登录')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// refresh init 信息(登录态/设备 id/会员状态)
  Future<void> _refreshInfo() async {
    try {
      final dir = await _playback.dataDir();
      final info = await rust.init(dataDir: dir);
      if (mounted) {
        setState(() {
          _info = info;
          _vip = info.vip;
        });
      }
      if (info.loggedIn) {
        await _loadLiked();
      } else {
        _liked = <BigInt>{};
      }
    } catch (_) {
      // init 失败保持旧状态
    }
  }

  /// 记账号资料(昵称/uid/会员)进账号簿; 离线拉不到只是没名字, 不影响登录态
  Future<void> _syncAccount() async {
    try {
      final account = await rust.accountSyncActive();
      if (!mounted) return;
      setState(() => _vip = account.vip);
    } catch (_) {}
  }

  /// 退出登录; thenLogin=true 表示切换账号(退出后立刻再开授权页)
  Future<void> _logout({bool thenLogin = false}) async {
    try {
      await _auth.logout();
      await _refreshInfo();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(thenLogin ? '已退出, 请登录另一个账号' : '已退出登录(账号仍留在账号簿)'),
        ),
      );
      if (thenLogin) await _login();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  // ---------------- 收藏(红心)与歌单 ----------------

  /// 拉一次"我喜欢的音乐"的 id 集合. 失败不影响播放, 只是红心状态未知。
  Future<void> _loadLiked() async {
    try {
      final ids = await rust.likedIds();
      if (!mounted) return;
      setState(() => _liked = ids.toSet());
    } catch (_) {}
  }

  bool _isLiked(BigInt? trackId) => trackId != null && _liked.contains(trackId);

  /// 红心/取消红心(当前曲目). 先乐观更新, 失败回滚。
  Future<void> _toggleLike() async {
    final id = _current?.id;
    if (id == null) return;
    if (_info?.loggedIn != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('收藏需要先登录')),
      );
      return;
    }
    final wasLiked = _liked.contains(id);
    setState(() {
      if (wasLiked) {
        _liked.remove(id);
      } else {
        _liked.add(id);
      }
    });
    try {
      await rust.setLiked(trackId: id, liked: !wasLiked);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (wasLiked) {
          _liked.add(id);
        } else {
          _liked.remove(id);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('收藏失败: $e')));
    }
  }

  /// 收藏/歌单面板: 我喜欢的音乐 + 我的歌单
  Future<void> _showPlaylists() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.6,
          child: FutureBuilder<List<rust.PlaylistDto>>(
            future: rust.myPlaylists(),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text('歌单获取失败: ${snap.error}'));
              }
              final lists = snap.data ?? const <rust.PlaylistDto>[];
              // "我喜欢的音乐"固定排最前(一次扫描就把 special 挑出来, 不依赖后端顺序)
              final special = lists.where((p) => p.special).toList();
              final others = lists.where((p) => !p.special).toList();
              final ordered = [...special, ...others];
              return ListView(
                children: [
                  ListTile(
                    dense: true,
                    title: const Text('我的收藏'),
                    subtitle: Text('${ordered.length} 个歌单'),
                  ),
                  const Divider(height: 1),
                  for (final pl in ordered)
                    ListTile(
                      leading: Icon(
                        pl.special ? Icons.favorite : Icons.queue_music,
                        color: pl.special
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(pl.name),
                      subtitle: Text('${pl.trackCount} 首'),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _openPlaylist(pl);
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 打开歌单: 曲目进列表(和搜索结果同一个列表, 点哪首播哪首, 队列就是整个歌单)
  Future<void> _openPlaylist(rust.PlaylistDto pl) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final songs = pl.special
          ? await rust.likedSongs()
          : await rust.playlistSongs(playlistId: pl.id);
      if (!mounted) return;
      setState(() {
        _library = songs;
        _libraryTitle = pl.special ? '我喜欢的音乐' : pl.name;
        if (pl.special) _liked = songs.map((s) => s.id).toSet();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 退出歌单浏览, 回到搜索
  void _closeLibrary() {
    setState(() {
      _library = const [];
      _libraryTitle = null;
    });
  }

  // ---------------- 播放控制 ----------------

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
    setState(() {
      _player = state;
      _showLyrics = false;
      _lyricLines = const [];
      _lyricTimes = const [];
      _lyricIndex = -1;
      _lyricTrackId = null;
    });
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
    _syncLyricIndex(state);
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final player = _player;
    final current = _current;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _showLyrics
              ? (current?.name ?? '歌词')
              : (_libraryTitle ?? '轻音 MiniNCM'),
        ),
        leading: _showLyrics
            ? IconButton(
                icon: const Icon(Icons.expand_more),
                tooltip: '收起歌词',
                onPressed: _toggleLyrics,
              )
            : (_libraryTitle != null
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: '返回搜索',
                    onPressed: _closeLibrary,
                  )
                : null),
        actions: [
          if (_auth.isAndroid) ...[
            if (_info?.loggedIn == true)
              const SizedBox.shrink()
            else
              TextButton.icon(
                onPressed: _login,
                icon: const Icon(Icons.login, size: 18),
                label: const Text('登录'),
              ),
            if (_info?.loggedIn == true)
              IconButton(
                tooltip: '我喜欢的音乐 / 我的歌单',
                icon: const Icon(Icons.library_music),
                onPressed: _showPlaylists,
              ),
            // 会员标识: 一眼看出当前账号是不是黑胶(曲库可用范围/音质跟它相关)
            if (_info?.loggedIn == true && _vip) _vipBadge(context, small: true),
            // 账号簿入口常驻: 退出后账号仍在簿里, 需要能一键切回
            IconButton(
              tooltip: '账号',
              icon: const Icon(Icons.account_circle),
              onPressed: _showAccountSheet,
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (!_showLyrics) _buildSearchBar(),
          if (info != null && !_showLyrics)
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
          Expanded(child: _showLyrics ? _buildLyrics() : _buildList()),
        ],
      ),
      // 没有曲目时不占位置(Media3 连接后拿到的是一份空状态)
      bottomNavigationBar: (player == null || (player.trackId == null && current == null))
          ? null
          : _buildPlayerBar(context, player, current),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
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
    );
  }

  Widget _buildList() {
    final current = _current;
    if (_result == null) {
      return const Center(child: Text('输入关键词后搜索'));
    }
    final songs = _visibleSongs;
    if (songs.isEmpty) {
      return const Center(child: Text('这个歌单是空的'));
    }
    return ListView.builder(
      itemCount: songs.length,
      itemBuilder: (context, i) {
        final s = songs[i];
        final active = current?.id == s.id;
        return ListTile(
          dense: true,
          selected: active,
          leading: _isLiked(s.id)
              ? Icon(Icons.favorite, size: 16, color: Theme.of(context).colorScheme.primary)
              : null,
          title: Row(
            children: [
              Flexible(child: Text(s.name, overflow: TextOverflow.ellipsis)),
              if (s.vip) _vipBadge(context, small: true),
              if (!s.vip && s.paid) _paidBadge(context),
            ],
          ),
          subtitle: Text('${s.artist} · ${s.album}'),
          trailing: Text('${s.durationMs ~/ BigInt.from(1000)}s'),
          onTap: () => _playFromList(s),
        );
      },
    );
  }

  Widget _buildLyrics() {
    if (_lyricError != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text('歌词获取失败: $_lyricError', textAlign: TextAlign.center)),
      );
    }
    if (_lyricLines.isEmpty) {
      return const Center(child: Text('暂无歌词'));
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      controller: _lyricScroll,
      itemExtent: _lyricItemExtent,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
      itemCount: _lyricLines.length,
      itemBuilder: (context, i) {
        final line = _lyricLines[i];
        final active = i == _lyricIndex;
        final text = line.text.isEmpty ? '♪' : line.text;
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: active ? 18 : 15,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              if (line.sub != null)
                Text(
                  line.sub!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: active ? scheme.primary.withValues(alpha: 0.8) : scheme.outline,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 会员/VIP 小标: 歌曲行与账号都用这一个(成套形态, 不要各处自己画)
  Widget _vipBadge(BuildContext context, {bool small = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: EdgeInsets.symmetric(horizontal: small ? 4 : 6, vertical: small ? 1 : 2),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.5), width: 0.8),
      ),
      child: Text(
        'VIP',
        style: TextStyle(
          fontSize: small ? 10 : 11,
          height: 1.2,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
    );
  }

  /// 需单独购买的数字专辑
  Widget _paidBadge(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.tertiary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '付费',
        style: TextStyle(
          fontSize: 10,
          height: 1.2,
          fontWeight: FontWeight.w700,
          color: scheme.tertiary,
        ),
      ),
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
              // 窄屏(411dp) + 大字号下, 标题若和 5 个按钮抢同一行会被挤成"晴…",
              // 因此标题独占一行, 控件单独居中一行.
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: _toggleLyrics,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 8, 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    current?.name ?? '未在播放',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.titleSmall,
                                  ),
                                ),
                                if (current?.vip == true) _vipBadge(context, small: true),
                                if (current?.paid == true && current?.vip != true)
                                  _paidBadge(context),
                              ],
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
                    ),
                  ),
                  // 红心: 当前曲目是否在我喜欢的音乐里, 点一下即收藏/取消
                  IconButton(
                    tooltip: _isLiked(current?.id) ? '取消喜欢' : '喜欢',
                    icon: Icon(
                      _isLiked(current?.id) ? Icons.favorite : Icons.favorite_border,
                      color: _isLiked(current?.id)
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    onPressed: _toggleLike,
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
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
