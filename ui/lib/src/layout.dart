import 'package:flutter/widgets.dart';

/// 歌曲行的统一水平留白(2026-11 用户反馈: 默认 ListTile 16+16 太浪费,
/// 歌名横向空间不足)。左侧 8dp 保证和封面留一点呼吸, 右侧 4dp 给行尾按钮。
const EdgeInsets kSongRowPadding = EdgeInsets.fromLTRB(8, 0, 4, 0);
