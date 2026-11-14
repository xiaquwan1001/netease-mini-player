import 'dart:async';

import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'async_view.dart';
import 'cloud_page.dart' show showCloudPage;
import 'cover_art.dart';
import 'cover_row.dart';
import 'digital_album_page.dart';
import 'expandable_text.dart';
import 'layout.dart';
import 'messages_page.dart';
import 'my_collections_page.dart';
import 'net_retry.dart';
import 'profile_header.dart';
import 'ranking_view.dart';
import 'recent_order.dart';
import 'rust/api.dart' as rust;
import 'section_header.dart';
import 'user_page.dart' show UserEventsList, showUserPage;
import 'song_actions.dart';
import 'song_tile.dart' show SongTitleWithBadges;
import 'state_views.dart';
import 'toast.dart' show showToast;

/// "我的": 个人资料卡 / 我的主页入口 / 简介(可编辑) / 我的动态 /
/// 我喜欢 / 收藏歌单 / 收藏专辑 / 收藏播客 / 最近听过 / 听歌排行.
/// 关注艺人 + 关注动态都在独立的"关注"底部 tab(艺人分类在那边横向展示)。
/// 所有区块独立加载; 未登录时只显示登录引导.
///
/// 2026-11 需求 1/2: 资料卡下面这三块与「其他用户主页」对齐 —— 简介空时也给文案,
/// 「我的动态」直接复用 [UserEventsList](与用户主页「动态」tab 同一份渲染),
/// 「我的主页」跳到同一个 [UserPage], 不再为"自己"另写一份资料页。
/// 整页下拉刷新会重拉资料并把各区块换 key 重挂载(含动态)。
///
/// 排序口径(用户 2026-11): 最近有交互的优先展示 ——
/// 收藏专辑默认在收藏播客之前, 但两个区块谁最近被打开/播放过谁在前;
/// 区块内条目(歌单/专辑/播客)也按最近一次交互倒序(规则见 [sortByRecentInteraction])。
class MineView extends StatefulWidget {
  const MineView({
    super.key,
    required this.loggedIn,
    required this.onLogin,
    required this.onOpenAccounts,
    required this.onPlaySongs,
    required this.onOpenPlaylist,
    required this.onOpenPodcast,
    required this.onOpenAlbum,
    required this.onOpenRecent,
    required this.onOpenFollows,
    required this.onOpenFolloweds,
    required this.onOpenLiked,
    this.onOpenMessages,
    this.onOpenMedals,
    this.onOpenVip,
    this.loadMessageCounts,
    this.onPlayLiked,
    this.loadLiked,
    this.loadPlaylists,
    this.loadPodcasts,
    this.loadProfile,
    this.loadRecent,
    this.loadRanking,
    this.loadAlbums,
    this.loadMyEvents,
    this.onOpenUrl,
    this.saveSignature,
  });

  final bool loggedIn;
  final VoidCallback onLogin;
  final VoidCallback onOpenAccounts;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(rust.Playlist playlist) onOpenPlaylist;
  final void Function(rust.PodcastRadio radio) onOpenPodcast;
  final void Function(rust.AlbumItem album) onOpenAlbum;
  final VoidCallback onOpenRecent;

  /// 资料卡上的"关注 N" / "粉丝 N"
  /// 返回 Future: 列表页 pop 后资料卡要重拉一次, 让关注/取关后的数字立即更新。
  final Future<void> Function() onOpenFollows;
  final Future<void> Function() onOpenFolloweds;

  /// 打开"我喜欢的音乐"详情页
  final VoidCallback onOpenLiked;

  /// 打开消息中心(不传就不显示入口)
  final VoidCallback? onOpenMessages;

  /// 等级/勋章墙入口(未登录或未接线时不显示)
  final VoidCallback? onOpenMedals;

  /// 黑胶会员入口(审查 P1-7.9: 会员是账号资产, 从设置搬到「我的」;
  /// 不传则不显示该行)
  final VoidCallback? onOpenVip;

  /// 未读计数(缺省走 rust.messageCounts)
  final MessageCountsLoader? loadMessageCounts;

  /// 点播"我喜欢的音乐"里的曲目(与 onPlaySongs 的区别: 队列来源可以标成
  /// "我喜欢的音乐"这个歌单 id, 详情页的"定位正在播放"才有依据)。缺省回落 onPlaySongs。
  final void Function(List<rust.SongDto> songs, int index)? onPlayLiked;

  final Future<List<rust.SongDto>> Function()? loadLiked;
  final Future<List<rust.Playlist>> Function()? loadPlaylists;
  final Future<List<rust.PodcastRadio>> Function()? loadPodcasts;
  final Future<rust.ProfileDetail> Function()? loadProfile;
  final Future<List<rust.SongDto>> Function()? loadRecent;

