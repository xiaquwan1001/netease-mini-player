import 'package:flutter/material.dart';

import 'search_controller.dart' as search_state;

/// 首页的**搜索输入条**(拆 `home_page.dart` §7.7 第二刀)。
///
/// 搬的是什么(逐行等价搬运: 同一个 [TextField] 属性顺序、同一个 suffix 清空
/// 判定、同一个「搜索中」按钮态):
/// - [build](原 `_buildSearchBar`): 输入框(标签/边框/清空按钮/提交动作)+
///   右侧「搜索」按钮; 不再并排放「取消」(与清空 suffix 同义, 见 P1-7.4)。
///
/// 边界(为什么能搬):
/// - **不持有状态**: 输入文本与焦点仍由页面持有(本类只收引用), 结果/联想/
///   忙碌标志在 [search_state.SearchController] —— 这里只按它的既有方法接线
///   (`onQueryChanged` / `search` / `clear` / `busy`);
/// - 搜索失败横幅/联想面板/落地页仍是页面的 `_buildPage` 结构, 不在本文件。
class HomeSearchBarHost {
  HomeSearchBarHost({
    required this.controller,
    required this.focusNode,
    required this.search,
  });

  /// 输入框的文本控制器(页面持有, 与 `SearchController` 共用)
  final TextEditingController controller;

  /// 输入焦点(页面持有; 切 tab 时由页面 unfocus)
  final FocusNode focusNode;

  /// 搜索状态机(结果/忙碌标志/清空/提交)
  final search_state.SearchController search;

  Widget build() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              decoration: InputDecoration(
                labelText: '搜索',
                border: const OutlineInputBorder(),
                isDense: true,
                // 输入过东西或已有结果时给一个显式的清空按钮
                suffixIcon: (controller.text.isEmpty && search.bundle == null)
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: search.clear,
                      ),
              ),
              textInputAction: TextInputAction.search,
              onChanged: search.onQueryChanged,
              onSubmitted: (_) => search.search(),
            ),
          ),
          const SizedBox(width: 8),
          // 不再并排放「取消」: 它与输入框里的清空 suffix 是同一个动作
          // (search.clear), 两个同义按钮只会让人不知道该按哪个(审查 P1-7.4)
          FilledButton(
            onPressed: search.busy ? null : search.search,
            child: Text(search.busy ? '搜索中' : '搜索'),
          ),
        ],
      ),
    );
  }
}
