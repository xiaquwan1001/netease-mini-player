import 'package:flutter/material.dart';

import 'state_views.dart';

/// 搜索请求进行中的占位动画。
///
/// 回归修复(2026-11 用户反馈): 结果还没回来时页面显示"输入关键词后搜索",
/// 容易被误读成断网/没有结果, 这里改成明确的加载态。
///
/// 2026-11 车道 12.3: 自身不再手写 spinner, 收敛成 [LoadingView] 的薄封装
/// (32dp / 线宽 3 / 关键词说明, 视觉与收敛前一致)。
class SearchLoading extends StatelessWidget {
  const SearchLoading(this.keyword, {super.key});

  final String keyword;

  @override
  Widget build(BuildContext context) {
    return LoadingView(
      size: 32,
      strokeWidth: 3,
      message: keyword.isEmpty ? '正在搜索…' : '正在搜索「$keyword」…',
    );
  }
}