  /// 听歌排行("all" 总量 / "week" 当周). 缺省走 rust.playRanking.
  final RankingLoader? loadRanking;

  /// 收藏的专辑(需登录). 缺省走 rust.subscribedAlbums.
  final Future<List<rust.AlbumItem>> Function()? loadAlbums;

  /// 我的动态(按 uid 取). 缺省走 rust.userEvents(第一页 3 条预览).
  final Future<List<rust.FeedEventDto>> Function(BigInt uid)? loadMyEvents;

  /// 动态详情里打开外链/视频; 缺省 [UserEventsList] 走 PlatformBridge。
  final Future<void> Function(String url)? onOpenUrl;

  /// 保存简介. **后端接口尚未接入**(见 [_MineViewState._editSignature]) ——
  /// 为空时只弹输入框并提示"还没接入", 不伪造成功。
  final Future<void> Function(String signature)? saveSignature;

  @override
  State<MineView> createState() => _MineViewState();
}

class _MineViewState extends State<MineView> {
  /// 下拉刷新代际: 变一次就让各区块换 key 重挂载(= 真正重拉数据)。
  /// 区块本身开了 keepAlive, 不换 key 的话 setState 只会复用旧数据。
  int _dataGeneration = 0;

  /// 我的资料(简介/等级/uid)。由本层持有: 资料卡、简介区块、动态区块都要用,
  /// 放在这里只发一次请求(之前资料卡自己拉一份, 再加两块就得拉三份)。
  rust.ProfileDetail? _profile;

  @override
  void initState() {
    super.initState();
    if (widget.loggedIn) unawaited(_loadProfile());
  }

