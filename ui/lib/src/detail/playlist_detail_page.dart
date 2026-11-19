import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;

import '../app_settings.dart';
import '../detail_pane.dart' show openDetail;
import '../async_view.dart';
import '../comment_thread.dart';
import '../cover_palette.dart';
import '../library_view.dart';
import '../layout.dart'
    show
        kCardRowPadding,
        kTwoColumnGap,
        kTwoColumnListWidth,
        rowExtentFor,
        twoColumnFor;
import '../net_retry.dart';
import '../playback_bridge.dart';
import '../rust/api.dart' as rust;
import '../toast.dart' show showToast, showUndoToast;
import 'detail_shared.dart' show showResourceShareSheet;
import 'playlist_dialogs.dart'
    show confirmDeletePlaylist, confirmRemoveTrack, showEditPlaylistInfoSheet;
import 'playlist_detail_parts.dart'
    show
        PlaylistEditingBanner,
        PlaylistFilterBar,
        PlaylistHeaderCard,
        PlaylistHiddenNote;
import 'playlist_songs_sliver.dart' show PlaylistSongsSliver;

/// 打开歌单详情(主从分栏的右栏 **或** 全屏路由). special=true 表示"我喜欢的音乐"
/// (曲目走 likedSongs)。
///
/// 走向由 [openDetail] 统一决定(方案 B · S4):
///   · 宽档 + 根路由 + 有右栏宿主 ⇒ 填右栏(此时用 [embedded] 形态: 去 AppBar /
///     去返回箭头 / 保留内容与滚动);
///   · 窄/中档, 或从"已经压上来的全屏页"里点 ⇒ 照旧 push 一整页(几何零变化)。
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
  void Function(BigInt id, bool liked)? onLikeChanged,
}) {
  Widget build({required bool embedded}) => _PlaylistDetailPage(
    playlistId: playlistId,
    name: name,
    coverUrl: coverUrl,
    special: special,
    loggedIn: loggedIn,
    likedIds: likedIds,
    currentTrackId: currentTrackId,
    currentPlaylistId: currentPlaylistId,
    onLikeChanged: onLikeChanged,
    embedded: embedded,
  );
  return openDetail(
    context,
    key: playlistId,
    pane: (_) => build(embedded: true),
    route: () =>
        MaterialPageRoute<void>(builder: (_) => build(embedded: false)),
  );
}

class _PlaylistDetailPage extends StatefulWidget {
  const _PlaylistDetailPage({
    required this.playlistId,
    required this.name,
    this.coverUrl,
    this.special = false,
    this.loggedIn = false,
    this.likedIds = const {},
    this.currentTrackId,
    this.currentPlaylistId,
    this.onLikeChanged,
    this.embedded = false,
  });

  /// 内嵌形态(主从分栏右栏): 没有 AppBar、没有返回箭头, 双列判据让位(右栏只有
  /// 420 宽, 按窗口宽切 300+12+528 会竖排溢出), 其余内容/滚动/四态全部照旧。
  final bool embedded;

  final BigInt playlistId;
  final String name;
  final String? coverUrl;
  final bool special;
  final bool loggedIn;
  final Set<BigInt> likedIds;
  final BigInt? currentTrackId;
  final BigInt? currentPlaylistId;
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

  /// 头部详情由本层持有 future 交给 [AsyncView]: 编辑歌单信息后的静默刷新
  /// 要把新数据包成"已完成的 future"换进去, 才不闪回整块加载态。
  late Future<rust.PlaylistDetail> _detailFuture;

