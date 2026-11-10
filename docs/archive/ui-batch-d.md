# UI 批次 D：技术债收敛（执行报告）

> 执行基线：批次 D 开工时工作区（含另一车道在途改动，未 commit）。
> 范围：纯 Dart；未触碰 core/**、rust/**、构建脚本与任何禁改文件。

## 结论

- dart analyze：**0 error / 0 warning**（33 条 info 均为存量，我新增代码 0 条）。
- flutter test：**271 passed + 1 skipped, All tests passed!**（基线 264+1，净增 7 条，无一减少）。
- 净删 **98 行**（86 insertions / 184 deletions，不含新建文件）。

## 1. 死代码删除（P2-7.28）— **保留，未删**

验证命令与输出（开工时执行）：

    rg -n 'ProgramDetailSheet|ProgramDetailLoader|podcast\.dart' ui/lib ui/test
    → ui/test/program_detail_test.dart:3,81,99,121,138   （测试真实使用）
    → ui/test/podcast_test.dart:3
    → lib/src/detail_page.dart:10   import 'podcast.dart' show ProgramDetailSheet, ProgramDetailLoader;
    → lib/src/detail_page.dart:1016 builder: (_) => ProgramDetailSheet(...)

审计判定"生产零调用"已过时：**歌单/电台详情页的"单集详情"弹层正真实引用 ProgramDetailSheet**，
按任务规则"任何一处真实引用就保留并报告"。因此 podcast.dart 全量保留（653 行），
只做无害化收敛（时长格式化、头部写法，见下）。

## 2. 公共格式化（P2-7.23）

新建 ui/lib/src/format.dart：formatDurationMs(BigInt ms)（mm:ss / h:mm:ss，与原 4 份口径一致）。

- 迁移 4 份私有 _fmtDuration：detail_page / artist_page / radio_explore_page / podcast（共 6 个调用点，删 4 份实现 ≈52 行）。
- **未动** song_tile.dart 的 formatSongDuration（另一车道，测试锁定）；format.dart 注释里列为后续收编项（口径不同：定长 04:05）。
- 未迁：new_release_page _duration（分钟级变体：0 时返回空串、分钟不补零，改了会变口径）；main.dart _fmt（禁改）。两者列为后续收编项。

新增 test/format_test.dart（2 条）。

## 3. 错误态视图（P2-7.21）

新建 ui/lib/src/error_views.dart：InlineError（行内文案+重试）/ FullError（居中文案+主按钮重试），视觉逐像素复刻原实现。

- 迁移 3 页：mine_view（1 处）、style_page（2 处）、discover（4 处）；删 3 份私有实现 ≈70 行。
- 未迁：recommend_view / vip_page（禁改/白名单外）、podcast _RetryView（保留原因见 §1，结构与 FullError 不同，列后续收编）、album_preview 带图标行内错误条（视觉独有，保留）。

## 4. 统一 SnackBar（P2-7.22）

新建 ui/lib/src/toast.dart：showToast(context, msg, {isError}) + showToastWith(messenger, …)（弹层 pop 后用，避免 context 失效；isError 用 error 底色）。

- 迁移 **10 个调用点**：detail_page ×4（_toast、分享三连）、mine_view ×2（签到成功/失败）、style_page ×1、discover ×2（不感兴趣）、song_actions ×1。
- 未迁（禁改/白名单外）：comment_thread、user_list_page、recommend_view、feed_detail_page、radio_subscribers_page、main.dart（_toast）。

## 5. 弹层统一标题/关闭（P2-7.24）

- sheet_header.dart 增加可选 trailing 槽（供加载小圈），无关闭键时补对称边距。
- podcast.dart 节目详情自绘头部 Row → SheetHeader(title, trailing, onClose)。
- 补 showDragHandle: true ×8：detail_page ×3（评论/单集详情/分享）、podcast ×2、discover ×2（每日推荐/最近听过）、song_actions ×1。
- 未迁：main.dart 三处（账号/收藏到歌单/分享，禁改）、similar_sheet / song_wiki / messages_page 等白名单外文件。

## 6. 300dp + 1.25 回归（P2-7.31）+ 底部 safeArea（P1-7.15）

新增 test/ui_batch_d_narrow_test.dart，给此前未覆盖的 5 个页面各补 1 条"300×640 + textScale 1.25 不溢出"用例：
**每日推荐 sheet、新歌速递/新碟上架、已购数字专辑、我的页(登录态)、关注动态**。

P1-7.15 底部 safeArea：4 个白名单全页滚动容器 bottom padding 改为 24 + MediaQuery.viewPaddingOf(context).bottom：
artist_page、radio_explore_page、settings_view、digital_album_page；new_release_page 用 SafeArea(top:false) 包 TabBarView（其 padding 在横滑条上不可改）。

## 门禁实测输出

    $ dart analyze
    33 issues found.   ← 全部 info（存量）；grep -E " error | warning " 计 0

    $ flutter test（全量）
    00:07 +271 ~1: All tests passed!

无指向 main.dart / comment_thread.dart / queue.dart 的失败，无需点名排除。

## 未做项与原因

| 项 | 原因 |
|---|---|
| 删 podcast.dart | 有真实引用（detail_page + 2 个测试），按规则保留 |
| P1-7.16 播放条收单行 | 在 main.dart（禁改），且成本 L |
| P1-7.18 分页自动加载 | 三个分页列表全在禁改/白名单外文件 |
| P2-7.21/7.22/7.24 剩余收敛点 | recommend/vip/podcast/main 等见上文各节 |
| 300dp 覆盖全量 45 文件 | 按任务只补 5 个最易溢出页 |
