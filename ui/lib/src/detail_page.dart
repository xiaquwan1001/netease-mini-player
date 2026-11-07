import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';

import 'comment_thread.dart';
import 'cover_art.dart';
import 'library_view.dart';
import 'net_retry.dart';
import 'radio_subscribers_page.dart';
import 'podcast.dart' show ProgramDetailSheet, ProgramDetailLoader;
import 'rust/api.dart' as rust;
import 'sheet_header.dart';
import 'song_actions.dart';
import 'song_tile.dart';
import 'format.dart' show formatDurationMs;
import 'toast.dart' show showToast;

/// 歌单/播客(电台)详情页: 全屏路由, AppBar 以下单滚动(CustomScrollView),
/// 曲目/节目行定高 56。曲目可见性沿用 library_view 的统一规则
/// (无版权且没收藏 → 隐藏, 顶部提示条数)。评论区独立加载, 失败不拖垮曲目列表。

/// 曲目/节目行统一行高, "定位正在播放"的滚动偏移按它算
const double _kRowHeight = 56.0;

/// 评论底部面板(歌曲/歌单/专辑/播客通用): "..." 菜单里的"查看评论"走这里
Future<void> showCommentsSheet(
  BuildContext context, {
  required String kind,
  required BigInt resourceId,
  String title = '评论',
  int totalHint = 0,

  // 测试注入(不传走 rust), 与 CommentThread 的可选 hook 一一对应
  CommentPageLoader? loadPage,
  CommentLikeHook? like,
  CommentRepliesLoader? loadReplies,
  CommentSendHook? send,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      // 键盘避让: 根节点按 viewInsets.bottom 抬升, 同时把面板高度压掉同样的量,
      // 保证输入框可见、列表可滚、收起键盘后高度回弹(不留白)。
      final insets = MediaQuery.of(sheetContext).viewInsets.bottom;
      final height = math.max(
        200.0,
        MediaQuery.of(sheetContext).size.height * 0.75 - insets,
      );
      return Padding(
        key: const ValueKey('b2-sheet-root'),
        padding: EdgeInsets.only(bottom: insets),
        child: SafeArea(
          child: SizedBox(
            height: height,
            child: Column(
              children: [
                SheetHeader(
                  title: title,
                  onClose: () => Navigator.pop(sheetContext),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    child: CommentThread(
                      kind: kind,
                      resourceId: resourceId,
                      totalHint: totalHint,
                      loadPage: loadPage,
                      like: like,
                      loadReplies: loadReplies,
                      send: send,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

// ---------------- 歌单详情 ----------------

/// 打开歌单详情页(全屏路由). special=true 表示"我喜欢的音乐"(曲目走 likedSongs)。
Future<void> showPlaylistDetail(
  BuildContext context, {
  required BigInt playlistId,
  required String name,
  String? coverUrl,
  bool special = false,
  bool loggedIn = false,
  Set<BigInt> likedIds = const {},
  BigInt? currentTrackId,
  BigInt? currentPlaylistId,
  required void Function(List<rust.SongDto> songs, int index) onPlaySongs,
  void Function(BigInt id, bool liked)? onLikeChanged,
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _PlaylistDetailPage(
        playlistId: playlistId,
        name: name,
        coverUrl: coverUrl,
        special: special,
        loggedIn: loggedIn,
        likedIds: likedIds,
        currentTrackId: currentTrackId,
        currentPlaylistId: currentPlaylistId,
        onPlaySongs: onPlaySongs,
        onLikeChanged: onLikeChanged,
      ),
    ),
  );
}

class _PlaylistDetailPage extends StatefulWidget {
  const _PlaylistDetailPage({
    required this.playlistId,
    required this.name,
    required this.onPlaySongs,
    this.coverUrl,
    this.special = false,
    this.loggedIn = false,
    this.likedIds = const {},
    this.currentTrackId,
    this.currentPlaylistId,
    this.onLikeChanged,
  });

  final BigInt playlistId;
  final String name;
  final String? coverUrl;
  final bool special;
  final bool loggedIn;
  final Set<BigInt> likedIds;
  final BigInt? currentTrackId;
  final BigInt? currentPlaylistId;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(BigInt id, bool liked)? onLikeChanged;

  @override
  State<_PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<_PlaylistDetailPage> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _listKey = GlobalKey();
  final TextEditingController _filterController = TextEditingController();
  String _filter = '';

  rust.PlaylistDetail? _detail;
  String? _detailError;
  bool _subscribed = false;
  bool _subBusy = false;

  /// 歌单是不是自己的(创建者 uid == 当前账号 uid) —— 决定能否改名/删除/移出曲目
  bool _canEdit = false;

  /// "移出曲目"模式: 开着的时候点曲目行 = 从歌单移除
  bool _editingTracks = false;

  List<rust.SongDto>? _songs;
  String? _songsError;

  /// 红心状态的页面内副本(以入参为初值, 变更经 onLikeChanged 同步回主页)
  Set<BigInt> _liked = <BigInt>{};

  @override
  void initState() {
    super.initState();
    _liked = Set<BigInt>.of(widget.likedIds);
    _loadDetail();
    _loadSongs();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _filterController.dispose();
    super.dispose();
  }

  // ---------- 数据 ----------

  /// 头部详情: 失败不整页报错, 头部用入参兜底, 卡片里给一个小重试链接
  Future<void> _loadDetail() async {
    setState(() => _detailError = null);
    try {
      final d = await retryNetwork(
        () => rust.playlistDetail(playlistId: widget.playlistId),
      );
      if (!mounted) return;
      final myUid = await _currentUid();
      if (!mounted) return;
      setState(() {
        _detail = d;
        _subscribed = d.subscribed;
        _canEdit =
            widget.loggedIn &&
            !widget.special &&
            d.creatorId > BigInt.zero &&
            d.creatorId == myUid;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _detailError = friendlyError(e));
    }
  }

  /// 当前账号 uid(同步接口, 未登录返回 0). 用来判断歌单归属
  Future<BigInt> _currentUid() async {
    try {
      return await rust.myUid();
    } catch (_) {
      return BigInt.zero;
    }
  }

  Future<void> _loadSongs() async {
    setState(() => _songsError = null);
    try {
      final songs = await retryNetwork(
        () => widget.special
            ? rust.likedSongs()
            : rust.playlistSongs(playlistId: widget.playlistId),
      );
      if (!mounted) return;
      setState(() {
        _songs = songs;
        // "我喜欢的音乐"里的曲目天然都在我喜欢列表, 并进红心集合
        // (主页的 likedIds 可能还没拉完, 以加载结果补齐)
        if (widget.special) _liked.addAll(songs.map((s) => s.id));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _songsError = friendlyError(e));
    }
  }

  // ---------- 派生数据 ----------

  /// 统一的无版权可见性规则(与搜索/歌单列表一致)
  List<rust.SongDto> get _visible {
    final songs = _songs;
    if (songs == null) return const [];
    return visibleSongs(songs, _liked);
  }

  /// 搜索框本地过滤: 歌名或歌手 contains, 大小写不敏感
  List<rust.SongDto> get _display {
    final q = _filter.trim().toLowerCase();
    final visible = _visible;
    if (q.isEmpty) return visible;
    return [
      for (final s in visible)
        if (s.name.toLowerCase().contains(q) ||
            s.artist.toLowerCase().contains(q))
          s,
    ];
  }

  int get _hiddenCount {
    final songs = _songs;
    if (songs == null) return 0;
    return hiddenUnplayableCount(songs, _liked);
  }

  /// 页内点播过的曲目(点完立刻能"定位"，不必等父层把状态传回来)
  BigInt? _localTrackId;

  /// 当前正在播放的曲目: 页内点播优先, 其次父层传入
  BigInt? get _playingId => _localTrackId ?? widget.currentTrackId;

  /// 当前队列正是这个歌单(或本页刚点播过)时才显示"定位正在播放"
  bool get _canLocate =>
      (_localTrackId != null ||
          widget.currentPlaylistId == widget.playlistId) &&
      _playingId != null;

  // ---------- 动作 ----------

  void _toast(String message) {
    if (!mounted) return;
    showToast(context, message);
  }

  Future<void> _toggleLike(rust.SongDto song) async {
    if (!widget.loggedIn) {
      _toast('收藏需要先登录');
      return;
    }
    final liked = _liked.contains(song.id);
    try {
      await rust.setLiked(trackId: song.id, liked: !liked);
      if (!mounted) return;
      setState(() {
        if (liked) {
          _liked.remove(song.id);
        } else {
          _liked.add(song.id);
        }
      });
      widget.onLikeChanged?.call(song.id, !liked);
    } catch (e) {
      _toast('收藏失败: ${friendlyError(e)}');
    }
  }

  Future<void> _toggleSubscribe() async {
    if (_subBusy || _detail == null) return;
    final target = !_subscribed;
    setState(() => _subBusy = true);
    try {
      final ok = await rust.setPlaylistSubscribed(
        playlistId: widget.playlistId,
        subscribed: target,
      );
      if (!mounted) return;
      if (ok) {
        setState(() => _subscribed = target);
        _toast(target ? '已收藏歌单' : '已取消收藏');
      } else {
        _toast('操作未生效, 请稍后重试');
      }
    } catch (e) {
      _toast(friendlyError(e));
    } finally {
      if (mounted) setState(() => _subBusy = false);
    }
  }

  /// 编辑歌单信息(名称/简介). 自己的歌单才有入口.
  Future<void> _showEditSheet() async {
    final d = _detail;
    if (d == null) return;
    final nameCtrl = TextEditingController(text: d.name);
    final descCtrl = TextEditingController(text: d.description);
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑歌单信息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              maxLength: 40,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            TextField(
              controller: descCtrl,
              maxLines: 4,
              minLines: 2,
              maxLength: 300,
              decoration: const InputDecoration(labelText: '简介'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final name = nameCtrl.text.trim();
    final desc = descCtrl.text;
    nameCtrl.dispose();
    descCtrl.dispose();
    if (save != true || !mounted) return;
    try {
      if (name.isNotEmpty && name != d.name) {
        await rust.renamePlaylist(playlistId: d.id, name: name);
      }
      if (desc != d.description) {
        await rust.updatePlaylistDesc(playlistId: d.id, desc: desc);
      }
      _toast('已保存');
      await _loadDetail();
    } catch (e) {
      _toast('保存失败: ${friendlyError(e)}');
    }
  }

  /// 删除歌单(自己创建的). 成功后直接退出详情页.
  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除歌单'),
        content: Text('确定删除《${_detail?.name ?? widget.name}》? 删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await rust.deletePlaylist(playlistId: widget.playlistId);
      if (!mounted) return;
      _toast('歌单已删除');
      Navigator.of(context).pop(true);
    } catch (e) {
      _toast('删除失败: ${friendlyError(e)}');
    }
  }

  /// 把一首歌移出歌单
  Future<void> _removeTrack(rust.SongDto song) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移出歌单'),
        content: Text('把《${song.name}》移出这个歌单?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await rust.removeFromPlaylist(
        playlistId: widget.playlistId,
        trackId: song.id,
      );
      if (!mounted) return;
      setState(() => _songs?.removeWhere((s) => s.id == song.id));
      _toast('已移出《${song.name}》');
    } catch (e) {
      _toast('移出失败: ${friendlyError(e)}');
    }
  }

  void _showShareSheet() {
    _showResourceShareSheet(
      context,
      kind: 'playlist',
      resourceId: widget.playlistId,
      message: _detail?.name ?? widget.name,
      link: 'https://music.163.com/#/playlist?id=${widget.playlistId}',
    );
  }

  /// "定位正在播放": 把正在播放的曲目滚进可视区。
  /// 行高恒定 56, 实际偏移 = 曲目列表起点 + 行数 × 56 (起点用 getOffsetToReveal
  /// 现场量, 因为头部/搜索框高度是动态的); 量不到就只保留行内高亮。
  void _locateCurrent() {
    final trackId = _playingId;
    if (trackId == null) return;
    final index = _display.indexWhere((s) => s.id == trackId);
    if (index < 0) {
      _toast('正在播放的曲目不在当前列表里');
      return;
    }
    if (!_scroll.hasClients) return;
    var base = 0.0;
    final listRo = _listKey.currentContext?.findRenderObject();
    if (listRo != null && listRo.attached) {
      final viewport = RenderAbstractViewport.maybeOf(listRo);
      if (viewport != null) {
        base = viewport.getOffsetToReveal(listRo, 0).offset;
      }
    }
    final target = (base + index * _kRowHeight).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final display = _display;
    return Scaffold(
      appBar: AppBar(
        title: Text(_detail?.name ?? widget.name),
        actions: [
          // "我喜欢的音乐"不提供收藏按钮; 详情没拉到时也不知道收藏状态
          if (!widget.special && widget.loggedIn && _detail != null)
            IconButton(
              tooltip: _subscribed ? '取消收藏' : '收藏歌单',
              icon: Icon(_subscribed ? Icons.favorite : Icons.favorite_border),
              onPressed: _subBusy ? null : _toggleSubscribe,
            ),
          // 自己的歌单才能管理(改名/移出曲目/删除)
          if (_canEdit)
            PopupMenuButton<String>(
              tooltip: '歌单管理',
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                switch (value) {
                  case 'edit':
                    _showEditSheet();
                  case 'remove':
                    setState(() => _editingTracks = !_editingTracks);
                  case 'delete':
                    _confirmDelete();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('编辑歌单信息')),
                PopupMenuItem(
                  value: 'remove',
                  child: Text(_editingTracks ? '结束移出曲目' : '移出曲目'),
                ),
                const PopupMenuItem(value: 'delete', child: Text('删除歌单')),
              ],
            ),
          IconButton(
            tooltip: '分享',
            icon: const Icon(Icons.share_outlined),
            onPressed: _showShareSheet,
          ),
        ],
      ),
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(child: _buildHeaderCard()),
          if (_editingTracks)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.remove_circle_outline, size: 16),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          '移出曲目模式: 点击曲目即可移出歌单',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() => _editingTracks = false),
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(child: _buildToolbar()),
          if (_hiddenCount > 0) SliverToBoxAdapter(child: _buildHiddenNote()),
          _buildSongs(display),
          SliverToBoxAdapter(
            child: CommentThread(
              kind: 'playlist',
              resourceId: widget.playlistId,
              totalHint: _detail?.commentCount.toInt() ?? 0,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _buildHeaderCard() {
    final d = _detail;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d?.name ?? widget.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (d != null && d.creatorName.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '创建者: ${d.creatorName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      if (d != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '${d.trackCount} 首 · 播放 ${d.playCount} 次',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      if (d != null && d.tags.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              for (final t in d.tags) _buildTagChip(t),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                CoverArt(
                  url: d?.coverUrl ?? widget.coverUrl,
                  size: 120,
                  radius: 8,
                ),
              ],
            ),
            if (_detailError != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _loadDetail,
                  child: Text(
                    '详情加载失败, 点击重试',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              )
            else if (d != null && d.description.trim().isNotEmpty)
              _ExpandableText(text: d.description),
          ],
        ),
      ),
    );
  }

  Widget _buildTagChip(String tag) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(tag, style: Theme.of(context).textTheme.labelSmall),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _filterController,
              onChanged: (value) => setState(() => _filter = value),
              decoration: InputDecoration(
                isDense: true,
                hintText: '筛选本页曲目',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _filter.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _filterController.clear();
                          setState(() => _filter = '');
                        },
                      ),
              ),
            ),
          ),
          if (_canLocate) ...[
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: _locateCurrent,
              icon: const Icon(Icons.my_location, size: 18),
              label: const Text('定位正在播放'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHiddenNote() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '已隐藏 $_hiddenCount 首无版权曲目',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }

  Widget _buildSongs(List<rust.SongDto> display) {
    if (_songs == null && _songsError == null) {
      return const SliverToBoxAdapter(child: _SkeletonList());
    }
    if (_songsError != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _songsError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              TextButton(onPressed: _loadSongs, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (display.isEmpty) {
      final message = _filter.trim().isNotEmpty
          ? '没有匹配 "${_filter.trim()}" 的曲目'
          : (_hiddenCount > 0
                ? '这里没有可播放的曲目($_hiddenCount 首无版权已隐藏)'
                : (widget.special ? '还没有喜欢的歌曲' : '这个歌单是空的'));
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
          child: Center(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
      );
    }
    return SliverFixedExtentList(
      key: _listKey,
      itemExtent: _kRowHeight,
      delegate: SliverChildBuilderDelegate((context, i) {
        final song = display[i];
        return _SongRow(
          song: song,
          index: i,
          playing: _playingId == song.id,
          liked: _liked.contains(song.id),
          onToggleLike: () => _toggleLike(song),
          onTap: () {
            // 移出模式下点行 = 移出歌单(不动播放队列)
            if (_editingTracks) {
              _removeTrack(song);
              return;
            }
            widget.onPlaySongs(display, i);
            setState(() => _localTrackId = song.id);
          },
        );
      }, childCount: display.length),
    );
  }
}

// ---------------- 播客(电台)详情 ----------------

/// 打开播客/电台详情页(全屏路由). 电台订阅本轮不做(Rust 侧暂无接口)。
Future<void> showPodcastDetail(
  BuildContext context, {
  required rust.PodcastRadioDto radio,
  required void Function(List<rust.SongDto> songs, int index) onPlaySongs,
  ProgramDetailLoader? loadProgramDetail,
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _PodcastDetailPage(
        radio: radio,
        onPlaySongs: onPlaySongs,
        loadProgramDetail:
            loadProgramDetail ?? (id) => rust.podcastProgram(programId: id),
      ),
    ),
  );
}

class _PodcastDetailPage extends StatefulWidget {
  const _PodcastDetailPage({
    required this.radio,
    required this.onPlaySongs,
    required this.loadProgramDetail,
  });

  final rust.PodcastRadioDto radio;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;

  /// 单集详情(podcast_program), 测试可注入 mock
  final ProgramDetailLoader loadProgramDetail;

  @override
  State<_PodcastDetailPage> createState() => _PodcastDetailPageState();
}

class _PodcastDetailPageState extends State<_PodcastDetailPage> {
  final TextEditingController _filterController = TextEditingController();
  String _filter = '';

  List<rust.PodcastProgramDto>? _programs;
  String? _programsError;

  @override
  void initState() {
    super.initState();
    _loadPrograms();
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _loadPrograms() async {
    setState(() => _programsError = null);
    try {
      final programs = await retryNetwork(
        () => rust.podcastPrograms(
          radioId: widget.radio.id,
          limit: 100,
          offset: 0,
        ),
      );
      if (!mounted) return;
      // song 为空的节目没有音频本体, 不进列表(点了也没法播)
      setState(() {
        _programs = [
          for (final p in programs)
            if (p.song != null) p,
        ];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _programsError = friendlyError(e));
    }
  }

  /// 搜索框本地过滤: 节目名 contains, 大小写不敏感
  List<rust.PodcastProgramDto> get _display {
    final programs = _programs ?? const <rust.PodcastProgramDto>[];
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return programs;
    return [
      for (final p in programs)
        if (p.name.toLowerCase().contains(q)) p,
    ];
  }

  void _showShareSheet() {
    _showResourceShareSheet(
      context,
      kind: 'djradio',
      resourceId: widget.radio.id,
      message: widget.radio.name,
      link: 'https://music.163.com/#/djradio?id=${widget.radio.id}',
    );
  }

  /// display 已经过滤掉 song 为空的节目, 行序即可播队列序
  void _playProgram(int index) {
    final songs = [
      for (final p in _display)
        if (p.song != null) p.song!,
    ];
    widget.onPlaySongs(songs, index);
  }

  @override
  Widget build(BuildContext context) {
    final radio = widget.radio;
    return Scaffold(
      appBar: AppBar(
        title: Text(radio.name),
        actions: [
          // 电台头部卡片没有订阅数字段(PodcastRadioDto 无 subCount),
          // 听众入口放 AppBar 图标(与分享并排).
          IconButton(
            tooltip: '听众',
            icon: const Icon(Icons.groups_outlined),
            onPressed: () => showRadioSubscribers(
              context,
              radioId: radio.id,
              radioName: radio.name,
            ),
          ),
          IconButton(
            tooltip: '分享',
            icon: const Icon(Icons.share_outlined),
            onPressed: _showShareSheet,
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _buildHeaderCard(radio)),
          SliverToBoxAdapter(child: _buildToolbar()),
          _buildPrograms(_display),
          SliverToBoxAdapter(
            child: CommentThread(kind: 'podcast', resourceId: radio.id),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _buildHeaderCard(rust.PodcastRadioDto radio) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        radio.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (radio.djName.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            radio.djName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${radio.programCount} 个节目 · 播放 ${radio.playCount} 次',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                CoverArt(url: radio.coverUrl, size: 120, radius: 8),
              ],
            ),
            if (radio.description.trim().isNotEmpty)
              _ExpandableText(text: radio.description),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: TextField(
        controller: _filterController,
        onChanged: (value) => setState(() => _filter = value),
        decoration: InputDecoration(
          isDense: true,
          hintText: '筛选节目',
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _filter.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _filterController.clear();
                    setState(() => _filter = '');
                  },
                ),
        ),
      ),
    );
  }

  /// 单集详情: 列表数据先占位, 弹层自己再拉一次完整简介(podcast_program)
  Future<void> _openProgramDetail(int index) async {
    final display = _display;
    if (index < 0 || index >= display.length) return;
    final p = display[index];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ProgramDetailSheet(
        program: p,
        loadDetail: widget.loadProgramDetail,
        onPlay: p.song == null
            ? null
            : () {
                Navigator.pop(context);
                _playProgram(index);
              },
      ),
    );
  }

  Widget _buildPrograms(List<rust.PodcastProgramDto> display) {
    if (_programs == null && _programsError == null) {
      return const SliverToBoxAdapter(child: _SkeletonList());
    }
    if (_programsError != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _programsError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              TextButton(onPressed: _loadPrograms, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (display.isEmpty) {
      final message = _filter.trim().isNotEmpty
          ? '没有匹配 "${_filter.trim()}" 的节目'
          : '这个电台还没有节目';
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
          child: Center(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
      );
    }
    return SliverFixedExtentList(
      itemExtent: _kRowHeight,
      delegate: SliverChildBuilderDelegate((context, i) {
        final p = display[i];
        return _ProgramRow(
          program: p,
          onTap: () => _playProgram(i),
          onInfo: () => _openProgramDetail(i),
        );
      }, childCount: display.length),
    );
  }
}

// ---------------- 共用件 ----------------

/// 简介: 默认 3 行 + 展开/收起(歌单/播客头部共用)
class _ExpandableText extends StatefulWidget {
  const _ExpandableText({required this.text});

  final String text;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final expanded = _expanded;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => setState(() => _expanded = !expanded),
            child: Text(
              widget.text.trim(),
              maxLines: expanded ? null : 3,
              overflow: expanded ? null : TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: () => setState(() => _expanded = !expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  expanded ? '收起' : '展开',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 定高 56 的曲目行: 序号(正在播换 volume_up) + 歌名 + 歌手·专辑 + 时长 + 红心
class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.song,
    required this.index,
    required this.playing,
    required this.liked,
    required this.onToggleLike,
    required this.onTap,
  });

  final rust.SongDto song;
  final int index;
  final bool playing;
  final bool liked;
  final VoidCallback onToggleLike;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context).textTheme;
    final grey = TextStyle(color: scheme.outline);
    final titleStyle = playing
        ? theme.bodyMedium?.copyWith(
            color: scheme.primary,
            fontWeight: FontWeight.w600,
          )
        : (song.playable ? theme.bodyMedium : grey);
    return InkWell(
      onTap: onTap,
      child: Container(
        color: playing ? scheme.primary.withValues(alpha: 0.10) : null,
        padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: playing
                  ? Icon(Icons.volume_up, size: 16, color: scheme.primary)
                  : Text(
                      '${index + 1}'.padLeft(2),
                      textAlign: TextAlign.right,
                      style: theme.bodySmall?.copyWith(color: scheme.outline),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          song.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                      ),
                      if (song.playable && song.vip)
                        const VipBadge(small: true),
                      if (song.playable && !song.vip && song.paid)
                        const PaidBadge(),
                      if (!song.playable) const UnplayableBadge(),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${song.artist} · ${song.album}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.labelSmall?.copyWith(
                      color: song.playable ? null : scheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                formatDurationMs(song.durationMs),
                style: theme.bodySmall?.copyWith(color: scheme.outline),
              ),
            ),
            IconButton(
              tooltip: liked ? '取消喜欢' : '喜欢',
              icon: Icon(
                liked ? Icons.favorite : Icons.favorite_border,
                size: 20,
                color: liked ? scheme.primary : null,
              ),
              onPressed: onToggleLike,
            ),
            SongOverflowButton(song: song, size: 20),
          ],
        ),
      ),
    );
  }
}

/// 定高 56 的节目行: 节目名 + DJ · 时长
class _ProgramRow extends StatelessWidget {
  const _ProgramRow({required this.program, required this.onTap, this.onInfo});

  final rust.PodcastProgramDto program;
  final VoidCallback onTap;

  /// 打开单集详情(没有音频本体的单集也给这个入口)
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context).textTheme;
    final song = program.song;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    program.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.bodyMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (program.djName.isNotEmpty) program.djName,
                      formatDurationMs(program.durationMs),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onInfo != null)
              IconButton(
                icon: const Icon(Icons.info_outline, size: 20),
                tooltip: '节目详情',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: onInfo,
              ),
            if (song != null) SongOverflowButton(song: song, size: 20),
          ],
        ),
      ),
    );
  }
}