  /// 当前歌单封面的取色结果(头部卡片主色调背景), null/回退时透明直通主题
  CoverPalette? _palette;
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
    _detailFuture = _loadDetail();
    _loadSongs();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _filterController.dispose();
    super.dispose();
  }

  // ---------- 数据 ----------

  /// 头部详情的取数入口(四态交给 [AsyncView]; 网络错误自动退避重试)。
  /// 顺带把封面取色 / 收藏态 / 可编辑态同步进页面 —— 失败不整页报错,
  /// 头部用入参兜底, 卡片里给一个小重试链接。
  Future<rust.PlaylistDetail> _loadDetail() async {
    final d = await retryNetwork(
      () => rust.playlistDetail(playlistId: widget.playlistId),
    );
    if (!mounted) return d;
    // 封面取色: 决定头部卡片的主色调背景(失败/灰白封面 → 回退主题, 不闪黑)
    paletteFromUrl(d.coverUrl ?? widget.coverUrl).then((palette) {
      if (!mounted) return;
      setState(() => _palette = palette);
    });
    final myUid = await _currentUid();
    if (!mounted) return d;
    setState(() {
      _detail = d;
      _subscribed = d.subscribed;
      _canEdit =
          widget.loggedIn &&
          !widget.special &&
          d.creatorId > BigInt.zero &&
          d.creatorId == myUid;
    });
    return d;
  }

  /// 重试(AsyncView 的 onRetry): 换 future 重取, 头部回到"入参兜底"形态
  void _retryDetail() {
    setState(() {
      _detailFuture = _loadDetail();
    });
  }

  /// 静默刷新(编辑歌单信息 / 改名成功后): 拿到新数据再换 future,
  /// 已渲染的卡片不闪回加载态; 失败保留旧内容(保存动作本身已有提示)。
  Future<void> _refreshDetailSilently() async {
    try {
      final d = await _loadDetail();
      if (!mounted) return;
      setState(() {
        _detailFuture = Future<rust.PlaylistDetail>.value(d);
      });
    } catch (_) {
      // 静默刷新失败: 不覆盖已渲染的头部
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

  /// 搜索框本地过滤: 歌名或艺人 contains, 大小写不敏感
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
      // 取消喜欢只给 3 秒提示(再点一次红心即可恢复), 不留常驻的撤销条
      if (liked) {
        showToast(context, '已取消喜欢《${song.name}》');
      }
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
        if (target) {
          _toast('已收藏歌单');
        } else {
          // 取消收藏歌单给 5 秒撤销(公众号召力最大的一次误触)
          showUndoToast(
            context,
            message: '已取消收藏歌单',
            onUndo: () => _toggleSubscribe(),
          );
        }
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
    final edited = await showEditPlaylistInfoSheet(
      context,
      name: d.name,
      description: d.description,
    );
    if (edited == null || !mounted) return;
    try {
      if (edited.name.isNotEmpty && edited.name != d.name) {
        await rust.renamePlaylist(playlistId: d.id, name: edited.name);
      }
      if (edited.desc != d.description) {
        await rust.updatePlaylistDesc(playlistId: d.id, desc: edited.desc);
      }
      _toast('已保存');
      await _refreshDetailSilently();
    } catch (e) {
      _toast('保存失败: ${friendlyError(e)}');
    }
  }

  /// 删除歌单(自己创建的). 成功后直接退出详情页.
  Future<void> _confirmDelete() async {
    final ok = await confirmDeletePlaylist(
      context,
      _detail?.name ?? widget.name,
    );
    if (!ok || !mounted) return;
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
    final ok = await confirmRemoveTrack(context, song.name);
    if (!ok || !mounted) return;
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
    showResourceShareSheet(
      context,
      kind: 'playlist',
      resourceId: widget.playlistId,
      message: _detail?.name ?? widget.name,
      link: 'https://music.163.com/#/playlist?id=${widget.playlistId}',
    );
  }

  /// 点曲目行: 移出模式下 = 移出歌单; 否则按设置决定起播范围并记下页内播放态
  void _handleSongTap(rust.SongDto song, int index) {
    // 移出模式下点行 = 移出歌单(不动播放队列)
    if (_editingTracks) {
      _removeTrack(song);
      return;
    }
    // 用户设置: 歌单内搜索后点歌, 是"只加当前歌"还是"切回完整列表"。
    // 没在筛选(或没有追加回调)时保持原行为: 按当前展示的列表起播。
    final filtering = _filter.trim().isNotEmpty;
    final action = AppSettings.instance.librarySearchPlayAction;
    // 播放能力走全局 PlaybackBridge 单入口; playlistId 是歌单队列的来源标记
    // (详情页"定位正在播放"据此判断当前队列是不是本歌单)
    final bridge = PlaybackBridge.instance;
    if (filtering &&
        action == LibrarySearchPlayAction.appendCurrent &&
        bridge.canAppendNext) {
      bridge.appendNext(song);
    } else if (filtering && action == LibrarySearchPlayAction.fullList) {
      final all = _visible;
      final idx = all.indexWhere((s) => s.id == song.id);
      bridge.playSongs(all, idx < 0 ? 0 : idx, playlistId: widget.playlistId);
    } else {
      bridge.playSongs(_display, index, playlistId: widget.playlistId);
    }
    setState(() => _localTrackId = song.id);
  }

  /// "定位正在播放": 把正在播放的曲目滚进可视区。
  /// 行高恒定(= 列表的 itemExtent, 即 [rowExtentFor]), 实际偏移 = 曲目列表起点 +
  /// 行数 × 行高 (起点用 getOffsetToReveal 现场量, 因为头部/搜索框高度是动态的);
  /// 量不到就只保留行内高亮。
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
    final target = (base + index * rowExtentFor(context)).clamp(
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
    // 内嵌形态(主从分栏右栏): 没有 AppBar/返回箭头 —— 否则右栏里会出现一条
    // "返回箭头退整页"的错语义。动作(收藏/管理/分享)一个不少, 挪到顶部一行;
    // 双列判据必须让位: 右栏 420 宽按窗口尺寸(1280)判会切出 300+12+528 ⇒ 溢出。
    if (widget.embedded) {
      final actions = _buildActions();
      return Scaffold(
        body: Column(
          children: [
            if (actions.isNotEmpty)
              Padding(
                padding: kCardRowPadding,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: actions,
                ),
              ),
            Expanded(child: _buildSingleColumnBody(display)),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_detail?.name ?? widget.name),
        actions: _buildActions(),
      ),
      // 双列判据用**窗口逻辑尺寸**(MediaQuery.sizeOf), 不是 body 的实测宽:
      // 壳层 ContentWidthLimit 把 body 限到 840, 拿它比 900 永远为假。
      // 窗口 >= 900 时 body 恰好 840 = 300 + 12 + 528, 两栏不挤压。
      body: twoColumnFor(MediaQuery.sizeOf(context))
          ? _buildTwoColumnBody(display)
          : _buildSingleColumnBody(display),
    );
  }

  /// AppBar 动作(内嵌形态里挪到顶部一行): 收藏 / 管理 / 分享。
  List<Widget> _buildActions() => [
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
  ];

  /// 单列 body(窄/中档): 与双列改造前**逐像素一致** —— 同一棵 sliver 树、同一顺序,
  /// 双列分支只是把它一分为二, 这里一行几何都没有动。
  Widget _buildSingleColumnBody(List<rust.SongDto> display) => CustomScrollView(
    controller: _scroll,
    slivers: [
      _buildHeaderCard(),
      if (_editingTracks) SliverToBoxAdapter(child: _editingBanner()),
      SliverToBoxAdapter(child: _buildToolbar()),
      if (_hiddenCount > 0) SliverToBoxAdapter(child: _buildHiddenNote()),
      _buildSongs(display),
      _buildComments(),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ],
  );

  /// 双列 body(窗口 >= [kTwoColumnMinWidth] 且 >= [kTwoColumnMinHeight])。
  ///
  /// 切分点取「头部卡片 / 其余」: 左栏只有歌单信息(封面/标题/创建者/统计/简介),
  /// 右栏是曲目相关的一切(移出模式横幅 / 筛选条 / 无版权提示 / 曲目 / 评论) ——
  /// 窄档里这些块的相对顺序原样保留(横幅 -> 筛选 -> 提示 -> 曲目 -> 评论)。
  ///
  /// 滚动口径: **两列各自滚动**, 理由三点:
  ///   · 头部卡片在 300 宽下高度随简介展开/系统字号变化, 与曲目列表没有"同步滚动"
  ///     的语义关系; 绑在一起会让"定位正在播放"把左栏一起滚出视野;
  ///   · 右栏继续用 _scroll ⇒ [_locateCurrent] 的"量曲目列表起点"语义原样成立
  ///     (左栏不设 controller, 两列互不影响);
  ///   · 左栏内容比右栏短时, 右栏仍能滚满整个 body 高度, 不浪费。
  Widget _buildTwoColumnBody(List<rust.SongDto> display) {
    final info = ListView(
      key: const Key('playlist-detail-info-column'),
      padding: EdgeInsets.zero,
      children: [_buildHeaderContent()],
    );
    final songs = CustomScrollView(
      key: const Key('playlist-detail-songs-column'),
      controller: _scroll,
      slivers: [
        if (_editingTracks) SliverToBoxAdapter(child: _editingBanner()),
        SliverToBoxAdapter(child: _buildToolbar()),
        if (_hiddenCount > 0) SliverToBoxAdapter(child: _buildHiddenNote()),
        _buildSongs(display),
        _buildComments(),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
    return Row(
      // stretch: 两列同高, 顶部/底部严格对齐(顶部对齐是双列的第一条几何断言)
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: kTwoColumnListWidth, child: info),
        const SizedBox(width: kTwoColumnGap),
        Expanded(child: songs),
      ],
    );
  }

  Widget _editingBanner() => PlaylistEditingBanner(
    onDone: () => setState(() => _editingTracks = false),
  );

  Widget _buildComments() => SliverToBoxAdapter(
    child: CommentThread(
      kind: 'playlist',
      resourceId: widget.playlistId,
      totalHint: _detail?.commentCount.toInt() ?? 0,
      // 评论分享卡片的语境(需求 10): 来自哪个歌单
      shareSourceTitle: widget.name,
      shareSourceKind: commentSourceKindLabel('playlist'),
    ),
  );

  /// 头部卡片: 四态收敛到 [AsyncView] —— 加载中/出错都用"入参兜底"的卡片
  /// (改造前也是立刻渲染兜底卡片, 不转圈), 出错时卡片右下角给"点击重试";
  /// 有数据时换成完整卡片。
  Widget _buildHeaderCard() => SliverToBoxAdapter(child: _buildHeaderContent());

  /// 头部卡片本体: 单列进 sliver, 双列直接进左栏 ListView(不再套 sliver)。
  Widget _buildHeaderContent() => AsyncView<rust.PlaylistDetail>(
    future: _detailFuture,
    onRetry: _retryDetail,
    // detail 是对象(不是 List/String), 不会落到空态; 文案只为断言/兜底
    emptyText: '歌单详情暂无数据',
    loadingBuilder: (_) => _headerCard(null, null, null),
    errorBuilder: (_, error, retry) =>
        _headerCard(null, friendlyError(error), retry),
    builder: (_, detail, _) => _headerCard(detail, null, null),
  );

  Widget _headerCard(
    rust.PlaylistDetail? detail,
    String? error,
    VoidCallback? retry,
  ) => PlaylistHeaderCard(
    detail: detail,
    name: widget.name,
    fallbackCoverUrl: widget.coverUrl,
    palette: _palette,
    detailError: error,
    onRetry: retry ?? _retryDetail,
  );

  Widget _buildToolbar() => PlaylistFilterBar(
    controller: _filterController,
    filter: _filter,
    onChanged: (value) => setState(() => _filter = value),
    onClear: () {
      _filterController.clear();
      setState(() => _filter = '');
    },
    canLocate: _canLocate,
    onLocate: _locateCurrent,
  );

  Widget _buildHiddenNote() => PlaylistHiddenNote(count: _hiddenCount);

  Widget _buildSongs(List<rust.SongDto> display) => PlaylistSongsSliver(
    songs: _songs,
    error: _songsError,
    display: display,
    filter: _filter,
    special: widget.special,
    hiddenCount: _hiddenCount,
    playingId: _playingId,
    liked: _liked,
    listKey: _listKey,
    onRetry: _loadSongs,
    onToggleLike: _toggleLike,
    onTapSong: _handleSongTap,
  );
}
