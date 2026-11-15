import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net_retry.dart';
import '../rust/api.dart' as rust;
import '../sheet_header.dart';
import '../toast.dart' show showToast;

/// 歌单/播客详情共用的零碎件: 分享底部菜单 + 曲目/节目加载骨架.

/// 分享底部菜单: 分享到动态(需登录, 失败只弹 SnackBar) / 复制链接
void showResourceShareSheet(
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
          SheetHeader(title: '分享'),
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
class DetailSkeletonList extends StatelessWidget {
  const DetailSkeletonList({super.key});

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
