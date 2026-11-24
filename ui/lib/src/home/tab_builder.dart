import 'package:flutter/material.dart';

import '../album_preview.dart';
import '../artist_page.dart';
import '../feed_view.dart';
import '../medal_wall.dart';
import '../messages_page.dart';
import '../mine_view.dart';
import '../new_release_page.dart';
import '../platform.dart';
import '../ranking_view.dart' show showPlayRanking;
import '../recommend_view.dart';
import '../rust/api_all.dart' as rust;
import '../search_landing.dart';
import '../search_loading.dart';
import '../search_results.dart';
import '../settings_view.dart';
import '../song_actions.dart';
import '../song_tile.dart';
import 'account_actions.dart';
import 'navigation.dart';
import 'search_controller.dart' as search_state;

/// 首页五个 tab 的**构建**(拆 `home_page.dart` 第二刀, 审计 §7.7)。
///
/// 搬的是什么(逐行等价搬运, 不改 widget 顺序/不改 key/不改回调语义):
/// - [buildPages]: 五个 tab 的 IndexedStack(访问过的才真正构建, 保留各自 State)
/// - [buildPage](原 `_buildTabPage`): 1 推荐 / 2 关注 / 3 我的 / 4 设置 / 其余 = 搜索
/// - [buildSearchTab](原 `_buildSearchTab`): 歌单浏览态 → 上一轮结果 → 搜索落地页
/// - [buildSearchResults](原 `_buildSearchResults`): 单曲/艺人/专辑/歌单/播客分区
/// - [buildList](原 `_buildList`): 曲目列表(无版权隐藏/加载占位/空态)
///
/// 边界(为什么这些能搬、那些不能):
/// - **依赖都是"读"**: 登录态/搜索控制器/账号动作/导航/可见曲目 —— 一律按
///   回调或既有 controller 注入, 本类不持有 BuildContext、不写任何状态;
/// - **不搬播放**: `_playFromList` / `_playFromSearch` / 心动模式起播仍是页面的
///   [playFromList] / [playFromSearch] / [openHeartMode](队列与协调器在页面那侧);
/// - **不搬搜索条与 AppBar**: 输入框/焦点/顶栏仍留在页面(那是"一次构建里最先
///   画出来的壳"), 这里只出 tab 正文。
///
/// 重建语义不变: 页面每次 `setState` 都调 [buildPages], 与拆分前
/// `_buildTabPages` 一一对应(没有缓存/没有额外的 Listenable)。
class HomeTabBuilder {
  HomeTabBuilder({
    required this.contextOf,
    required this.infoOf,
    required this.account,
    required this.search,
    required this.navigation,
    required this.queryOf,
    required this.tabOf,
    required this.tabVisitedOf,
    required this.currentOf,
    required this.visibleSongsOf,
    required this.hiddenUnplayableOf,
    required this.likedOf,
    required this.errorOf,
    required this.isLiked,
    required this.playFromList,
    required this.playFromSearch,
    required this.notifyUnplayable,
    required this.buildActionsHost,
    required this.openHeartMode,
  });

  /// 调用瞬间取 BuildContext(本类不持有)
  final BuildContext Function() contextOf;

  /// 登录态快照(推荐/关注/我的三页的 key 与分支都读它)
  final rust.InitInfo? Function() infoOf;

  /// 歌单浏览态四件套 + 二级页入口的唯一写入口(见 src/home/account_actions.dart)
  final AccountActions account;

  /// 搜索状态机(结果/活跃标志/落地页数据), 只读
  final search_state.SearchController search;

  /// 导航类动作(精确实体/日推/最近听过/播客详情), 见 src/home/navigation.dart
  final HomeNavigation navigation;

  /// 搜索框里的输入(未提交也算)
  final String Function() queryOf;

  /// 当前 tab(0 搜索 / 1 推荐 / 2 关注 / 3 我的 / 4 设置)
  final int Function() tabOf;

  /// 已经访问过的 tab(惰性构建: 只有访问过的才进 IndexedStack)
  final Set<int> Function() tabVisitedOf;

  final rust.SongDto? Function() currentOf;

  /// 真正要显示的曲目(无版权且没收藏的直接不显示)
  final List<rust.SongDto> Function() visibleSongsOf;

  /// 被隐藏的无版权曲目数量(列表顶部提示用)
  final int Function() hiddenUnplayableOf;

  final Set<BigInt> Function() likedOf;

  /// 搜索失败横幅(顶部由页面画, 这里只决定正文是否留空)
  final String? Function() errorOf;

  final bool Function(BigInt? trackId) isLiked;

  /// 点列表: 用当前可见列表重置队列, 从被点那首开始(播放归页面/协调器)
  final Future<void> Function(rust.SongDto song) playFromList;

