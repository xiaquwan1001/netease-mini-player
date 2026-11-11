import 'dart:async';

import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'cover_art.dart';
import 'sheet_header.dart';

/// 档位预览用的真实 CDN 封面(取自用户自己的歌单封面, 官方 CDN 直链).
/// 只在设置页里作对比样本; 换一张也不影响功能。
const String kCoverQualitySampleUrl =
    'https://p1.music.126.net/2Tx-QTkfcyuwK5OKdOLrZg==/109951174145681281.jpg';

/// 「封面与图片清晰度」档位选择面板.
///
/// 三档各带一张**同一张图、不同请求像素**的预览 —— 用户能直接看出省流/标准/超清的差别,
/// 比纯文字说明可靠。选完立即写设置(封面会随 [AppSettings] 的通知重建)。
Future<void> showCoverQualitySheet(BuildContext context) {
  final settings = AppSettings.instance;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: AnimatedBuilder(
        animation: settings,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetHeader(
              title: '封面与图片清晰度',
              subtitle:
                  '按「显示尺寸 x 设备像素比 x 档位」向 CDN 取缩略图; 全屏看图与保存始终用原图。',
            ),
            for (final tier in CoverQuality.values)
              _tierRow(
                context,
                tier: tier,
                selected: settings.coverQuality == tier,
                // 先关面板再落盘: 写设置会做一次文件 IO, 等它完成再 pop 会让人误以为没点上
                onPick: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(settings.update(coverQuality: tier));
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

Widget _tierRow(
  BuildContext context, {
  required CoverQuality tier,
  required bool selected,
  required VoidCallback onPick,
}) {
  final scheme = Theme.of(context).colorScheme;
  return InkWell(
    onTap: onPick,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // 同一张样例封面, 按该档位真实请求像素渲染
          CoverArt(
            url: kCoverQualitySampleUrl,
            size: 64,
            radius: 8,
            quality: tier,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tier.label,
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  tier.hint,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (selected) Icon(Icons.check, color: scheme.primary),
        ],
      ),
    ),
  );
}
