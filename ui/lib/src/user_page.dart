import 'package:flutter/material.dart';

import 'adaptive_text.dart';
import 'cover_art.dart';
import 'cover_row.dart';
import 'detail_page.dart';
import 'layout.dart';
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'profile_banner.dart';
import 'profile_scaffold.dart';
import 'rust/api.dart' as rust;
import 'section_header.dart';
import 'state_views.dart';
import 'toast.dart';
import 'user_list_page.dart';

/// 他人主页: 与艺人页共用 [ProfileScaffold] 骨架(横幅 + 身份卡 + 统计 chip +
/// 分区 + pinned TabBar), 内容分 tab: 歌单 / 关注(有才显示) / 粉丝(有才显示).
///
/// 为什么需要它: 听众列表(radio_subscribers_page)与关注/粉丝列表(user_list_page)
/// 早就能列出用户, 但点不动 —— 没有"用户主页"这个目的地. 数据面用
/// `user_profile`(user/detail, 匿名可用) + `user_playlists_of`(user/playlist)
/// + `user_follows`/`user_followeds`(关注/粉丝列表).
///
/// 只读边界: 不在本页做关注/取关、不发私信、不进对方"我喜欢的音乐"(私密歌单,
/// 服务端也不会回); 关注/粉丝 chip 只是入口(切 tab, 或退到关注与粉丝列表页).
class UserPage extends StatefulWidget {
  const UserPage({
    super.key,
    required this.userId,
    this.fallbackNickname,
    this.onPlaySongs,
    this.loadProfile,
    this.loadPlaylists,
    this.loadFollows,
    this.loadFolloweds,
    this.onOpenFollows,
    this.onOpenFolloweds,
  });

  final BigInt userId;
  final String? fallbackNickname;

  /// 点歌单后播放回调(宿主注入); 为空时歌单只展示不可播(测试/无播放器场景)
  final void Function(List<rust.SongDto> songs, int index)? onPlaySongs;

  /// 测试注入
  final Future<rust.ProfileDetail> Function(BigInt uid)? loadProfile;
  final Future<List<rust.Playlist>> Function(BigInt uid)? loadPlaylists;

  /// 关注/粉丝列表 loader(测试注入; 默认走 rust.userFollows/userFolloweds)
  final UserListLoader? loadFollows;
  final UserListLoader? loadFolloweds;

  /// 关注/粉丝 chip 的处理器(宿主可覆盖导航目标; 不传则切自身 tab)
  final VoidCallback? onOpenFollows;
  final VoidCallback? onOpenFolloweds;

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> with TickerProviderStateMixin {
  rust.ProfileDetail? _detail;
  List<rust.Playlist>? _playlists;
  String? _error;
  bool _loading = true;

  final ScrollController _scroll = ScrollController();
  bool _collapsed = false;
  late TabController _tabController = TabController(length: 1, vsync: this);

  Future<rust.ProfileDetail> Function(BigInt uid) get _loadProfile =>
      widget.loadProfile ?? (uid) => rust.userProfile(userId: uid);

  Future<List<rust.Playlist>> Function(BigInt uid) get _loadPlaylists =>
      widget.loadPlaylists ??
      (uid) => rust.userPlaylistsOf(userId: uid, limit: 50);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final collapsed = _scroll.hasClients && _scroll.offset > 90;
    if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
  }

  /// tab 集合按数据可用性生成: 歌单恒在, 关注/粉丝有计数才出现。
  int get _tabCount =>
      1 +
      ((_detail?.follows ?? BigInt.zero) > BigInt.zero ? 1 : 0) +
      ((_detail?.followeds ?? BigInt.zero) > BigInt.zero ? 1 : 0);

