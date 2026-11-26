import 'package:flutter/material.dart';

import '../async_view.dart';
import '../cover_art.dart';
import '../error_views.dart' show FullError;
import '../net_retry.dart' show errorKind, friendlyError;
import '../rust/api_all.dart' as rust;
import '../state_views.dart';
import 'discover_types.dart';

/// 「推荐歌单」页签: 一次全量返回, 点歌单先关本页再交给上层打开.
///
/// 整页四态收敛到 [AsyncView](与 VIP/勋章墙/专辑页同一口径);
/// 出错文案保留"需要登录"的前缀(这一页最常见的原因就是未登录)。
class DailyPlaylistsTab extends StatelessWidget {
  const DailyPlaylistsTab({
    super.key,
    required this.load,
    required this.onOpen,
    this.onLogin,
  });

  final PlaylistListLoader load;
  final void Function(rust.Playlist playlist) onOpen;

  /// 登录入口(由首页 `AccountActions.login` 一路传下来); null = 没有可用的
  /// 登录通道时仍旧显示「重试」。未登录进这一页时 auth 错误**重试永远不会成功**
  /// —— 同一请求带着同一份未登录身份再发一次, 后端只会再回一次 auth。
  final VoidCallback? onLogin;

  @override
  Widget build(BuildContext context) {
    return AsyncView<List<rust.Playlist>>(
      load: load,
      keepAlive: true,
      emptyText: '今天没有推荐歌单',
      loadingBuilder: (_) => const LoadingView(),
      emptyBuilder: (_) =>
          const EmptyView(icon: Icons.queue_music_outlined, title: '今天没有推荐歌单'),
      errorBuilder: (_, error, retry) {
        final authError = errorKind(error) == 'auth';
        return FullError(
          // auth 类错误 friendlyError 已经统一给「需要登录后才能查看」, 不要再叠一句
          // 「需要登录后才能获取」(同一句话显示成两行, 2026-11-18 收敛); 其它错误
          // (网络/风控)仍旧带上这页的上下文前缀。
          message: authError
              ? friendlyError(error)
              : '推荐歌单需要登录后才能获取\n${friendlyError(error)}',
          onRetry: retry,
          // auth 错误重试无意义: 用现成的登录入口把主按钮换成「去登录」
          // (2026-11-26 审查: 以前只能点「重试」, 而未登录时重试永远失败)。
          actionLabel: authError && onLogin != null ? '去登录' : null,
          onAction: authError ? onLogin : null,
        );
      },
      // 非分页: 推荐歌单随一次请求全量返回, 接口无分页
      builder: (context, lists, _) => ListView.builder(
        itemCount: lists.length,
        itemBuilder: (context, i) {
          final pl = lists[i];
          return ListTile(
            leading: CoverArt(url: pl.coverUrl, size: 48, radius: 6),
            title: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${pl.trackCount} 首'),
            onTap: () {
              Navigator.pop(context);
              onOpen(pl);
            },
          );
        },
      ),
    );
  }
}