  @override
  void didUpdateWidget(covariant MineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loggedIn && !oldWidget.loggedIn) unawaited(_loadProfile());
    if (!widget.loggedIn && _profile != null) _profile = null;
  }

  Future<void> _loadProfile() async {
    if (!widget.loggedIn) return;
    try {
      final detail = await retryNetwork(
        widget.loadProfile ?? rust.profileDetail,
      );
      if (!mounted) return;
      setState(() => _profile = detail);
    } catch (_) {
      // 资料是锦上添花: 失败只保留默认背景/昵称与「还没填写简介」的空态
    }
  }

  /// 资料卡用的 detail: 简介已由下面的「简介」区块展示(与其他用户主页同一口径),
  /// 这里把 signature 置空, 免得同一段文字在卡片副标题里再重复一遍。
  rust.ProfileDetail? get _headerDetail {
    final d = _profile;
    if (d == null) return null;
    return rust.ProfileDetail(
      userId: d.userId,
      artistId: d.artistId,
      nickname: d.nickname,
      avatarUrl: d.avatarUrl,
      backgroundUrl: d.backgroundUrl,
      signature: '',
      vip: d.vip,
      follows: d.follows,
      followeds: d.followeds,
      level: d.level,
    );
  }

  /// 关注/粉丝列表页里可能关注/取关了, 返回后重拉资料卡让数字立即更新。
  Future<void> _openFollowList(Future<void> Function() open) async {
    await open();
    if (!mounted || !widget.loggedIn) return;
    await _loadProfile();
  }

  /// 打开「我对外的主页」—— 与「其他用户主页」是同一个组件([showUserPage]),
  /// 不再另写一份资料卡; initialTab 可直达某条 tab(如从「我的动态」进「动态」)。
  Future<void> _openSelfPage({String? initialTab}) async {
    final uid = _profile?.userId;
    if (uid == null) return;
    await showUserPage(
      context,
      userId: uid,
      fallbackNickname: _profile?.nickname,
      onPlaySongs: widget.onPlaySongs,
      onOpenUrl: widget.onOpenUrl,
      initialTab: initialTab,
    );
  }

  /// 编辑简介: **目前只有 UI 入口** —— core/vendor 没有任何「修改用户资料/签名」
  /// 的端点(2026-11 核对: vendor/ncm-api 的 api/ 下只有 user_detail/user_playlist
  /// 等只读接口, 没有 user/update), 所以这里弹输入框后如实提示「没接入」,
  /// 不伪造成功、不自己造接口。
  ///
  /// 需要 Rust 侧补的能力(见交付报告): provider 新增 update_signature 能力
  /// (网易云 /api/user/update, POST 表单 nickName/signature, 需带 csrf 与 device
  /// cookie), FFI 暴露 updateSignature(signature: String); 注入
  /// MineView.saveSignature 后这里自动变成真保存。
  Future<void> _editSignature() async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _SignatureEditDialog(initial: _profile?.signature ?? ''),
    );
    if (text == null || !mounted) return;
    final save = widget.saveSignature;
    if (save == null) {
      showToast(context, '简介保存还没接入后端接口(user/update), 暂不生效');
      return;
    }
    try {
      await save(text);
      if (!mounted) return;
      showToast(context, '简介已保存');
      await _loadProfile();
    } catch (e) {
      if (!mounted) return;
      showToast(context, '保存失败: ${friendlyError(e)}', isError: true);
    }
  }

  Future<List<rust.SongDto>> Function() get _liked =>
      widget.loadLiked ?? rust.likedSongs;
  Future<List<rust.Playlist>> Function() get _playlists =>
      widget.loadPlaylists ?? rust.myPlaylists;
  Future<List<rust.PodcastRadio>> Function() get _podcasts =>
      widget.loadPodcasts ?? (() => rust.subscribedPodcasts(limit: 50));
  Future<List<rust.AlbumItem>> Function() get _albums =>
      widget.loadAlbums ?? (() => rust.subscribedAlbums(limit: 50));

  /// 播放历史: 云端拉不到(未登录/网络差)时回落到本地播放记录
  Future<List<rust.SongDto>> _loadRecent() async {
    try {
      return await retryNetwork(
        widget.loadRecent ?? (() => rust.recentSongs(limit: 20)),
      );
    } catch (_) {
      return rust.localRecentSongs(limit: 20);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.loggedIn) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.account_circle,
                size: 56,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 12),
              const Text('登录后查看我喜欢的音乐、收藏歌单/播客和关注艺人'),
              const SizedBox(height: kSectionGap),
              FilledButton(onPressed: widget.onLogin, child: const Text('登录')),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async {
        setState(() => _dataGeneration += 1);
        await _loadProfile();
      },
      // 横向栅格见 layout.dart: 卡片外边缘距屏 12, 卡片内行内容 12+4 = 16。
      // 之前是「页面 12 + 行 12 = 24 起步」, 再叠 leading 后文字被推到 1/4 屏宽外。
      // 标题与 leading 的间距从 Material 默认 16 收到 kRowTitleGap(8)。
      child: ListTileTheme(
        data: const ListTileThemeData(
          contentPadding: kCardRowPadding,
          horizontalTitleGap: kRowTitleGap,
        ),
        child: ListView(
          padding: kPageInsets,
          children: [
            ProfileHeader(
              detail: _headerDetail,
              fallbackNickname: widget.loggedIn ? '我的账号' : null,
              loggedIn: widget.loggedIn,
              onTap: widget.loggedIn ? widget.onOpenAccounts : widget.onLogin,
              onTapFollows: widget.loggedIn
                  ? () => _openFollowList(widget.onOpenFollows)
                  : null,
              onTapFolloweds: widget.loggedIn
                  ? () => _openFollowList(widget.onOpenFolloweds)
                  : null,
            ),
            if (widget.loggedIn) ...[
              const SizedBox(height: kCardGap),
              // 需求 1/2: 「我的」页与「其他用户主页」统一结构 ——
              // 简介(空也给文案 + 编辑入口) / 我的动态 / 跳到自己对外的主页形态。
              _SelfPageEntry(
                enabled: _profile != null,
                onOpen: () => _openSelfPage(),
              ),
              const SizedBox(height: kSectionGap),
              _MySignatureSection(detail: _profile, onEdit: _editSignature),
              const SizedBox(height: kSectionGap),
              _MyFeedSection(
                key: ValueKey('mine-feed-$_dataGeneration'),
                uid: _profile?.userId,
                load: widget.loadMyEvents,
                onOpenAll: () => _openSelfPage(initialTab: '动态'),
                onPlaySongs: widget.onPlaySongs,
                onOpenUrl: widget.onOpenUrl,
              ),
            ],
            if (widget.onOpenMessages != null) ...[
              const SizedBox(height: kCardGap),
              MessageEntryCard(
                onOpen: widget.onOpenMessages!,
                load: widget.loadMessageCounts,
              ),
            ],
            if (widget.onOpenVip != null) ...[
              const SizedBox(height: kCardGap),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.workspace_premium_outlined),
                  title: const Text('黑胶会员'),
                  subtitle: const Text('签到 / 任务 / 成长值(只读)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: widget.onOpenVip,
                ),
              ),
            ],
            if (widget.loggedIn) ...[
              const SizedBox(height: kCardGap),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: const Text('音乐云盘'),
                  subtitle: const Text('已上传的歌曲 · 播放 / 删除'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showCloudPage(
                    context,
                    onPlay: (song) => widget.onPlaySongs([
                      rust.SongDto(
                        id: song.songId,
                        name: song.name,
                        artist: song.artist,
                        artistId: BigInt.zero,
                        album: song.album,
                        albumId: BigInt.zero,
                        coverUrl: song.coverUrl,
                        durationMs: BigInt.zero,
                        fee: 0,
                        vip: false,
                        paid: false,
                        playable: true,
                      ),
                    ], 0),
                  ),
                ),
              ),
              const SizedBox(height: kCardGap),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.album_outlined),
                  title: const Text('数字专辑(只读)'),
                  subtitle: const Text('已购专辑 / 已购单曲 / 详情销量'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const DigitalAlbumPage(),
                    ),
                  ),
                ),
              ),
            ],
            if (widget.loggedIn && widget.onOpenMedals != null) ...[
              const SizedBox(height: kCardGap),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.military_tech_outlined),
                  title: const Text('等级与勋章'),
                  subtitle: const Text('等级进度 / 勋章墙(只读)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: widget.onOpenMedals,
                ),
              ),
            ],
            const SizedBox(height: kCardGap),
            const SigninCard(),
            const SizedBox(height: kCardGap),
            _LikedSection(
              key: ValueKey('mine-liked-$_dataGeneration'),
              load: _liked,
              onPlay: widget.onPlayLiked ?? widget.onPlaySongs,
              onOpenAll: widget.onOpenLiked,
            ),
            const SizedBox(height: kSectionGap),
            _PlaylistsSection(
              key: ValueKey('mine-playlists-$_dataGeneration'),
              load: _playlists,
              onOpen: widget.onOpenPlaylist,
              onOpenAll: () => showMyPlaylistsPage(
                context,
                load: _playlists,
                onOpen: widget.onOpenPlaylist,
              ),
            ),
            const SizedBox(height: kSectionGap),
            _AlbumPodcastSections(
              key: ValueKey('mine-album-podcast-$_dataGeneration'),
              loadAlbums: _albums,
              loadPodcasts: _podcasts,
              onOpenAlbum: widget.onOpenAlbum,
              onOpenPodcast: widget.onOpenPodcast,
              onOpenAllAlbums: () => showMyAlbumsPage(
                context,
                load: _albums,
                onOpen: widget.onOpenAlbum,
              ),
              onOpenAllPodcasts: () => showMyPodcastsPage(
                context,
                load: _podcasts,
                onOpen: widget.onOpenPodcast,
              ),
            ),
            const SizedBox(height: kSectionGap),
            _RecentSection(
              key: ValueKey('mine-recent-$_dataGeneration'),
              load: _loadRecent,
              onOpenAll: widget.onOpenRecent,
              onPlay: widget.onPlaySongs,
            ),
            const SizedBox(height: kSectionGap),
            _RankingSection(
              key: ValueKey('mine-ranking-$_dataGeneration'),
              load: widget.loadRanking,
              onPlay: widget.onPlaySongs,
              onOpenAll: () => showPlayRanking(
                context,
                onPlaySongs: widget.onPlaySongs,
                load: widget.loadRanking,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------- 我的主页 / 简介 / 我的动态 ----------------

/// 编辑简介的输入弹窗。
///
/// controller 必须由**弹窗自己**持有并随 State 释放: 之前在调用方的 finally 里
/// dispose, 此时弹窗路由还在做退出动画、TextField 仍在 build, 会抛
/// "A TextEditingController was used after being disposed"。
class _SignatureEditDialog extends StatefulWidget {
  const _SignatureEditDialog({required this.initial});

  /// 当前简介(预填到输入框)
  final String initial;

  @override
  State<_SignatureEditDialog> createState() => _SignatureEditDialogState();
}

class _SignatureEditDialogState extends State<_SignatureEditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑简介'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        maxLength: 60,
        decoration: const InputDecoration(hintText: '介绍一下自己(最多 60 字)'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 「我的主页」入口: 我对外可见的那一版(与「其他用户主页」是同一个页面组件).
///
/// 资料还没落地(uid 未知)时禁用而不是隐藏 —— 用户能提前看到"这里有一扇门",
/// 点击无效果比整块时有时无更不迷惑。
class _SelfPageEntry extends StatelessWidget {
  const _SelfPageEntry({required this.enabled, required this.onOpen});

  final bool enabled;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: kCardMargin,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.badge_outlined),
        title: const Text('我的主页'),
        subtitle: const Text('别人看到的资料 / 动态 / 公开歌单'),
        trailing: const Icon(Icons.chevron_right),
        onTap: enabled ? onOpen : null,
      ),
    );
  }
}