  void _rebuildTabs() {
    _tabController = syncProfileTabs(
      vsync: this,
      current: _tabController,
      length: _tabCount,
      onChanged: () => setState(() {}),
    );
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 资料与歌单互不阻塞: 任一失败不该让另一块空白
      final results = await Future.wait<Object?>([
        retryNetwork(() => _loadProfile(widget.userId)),
        retryNetwork(() => _loadPlaylists(widget.userId)),
      ]);
      if (!mounted) return;
      setState(() {
        _detail = results[0] as rust.ProfileDetail?;
        _playlists = results[1] as List<rust.Playlist>?;
        _loading = false;
      });
      _rebuildTabs();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _openPlaylist(rust.Playlist playlist) async {
    final play = widget.onPlaySongs;
    if (play == null) {
      showToast(context, '当前页面不支持播放');
      return;
    }
    await showPlaylistDetail(
      context,
      playlistId: playlist.id,
      name: playlist.name,
      coverUrl: playlist.coverUrl,
      special: playlist.special,
      onPlaySongs: play,
    );
  }

  /// 关注/粉丝 chip 入口: 宿主有钩子就交给宿主; 本页有对应 tab 就切过去;
  /// 否则(计数为 0 / 未知, tab 未生成)退到独立的关注与粉丝列表页。
  Future<void> _openRelationship({required bool fans}) async {
    final hook = fans ? widget.onOpenFolloweds : widget.onOpenFollows;
    if (hook != null) {
      hook();
      return;
    }
    final index = _tabSpecs().indexWhere(
      (s) => s.label == (fans ? '粉丝' : '关注'),
    );
    if (index >= 0) {
      _tabController.animateTo(index);
      return;
    }
    await showUserList(
      context,
      uid: widget.userId,
      startOnFans: fans,
      loadFollows: widget.loadFollows,
      loadFolloweds: widget.loadFolloweds,
      onPlaySongs: widget.onPlaySongs,
    );
  }

  String get _nickname {
    final d = _detail;
    if (d != null && d.nickname.isNotEmpty) return d.nickname;
    return widget.fallbackNickname ?? '用户';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nickname = _nickname;
    // 首屏失败(资料与歌单都拿不到): 整页错误 + 重试
    if (_detail == null && _error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(nickname)),
        body: ListView(
          padding: EdgeInsets.fromLTRB(
            kPagePadding,
            8,
            kPagePadding,
            24 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [_errorCard(context)],
        ),
      );
    }
    return ProfileScaffold(
      scrollController: _scroll,
      collapsedTitle: _collapsed ? nickname : null,
      banner: ProfileBannerImage(url: _detail?.backgroundUrl),
      identity: _buildIdentity(theme, nickname),
      tabs: _tabSpecs(),
      controller: _tabController,
    );
  }

  /// 身份卡: 头像/昵称/VIP/签名 + 统一统计 chip(关注/粉丝可点, 等级只展示)
  Widget _buildIdentity(ThemeData theme, String nickname) {
    final d = _detail;
    final signature = d?.signature.trim() ?? '';
    final loading = _loading && d == null;
    return ProfileIdentity(
      title: nickname,
      subtitle: signature.isEmpty ? null : signature,
      avatarUrl: d?.avatarUrl,
      vip: d?.vip ?? false,
      avatarSize: 56,
      footer: ProfileStatRow(
        chips: loading
            ? const [ProfileStatChip(label: '加载中…')]
            : [
                ProfileStatChip(
                  icon: Icons.people_outline,
                  label: '关注 ${d?.follows ?? BigInt.zero}',
                  onTap: () => _openRelationship(fans: false),
                ),
                ProfileStatChip(
                  icon: Icons.person_outline,
                  label: '粉丝 ${d?.followeds ?? BigInt.zero}',
                  onTap: () => _openRelationship(fans: true),
                ),
                ProfileStatChip(
                  icon: Icons.military_tech_outlined,
                  label: 'Lv.${d?.level ?? BigInt.zero}',
                ),
              ],
      ),
    );
  }

  /// 声明式 tab 集合(与艺人页同一机制: 按数据可用性生成)。
  List<ProfileTabSpec> _tabSpecs() {
    final d = _detail;
    final follows = d?.follows ?? BigInt.zero;
    final followeds = d?.followeds ?? BigInt.zero;
    return [
      ProfileTabSpec('歌单', builder: _playlistsTab),
      if (follows > BigInt.zero)
        ProfileTabSpec(
          '关注',
          badge: ProfileTabBadge('$follows'),
          builder: (context) => _relationTab(context, fans: false),
        ),
      if (followeds > BigInt.zero)
        ProfileTabSpec(
          '粉丝',
          badge: ProfileTabBadge('$followeds'),
          builder: (context) => _relationTab(context, fans: true),
        ),
    ];
  }

  Widget _errorCard(BuildContext context) {
    return Card(
      margin: kCardMargin,
      child: ListTile(
        leading: const Icon(Icons.error_outline),
        title: const Text('加载失败'),
        subtitle: Text(_error ?? ''),
        trailing: TextButton(onPressed: _reload, child: const Text('重试')),
      ),
    );
  }

