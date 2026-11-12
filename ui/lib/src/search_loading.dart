import 'package:flutter/material.dart';

/// 搜索请求进行中的占位动画。
///
/// 回归修复(2026-11 用户反馈): 结果还没回来时页面显示"输入关键词后搜索",
/// 容易被误读成断网/没有结果, 这里改成明确的加载态。
class SearchLoading extends StatelessWidget {
  const SearchLoading(this.keyword, {super.key});

  final String keyword;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 12),
          Text(
            keyword.isEmpty ? '正在搜索…' : '正在搜索「$keyword」…',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