/// 「简介」区块: 与其他用户主页同一条内容(空时给明确文案), 再加编辑入口。
///
/// 之前「我的」页完全没有简介(資料卡只显示昵称), 用户看不见自己对外展示的签名,
/// 也没有任何修改入口 —— 与别人主页的信息密度不一致(需求 1)。
class _MySignatureSection extends StatelessWidget {
  const _MySignatureSection({required this.detail, required this.onEdit});

  final rust.ProfileDetail? detail;

  /// 编辑动作; 后端接口未接入时由调用方提示"暂不生效"(见 [_MineViewState])
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final signature = detail?.signature.trim() ?? '';
    final loaded = detail != null;
    final Widget body;
    if (!loaded) {
      body = Text(
        '正在加载资料…',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    } else if (signature.isEmpty) {
      body = Text(
        '还没有填写简介',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    } else {
      // 与用户主页/艺人页同一条长文本组件(3 行截断 + 展开)
      body = ExpandableText(text: signature);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: '简介',
          trailing: SectionSeeAllButton(label: '编辑简介', onTap: onEdit),
        ),
        Card(
          margin: kCardMargin,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(kPagePadding),
            child: body,
          ),
        ),
      ],
    );
  }
}

/// 「我的动态」区块: 复用用户主页的 [UserEventsList](同一份渲染/四态),
/// 只放前 [maxItems] 条预览, 「查看全部」进自己的主页「动态」tab。
class _MyFeedSection extends StatelessWidget {
  const _MyFeedSection({
    super.key,
    required this.uid,
    required this.load,
    required this.onOpenAll,
    this.onPlaySongs,
    this.onOpenUrl,
  });

