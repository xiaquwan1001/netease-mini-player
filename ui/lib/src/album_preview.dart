import 'dart:async';

import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'async_view.dart';
import 'artist_page.dart';
import 'cover_art.dart';
import 'error_views.dart' show InlineError;
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'song_actions.dart';
import 'song_tile.dart' show SongRow, SongRowLayout, SongRowSubtitle;
import 'state_views.dart';
import 'toast.dart' show showToast;

typedef AlbumLoader = Future<rust.AlbumDetailDto> Function(BigInt albumId);

/// 专辑详情: 大图 + 专辑信息 + 曲目列表.
/// 点曲目 → 关闭本页, 用整张专辑重置播放队列并从这首开始.
/// loadAlbum 可注入(测试用), 默认走 Rust 接口.
///
/// 审查 P1-7.5: 原本是 [showDialog] 弹层(无 AppBar/无返回键, insetPadding 上下 32,
/// 小屏大字号把内容挤在圈里), 与同重量的歌单详情(全页 Scaffold)不一致;
/// 现改为全页 [Scaffold], 语义/注入点/回调整批曲目的行为完全保留。
Future<void> showAlbumPreview(
  BuildContext context, {
  required BigInt albumId,
  String? albumName,
  String? coverUrl,
  required void Function(List<rust.SongDto> songs, int index) onPlay,
  AlbumLoader? loadAlbum,

  /// 从"收藏的专辑"进来时已知已收藏, 直接显示"已收藏"
  bool initiallySubscribed = false,

  /// 测试注入: 收藏/取消收藏
  Future<bool> Function(BigInt albumId, bool subscribed)? setSubscribed,

  /// 测试注入: 按艺人名解析 id(默认走 searchExact)
  Future<BigInt> Function(String name)? resolveArtistId,

  /// 测试注入: 打开艺人主页(默认 showArtistDetail)
  void Function(BigInt artistId, String name)? onOpenArtist,
}) {
  // 记录"最近一次交互"(我的页收藏专辑按它排序; 见 recent_order.dart)。
  // 放在入口处而不是各调用点: 专辑入口有 10 处(推荐/我的/搜索/艺人页…),
  // 漏一个就会出现"我明明刚点过却排后面"。
  if (albumId > BigInt.zero) {
    unawaited(AppSettings.instance.touchInteraction('album', albumId));
  }
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => AlbumPreviewPage(
        albumId: albumId,
        albumName: albumName,
        coverUrl: coverUrl,
        onPlay: onPlay,
        load: loadAlbum ?? (id) => rust.albumDetail(albumId: id),
        initiallySubscribed: initiallySubscribed,
        setSubscribed:
            setSubscribed ??
            (id, subscribed) =>
                rust.setAlbumSubscribed(albumId: id, subscribed: subscribed),
        resolveArtistId: resolveArtistId,
        onOpenArtist: onOpenArtist,
      ),
    ),
  );
}

/// 专辑详情全页(原 _AlbumPreviewDialog).
class AlbumPreviewPage extends StatefulWidget {
  const AlbumPreviewPage({
    super.key,
    required this.albumId,
    required this.albumName,
    required this.coverUrl,
    required this.onPlay,
    required this.load,
    required this.initiallySubscribed,
    required this.setSubscribed,
    this.resolveArtistId,
    this.onOpenArtist,
  });

  final BigInt albumId;
  final String? albumName;
  final String? coverUrl;
  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final AlbumLoader load;
  final bool initiallySubscribed;
  final Future<bool> Function(BigInt albumId, bool subscribed) setSubscribed;

  /// 按艺人名解析 id(测试注入; 默认 searchExact)
  final Future<BigInt> Function(String name)? resolveArtistId;

  /// 打开艺人主页(测试注入; 默认 showArtistDetail)
  final void Function(BigInt artistId, String name)? onOpenArtist;

  @override
  State<AlbumPreviewPage> createState() => _AlbumPreviewPageState();
}