  /// 搜索结果里点单曲(跳过无版权)
  final Future<void> Function(rust.SongDto song) playFromSearch;

  /// 无版权提示(与官方一致的"点了才告诉你")
  final void Function(rust.SongDto song) notifyUnplayable;

  /// "..." 菜单的动作宿主
  final SongActionHost Function() buildActionsHost;

  /// 心动模式起播(以当前曲目为种子)
  final Future<void> Function() openHeartMode;

  /// 五个 tab 都塞进 IndexedStack(访问过的才真正构建), 保留各自的 State.
  Widget buildPages(Object? selectedKey) {
    final tab = tabOf();
    final visited = tabVisitedOf();
    return IndexedStack(
      index: tab,
      children: [
        for (var i = 0; i < 5; i++)
          if (visited.contains(i))
            buildPage(i, selectedKey)
          else
            const SizedBox.shrink(),
      ],
    );
  }

  /// 单个 tab 的正文。[selectedKey] 是主从分栏右栏正在看的歌单 id
  /// (窄/中档恒为 null) —— 搜索列表据此给卡片画选中外框。
  Widget buildPage(int index, Object? selectedKey) {
    final context = contextOf();
    final info = infoOf();
    switch (index) {
      case 1:
        return RecommendView(
          key: ValueKey('recommend-${info?.loggedIn}-${info?.vip}'),
          loggedIn: info?.loggedIn == true,
          // 每日推荐歌单/歌曲都走本地缓存(同一天只拉一次; 设置里可关/改保留天数)
          loadDailySongs: account.dailySongs,
          loadDailyPlaylists: account.dailyPlaylists,
          onOpenPlaylist: account.openPlaylist,
          onOpenPodcast: navigation.openPodcastRadio,
          onHeartMode: () => openHeartMode(),
          onOpenDaily: navigation.openDiscover,
          // B7 顶栏「自定义」卡可绑定的动作: 历史日推 = 每日推荐页第三个页签;
          // 排行榜复用「我的」页同一个落地页(showPlayRanking)。
          onOpenDailyHistory: () => navigation.openDiscover(initialTab: 2),
          onOpenRanking: () => showPlayRanking(context),
          onOpenAlbum: (album) => showAlbumPreview(
            context,
            albumId: album.id,
            albumName: album.name,
            coverUrl: album.coverUrl,
          ),
          onOpenNewRelease: () => showNewReleasePage(
            context,
            onOpenAlbum: (album) => showAlbumPreview(
              context,
              albumId: album.id,
              albumName: album.name,
              coverUrl: album.coverUrl,
            ),
            onOpenArtist: (artist) => showArtistDetail(
              context,
              artistId: artist.id,
              name: artist.name,
              onOpenAlbum: (id, name, cover) => showAlbumPreview(
                context,
                albumId: id,
                albumName: name,
                coverUrl: cover,
              ),
            ),
          ),
        );
      case 2:
        return FeedView(
          key: ValueKey('feed-${info?.loggedIn}'),
          loggedIn: info?.loggedIn == true,
          onLogin: account.login,
          onOpenUrl: PlatformBridge.openUrl,
        );
      case 3:
        return MineView(
          key: ValueKey('mine-${info?.loggedIn}-${info?.vip}'),
          loggedIn: info?.loggedIn == true,
          onLogin: account.login,
          onOpenAccounts: account.openAccountPage,
          onOpenPlaylist: account.openPlaylist,
          onOpenPodcast: navigation.openPodcastRadio,
          onOpenFollows: () => account.openUserList(startOnFans: false),
          onOpenFolloweds: () => account.openUserList(startOnFans: true),
          onOpenAlbum: (album) => showAlbumPreview(
            context,
            albumId: album.id,
            albumName: album.name,
            coverUrl: album.coverUrl,
            initiallySubscribed: true,
          ),
          onOpenRecent: navigation.openRecent,
          onOpenLiked: account.openLikedDetail,
          onOpenMessages: () => showMessagesPage(context),
          onOpenMedals: () => showMedalWall(context, isVip: info?.vip == true),
          onOpenVip: account.openVip,
          // "我喜欢的音乐"区块点播时的队列来源标记(解析出来之前为 null)
          likedPlaylistId: account.likedPlaylistId,
          // 简介保存: POST /api/user/profile/update(局部更新, 只改 signature)
          saveSignature: (signature) =>
              rust.updateSignature(signature: signature),
        );
      case 4:
        // 设置只剩下「App 怎么表现」的偏好开关 + 分组入口:
        // 账号管理、诊断与数据都是这里的二级页(账号入口 2026-11 统一收在这里)。
        return SettingsView(
          info: info,
          onOpenAccounts: account.openAccountPage,
        );
      default:
        return buildSearchTab(selectedKey);
    }
  }