  final BigInt? uid;
  final Future<List<rust.FeedEventDto>> Function(BigInt uid)? load;
  final VoidCallback onOpenAll;
  final void Function(List<rust.SongDto> songs, int index)? onPlaySongs;
  final Future<void> Function(String url)? onOpenUrl;

  static const int maxItems = 3;

  /// async: 让"FFI 同步抛错"变成 Future 错误, 交给 AsyncView 的四态(不整块炸掉)
  Future<List<rust.FeedEventDto>> _load(BigInt uid) async =>
      (load ?? _defaultEvents)(uid);

  static Future<List<rust.FeedEventDto>> _defaultEvents(BigInt uid) async =>
      rust.userEvents(uid: uid, limit: maxItems, lastTime: -1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uid = this.uid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: '我的动态',
          trailing: SectionSeeAllButton(label: '查看全部', onTap: onOpenAll),
        ),
        if (uid == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              '正在加载资料…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          UserEventsList(
            load: () => _load(uid),
            maxItems: maxItems,
            emptyText: '还没有发布动态',
            onPlaySongs: onPlaySongs,
            onOpenUrl: onOpenUrl,
          ),
      ],
    );
  }
}

// ---------------- 我喜欢 ----------------

class _LikedSection extends StatelessWidget {
  const _LikedSection({
    super.key,
    required this.load,
    required this.onPlay,
    required this.onOpenAll,
  });