class _AlbumPreviewPageState extends State<AlbumPreviewPage> {
  /// AppBar 标题要用"取到的专辑名", 而四态内容在 body 的 AsyncView 里 ——
  /// 这里只留一份专辑引用给标题用, 四态判定仍在 AsyncView(见 _buildBody)。
  rust.AlbumDetailDto? _album;

  /// 收藏状态: 由入参决定初值, 点按钮后本地翻转(没有可靠的"是否已收藏"查询接口)
  late bool _subscribed = widget.initiallySubscribed;
  bool _subBusy = false;
  String? _subError;

  /// 取数(**不要**再套 retryNetwork: AsyncView 的 load 形态已套了一层,
  /// 双层会变成 3x3 = 9 次重试); 顺手记下专辑给 AppBar 标题用。
  Future<rust.AlbumDetailDto> _loadAlbum() async {
    final album = await widget.load(widget.albumId);
    if (mounted && !identical(_album, album)) {
      setState(() {
        _album = album;
      });
    }
    return album;
  }

  Future<void> _toggleSubscribe() async {
    final target = !_subscribed;
    setState(() {
      _subBusy = true;
      _subError = null;
    });
    try {
      final ok = await widget.setSubscribed(widget.albumId, target);
      if (!mounted) return;
      setState(() => _subscribed = ok ? target : _subscribed);
    } catch (e) {
      if (!mounted) return;
      setState(() => _subError = friendlyError(e));
    } finally {
      if (mounted) setState(() => _subBusy = false);
    }
  }