  /// 搜索 tab 的正文: 歌单浏览态优先, 其次上一轮结果, 最后是落地页。
  ///
  /// [selectedKey] 只在"有上一轮结果"这一支有用(左栏给右栏正在看的歌单画外框)。
  Widget buildSearchTab(Object? selectedKey) {
    final query = queryOf().trim();
    // 歌单浏览态优先(从我的/推荐点进来的)
    if (account.libraryOpen) return buildList();
    // 有上一轮结果就展示分区结果; 取消按钮会清空它
    if (search.bundle != null) return buildSearchResults(selectedKey);
    // 没输入关键词时: 搜索历史 + 猜你想搜 + 热门榜
    if (query.isEmpty) {
      return SearchLanding(
        history: search.history,
        hot: search.hotTerms,
        recommended: search.recommended,
        onSelected: search.searchKeyword,
        onClearHistory: search.clearHistory,
        hotLoading: search.hotLoading,
        hotError: search.hotError,
        onRetryHot: search.loadLanding,
        // 排行榜从「推荐」搬到这里(2026-11 用户要求)
        onOpenChartPlaylist: account.openPlaylist,
      );
    }
    return buildList();
  }

  /// 综合搜索结果: 单曲/艺人/专辑/歌单/播客分区
  ///
  /// [selectedKey] 是主从分栏右栏正在看的歌单 id(窄/中档恒为 null) —— 左栏据此给
  /// 该卡片画选中外框。
  Widget buildSearchResults(Object? selectedKey) {
    final context = contextOf();
    return SearchResultsView(
      bundle: search.bundle!,
      selectedPlaylistId: selectedKey is BigInt ? selectedKey : null,
      // 后端 cloudsearch type=1004 的 MV 结果 → UI 的 SearchMv(同构映射)
      mvs: [
        for (final m in search.bundle!.mvs)
          SearchMv(
            id: m.id,
            name: m.name,
            coverUrl: m.coverUrl,
            artistName: m.artistName,
            playCount: m.playCount,
          ),
      ],
      liked: likedOf(),
      currentTrackId: currentOf()?.id,
      onPlaySong: playFromSearch,
      onOpenArtist: navigation.openSearchArtist,
      onOpenAlbum: navigation.openSearchAlbum,
      onOpenPlaylist: navigation.openSearchPlaylist,
      onOpenPodcast: navigation.openSearchPodcast,
      onMenu: (song) => showSongActionsSheet(
        context,
        song,
        buildActionsHost(),
        // 综合搜索结果里的单曲
        source: SongActionSource.search,
      ),
    );
  }

  /// 曲目列表: 歌单浏览态(播放队列的视图)或搜索结果的单曲。
  Widget buildList() {
    final context = contextOf();
    final current = currentOf();
    if (!account.libraryOpen) {
      // 搜索请求还没回来时给加载占位: 原来的"输入关键词后搜索"会让用户
      // 以为断网或没有结果(本次回归修复)。错误由顶部横幅展示(带重试)。
      if (search.busy) return SearchLoading(queryOf().trim());
      if (errorOf() != null) return const SizedBox.shrink();
      final typed = queryOf().trim();
      if (typed.isEmpty) {
        return const Center(child: Text('输入关键词后搜索'));
      }
      // 已经输入但还没提交: 上方是联想面板, 这里给一句明确的操作提示
      return Center(
        child: Text(
          '点「搜索」查看「$typed」的结果',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    final songs = visibleSongsOf();
    final hidden = hiddenUnplayableOf();
    if (songs.isEmpty) {
      // 浏览态现在是队列的视图: 队列被清空时这里要说明白, 不然会读成"歌单空了"
      final emptyText = !account.libraryOpen ? '这个歌单是空的' : '播放队列是空的';
      return Center(
        child: Text(hidden > 0 ? '这里没有可播放的曲目($hidden 首无版权已隐藏)' : emptyText),
      );
    }
    // 列表顶部一句说明: 无版权且没收藏的曲目按官方行为直接不出现, 但要让用户知道少了什么
    final headerCount = hidden > 0 ? 1 : 0;
    return ListView.builder(
      itemCount: songs.length + headerCount,
      itemBuilder: (context, i) {
        if (headerCount == 1 && i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              '已隐藏 $hidden 首无版权曲目',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        final s = songs[i - headerCount];
        final active = current?.id == s.id;
        // 没版权: 整行灰掉 + "无版权"标, 点了才提示(官方同款行为)
        return SongTile(
          song: s,
          active: active,
          liked: isLiked(s.id),
          onTap: () {
            if (s.playable) {
              playFromList(s);
            } else {
              notifyUnplayable(s);
            }
          },
          onMenu: () => showSongActionsSheet(
            context,
            s,
            buildActionsHost(),
            // 库内歌单/列表详情
            source: SongActionSource.playlist,
          ),
        );
      },
    );
  }
}
