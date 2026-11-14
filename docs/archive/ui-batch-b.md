# UI 批次 B：两个缺失面板（评论可发 + 队列可看）

审计项：**P0-7.2**（评论区无「写评论」入口）、**P0-7.3**（播放队列零 UI），见 `ui-ux-audit.md:467-468`（证据行：`comment_thread.dart` 无输入框、`queue.dart:3` 纯逻辑无 UI、`main.dart:2208` 只有 `$inQueue/$total` 文本）。

- 车道范围：纯 Dart。**没有**碰 Rust / codegen / `core/**` / `ui/lib/src/rust/**`，也**没有**新增 FFI。
- 改动文件：`ui/lib/src/comment_thread.dart`、`ui/lib/src/queue.dart`、`ui/lib/main.dart`（全部在白名单内）；
  新增测试 `ui/test/comment_compose_test.dart`、`ui/test/queue_sheet_test.dart`，扩充 `ui/test/queue_test.dart`。

---

## 1. P0-7.2 评论输入（可发顶层评论）

### 1.1 FFI 复用（0 新增）

| 位置 | 内容 |
| --- | --- |
| `comment_thread.dart:26` | `typedef CommentSendHook = CommentReplyHook;` —— 直接复用既有 `CommentReplyHook`（:57 原 typedef）形态 |
| `comment_thread.dart:66` | 新注入点 `final CommentSendHook? send;`（测试可注入） |
| `comment_thread.dart:149` | `CommentSendHook get _send => widget.send ?? _reply;`（默认走既有 `rust.replyComment`，:132 的调用点） |
| `comment_thread.dart:389-432` | `_submitComment` 调 `_send(BigInt.zero, content)` |

**为什么 commentId = 0**：网易云 `comment_reply` 接口的 `commentId=0` 就是「评论整个资源」，
`core/crates/ncm-service/src/netease.rs:1517-1540` 的 `reply_comment` 原样透传 `commentId` / `threadId` / `content`，
所以顶层评论**不需要**新写 FFI 或新 provider 方法。

### 1.2 交互流程

入口：`comment_thread.dart:592` 的 `_ComposerBar`（评论区底部「✎ 写评论…」条），
点击 → `_openCompose`（:374-386）打开输入面板 `_ComposeSheet`（:1009-1125）：

1. 面板内 `TextField`（`autofocus`，minLines 1 / maxLines 4，maxLength 140）+「取消」「发送」。
2. **空文本不可发**：`_canSend`（:1031）= 未在发送中 **且** `trim()` 非空，否则 `FilledButton.onPressed == null`。
3. **发送中**：按钮禁用并换成 16dp `CircularProgressIndicator`（:1107-1119），重复点击无效。
4. **成功**：父级 `_submitComment` 已乐观插入 → 面板清空输入、`unfocus`、`Navigator.pop`。
5. **失败**：`catch` 里 `setState(_error = friendlyError(e))`（:1046-1050）——
   - 错误文案就地显示在输入框下方；
   - **保留已输入文本**（不清 controller）；
   - 「发送」按钮恢复可点 = **重试**。
6. **乐观插入 + 回滚**（:389-432）：先把 draft（`id = BigInt.zero`、昵称「我」、无头像、`timeMs = now` → 列表显示「刚刚」）插到**热评之后**（与接口「精彩评论 + 最新」的顺序一致，:368-371），总数 +1；成功后保留该条（`_snack('已发表')`）；**失败时按对象身份回滚**（`_items.indexWhere((c) => identical(c, draft))`，:415）并把异常抛回面板。
7. 乐观项 `id == 0` 还没有服务端 id → **不显示「删除」**（:558-560 的守卫），避免删错。

### 1.3 键盘避让

`_ComposeSheet` 是 `isScrollControlled` 的 bottom sheet，根节点
`Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom))`（:1059-1062），
高度随内容撑开 → 输入框与发送按钮始终贴在键盘上沿。
因为它是**独立路由**，所以从 `detail_page.showCommentsSheet` 那个 75% 高的弹层里打开也同样不被挡。

> 设计取舍（为什么入口是「点开才出现 TextField」，而不是常驻输入框）：
> ① `_RepliesSheet`（楼层回复，:782-1125 之前的一段；其 `_send` 在 :827）里已有一个 `TextField` 和「发送」按钮，
> 常驻会让 `find.byType(TextField)` / `find.text('发送')` 在既有测试里出现歧义（那些测试不在本车道白名单，不能改）；
> ② 评论区常嵌在 75% 高的弹层里，常驻输入框会被键盘压住，而弹层根节点的 viewInsets padding 在 `detail_page.dart`（禁改车道）。
> 独立输入面板把这两个问题一起解决，同时保留「底部输入区 + TextField + 发送」的完整交互。

