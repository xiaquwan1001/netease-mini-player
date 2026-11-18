import 'package:flutter/material.dart';

import '../app_sheet.dart';

/// 歌单管理弹层(歌单详情页 "..." 菜单用): 只负责弹窗与输入收集,
/// 网络请求留在页面里做, 弹层本身不吞错误.

/// 编辑歌单信息: 返回用户填写的新名称/简介, 取消返回 null。
Future<({String name, String desc})?> showEditPlaylistInfoSheet(
  BuildContext context, {
  required String name,
  required String description,
}) async {
  final nameCtrl = TextEditingController(text: name);
  final descCtrl = TextEditingController(text: description);
  final save = await showAppDialog<bool>(
    context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('编辑歌单信息'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameCtrl,
            maxLength: 40,
            decoration: const InputDecoration(labelText: '名称'),
          ),
          TextField(
            controller: descCtrl,
            maxLines: 4,
            minLines: 2,
            maxLength: 300,
            decoration: const InputDecoration(labelText: '简介'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  final newName = nameCtrl.text.trim();
  final newDesc = descCtrl.text;
  nameCtrl.dispose();
  descCtrl.dispose();
  if (save != true) return null;
  return (name: newName, desc: newDesc);
}

/// 删除歌单确认(不可恢复, 文案带歌单名)
Future<bool> confirmDeletePlaylist(BuildContext context, String name) async {
  final ok = await showAppDialog<bool>(
    context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('删除歌单'),
      content: Text('确定删除《$name》? 删除后无法恢复。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// 把一首歌移出歌单的确认
Future<bool> confirmRemoveTrack(BuildContext context, String songName) async {
  final ok = await showAppDialog<bool>(
    context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('移出歌单'),
      content: Text('把《$songName》移出这个歌单?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('移出'),
        ),
      ],
    ),
  );
  return ok == true;
}
