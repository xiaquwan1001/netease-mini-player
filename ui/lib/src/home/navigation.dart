import 'package:flutter/material.dart';

import '../album_preview.dart';
import '../artist_page.dart';
import '../daily_cache.dart' show DailyCacheDay;
import '../detail_page.dart' show showPodcastDetail;
import '../discover.dart';
import '../rust/api_all.dart' as rust;

/// 首页的**导航类**动作(拆 `home_page.dart` 第一刀, 审计 §7.7)。
///
/// 搬的是什么(逐行等价搬运, 不改时序/不改路由类型/不改"点了才提示"的时机):
/// - 输入联想的精确实体: [openExactArtist] / [openExactPlaylist] / [openExactRadio]
/// - 搜索结果的五类卡片: [openSearchArtist] / [openSearchAlbum] /
///   [openSearchPlaylist] / [openSearchPodcast]
/// - 全页二级入口: [openDiscover](每日推荐·三个页签) / [openRecent](最近听过) /
///   [openPodcastRadio](播客详情)
///
/// 边界(为什么是"纯导航"而不是又一个控制器):
/// - **不持有任何状态**: 精确实体由 [exactOf] 现取(真相仍在
///   `search_state.SearchController`), 不复制快照;
/// - **不写浏览态字段**: 打开歌单落到注入的 [openPlaylist](由 `AccountActions`
///   实现 —— "歌单浏览态"四件套的唯一写入口, 含"最近交互"记录);
/// - **不持有 BuildContext**: 需要时经 [contextOf] 在调用瞬间取(与
///   `AccountActions` / `QueueSheetController` 同一口径);
/// - **不碰播放/队列/歌词**: 这里只开页面与弹层, 起播仍由页面/协调器负责。
///
/// 唯一的页面副作用是"最近一次交互"([touchInteraction]): 打开动作是收藏排序
/// 唯一可靠的信号(收藏列表本身没有"最近使用"字段), 所以它必须发生在**点开**
/// 的那一刻 —— 搬过来时顺序不变(先记账, 再开页)。
class HomeNavigation {
  HomeNavigation({
    required this.contextOf,
    required this.exactOf,
    required this.openPlaylist,
    required this.dailyPlaylists,
    required this.dailyLocalDays,
    required this.touchInteraction,
  });

  /// 调用瞬间取 BuildContext(本类不持有, 与 [AccountActions] /
  /// [QueueSheetController] 同款)。
  final BuildContext Function() contextOf;

  /// 当前输入联想的精确实体(搜索控制器持有, 这里只读)。
  final rust.SearchExact? Function() exactOf;

  /// 打开歌单(含"最近交互"记录与歌单浏览态写入), 由 [AccountActions] 实现。
  final Future<void> Function(rust.Playlist playlist) openPlaylist;

  /// 每日推荐页的歌单加载(带本地缓存, 见 `AccountActions.dailyPlaylists`)
  final Future<List<rust.Playlist>> Function() dailyPlaylists;

  /// 每日推荐页「历史日推」要合并的本地缓存天(`AccountActions.dailyLocalDays`)
  final Future<List<DailyCacheDay>> Function() dailyLocalDays;

  /// 记录"最近一次交互"(我的页收藏栏按它排序, 见 recent_order.dart)
  final void Function(String kind, BigInt id) touchInteraction;

  // ---------------- 输入联想: 精确实体 ----------------

  Future<void> openExactArtist(int id) async {
    for (final a in exactOf()?.artists ?? const <rust.Artist>[]) {
      if (a.id.toInt() != id) continue;
      await showArtistDetail(
        contextOf(),
        artistId: a.id,
        name: a.name,
        onOpenAlbum: (albumId, name, cover) => showAlbumPreview(
          contextOf(),
          albumId: albumId,
          albumName: name,
          coverUrl: cover,
        ),
      );
      return;
    }
  }

  Future<void> openExactPlaylist(int id) async {
    for (final p in exactOf()?.playlists ?? const <rust.Playlist>[]) {
      if (p.id.toInt() == id) {
        await openPlaylist(p);
        return;
      }
    }
  }

  void openExactRadio(int id) {
    for (final r in exactOf()?.podcasts ?? const <rust.PodcastRadio>[]) {
      if (r.id.toInt() == id) {
        openPodcastRadio(r);
        return;
      }
    }
  }

  // ---------------- 全页二级入口 ----------------

  /// 每日推荐页。[initialTab] 给「历史日推」快捷动作复用(B7):
  /// 0 推荐歌曲 / 1 推荐歌单 / 2 历史日推, 默认 0(历史行为不变)。
  void openDiscover({int initialTab = 0}) {
    showDiscoverPage(
      contextOf(),
      onOpenPlaylist: openPlaylist,
      loadPlaylists: dailyPlaylists,
      // 设置里启用缓存后, 历史日推把磁盘上的本地缓存天也列进来(合并去重 + 「本地」标记)
      loadLocalDays: dailyLocalDays,
      initialTab: initialTab,
    );
  }

  /// 最近听过(单曲/专辑/歌单/播客 四个分类)
  void openRecent() {
    showRecentPage(
      contextOf(),
      onOpenPlaylist: openPlaylist,
      onOpenPodcast: openPodcastRadio,
      onOpenAlbum: (album) => showAlbumPreview(
        contextOf(),
        albumId: album.id,
        albumName: album.name,
        coverUrl: album.coverUrl,
      ),
    );
  }

  /// 直接打开某个播客的详情页(推荐/我的页面的卡片点进来)
  void openPodcastRadio(rust.PodcastRadio radio) {
    touchInteraction('podcast', radio.id);
    showPodcastDetail(contextOf(), radio: radio);
  }

  // ---------------- 搜索结果的五类卡片 ----------------

  /// 搜索结果: 艺人卡片 → 艺人页
  Future<void> openSearchArtist(rust.SearchArtist artist) async {
    await showArtistDetail(
      contextOf(),
      artistId: artist.id,
      name: artist.name,
      onOpenAlbum: (id, name, cover) => showAlbumPreview(
        contextOf(),
        albumId: id,
        albumName: name,
        coverUrl: cover,
      ),
    );
  }

  void openSearchAlbum(rust.SearchAlbum album) {
    showAlbumPreview(
      contextOf(),
      albumId: album.id,
      albumName: album.name,
      coverUrl: album.coverUrl,
    );
  }

  /// 搜索结果: 歌单卡片 → 歌单详情
  void openSearchPlaylist(rust.SearchPlaylistItem item) {
    openPlaylist(
      rust.Playlist(
        id: item.id,
        name: item.name,
        coverUrl: item.coverUrl,
        trackCount: item.trackCount,
        special: false,
        subscribed: false,
      ),
    );
  }

  /// 搜索结果: 播客卡片 → 播客详情
  void openSearchPodcast(rust.SearchPodcast item) {
    openPodcastRadio(
      rust.PodcastRadio(
        id: item.id,
        name: item.name,
        coverUrl: item.coverUrl,
        description: '',
        djName: item.djName,
        programCount: item.programCount,
        playCount: item.playCount,
      ),
    );
  }
}
