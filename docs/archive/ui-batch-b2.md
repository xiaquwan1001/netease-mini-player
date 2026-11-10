# 批次 B2：评论弹层键盘遮挡修复（2026-xx）

## 做了什么

- `ui/lib/src/detail_page.dart` `showCommentsSheet`：弹层 builder 根节点包上
  `Padding(padding: EdgeInsets.only(bottom: viewInsets.bottom))`，同时把面板高度从
  固定 `75% 屏高` 改为 `max(200, 75% 屏高 - insets.bottom)`（新增 `dart:math` 导入）。
  效果：键盘弹出时弹层整体坐在键盘上、输入面板/发送按钮不被压住、列表可滚到最新评论；
  收起键盘后 padding 归零、高度回弹到 75%，不留白。已有 `isScrollControlled: true` 保留。
- 为测试可注入，给 `showCommentsSheet` 增加可选 hook 参数
  （loadPage/like/loadReplies/send，透传给 `CommentThread`，不传走 rust，行为不变）。
- 未动白名单外任何文件；未碰 Rust/codegen/构建脚本。

## 为什么

审计/批次 B 遗留项①：写评论面板（_ComposeSheet）自身已做 viewInsets 避让，但承载它的
`showModalBottomSheet` 根节点没做，键盘弹出时评论列表整体被挡。

## 测试

新增 `ui/test/ui_batch_b2_keyboard_test.dart`（4 例，模拟键盘 FakeViewPadding(bottom:300)）：

1. 键盘弹出时根节点 padding = 300、面板高度压到 300、弹层底贴键盘顶(500)；
2. 键盘弹出时点开输入面板，TextField/发送按钮都在可视区内（bottom ≤ 500）；
3. 键盘弹出时列表可 scrollUntilVisible 到最新评论（评论12）；
4. 键盘收起后 padding 归零、高度回弹 600、弹层底回贴屏幕底(800)，无留白。

## 门禁输出

- `dart analyze`：error/warning = 0（仅存量 info）。
- `flutter test` 全量：**293 passed + 1 skip**（基线 289 + 1 skip，新增 4，零失败）。
