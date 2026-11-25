import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../album_preview.dart';
import '../app_sheet.dart';
import '../app_settings.dart';
import '../artist_page.dart';
import '../comment_thread.dart' show commentSourceKindLabel;
import '../cover_art.dart' show CoverArt, kImageUserAgent;
import '../detail/comments_sheet.dart' show showCommentsSheet;
import '../format.dart' show formatCountMagnitude;
import '../lru.dart' show LruMap;
import '../mv_page.dart' show showMvPage;
import '../net_retry.dart' show friendlyError, retryNetwork;
import '../playback.dart' show preferHttpsStreamUrl;
import '../platform.dart' show PlatformBridge;
import '../queue.dart';
import '../rust/api_all.dart' as rust;
import '../sheet_header.dart' show SheetHeader;
import '../similar_sheet.dart' show showSimilarSongs;
import '../song_actions.dart';
import '../song_wiki.dart' show showSongWiki;

/// 歌曲动作宿主装配(从 main.dart 的 `_HomePageState` 搬出, 2026-11 拆壳 S5)。
///
/// 搬的是什么(逐行等价搬运, 不改菜单项/不改 enabled 判定):
/// - `_buildActionsHost` 的宿主构建([buildHost])与歌曲菜单的三项计数([loadCounts]);
/// - 所有歌曲/艺人/专辑动作闭包: 喜欢([toggleLikeFor]/[toggleCurrentLike])、
///   下一首播放([playNextSong])、加队列([appendSongToQueue])、收藏到歌单(含新建)、
///   分享、查看评论、艺人/专辑信息、下载、不感兴趣。
///
/// 所有权边界(为什么这些仍留在页面):
/// - **红心集合 / 登录态 / 播放来源 / 队列** 都是页面状态, 这里只拿访问器与队列
///   引用(与 [PlaybackCoordinator] 同一口径, 不复制), 改动回灌 [markLiked] /
///   [rebuild] 由页面 setState。
/// - **播放动作**落到注入的 [playSongsList](PlaybackCoordinator) 与队列上, 这里
///   不碰播放器/歌词/搜索。
/// - **需要 BuildContext 的东西**一律不进来: 面板/对话框/路由跳转都经 [contextOf]
///   在调用瞬间取, 本类不持有 BuildContext。
///
/// 本类自己不持状态, 所以不是 `ChangeNotifier`: 登录态变化时由页面重新
/// [buildHost](原 `actionsHost.value = _buildActionsHost()` 的时机不变)。
class SongActionWiring {
  SongActionWiring({
    required this.contextOf,
    required this.toast,
    required this.isMounted,
    required this.loggedIn,
    required this.isLiked,
    required this.markLiked,
    required this.rebuild,
    required this.queue,
    required this.playSongsList,
    required this.currentSong,
    required this.playSource,
    required this.syncActionState,
    required this.openPlaylist,
  });

  /// 当前页面的 BuildContext(面板/对话框/路由跳转用; 调用瞬间取, 不缓存)。
  final BuildContext Function() contextOf;

  /// 普通提示(页面实现: mounted 判断 + `showToast`)。
  final void Function(String message) toast;

  /// 页面是否还挂在树上(原 `mounted` 判定)。
  final bool Function() isMounted;

  /// 是否已登录(原 `_info?.loggedIn == true`)。
  final bool Function() loggedIn;

  /// 该歌曲当前是否已喜欢(红心集合的唯一真相在页面)。
  final bool Function(BigInt? trackId) isLiked;

  /// 页面侧改动红心集合(原 `setState(() => _liked.add/remove)`)。
  final void Function(BigInt trackId, bool liked) markLiked;

  /// 页面侧重建(原队列增删后的 `setState(() {})`)。
  final void Function() rebuild;

  /// 播放队列(真相在页面, 这里只持有引用)。
  final PlayQueue<rust.SongDto> queue;