  final Future<List<rust.SongDto>> Function() load;
  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: '我喜欢的音乐',
          trailing: SectionSeeAllButton(label: '查看全部', onTap: onOpenAll),
        ),
        AsyncView<List<rust.SongDto>>(
          load: load,
          emptyText: '还没有喜欢的歌曲',
          // 收敛: 四态(加载/错误/空/数据)统一交给 AsyncView, 不再各页一份私有实现。
          keepAlive: true,
          builder: (context, songs, reload) {
            final playable = [
              for (final s in songs)
                if (s.playable) s,
            ];
            final preview = songs.take(8).toList();
            return Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < preview.length; i++)
                    ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      // 与同页入口行同一栅格: 卡片边缘 12 + 行内 4 = 16
                      contentPadding: kCardRowPadding,
                      leading: CoverArt(
                        url: preview[i].coverUrl,
                        size: 40,
                        radius: 4,
                      ),
                      title: SongTitleWithBadges(song: preview[i]),
                      subtitle: Text(
                        preview[i].artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (songs.length > preview.length &&
                              i == preview.length - 1)
                            Text(
                              '共 ${songs.length} 首',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          SongOverflowButton(
                            song: preview[i],
                            size: 20,
                            source: SongActionSource.playlist,
                          ),
                        ],
                      ),
                      onTap: preview[i].playable
                          ? () {
                              final index = playable.indexWhere(
                                (s) => s.id == preview[i].id,
                              );
                              onPlay(playable, index < 0 ? 0 : index);
                            }
                          : null,
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

// ---------------- 歌单 / 播客 ----------------

class _PlaylistsSection extends StatelessWidget {
  const _PlaylistsSection({
    super.key,
    required this.load,
    required this.onOpen,
    required this.onOpenAll,
  });

  final Future<List<rust.Playlist>> Function() load;
  final void Function(rust.Playlist playlist) onOpen;

  /// 二级整页("查看全部")
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    // 交互记录变了要重排, 所以挂在 AppSettings 上重建(数据由 AsyncView 持有,
    // rebuild 只重算顺序, 不会重新取数)。
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: '收藏的歌单',
            trailing: SectionSeeAllButton(label: '查看全部', onTap: onOpenAll),
          ),
          AsyncView<List<rust.Playlist>>(
            load: load,
            emptyText: '还没有收藏歌单',
            keepAlive: true,
            // 高度交给 CoverRow(按系统字号自适应), 不再写死 176 ——
            // 1.625 字号下两行文字会顶出固定的 176 高度。
            builder: (context, lists, reload) => CoverRow(
              children: [
                for (final pl in sortByRecentInteraction(
                  lists,
                  (pl) => pl.id,
                  (id) =>
                      AppSettings.instance.lastInteractionMs('playlist', id),
                ))
                  CoverCard(
                    coverUrl: pl.coverUrl,
                    title: pl.special ? '我喜欢的音乐' : pl.name,
                    subtitle: '${pl.trackCount} 首',
                    onTap: () => onOpen(pl),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PodcastsSection extends StatelessWidget {
  const _PodcastsSection({
    super.key,
    required this.load,
    required this.onOpen,
    required this.onOpenAll,
  });

  final Future<List<rust.PodcastRadio>> Function() load;
  final void Function(rust.PodcastRadio radio) onOpen;

  /// 二级整页("查看全部")
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: '收藏的播客',
          trailing: SectionSeeAllButton(label: '查看全部', onTap: onOpenAll),
        ),
        AsyncView<List<rust.PodcastRadio>>(
          load: load,
          emptyText: '还没有收藏播客',
          keepAlive: true,
          builder: (context, radios, reload) => CoverRow(
            children: [
              // 最近播放/打开过的播客排在前面(无记录保持后端顺序)
              for (final r in sortByRecentInteraction(
                radios,
                (r) => r.id,
                (id) => AppSettings.instance.lastInteractionMs('podcast', id),
              ))
                CoverCard(
                  coverUrl: r.coverUrl,
                  title: r.name,
                  subtitle: [
                    if (r.djName.isNotEmpty) r.djName,
                    if (r.programCount > BigInt.zero) '${r.programCount} 集',
                  ].join(' · '),
                  onTap: () => onOpen(r),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------- 收藏的专辑 ----------------

class _AlbumsSection extends StatelessWidget {
  const _AlbumsSection({
    super.key,
    required this.load,
    required this.onOpen,
    required this.onOpenAll,
  });

  final Future<List<rust.AlbumItem>> Function() load;
  final void Function(rust.AlbumItem album) onOpen;

  /// 二级整页("查看全部")
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: '收藏的专辑',
          trailing: SectionSeeAllButton(label: '查看全部', onTap: onOpenAll),
        ),
        AsyncView<List<rust.AlbumItem>>(
          load: load,
          emptyText: '还没有收藏专辑(在专辑页点收藏)',
          keepAlive: true,
          builder: (context, albums, reload) => CoverRow(
            children: [
              // 最近播放/打开过的专辑排在前面(无记录保持后端顺序)
              for (final a in sortByRecentInteraction(
                albums,
                (a) => a.id,
                (id) => AppSettings.instance.lastInteractionMs('album', id),
              ))
                CoverCard(
                  coverUrl: a.coverUrl,
                  title: a.name,
                  subtitle: [
                    if (a.artist.isNotEmpty) a.artist,
                    if (a.trackCount > BigInt.zero) '${a.trackCount} 首',
                  ].join(' · '),
                  onTap: () => onOpen(a),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------- 收藏的专辑 / 收藏的播客(按最近交互互换前后) ----------------

/// 把"收藏的专辑"和"收藏的播客"两个区块按最近交互决定前后位置.
///
/// 口径(见 [compareSectionsByRecent]):
/// - 默认顺序: 收藏专辑 → 收藏播客;
/// - 谁最近被交互过(取该区块内最新一条的时间戳)谁在前, 持平时按默认顺序.
///
/// 为什么由本组件(父层)持有数据: 区块间次序要同时拿到两边的列表才能算, 单个区块
/// 自己的 AsyncView 拿不到对方. 这里统一发起一次请求(仍用调用方注入的 loader),
/// 再把同一个 future 交给下面的 AsyncView 去渲染四态 —— 不会重复取数;
/// 取数失败时只影响排序(按默认顺序), 错误态仍由 AsyncView 展示。
class _AlbumPodcastSections extends StatefulWidget {
  const _AlbumPodcastSections({
    super.key,
    required this.loadAlbums,
    required this.loadPodcasts,
    required this.onOpenAlbum,
    required this.onOpenPodcast,
    required this.onOpenAllAlbums,
    required this.onOpenAllPodcasts,
  });

  final Future<List<rust.AlbumItem>> Function() loadAlbums;
  final Future<List<rust.PodcastRadio>> Function() loadPodcasts;
  final void Function(rust.AlbumItem album) onOpenAlbum;
  final void Function(rust.PodcastRadio radio) onOpenPodcast;
  final VoidCallback onOpenAllAlbums;
  final VoidCallback onOpenAllPodcasts;

  @override
  State<_AlbumPodcastSections> createState() => _AlbumPodcastSectionsState();
}

class _AlbumPodcastSectionsState extends State<_AlbumPodcastSections> {
  /// 已取到的数据, 只用来算区块间次序; 未完成/失败时保持 null(= 按默认顺序)。
  List<rust.AlbumItem>? _albums;
  List<rust.PodcastRadio>? _podcasts;

  Future<List<rust.AlbumItem>> _loadAlbums() {
    final future = widget.loadAlbums();
    unawaited(
      future.then(
        (list) {
          if (!mounted) return;
          setState(() => _albums = list);
        },
        onError: (Object _) {
          // 错误态由 AsyncView 渲染, 这里只需要"没有数据可排序"
        },
      ),
    );
    return future;
  }

  Future<List<rust.PodcastRadio>> _loadPodcasts() {
    final future = widget.loadPodcasts();
    unawaited(
      future.then((list) {
        if (!mounted) return;
        setState(() => _podcasts = list);
      }, onError: (Object _) {}),
    );
    return future;
  }

  @override
  Widget build(BuildContext context) {
    // 交互记录变化(打开过某个专辑/播客)要立刻换位置: 挂在 AppSettings 上重建。
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (context, _) {
        final settings = AppSettings.instance;
        final albumLatest = latestInteractionMs(
          _albums,
          (a) => a.id,
          (id) => settings.lastInteractionMs('album', id),
        );
        final podcastLatest = latestInteractionMs(
          _podcasts,
          (r) => r.id,
          (id) => settings.lastInteractionMs('podcast', id),
        );
        // >= 0 时专辑在前: 也包括"两边一样新/都没有记录"时的默认顺序
        final albumFirst =
            compareSectionsByRecent(albumLatest, podcastLatest) >= 0;
        final albums = _AlbumsSection(
          key: const ValueKey('mine-albums'),
          load: _loadAlbums,
          onOpen: widget.onOpenAlbum,
          onOpenAll: widget.onOpenAllAlbums,
        );
        final podcasts = _PodcastsSection(
          key: const ValueKey('mine-podcasts'),
          load: _loadPodcasts,
          onOpen: widget.onOpenPodcast,
          onOpenAll: widget.onOpenAllPodcasts,
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: albumFirst
              ? [albums, const SizedBox(height: kSectionGap), podcasts]
              : [podcasts, const SizedBox(height: kSectionGap), albums],
        );
      },
    );
  }
}

// ---------------- 听歌排行 ----------------

/// "我的"页下方的听歌排行: 总排行/当周切换 + 前 5 条 + 查看全部.
class _RankingSection extends StatelessWidget {
  const _RankingSection({
    super.key,
    required this.load,
    required this.onPlay,
    required this.onOpenAll,
  });

  final RankingLoader? load;
  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: '听歌排行'),
        PlayRankingView(
          load: load,
          onPlaySongs: onPlay,
          compact: true,
          onOpenAll: onOpenAll,
        ),
      ],
    );
  }
}

// ---------------- 最近听过 ----------------

class _RecentSection extends StatelessWidget {
  const _RecentSection({
    super.key,
    required this.load,
    required this.onOpenAll,
    required this.onPlay,
  });

  final Future<List<rust.SongDto>> Function() load;
  final VoidCallback onOpenAll;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: '最近听过',
          trailing: SectionSeeAllButton(label: '查看全部', onTap: onOpenAll),
        ),
        AsyncView<List<rust.SongDto>>(
          load: load,
          emptyText: '还没有播放记录',
          keepAlive: true,
          builder: (context, songs, reload) {
            final preview = songs.take(5).toList();
            return Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < preview.length; i++)
                    ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      // 与同页入口行同一栅格: 卡片边缘 12 + 行内 4 = 16
                      contentPadding: kCardRowPadding,
                      leading: CoverArt(
                        url: preview[i].coverUrl,
                        size: 40,
                        radius: 4,
                      ),
                      title: SongTitleWithBadges(song: preview[i]),
                      subtitle: Text(
                        preview[i].artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: SongOverflowButton(
                        song: preview[i],
                        size: 20,
                        source: SongActionSource.playlist,
                      ),
                      onTap: () => onPlay(songs, i),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

// ---------------- 消息中心入口 ----------------

/// "我的"页的消息入口: 未读数合计 + 分项摘要。
/// 载入失败(未登录/网络)时退化成只有标题, 不报错。
class MessageEntryCard extends StatefulWidget {
  const MessageEntryCard({super.key, required this.onOpen, this.load});

  final VoidCallback onOpen;
  final MessageCountsLoader? load;

  @override
  State<MessageEntryCard> createState() => _MessageEntryCardState();
}

class _MessageEntryCardState extends State<MessageEntryCard>
    with AutomaticKeepAliveClientMixin<MessageEntryCard> {
  rust.MessageCountsDto? _counts;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final counts = await retryNetwork(widget.load ?? rust.messageCounts);
      if (!mounted) return;
      setState(() => _counts = counts);
    } catch (_) {
      // 静默: 入口仍可点开, 页内各自报错
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final counts = _counts;
    final theme = Theme.of(context);
    // 未读数改成「文字展示」: 不再用红色数字角标压在图标上(用户要求),
    // 分项计数直接写进副标题, @我 也算一项。
    final detail = counts == null
        ? '私信 / 通知 / 评论 / @我'
        : [
            if (counts.private > 0) '私信 ${counts.private}',
            if (counts.notices > 0) '通知 ${counts.notices}',
            if (counts.comments > 0) '评论 ${counts.comments}',
            if (counts.forwards > 0) '@我 ${counts.forwards}',
          ].join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        dense: true,
        leading: Icon(
          Icons.forum_outlined,
          color: (counts?.total ?? 0) > 0
              ? Theme.of(context).colorScheme.primary
              : null,
        ),
        title: const Text('消息中心'),
        subtitle: Text(
          detail.isEmpty ? '暂无未读' : detail,
          style: theme.textTheme.bodySmall,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: widget.onOpen,
      ),
    );
  }
}

// ---------------- 每日签到(云贝) ----------------

/// 签到卡片: 今日状态 + 累计/连续/本周天数.
/// 载入失败(未登录/网络)就整块不显示 —— 它是锦上添花, 不该在"我的"顶部占一行报错.
/// load/sign 可注入(测试用), 默认走 Rust 接口.
class SigninCard extends StatefulWidget {
  const SigninCard({super.key, this.load, this.sign});

  final Future<rust.SigninStatus> Function()? load;
  final Future<rust.SigninStatus> Function()? sign;

  @override
  State<SigninCard> createState() => _SigninCardState();
}

class _SigninCardState extends State<SigninCard>
    with AutomaticKeepAliveClientMixin<SigninCard> {
  rust.SigninStatus? _status;

  @override
  bool get wantKeepAlive => true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final status = await retryNetwork(widget.load ?? rust.signinStatus);
      if (!mounted) return;
      setState(() => _status = status);
    } catch (_) {
      // 未登录/网络失败: 不显示这块
    }
  }

  Future<void> _sign() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final before = _status;
      final status = await (widget.sign ?? rust.signIn)();
      if (!mounted) return;
      setState(() => _status = status);
      final earned = status.todayPoint;
      final already = before?.signedToday == true;
      showToast(
        context,
        already || earned == 0
            ? '今天已经签过了(累计 ${status.totalDays} 天)'
            : '签到成功, 云贝 +$earned(累计 ${status.totalDays} 天)',
      );
    } catch (e) {
      if (!mounted) return;
      showToast(context, '签到失败: ${friendlyError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final status = _status;
    if (status == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final detail = [
      '累计 ${status.totalDays} 天',
      '连续 ${status.continuousDays} 天',
      '本周 ${status.weekDays} 天',
    ].join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        dense: true,
        leading: Icon(
          status.signedToday ? Icons.task_alt : Icons.calendar_month_outlined,
          color: status.signedToday ? theme.colorScheme.primary : null,
        ),
        title: Text(status.signedToday ? '今日已签到' : '今天还没签到'),
        subtitle: Text(detail, style: theme.textTheme.bodySmall),
        trailing: status.signedToday
            ? Text('已签', style: TextStyle(color: theme.colorScheme.outline))
            : FilledButton.tonal(
                onPressed: _busy ? null : _sign,
                child: _busy
                    ? const LoadingView.inline(size: 16)
                    : const Text('签到'),
              ),
      ),
    );
  }
}