  /// 多艺人分隔符: "A / B"、"A、B"、"A & B" 都拆开
  List<String> _artistNames(rust.AlbumDetailDto album) => album.artist
      .split(RegExp(r'\s*(?:/|、|,|，|&|＆)\s*'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> _openArtist(
    BuildContext context,
    rust.AlbumDetailDto album,
  ) async {
    final names = _artistNames(album);
    if (names.isEmpty) return;
    var name = names.first;
    if (names.length > 1) {
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('选择艺人'),
          children: [
            for (final n in names)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, n),
                child: Text(n),
              ),
          ],
        ),
      );
      if (picked == null || !context.mounted) return;
      name = picked;
    }
    // 单艺人且曲目里有 artistId: 不用联网解析
    var id = BigInt.zero;
    if (names.length == 1) {
      for (final s in album.songs) {
        if (s.artistId > BigInt.zero &&
            (s.artist == name || s.artist.contains(name))) {
          id = s.artistId;
          break;
        }
      }
    }
    if (id == BigInt.zero) {
      final resolve = widget.resolveArtistId;
      try {
        id = resolve != null
            ? await resolve(name)
            : await _searchArtistId(name);
      } catch (_) {
        id = BigInt.zero;
      }
    }
    if (!context.mounted) return;
    if (id == BigInt.zero) {
      showToast(context, '没有找到艺人「$name」');
      return;
    }
    final open = widget.onOpenArtist;
    if (open != null) {
      open(id, name);
      return;
    }
    await showArtistDetail(
      context,
      artistId: id,
      name: name,
      onPlaySongs: widget.onPlay,
    );
  }

  /// 按名字解析艺人 id(默认走精确搜索; 取同名或第一个命中)
  Future<BigInt> _searchArtistId(String name) async {
    final exact = await rust.searchExact(keywords: name);
    for (final a in exact.artists) {
      if (a.name == name) return a.id;
    }
    return exact.artists.isEmpty ? BigInt.zero : exact.artists.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final name = _album?.name ?? widget.albumName ?? '专辑';
    return Scaffold(
      // 全页骨架对齐歌单详情: AppBar 自带返回键, 破坏性/长内容不再挤在 Dialog 圈里
      appBar: AppBar(
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _buildBody(context),
    );
  }

  /// 整页四态: 加载 / 出错交给 [AsyncView], 数据态(含"详情有返回但曲目为空"
  /// 的空态, 以及 albumId 为 0 的无 id 兜底)在 [_content] 里给。
  ///
  /// 取舍: AsyncView 的空判定只看 null / 空集合, 而"空专辑"是"详情非空、曲目为空",
  /// 且头部(封面/艺人/收藏按钮)要照常显示 —— 所以空态留在内容里用统一的
  /// [EmptyView], 不为了套 AsyncView 编造一份空数据。
  Widget _buildBody(BuildContext context) {
    if (widget.albumId <= BigInt.zero) {
      // 没有专辑 id: 无可取数据(与改前一致, 一个请求都不发), 直接骨架 + 空态
      return _content(context, null);
    }
    return AsyncView<rust.AlbumDetailDto>(
      load: _loadAlbum,
      emptyText: '这张专辑暂无曲目, 先去听听别的吧',
      // 整页只有"头部 + 曲目表"两块, 加载/出错沿用改前视觉:
      // 加载 = 整页 LoadingView; 出错 = 行内一行 + 右侧重试。
      loadingBuilder: (_) => const LoadingView(),
      errorBuilder: (_, error, retry) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: InlineError(
          message: '专辑加载失败: ${friendlyError(error)}',
          onRetry: retry,
        ),
      ),
      builder: (context, album, _) => _content(context, album),
    );
  }

  Widget _content(BuildContext context, rust.AlbumDetailDto? album) {
    final cover = album?.coverUrl ?? widget.coverUrl;
    final songs = album?.songs ?? const <rust.SongDto>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CoverArt(url: cover, size: 120, radius: 10),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 专辑名只在 AppBar 出现一次(全页后正文不再重复标题)
                    // 艺人可点: 单艺人直接进主页, 多艺人先弹窗选择(用户要求)
                    InkWell(
                      onTap: album == null
                          ? null
                          : () => _openArtist(context, album),
                      borderRadius: BorderRadius.circular(4),
                      child: Text(
                        album?.artist ?? '未知艺人',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: album == null
                              ? null
                              : Theme.of(context).colorScheme.primary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (songs.isNotEmpty)
                      Text(
                        '共 ${songs.length} 首',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (album != null && album.description.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        album.description,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (widget.albumId > BigInt.zero)
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: _subBusy ? null : _toggleSubscribe,
                            icon: Icon(
                              _subscribed
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              size: 18,
                              color: _subscribed
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                            label: Text(_subscribed ? '已收藏' : '收藏专辑'),
                          ),
                          if (_subBusy) const LoadingView.inline(size: 14),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_subError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              _subError!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        const Divider(height: 16),
        Expanded(
          child: songs.isEmpty
              ? const EmptyView(
                  icon: Icons.music_note_outlined,
                  title: '这张专辑暂无曲目, 先去听听别的吧',
                )
              : _songsArea(context, songs),
        ),
      ],
    );
  }

  /// 曲目表(非分页: 专辑曲目随专辑详情一次全量返回)
  Widget _songsArea(BuildContext context, List<rust.SongDto> songs) {
    return ListView.builder(
      // 手势条留白(审查 P1-7.15: 全页列表要算底部 inset)
      padding: EdgeInsets.only(
        bottom: 12 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      itemCount: songs.length,
      itemBuilder: (context, i) {
        final s = songs[i];
        // 正在播放的那首在曲目表里要高亮(与歌单详情/日推同一语汇) ——
        // 播放态由 SongRow 自己读全局 nowPlayingSongId, 页面不再各自接线。
        return SongRow(
          song: s,
          layout: SongRowLayout.tile,
          // 序号列(正在播放时换成喇叭); 专辑曲目没有封面
          indexText: '${i + 1}',
          subtitle: SongRowSubtitle.artist,
          // 行尾 "..." = 统一歌曲菜单(专辑来源)
          menuSource: SongActionSource.album,
          // 无版权曲目灰显且点了没反应(官方同款)
          tapOnlyWhenPlayable: true,
          // 点播不退出专辑页(与歌单详情/日推一致): 换队列, 页面留在原地
          onTap: () => widget.onPlay(songs, i),
        );
      },
    );
  }
}
