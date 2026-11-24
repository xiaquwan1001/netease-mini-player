import 'package:flutter/material.dart';

import 'app_meta.dart';
import 'app_settings.dart';
import 'app_sheet.dart';
import 'release_notes.dart';
import 'update_checker.dart';

/// 发现新版本时的统一弹窗(启动自动检查 / 设置页手动检查共用)。
///
/// 行为:
/// - 正文先列「新特性公告」(手工维护的用户语言, 见 `release_notes.dart`),
///   再附 release 正文里的说明(没有公告条目的版本就只显示后者);
/// - 「前往下载」: 打开当前平台资产(没有就回退 GitHub 仓库页);
/// - 「稍后」: 记住该版本 tag, 启动检查不再为这个版本弹窗;
/// - 直接返回(dismiss): 什么都不记, 下次启动仍会提示。
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) async {
  final upd = info;
  final highlights = highlightsSince(upd.current);
  final choice = await showAppDialog<String>(
    context,
    builder: (dialogContext) => AlertDialog(
      title: Text('发现新版本 ${upd.latest}'),
      content: UpdateNotesBody(
        highlights: highlights,
        notes: trimUpdateNotes(upd.notes),
      ),
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

/// 更新已经装上后的「本次更新」公告(启动时弹一次, 每个版本只弹一次)。
///
/// 和更新之前那个弹窗的区别: 这里没有下载按钮, 只告诉用户"你已经在用这个版本了,
/// 以下是它带来的变化"; 用户看完点「知道了」后由调用方记下公告版本。
Future<void> showWhatsNewDialog(
  BuildContext context, {
  required String version,
  required List<String> highlights,
}) async {
  if (highlights.isEmpty) return;
  await showAppDialog<String>(
    context,
    builder: (dialogContext) => AlertDialog(
      title: Text('已更新到 $version'),
      content: UpdateNotesBody(highlights: highlights, notes: ''),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop('ok'),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

/// 弹窗正文: 新特性公告(带圆点) + release 说明。两边都空时给一句兜底文案。
///
/// 抽成独立 widget 是因为两处弹窗(更新前 / 更新后)共用同一视觉, 且长正文
/// 必须自己可滚(超长 release notes 不能把按钮挤出屏幕, 也不能溢出)。
class UpdateNotesBody extends StatelessWidget {
  const UpdateNotesBody({
    super.key,
    required this.highlights,
    required this.notes,
  });

  final List<String> highlights;
  final String notes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <Widget>[];
    if (highlights.isNotEmpty) {
      rows.add(
        Text(
          '新特性公告',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      );
      for (final item in highlights) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('• ', style: theme.textTheme.bodyMedium),
                Expanded(child: Text(item, style: theme.textTheme.bodyMedium)),
              ],
            ),
          ),
        );
      }
    }
    if (notes.isNotEmpty) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 8));
      rows.add(
        Text(
          '更新说明',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      );
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(notes, style: theme.textTheme.bodySmall),
        ),
      );
    }
    if (rows.isEmpty) {
      return const Text('这个版本没有填写更新说明。');
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: rows,
      ),
    );
  }
}

/// release notes 截断: 弹窗里最多 200 字, 避免超长正文把按钮挤出屏幕。
String trimUpdateNotes(String? notes) {
  if (notes == null) return '';
  final one = notes.trim();
  return one.length > 200 ? '${one.substring(0, 200)}…' : one;
}