---

## 2. P0-7.3 播放队列面板

### 2.1 `PlayQueue` 补的操作（`queue.dart`，纯逻辑）

| 行 | API | 语义 |
| --- | --- | --- |
| :136-148 | `T? removeAt(int i)` | 删除第 i 项并返回它；越界返回 null 且不改队列。下标修正：删当前项 → 由顶上来的下一首接棒（删队尾则前移到新队尾）；删当前项之前的项 → 当前下标 −1（当前曲目不变）；删空 → `index = -1`、`current = null` |
| :150-166 | `bool moveTo(int from, int to)` | 拖拽排序；**当前曲目身份不变**，下标算术修正（from 是当前 → 跟到 to；跨过当前 → ±1）；越界/原地不动返回 false |
| （既有） | `clear()` | 已有，未改 |

### 2.2 UI

| 位置 | 内容 |
| --- | --- |
| `main.dart:2384-2388` | 播放条控制行新增 `IconButton(Icons.queue_music, tooltip: '播放队列')`（第 6 个按钮，顺序在「心动模式」之后） |
| `main.dart:1668-1690` | `_openQueueSheet`：`showModalBottomSheet(isScrollControlled: true, showDragHandle: true)`；空队列直接 toast「播放队列是空的」不入面板 |
| `main.dart:2401-2588` | `PlayQueueSheet`（公开 widget，只吃 items/index/onSelect/onRemove，不碰 Rust → 可单独测）：标题「当前播放队列」+「共 N 首」、`Divider`、`ListView` |
| `main.dart:2539-2582` | 每行：`Dismissible`（左滑删）+ `ListTile`（dense/selected；当前项 `Icons.volume_up` + 主色加粗标题，其它显示序号）+ 尾部删除按钮 + `onLongPress` 删除 |
| `main.dart:2452-2477` | 长按/点删除图标 → 确认弹窗「从播放队列移除?」+ 取消/移除（防手滑误删） |
| `main.dart:2510-2522` | 空态：`播放队列是空的\n在列表里点一首歌就会入队` |

### 2.3 交互与「删除当前项」的明确行为

- **点项跳转**：`PlayQueueSheet` 先本地 `_index = i` 再 `onSelect(song)` → `_openQueueSheet` 关闭面板 →
  `_jumpToQueueSong`（`main.dart:1692-1699`）重新查下标（`indexOf`，防止别处挪动过）→ `_queue.jumpTo(i)` → `_playSong(song)`。
- **删除非当前项**：只改列表，当前下标由 `PlayQueue.removeAt` 修正，不换歌。
- **删除当前项**（`_removeFromQueue`，`main.dart:1701-1712`）：
  - 队里还有项 → 顶上来的下一首成为当前，并**立即开始播放**它；
  - 队列被删空 → `_stopAfterQueueEmpty`（:1714-1725）：`_userStopped = true` + `Playback.stop()` + toast「播放队列已清空, 播放已停止」（否则播放器会继续放一首已经从队列里消失的歌）。
- 面板内的本地列表与 `PlayQueue` 用**同一套下标修正规则**（`_removeAt`，`main.dart:2434-2450`）。

---

## 3. 新增测试清单（共 **18** 条）

### `ui/test/comment_compose_test.dart`（4 条）

| 行 | 用例 |
| --- | --- |
| :44 | 空文本不可发送：按钮禁用，**只有空白字符也不发**，回调 0 次 |
| :74 | 发送成功：`commentId == 0`、面板关闭、本地插入「我的新评论」、显示「刚刚」+ 昵称「我」、无删除入口、总数 +1 |
| :110 | 发送失败：显示 `friendlyError`（含 boom）+ **文本保留在输入框** + 乐观项已回滚（总数回到 1）+ 同一按钮重试成功 |
| :153 | 键盘 `viewInsets.bottom = 300`（400×800）时，TextField 与发送按钮的 `rect.bottom <= 500`，不被遮挡 |

### `ui/test/queue_sheet_test.dart`（6 条，用「面板 + 真 PlayQueue」的 Harness 模拟 HomePage 接线）