  /// 用一批曲目重置队列并起播(PlaybackCoordinator.playSongsList)。
  final Future<void> Function(List<rust.SongDto> songs, int index)
  playSongsList;

  /// 当前曲目(通知栏红心只同步当前曲目)。
  final rust.SongDto? Function() currentSong;

  /// 当前队列来源(决定"不感兴趣"走 FM 还是日推口径)。
  final SongActionSource Function() playSource;

  /// 换曲/喜欢后把红心状态回传原生通知栏(页面的 `_syncActionState`)。
  final Future<void> Function() syncActionState;

  /// 打开歌单详情(相似歌单点进去用; 页面持有浏览态与红心集合)。
  final Future<void> Function(rust.Playlist playlist) openPlaylist;

  /// "..." 菜单的回调宿主(登录态变化时由页面重建)
  SongActionHost buildHost() => SongActionHost(
    loggedIn: loggedIn(),
    isLiked: isLiked,
    toggleLike: toggleLikeFor,
    playNext: playNextSong,
    addToPlaylist: _showAddToPlaylist,
    share: _showShareSong,
    comments: _showSongComments,
    openArtist: _openSongArtist,
    openAlbum: _openSongAlbum,
    download: _downloadSong,
    dislike: _dislikeSong,
    songWiki: (song) => showSongWiki(contextOf(), song: song),
    counts: loadCounts,
    mvId: loadMvId,
    openMv: openSongMv,
    similarSongs: (song) =>
        showSimilarSongs(contextOf(), song: song, onOpenPlaylist: openPlaylist),
  );

  /// 曲目 id → 官方 MV id 的进程内缓存(含"没有 MV"的否定结果).
  ///
  /// 菜单打开就预取(不等用户点), 所以同一首歌反复开菜单必须命中缓存 ——
  /// 不能每开一次菜单就多打一次 song/detail。
  final MvIdCache _mvIds = MvIdCache(
    request: (trackId) => rust.songMvId(trackId: trackId),
  );

  /// 该曲目的官方 MV id(None = 没有官方 MV; 失败由面板当空态处理)。
  ///
  /// 未登录也能查: MV 与播放权限是两件事。
  Future<BigInt?> loadMvId(rust.SongDto song) => _mvIds.of(song.id);

  /// 打开官方 MV 播放页(Android 内嵌 VideoView, 桌面用系统播放器)。
  Future<void> openSongMv(rust.SongDto song, BigInt mvId) =>
      showMvPage(contextOf(), mvId: mvId, name: '${song.name} MV');

  /// 歌曲菜单里的三项数量级: 喜欢人数 / 评论数 / 分享数(与原版对齐).
  ///
  /// 数据来源:
  /// - 评论数 + 分享数: 评论线程统计 `R_SO_4_<id>`(我们本来就有这接口);
  /// - 喜欢人数: 官方 App 的 `/api/song/like/get`(`likedCount`), api-enhanced
  ///   里没有这个模块, 从官方客户端抓到的路径, 已按 vendor 规则加到 vendor 侧。
  ///   该接口**需要登录**, 匿名返回 301 —— 未登录时不显示, 菜单其余项不受影响。
  ///
  /// 任何一项失败都只是"这一项不显示", 绝不让菜单报错。
  Future<SongActionCounts> loadCounts(rust.SongDto song) async {
    final id = song.id;
    Future<String?> likedLabel() async {
      if (!loggedIn()) return null;
      try {
        final state = await rust.songLikeState(trackId: id);
        return formatCountMagnitude(state.likedCount.toInt());
      } catch (_) {
        return null;
      }
    }

    Future<rust.CommentStats?> stats() async {
      try {
        return await rust.commentStats(threadId: 'R_SO_4_$id');
      } catch (_) {
        return null;
      }
    }

    final results = await Future.wait<Object?>([likedLabel(), stats()]);
    final liked = results[0] as String?;
    final s = results[1] as rust.CommentStats?;
    String? comments;
    if (s != null) {
      // 上游自带官方文案("100w+"/"999+")优先, 没有才用我们的量级口径
      final desc = s.commentCountDesc.trim();
      comments = desc.isNotEmpty
          ? desc
          : formatCountMagnitude(s.commentCount.toInt());
    }
    final shares = s == null
        ? null
        : formatCountMagnitude(s.shareCount.toInt());
    return SongActionCounts(liked: liked, comments: comments, shares: shares);
  }

