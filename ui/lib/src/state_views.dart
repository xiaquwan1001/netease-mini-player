/// 统一的「进行中 / 无内容」状态视图, 与 `error_views.dart` 的错误态并列。
///
/// 收敛前全仓有 26 个文件各自手写 `Center(child: CircularProgressIndicator())`,
/// 空态文案也散落在 9 个文件各写各的。这里给一套唯一实现:
/// - [LoadingView]: 加载中(页面级居中 + 可选说明; [LoadingView.inline] 给按钮/行尾);
/// - [EmptyView]: 空态(图标 / 标题 / 提示 / 可选按钮)。
///
/// 除 `search_loading.dart`(带关键词的搜索占位薄封装)与本文件外,
/// `CircularProgressIndicator` 不应再出现在别处。
library;

import 'package:flutter/material.dart';

/// 加载中占位。
///
/// 默认形态是页面/区块级: `Center` + 可选一行说明文字。
/// [size] 非空时用固定见方的指示器(小 spinner 场景), 仍保持居中;
/// 若是按钮内/行尾这种由父布局负责摆放的窄位置, 改用 [LoadingView.inline]。
class LoadingView extends StatelessWidget {
  const LoadingView({
    super.key,
    this.message,
    this.size,
    this.padding,
    this.strokeWidth,
    this.color,
  }) : inline = false;

  /// 行内小 spinner: 只占 [size] 见方, 不插入居中容器,
  /// 用于按钮 loading 态 / ListTile trailing / 图标位替换。
  const LoadingView.inline({
    super.key,
    double this.size = 16,
    double this.strokeWidth = 2,
    this.color,
  }) : message = null,
       padding = null,
       inline = true;

  /// 指示器下方的一行说明(如「正在搜索…」), null 则不显示。
  final String? message;

  /// 指示器边长; null 用 [CircularProgressIndicator] 的默认尺寸。
  final double? size;

  /// 留白(页面级形态生效), 如列表底部那种 `vertical: 20`。
  final EdgeInsetsGeometry? padding;

  /// 线宽; 未指定时, 固定尺寸的小 spinner 用 2, 默认尺寸用 SDK 默认值。
  final double? strokeWidth;

  /// 指示器颜色(深色封面上的保存按钮等需要显式给白)。
  final Color? color;

  final bool inline;

  @override
  Widget build(BuildContext context) {
    final size = this.size;
    final indicator = size == null
        ? CircularProgressIndicator(strokeWidth: strokeWidth, color: color)
        : SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              strokeWidth: strokeWidth ?? 2,
              color: color,
            ),
          );

    if (inline) return indicator;

    final message = this.message;
    return Center(
      child: Padding(
        padding: padding ?? EdgeInsets.zero,
        child: message == null
            ? indicator
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  indicator,
                  const SizedBox(height: 12),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
      ),
    );
  }
}

/// 空态占位: 图标 / 标题 / 提示 / 可选按钮, 统一各页列表为空时的视觉。
///
/// 标题文案由调用方给, 组件不替调用方改口径。
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    this.icon,
    required this.title,
    this.hint,
    this.action,
    this.padding,
  });

  /// 顶部图标; null 则不占位(纯文案空态)。
  final IconData? icon;

  /// 主文案(必填)。
  final String title;

  /// 次级提示, 用于「怎么才会有内容」这类补充说明。
  final String? hint;

  /// 可选操作按钮(如「去登录」)。
  final Widget? action;

  /// 留白, 默认 [EdgeInsets.all] 24。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final icon = this.icon;
    final hint = this.hint;
    final action = this.action;
    return Center(
      // 可滚包装: 空态常被塞进很矮的 Tab/卡片槽位(测试里出现过 18dp 高的约束),
      // 用 SingleChildScrollView 兜住, 避免 RenderFlex overflow。
      child: SingleChildScrollView(
        padding: padding ?? const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 40, color: muted),
              const SizedBox(height: 12),
            ],
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action],
          ],
        ),
      ),
    );
  }
}