| 行 | 用例 |
| --- | --- |
| :84 | 打开面板渲染当前项：标题、「共 3 首」、三首齐全、当前项 `selected == true` 且有 volume_up 图标 |
| :108 | 点项切歌：回调收到「第三首」，队列 current 与高亮都切到它 |
| :123 | 删除非当前项（左滑 Dismissible）：列表移除、不换歌、下标左移 |
| :141 | 删除当前项（长按 → 确认「移除」）：顶上的下一首成为当前并被播放，不触发停播 |
| :161 | 删光队列：空态文案 + stop 被执行 + `current == null` |
| :179 | 空队列：直接空态文案，不渲染任何 `ListTile` |

### `ui/test/queue_test.dart`（新增 8 条，原有 14 条不动 → 共 22 条）

| 行 | 用例 |
| --- | --- |
| :125 | `removeAt` 删非当前项：当前曲目不变、下标左移 |
| :134 | `removeAt` 删当前项：下一首顶上；删队尾时当前前移 |
| :146 | `removeAt` 删空队列：`index = -1`、`current = null`、`next() = null` |
| :155 | `removeAt` 越界返回 null 且不改队列 |
| :163 | `moveTo` 移动当前项：当前曲目跟到新位置 |
| :172 | `moveTo` 跨过当前项时下标自动修正（两个方向） |
| :189 | `moveTo` 越界/原地不动返回 false |
| :197 | 删当前项后 `onEnded`/`next` 仍按新长度走 |

---

## 4. 门禁实测

### `cd ui && timeout 1200 dart analyze`（末次）

```
Analyzing ui...

35 issues found.        <- 全部 info（unnecessary_underscores 等），且都在其它车道的既有文件里
```

- **error = 0，warning = 0**（非 info 行只有 `Analyzing ui...` 与 `35 issues found.`）。
- 本车道改动的 3 个源文件 + 3 个测试文件**没有新增任何 info**（info 总数改动前后均为 35 条）。

### `cd ui && timeout 3600 flutter test`（全量）

```
00:08 +289 ~1: All tests passed!
```

| | passed | skip |
| --- | --- | --- |
| 本车道基线（HEAD 7727d26，另一车道 D 批次已并入） | **271** | 1 |
| 本车道完成后 | **289** | 1 |

- 差值 **+18** = 本车道新增的 18 条（4 + 6 + 8）；无既有用例被删/跳过，**没有失败**。
- 说明：任务书给的基线是 264+1；执行期间另一条车道提交了 `7727d26`（其 message 自述「271 passed + 1 skip（基线 264+1）」，新增 format_test(2) + ui_batch_d_narrow_test(5)），所以本车道实测基线是 271。两车道互不干扰，无需排除任何失败用例。

---

## 5. 未做项 / 给白名单外车道的建议（未动手）

1. **`detail_page.showCommentsSheet`（detail_page.dart:24-58）**：弹层根节点没有 viewInsets padding，评论线程整体在 75% 高的 `SizedBox` 内。本车道输入面板是独立路由所以不受影响，但**列表本身**在键盘弹出时不会上移。建议该弹层根节点加 `Padding(bottom: MediaQuery.viewInsets.bottom)`（约 2 行），属禁改文件。
2. **「写评论」也可以放在 `SheetHeader` 右侧**（审计的另一方案，`sheet_header.dart` 属禁改车道）：已有 `SheetHeader.trailing`（D 批次新增），把 `showCommentsSheet` 的 header 接上即可复用同一份面板 —— 需要把 `_ComposeSheet` 提升为公开 widget（如 `CommentComposeSheet`）才能跨文件引用，建议后续统一。
3. **队列拖拽排序**：`PlayQueue.moveTo` 已就绪并有单测，但面板里尚未接 `ReorderableListView`（与滑删的 `Dismissible` 组合需自定义 drag proxy），超出本批最小可用范围。
4. **队列面板的「清空队列」/「存为歌单」**：审计未要求；`PlayQueue.clear()` 已可用，未接入 UI（避免再扩一条播放态联动语义）。
5. **`PlayQueueSheet` 落在 `main.dart`**（白名单只给 main.dart / comment_thread.dart / queue.dart）：更合适的位置是新建 `ui/lib/src/queue_sheet.dart`（与 queue.dart 的「纯逻辑」注释不冲突）。建议后续搬出并改 import。
6. **播放条标题行的 `$inQueue/$total` 文本**仍不可点（只在同排新增了 `queue_music` 按钮）。若想让它也能开面板，一行 `InkWell` 即可（未做：标题行 411dp 挤字问题已在源码注释里写明）。