  /// 任意曲目的红心切换(列表/播放条共用; 先乐观更新, 失败回滚)
  Future<void> toggleLikeFor(rust.SongDto song) async {
    if (!loggedIn()) {
      toast('收藏需要先登录');
      return;
    }
    final id = song.id;
    final wasLiked = isLiked(id);
    markLiked(id, !wasLiked);
    try {
      await rust.setLiked(trackId: id, liked: !wasLiked);
      // 通知栏红心按钮同步(当前曲目才影响通知图标, syncActionState 里已取当前曲目)
      if (id == currentSong()?.id) unawaited(syncActionState());
      // 取消喜欢只给一条 3 秒提示, 不给「撤销」按钮:
      // 红心本身一点就回来(再点一次), 而带 action 的撤销条会在底部常驻更久、
      // 压住播放条和内容(用户反馈"不会自动回落, 遮挡内容")。
      if (wasLiked) toast('已取消喜欢《${song.name}》');
    } catch (e) {
      if (!isMounted()) return;
      markLiked(id, wasLiked);
      if (id == currentSong()?.id) unawaited(syncActionState());
      rethrow;
    }
  }

  /// 红心/取消红心(当前曲目). 先乐观更新, 失败回滚。
  Future<void> toggleCurrentLike() async {
    final song = currentSong();
    if (song == null) return;
    try {
      await toggleLikeFor(song);
    } catch (e) {
      if (isMounted()) toast('收藏失败: ${friendlyError(e)}');
    }
  }

  /// 歌单内搜索后"只添加当前歌": 保留现有队列, 追加到队尾(已在队列则不重复)
  Future<void> appendSongToQueue(rust.SongDto song) async {
    if (queue.isEmpty) {
      await playSongsList([song], 0);
      return;
    }
    final existed = queue.items.any((s) => s.id == song.id);
    queue.append(song);
    if (!isMounted()) return;
    rebuild();
    toast(existed ? '这首歌已在播放队列中' : '已添加到播放队列');
  }

  Future<void> playNextSong(rust.SongDto song) async {
    queue.insertNext(song);
    if (isMounted()) {
      rebuild();
      toast('已添加到下一首播放');
    }
  }