  /// 歌单 tab: 横滑卡片(CoverRow/CoverCard), 标题允许 2 行。
  Widget _playlistsTab(BuildContext context) {
    final lists = _playlists;
    final bottom = 24 + MediaQuery.viewPaddingOf(context).bottom;
    if (_error != null && lists == null) {
      return ListView(
        padding: EdgeInsets.fromLTRB(kPagePadding, 8, kPagePadding, bottom),
        children: [_errorCard(context)],
      );
    }
    if (lists == null) {
      return const LoadingView(message: '正在加载歌单…');
    }
    if (lists.isEmpty) {
      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: EdgeInsets.fromLTRB(kPagePadding, 24, kPagePadding, bottom),
          children: const [
            EmptyView(
              icon: Icons.queue_music,
              title: '没有公开歌单',
              hint: '对方可能没建过歌单, 或歌单都设为私密',
            ),
          ],
        ),
      );
    }
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        // 右侧不留白: 横滑轨道要能滚到屏幕边缘
        padding: EdgeInsets.fromLTRB(kPagePadding, 8, 0, bottom),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: kPagePadding),
            child: SectionHeader(
              title: 'TA 的歌单',
              trailing: Text(
                '${lists.length} 个',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          CoverRow(
            children: [
              for (final p in lists.take(30))
                CoverCard(
                  coverUrl: p.coverUrl,
                  title: p.name,
                  subtitle: '${p.trackCount} 首',
                  onTap: () => _openPlaylist(p),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 关注/粉丝 tab: 只读列表(点行进对方主页)
  Widget _relationTab(BuildContext context, {required bool fans}) {
    final loader =
        (fans ? widget.loadFolloweds : widget.loadFollows) ??
        (fans
            ? (uid, limit, offset) =>
                  rust.userFolloweds(uid: uid, limit: limit, offset: offset)
            : (uid, limit, offset) =>
                  rust.userFollows(uid: uid, limit: limit, offset: offset));
    return _RelationListView(
      uid: widget.userId,
      fans: fans,
      loader: loader,
      onPlaySongs: widget.onPlaySongs,
    );
  }
}

/// 关注/粉丝列表(带分页/空态/重试), 点行进对方主页。
class _RelationListView extends StatelessWidget {
  const _RelationListView({
    required this.uid,
    required this.fans,
    required this.loader,
    this.onPlaySongs,
  });

  final BigInt uid;
  final bool fans;
  final UserListLoader loader;
  final void Function(List<rust.SongDto> songs, int index)? onPlaySongs;

  @override
  Widget build(BuildContext context) {
    const pageSize = 30;
    return PagedListView<rust.UserItem>(
      key: ValueKey('user-relation-$fans'),
      pageSize: pageSize,
      keyOf: (u) => u.id,
      emptyText: fans ? '还没有粉丝' : '还没有关注任何人',
      padding: EdgeInsets.only(
        bottom: 24 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      loader: (cursor) async {
        final page = await retryNetwork(() => loader(uid, pageSize, cursor));
        return PagedPage(
          page,
          hasMore: page.length >= pageSize,
          nextCursor: cursor + page.length,
        );
      },
      itemBuilder: (context, u, index, items) => ListTile(
        leading: CircleCover(
          url: u.avatarUrl,
          size: 40,
          icon: Icons.person_outline,
        ),
        title: AdaptiveText(u.name),
        subtitle: Text(
          u.signature.isEmpty ? '暂无签名' : u.signature,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => showUserPage(
          context,
          userId: u.id,
          fallbackNickname: u.name,
          onPlaySongs: onPlaySongs,
        ),
      ),
    );
  }
}

/// 打开他人主页(签名保持兼容: 只新增可选参数)。
Future<void> showUserPage(
  BuildContext context, {
  required BigInt userId,
  String? fallbackNickname,
  void Function(List<rust.SongDto> songs, int index)? onPlaySongs,
  Future<rust.ProfileDetail> Function(BigInt uid)? loadProfile,
  Future<List<rust.Playlist>> Function(BigInt uid)? loadPlaylists,
  UserListLoader? loadFollows,
  UserListLoader? loadFolloweds,
  VoidCallback? onOpenFollows,
  VoidCallback? onOpenFolloweds,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => UserPage(
        userId: userId,
        fallbackNickname: fallbackNickname,
        onPlaySongs: onPlaySongs,
        loadProfile: loadProfile,
        loadPlaylists: loadPlaylists,
        loadFollows: loadFollows,
        loadFolloweds: loadFolloweds,
        onOpenFollows: onOpenFollows,
        onOpenFolloweds: onOpenFolloweds,
      ),
    ),
  );
}
