# plans-2026-11 —— 车道执行记录归档(2026-11-13 ~ 11-19)

这里原本是本地 `.pi/plans/`(gitignore, 属个人工作区)的**车道任务书 / 执行记录**。
2026-11-19 文档精简时整批迁进 `docs/archive/` **留档不删正文**:每一份对应的落地提交都已在 `release/v0.26.x` 上
(git log 逐条核对过),正文只用于回答「当时怎么切的、验收怎么定的、踩了什么坑」。
**现状与结论层不在这些文件里**:进度见 [`../../PROGRESS.md`](../../PROGRESS.md),
待办见 [`../../remaining-batches.md`](../../remaining-batches.md),机制/坑见 `.pi/memory/*.md`。

> 口径:下表「落地提交」= 该任务书产出(或最终收口)的 commit;标「审计/调研」的是只读产出,已被后续实现消费。

| 文件 | 一句话 | 落地提交 |
|---|---|---|
| [HANDOFF-2026-11-19.md](HANDOFF-2026-11-19.md) | 隔夜交接(写「wip/2026-11-18-night 在飞、未 push」)—— **已作废**,三条车道全部合并 | `f067c4d` · `8528900` · `1a40332` |
| [2026-11-18-next-batch.md](2026-11-18-next-batch.md) | 2026-11-18 批次拆解:反馈批 D/E/F/G + 结构性 H 批 + 三条只读审计车道 | `7ca7185` 等(逐条在 PROGRESS 2026-11-18 各小节) |
| [2026-11-13-ui-consolidation.md](2026-11-13-ui-consolidation.md) | UI/API 整合改造方案(用户 10 条反馈的根因与改法) | v0.9.x 批 + 拆壳收口 `30a8085` |
| [arch-audit-backend-2026-11-15.md](arch-audit-backend-2026-11-15.md) | 后端结构债务审计(审计/调研) | `77a7bcd` · `ca8b5c4`(§12 主体已清) |
| [arch-audit-frontend-2026-11-15.md](arch-audit-frontend-2026-11-15.md) | 前端结构审计 6/6 节(审计/调研) | `54af147` 收口(浮层入口统一) |
| [arch-audit-platform-2026-11-16.md](arch-audit-platform-2026-11-16.md) | 平台层审计 22 条(P1×6/P2×11/P3×5) | 21 条:`00f1381` `c57a845` `eada22d` `49c62d0` `02a3328`;余 2 条需真机 |
| [arch-audit-ui-overlay-2026-11-18.md](arch-audit-ui-overlay-2026-11-18.md) | UI 浮层/返回栈/生命周期审计 13 条 | `ae1371d` · `54af147` · `c71e0ba` · `ef0be4c` |
| [arch-slim-2026-11-15.md](arch-slim-2026-11-15.md) | 仓库精简建议(main.dart 拆壳 / PROGRESS 拆分) | `30a8085`(S8-3) · `a3f6d0e`(PROGRESS 1212→517) |
| [deadcode-audit-2026-11-18.md](deadcode-audit-2026-11-18.md) | 死代码审计(148 Dart 源 / 72 Rust 文件 / 7 Kotlin) | `7ca7185` · `0ebbe2c` · `1cf2a6f` |
| [deadcode-cleanup-2026-11-18.md](deadcode-cleanup-2026-11-18.md) | 死码清账执行记录(复核命令与输出) | `7ca7185`(51 行) |
| [i-lane-ffi-dead-exports-2026-11-18.md](i-lane-ffi-dead-exports-2026-11-18.md) | FFI 真死导出清理(161→158) | `0ebbe2c` |
| [lane-j-deadcode-symbols-2026-11-18.md](lane-j-deadcode-symbols-2026-11-18.md) | 仅测试引用的公开符号清理 | `1cf2a6f` |
| [mv-audio-focus-2026-11-18.md](mv-audio-focus-2026-11-18.md) | MV 与歌曲双音源抢音频焦点 | `ef0be4c` |
| [n1-eq-2026-11-18.md](n1-eq-2026-11-18.md) | EQ 导入先走 Rust 校验 + 曲线高度 | `a0f9427` |
| [n3-linux-tray-playback-2026-11-18.md](n3-linux-tray-playback-2026-11-18.md) | Linux 托盘播放控制(播/暂·上下曲·喜欢) | `02a3328` |
| [n4-sleep-timer-2026-11-18.md](n4-sleep-timer-2026-11-18.md) | 定时关闭(立刻 / 播完这首) | `02a3328` |
| [p1-player-bar-index-2026-11-18.md](p1-player-bar-index-2026-11-18.md) | 桌面播放条不再显示队列排位 N/M | `6e056a3` |
| [p2-feed-2026-11-18.md](p2-feed-2026-11-18.md) | feed 顶部横条按宽自适应 + 点击语义统一 + 刷新合并 | `149f277` |
| [p3-appimage-smoke-2026-11-18.md](p3-appimage-smoke-2026-11-18.md) | AppImage 冒烟固化脚本(39 项静态资产 + 运行期) | `6ac2915` |
| [p4-two-column-s0s1-2026-11-18.md](p4-two-column-s0s1-2026-11-18.md) | 横屏双列 S0+S1(`twoColumnFor` + 歌单详情三栏) | `7f4e546` |
| [player-bar-tiers-2026-11-18.md](player-bar-tiers-2026-11-18.md) | 播放条三档文案(竖屏只留封面 icon) | `8869239` |
| [q1-two-column-s2s3-2026-11-18.md](q1-two-column-s2s3-2026-11-18.md) | 双列 S2(播客详情)落地 / S3(我的)判不做 | `6b0b08d` |
| [q2-app-sheet-2026-11-18.md](q2-app-sheet-2026-11-18.md) | 统一浮层入口 `showAppSheet`/`showAppDialog`(U-03) | `54af147` |
| [q3-lifecycle-guards-2026-11-18.md](q3-lifecycle-guards-2026-11-18.md) | 生命周期守卫 U-05/U-06/U-07 | `c71e0ba` |
| [source-acquisition-research-2026-11-18.md](source-acquisition-research-2026-11-18.md) | 音源获取方案调研(A 采纳 / B·C 不采纳) | `8528900`(方案 A) |
| [t1-source-plan-a-2026-11-18.md](t1-source-plan-a-2026-11-18.md) | 音源信息无损(方案 A)+ 播放条来源第二行 | `8528900` · `f067c4d` |
| [t2-buffering-download-2026-11-18.md](t2-buffering-download-2026-11-18.md) | 缓冲/下载加固 + 缓存键带 level | `f067c4d` |
| [t3-app-sheet-batch2-2026-11-18.md](t3-app-sheet-batch2-2026-11-18.md) | 浮层入口第二批 7 处收口 + 详情页歌词⇄封面 | `1a40332` |
| [tab-switch-popups-2026-11-18.md](tab-switch-popups-2026-11-18.md) | 切 tab 收起全部浮层(U-01)+ 队列面板 close 不误关(U-02) | `ae1371d` |
| [ui-adaptive-layout-2026-11-18.md](ui-adaptive-layout-2026-11-18.md) | 横屏/宽屏三档响应式(断点 + 限宽 + NavigationRail) | `d4075a9` |
| [wide-two-column-eval-2026-11-18.md](wide-two-column-eval-2026-11-18.md) | 横屏双列布局评估(方案 A「页内双列」被采纳) | `7f4e546` · `6b0b08d` |

## 仍在 `.pi/plans/archive/` 的两份(未随本批迁移)

`2026-11-05-ui-restructure.md`、`2026-11-06-feature-pack.md` 是 v1 时代的计划, 2026-11-10 就已归档在
`.pi/plans/archive/`(gitignore), 属个人工作区存档, 不随本批进仓库。
