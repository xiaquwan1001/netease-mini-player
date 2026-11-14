import 'package:flutter/material.dart';

import 'adaptive_text.dart';
import 'cover_art.dart';
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'rust/api.dart' as rust;
import 'toast.dart' show showToast;
import 'user_page.dart';

/// 关注/粉丝列表: 两个 tab, 每行可关注/取关.
///
/// uid = 0 时后端用当前登录账号(我的资料卡点进来就是这种)。
///
/// 2026-11-14 用户反馈 12: 这一行(关注对象)点**头像或名字**都进 ta 的「动态」,
/// 且留在本页(压一层用户主页, 默认「动态」tab); 只有在动态内容区里点作者头像/
/// 名字才进 ta 的主页。以前整行进主页、点名字另跳动态, 同一行两种结果, 用户按不中。
typedef UserListLoader = Future<List<rust.UserItem>> Function(
  BigInt uid,
  int limit,
  int offset,
);
typedef FollowHook = Future<bool> Function(BigInt uid, bool follow);

Future<void> showUserList(
  BuildContext context, {
  BigInt? uid,
  bool startOnFans = false,
  UserListLoader? loadFollows,
  UserListLoader? loadFolloweds,
  FollowHook? setFollow,
  void Function(BigInt userId)? onOpenUser,
  void Function(List<rust.SongDto> songs, int index)? onPlaySongs,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('关注与粉丝')),
        body: UserListView(
          uid: uid ?? BigInt.zero,
          startOnFans: startOnFans,
          loadFollows: loadFollows,
          loadFolloweds: loadFolloweds,
          setFollow: setFollow,
          onOpenUser: onOpenUser,
          onPlaySongs: onPlaySongs,
        ),
      ),
    ),
  );
}

class UserListView extends StatefulWidget {
  const UserListView({
    super.key,
    required this.uid,
    this.startOnFans = false,
    this.loadFollows,
    this.loadFolloweds,
    this.setFollow,
    this.onOpenUser,
    this.onPlaySongs,
  });

  final BigInt uid;
  final bool startOnFans;
  final UserListLoader? loadFollows;
  final UserListLoader? loadFolloweds;
  final FollowHook? setFollow;
  final void Function(BigInt userId)? onOpenUser;

  /// 进他人主页后点歌单要能播(宿主注入); 不传则歌单只展示
  final void Function(List<rust.SongDto> songs, int index)? onPlaySongs;

  @override
  State<UserListView> createState() => _UserListViewState();
}

class _UserListViewState extends State<UserListView> {
  static const _pageSize = 30;

  late bool _fans = widget.startOnFans;

  /// 关注状态的本地覆盖(点过按钮的才有)
  final Map<BigInt, bool> _followOverrides = {};

  UserListLoader get _rawLoader => _fans
      ? (widget.loadFolloweds ??
            (uid, limit, offset) =>
                rust.userFolloweds(uid: uid, limit: limit, offset: offset))
      : (widget.loadFollows ??
            (uid, limit, offset) =>
                rust.userFollows(uid: uid, limit: limit, offset: offset));

  FollowHook get _setFollow =>
      widget.setFollow ??
      (uid, follow) => rust.setFollow(uid: uid, follow: follow);

  /// offset 追加按服务端已消费行数算(与去重后的列表长度无关)
  PagedLoader<rust.UserItem> get _loader {
    final raw = _rawLoader;
    final uid = widget.uid;
    var consumed = 0;
    return (cursor) async {
      final page = await retryNetwork(() => raw(uid, _pageSize, cursor));
      consumed = cursor + page.length;
      return PagedPage(
        page,
        hasMore: page.length >= _pageSize,
        nextCursor: consumed,
      );
    };
  }

  bool _followed(rust.UserItem u) => _followOverrides[u.id] ?? u.followed;

  Future<void> _toggleFollow(rust.UserItem u) async {
    final target = !_followed(u);
    setState(() => _followOverrides[u.id] = target);
    try {
      await _setFollow(u.id, target);
    } catch (e) {
      if (!mounted) return;
      setState(() => _followOverrides[u.id] = !target);
      _snack('操作失败: ${friendlyError(e)}');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    showToast(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('关注')),
              ButtonSegment(value: true, label: Text('粉丝')),
            ],
            selected: {_fans},
            onSelectionChanged: (s) {
              if (s.first == _fans) return;
              // PagedListView 以 _fans 为 key, 切换即重挂载并重新加载
              setState(() => _fans = s.first);
            },
          ),
        ),
        Expanded(
          child: PagedListView<rust.UserItem>(
            key: ValueKey(_fans),
            loader: _loader,
            itemBuilder: (context, u, i, items) {
              final followed = _followed(u);
              return ListTile(
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
                // 整行(含头像/名字)都进 ta 的「动态」: 关注列表的用途就是
                // "他们最近发了什么"; 主页从动态卡片里的作者还能进。
                onTap: () => widget.onOpenUser != null
                    ? widget.onOpenUser!(u.id)
                    : showUserPage(
                        context,
                        userId: u.id,
                        fallbackNickname: u.name,
                        onPlaySongs: widget.onPlaySongs,
                        initialTab: '动态',
                      ),
                trailing: OutlinedButton(
                  onPressed: () => _toggleFollow(u),
                  child: Text(
                    followed ? '已关注' : '关注',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              );
            },
            emptyBuilder: (context, _) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _fans ? '还没有粉丝' : '还没有关注任何人',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _fans ? '多发动态、被点赞后粉丝会慢慢多起来' : '去发现页找找感兴趣的人并关注吧',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