  /// 收藏到歌单: 先选歌单, 再调接口. "我喜欢的音乐"走红心接口.
  Future<void> _showAddToPlaylist(rust.SongDto song) async {
    if (!loggedIn()) {
      toast('收藏到歌单需要先登录');
      return;
    }
    final lists = await retryNetwork(rust.myPlaylists);
    final context = contextOf();
    if (!context.mounted) return;
    // 返回 PlaylistDto(选已有歌单) 或 'create'(新建歌单)
    final picked = await showAppSheet<Object>(
      context,
      // 迁移前没写 isScrollControlled(= showModalBottomSheet 的 false):
      // 面板高度 0.6 屏会被 9/16 屏上限夹住, 这里保持旧的夹取行为
      isScrollControlled: false,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.6,
          child: Column(
            children: [
              SheetHeader(title: '收藏到歌单', subtitle: song.name),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 20,
                  backgroundColor: Theme.of(sheetContext)
                      .colorScheme
                      .surfaceContainerHighest,
                  child: const Icon(Icons.add, size: 20),
                ),
                title: const Text('新建歌单'),
                subtitle: const Text('创建后把这首加进去'),
                onTap: () => Navigator.pop(sheetContext, 'create'),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: lists.length,
                  itemBuilder: (context, i) {
                    final pl = lists[i];
                    return ListTile(
                      dense: true,
                      leading: CoverArt(url: pl.coverUrl, size: 40, radius: 4),
                      title: Text(
                        pl.special ? '我喜欢的音乐' : pl.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${pl.trackCount} 首'),
                      onTap: () => Navigator.pop(sheetContext, pl),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    if (picked is String) {
      await _createPlaylistAndAdd(song);
      return;
    }
    final pl = picked as rust.Playlist;
    if (pl.special) {
      await rust.setLiked(trackId: song.id, liked: true);
      if (!isMounted()) return;
      markLiked(song.id, true);
      toast('已加入我喜欢的音乐');
      return;
    }
    final ok = await rust.addToPlaylist(playlistId: pl.id, trackId: song.id);
    if (!isMounted()) return;
    toast(ok ? '已收藏到《${pl.name}》' : '收藏未生效, 请稍后重试');
  }

  /// 新建歌单并把当前歌曲放进去
  Future<void> _createPlaylistAndAdd(rust.SongDto song) async {
    final context = contextOf();
    final controller = TextEditingController();
    final name = await showAppDialog<String>(
      context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '歌单名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !isMounted()) return;
    try {
      final id = await rust.createPlaylist(name: name, privacy: 0);
      final ok = await rust.addToPlaylist(playlistId: id, trackId: song.id);
      if (!isMounted()) return;
      toast(ok ? '已新建《$name》并收藏' : '歌单已建, 收藏未生效');
    } catch (e) {
      if (!isMounted()) return;
      toast('新建歌单失败: ${friendlyError(e)}');
    }
  }

  Future<void> _showShareSong(rust.SongDto song) async {
    final context = contextOf();
    final link = 'https://music.163.com/#/song?id=${song.id}';
    await showAppSheet<void>(
      context,
      // 迁移前没写 isScrollControlled(= false); 三行小列表, 保持旧口径
      isScrollControlled: false,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetHeader(title: '分享'),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('分享到动态'),
              onTap: () async {
                Navigator.pop(sheetContext);
                try {
                  final ok = await rust.shareResource(
                    kind: 'song',
                    resourceId: song.id,
                    msg: song.name,
                  );
                  toast(ok ? '已分享到动态' : '分享未生效');
                } catch (e) {
                  toast(friendlyError(e));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('复制链接'),
              onTap: () async {
                Navigator.pop(sheetContext);
                await Clipboard.setData(ClipboardData(text: link));
                toast('链接已复制');
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 「查看评论」的公共入口(歌曲"..."菜单 + 详情页封面面的评论按钮共用)。
  ///
  /// 详情面板只拿到"当前曲目", 不该自己拼 kind/resourceId/分享语境 —— 这条链路
  /// 已经在歌曲菜单里存在一份, 复制第二份必然会漂。
  Future<void> openComments(rust.SongDto song) => _showSongComments(song);

  Future<void> _showSongComments(rust.SongDto song) async {
    await showCommentsSheet(
      contextOf(),
      kind: 'song',
      resourceId: song.id,
      title: '《${song.name}》的评论',
      // 评论分享卡片的语境(需求 10): 来自哪首歌
      shareSourceTitle: song.name,
      shareSourceKind: commentSourceKindLabel('song'),
    );
  }

  Future<void> _openSongArtist(rust.SongDto song) async {
    final context = contextOf();
    if (song.artistId == BigInt.zero) {
      toast('这首歌没有关联艺人信息');
      return;
    }
    await showArtistDetail(
      context,
      artistId: song.artistId,
      name: song.artist,
      onOpenAlbum: (id, name, cover) => showAlbumPreview(
        context,
        albumId: id,
        albumName: name,
        coverUrl: cover,
      ),
    );
  }

  Future<void> _openSongAlbum(rust.SongDto song) async {
    await showAlbumPreview(
      contextOf(),
      albumId: song.albumId,
      albumName: song.album,
      coverUrl: song.coverUrl,
    );
  }

  Future<void> _downloadSong(rust.SongDto song) async {
    toast('正在获取下载地址…');
    try {
      final stream = await retryNetwork(
        () => rust.songUrl(
          trackId: song.id,
          level: AppSettings.instance.audioLevel,
          name: song.name,
          singer: song.artist,
          albumName: song.album,
          interval: song.durationMs ~/ BigInt.from(1000),
        ),
      );
      final raw = stream.url;
      if (raw == null || raw.isEmpty) {
        toast('这首歌暂时没有可用直链(会员/版权限制)');
        return;
      }
      final url = preferHttpsStreamUrl(raw);
      final ext = url.contains('.flac') ? 'flac' : 'mp3';
      final name = '${song.artist} - ${song.name}.$ext';
      // UA 必须透传(D12): 网易 CDN 对 `Dart/3.x` 默认 UA 回 403 —— 图片侧已在
      // cover_art 实测过同一件事, 下载走同一条 CDN。Android 的 DownloadManager
      // 与桌面 curl 都按这个值发 `User-Agent`, 与 Referer 一起才拿得到字节。
      final saved = await PlatformBridge.download(
        url: url,
        filename: name,
        userAgent: kImageUserAgent,
      );
      if (!isMounted()) return;
      toast(saved == null ? '下载失败' : '已开始下载(Android 在通知栏/Download 目录)');
    } catch (e) {
      if (!isMounted()) return;
      toast('下载失败: ${friendlyError(e)}');
    }
  }

  /// 不感兴趣: FM 队列里走"不再播放", 其它场景走"少推这类歌"
  Future<void> _dislikeSong(rust.SongDto song) async {
    if (!loggedIn()) {
      toast('不感兴趣需要先登录');
      return;
    }
    try {
      if (playSource() == SongActionSource.personalFm) {
        await rust.trashFmSong(songId: song.id);
        if (!isMounted()) return;
        toast('已从私人FM里去掉《${song.name}》');
      } else {
        await rust.dislikeRecommendSong(songId: song.id);
        if (!isMounted()) return;
        toast('已减少《${song.name}》这类推荐');
      }
    } catch (e) {
      if (!isMounted()) return;
      toast('操作失败: ${friendlyError(e)}');
    }
  }
}

/// 曲目 id → 官方 MV id 的进程内缓存(含"没有 MV"的否定结果)。
///
/// 两个语义必须一起成立, 所以缓存的是 `Future` 本身:
/// - **同曲不重查**: 菜单每次打开都会预取, 连点/并发打开也只发一个请求
///   (`LruMap` 读即触碰, 上限 200 条);
/// - **失败不进缓存**: 缓存的是失败的那次 Future 会让入口"永久消失",
///   网络抖一下之后再打开菜单必须能重查。
class MvIdCache {
  MvIdCache({required this.request, int maxEntries = 200})
    : _pending = LruMap<BigInt, Future<BigInt?>>(maxEntries: maxEntries);

  /// 真正打接口取 mv id(生产: `rust.songMvId`)。
  final Future<BigInt?> Function(BigInt trackId) request;

  final LruMap<BigInt, Future<BigInt?>> _pending;

  /// 当前缓存条目数(测试用来断言上限淘汰)。
  int get length => _pending.length;

  Future<BigInt?> of(BigInt trackId) {
    final cached = _pending[trackId];
    if (cached != null) return cached;
    final pending = request(trackId);
    _pending.put(trackId, pending);
    unawaited(
      pending.then<void>(
        (_) {},
        onError: (Object _) {
          // 只删"还是这一次请求"的条目: 并发下可能已被后一次请求覆盖
          if (identical(_pending.peek(trackId), pending)) {
            _pending.remove(trackId);
          }
        },
      ),
    );
    return pending;
  }
}
