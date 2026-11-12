import 'package:flutter/material.dart';

import 'app_meta.dart';
import 'app_settings.dart';
import 'update_checker.dart';

/// 发现新版本时的统一弹窗(启动自动检查 / 设置页手动检查共用)。
///
/// 行为:
/// - 「前往下载」: 打开当前平台资产(没有就回退 GitHub 仓库页);
/// - 「稍后」: 记住该版本 tag, 启动检查不再为这个版本弹窗;
/// - 直接返回(dismiss): 什么都不记, 下次启动仍会提示。
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) async {
  final upd = info;
  final choice = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('发现新版本 ${upd.latest}'),
      content: Text(trimUpdateNotes(upd.notes)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop('later'),
          child: const Text('稍后'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop('download'),
          child: const Text('前往下载'),
        ),
      ],
    ),
  );
  if (choice == 'later') {
    AppSettings.instance.skipUpdate(upd.latest);
    return;
  }
  if (choice != 'download') return;
  final url = upd.downloadUrl;
  if (url != null && url.isNotEmpty) {
    await UpdateCheckHost.openUrl(url);
  } else {
    await UpdateCheckHost.openUrl(kGithubUrl);
  }
}

/// release notes 截断: 弹窗里最多 200 字, 避免超长正文把按钮挤出屏幕。
String trimUpdateNotes(String? notes) {
  if (notes == null) return '';
  final one = notes.trim();
  return one.length > 200 ? '${one.substring(0, 200)}…' : one;
}