/// 分享底部菜单: 分享到动态(需登录, 失败只弹 SnackBar) / 复制链接
void _showResourceShareSheet(
  BuildContext context, {
  required String kind,
  required BigInt resourceId,
  required String message,
  required String link,
}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: const Text('分享到动态'),
            onTap: () async {
              Navigator.pop(sheetContext);
              try {
                final ok = await rust.shareResource(
                  kind: kind,
                  resourceId: resourceId,
                  msg: message,
                );
                if (!context.mounted) return;
                showToast(context, ok ? '已分享到动态' : '分享未生效, 请稍后重试');
              } catch (e) {
                if (!context.mounted) return;
                showToast(context, friendlyError(e), isError: true);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('复制链接'),
            onTap: () async {
              Navigator.pop(sheetContext);
              await Clipboard.setData(ClipboardData(text: link));
              if (!context.mounted) return;
              showToast(context, '链接已复制');
            },
          ),
        ],
      ),
    ),
  );
}

/// 曲目/节目加载骨架(灰块占位, 不引入动画依赖)
class _SkeletonList extends StatelessWidget {
  const _SkeletonList();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget box(double width, double height) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }

    return Column(
      children: [
        for (var i = 0; i < 8; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                box(20, 14),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      box(180, 14),
                      const SizedBox(height: 6),
                      box(120, 12),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                box(32, 12),
                const SizedBox(width: 12),
                box(20, 20),
              ],
            ),
          ),
      ],
    );
  }
}
