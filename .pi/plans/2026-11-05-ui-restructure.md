# 轻音 MiniNCM · UI 重构批次（2026-11-05）

需求来源：用户在模拟器验收后提出 6 项。

## 任务分解

| # | 需求 | 落地位置 | 依赖 | 状态 |
|---|---|---|---|---|
| 1 | 推荐页顶部快捷卡「最近听过」→「私人FM」；删除下方重复的 私人FM / 心动模式 区块 | ui/lib/src/recommend_view.dart | 无 | Lane A |
| 4 | 顶栏删除 收藏歌单图标 / VIP 标识 / 推荐(发现)菜单，只留账号按钮 | ui/lib/main.dart | 无 | Lane A |
| 6 | 「最近听过」搬到「我的」栏目（含查看全部） | ui/lib/src/mine_view.dart + main.dart | 无 | Lane A |
| 3 | 「我喜欢的音乐」右侧加「查看全部」→ 歌单详情页；详情页内可搜歌；若当前队列正是该歌单，提供「定位正在播放」 | 新 ui/lib/src/playlist_detail.dart + main.dart | Rust: playlist_detail | Lane B |
| 5 | 点歌单/播客进详情页：浏览曲目、搜歌、封面、简介、转发/收藏、评论 | 同上 + podcast 详情 | Rust: comments / share / playlist_subscribe / podcast_radio | Lane B |
| 2 | 模拟器窗口被 Ubuntu 判定"无响应" | 环境配置（非代码） | — | 已诊断 |

## 任务 2 结论（诊断）

- 弹窗来自 **mutter 的挂起检测**：GNOME 用 `_NET_WM_PING` 探活 X11/XWayland 客户端，
  门限是 `org.gnome.mutter check-alive-timeout`（本机 = **5000 ms**，schema 描述原文：
  「为了不被检测为冻结，客户端必须响应 ping 请求的毫秒数。使用 0 将完全禁用活动检测。」）。
- 模拟器 GUI 是 `qemu-system-x86_64` 的 Qt/XWayland 窗口（128 线程），VM 本身跑在独立线程，
  所以"判定无响应"时 adb/播放/截图全都正常 —— 与用户观感一致。
- 实测（本机）：GUI 主线程在空载、连续滑动注入、反复 resize 场景下 wchan 基本恒为
  `poll_schedule_timeout`（事件循环在线），最长非 poll 停留 0.03–0.06 s；
  X 连接接收队列 Recv-Q 稳定在 0–40 字节（客户端在读事件）。
  ⇒ 常态是健康的，判定只发生在偶发的长阻塞时刻（快照保存/载入、GPU present 阻塞、host GPU 抖动）。
- 处置：`gsettings set org.gnome.mutter check-alive-timeout 0`（彻底关掉探活弹窗，mutter 启动时读该值，
  需重新登录生效；`gsettings reset` 可恢复默认 5000）。agent 侧日常用 `~/bin/avd headless a36` 无窗口跑，
  根本不会触发该弹窗。

## 层间契约（Lane B 依赖）

Rust → Dart 新增（`ui/lib/src/rust/api.dart` 由 codegen 生成）：

- `playlistDetail(playlistId: u64) -> PlaylistDetailDto`
  {id,name,coverUrl,description,creatorName,trackCount,playCount,subscribed,subscribedCount,shareCount,commentCount,tags}
- `setPlaylistSubscribed(playlistId, subscribed) -> bool`
- `comments(kind: song|playlist|album|podcast, resourceId, limit, offset) -> CommentPageDto`
  {comments[{id,userName,avatarUrl,content,timeMs,likedCount,liked}], total, hasMore}
- `shareResource(kind, resourceId, msg) -> bool`
- `podcastRadio(radioId) -> PodcastRadioDto`

## 验证路径

`cargo test` → `cargo build -p ncm_ffi` → codegen → `flutter analyze` → `flutter test` →
`bash tools/build-android.sh` → `adb install -r -t` → a36 截图逐项核对。
