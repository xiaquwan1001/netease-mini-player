# P-10 方案 B: 渐进播放期 seek(待跳登记 + 换源重建解码器)

> 车道 `lane/p10-seek`, 基于 main `a883f6f`。用户 2026-11-17 拍板: 方案 B 直接做,
> 允许改播放引擎结构 / 新增 FFI 状态。听感与 UI 细节由用户最后微调。

## 1. 现状判定(动手前实测)

| 事实 | 位置 |
|---|---|
| 渐进播放用 `Decoder::builder().with_seekable(false)`, `try_seek` 必失败 | `lib.rs` `Cmd::Play` 的 `PlaySource::Growing` 分支 |
| 失败被如实回传(方案 A 已落), 但只有"拒绝"一条路: UI 只能禁进度条 | `check_seek` / `PlayerState::seekable` |
| `EqSource` 包装层已把 `try_seek` 透传给内层(否则连落盘文件都跳不动) | `EqSource::try_seek` |
| 渐进下载完成后 `.part` 被 rename 成正式缓存文件, `done` 在 rename **之后**置位 | `ncm-service/src/cache.rs` `download_progressive` |
| 老毛病: 同一首歌下载完成后, 播放线程仍开着**旧的**非 seekable 解码器, 必须重播一次才能 seek | 同上(本次修掉) |
| `ProgressiveFetch.final_path` 早就有值, 但 FFI 只把 `part_path` 传给播放线程 | `ncm-ffi/src/api.rs` `play_track` |
| `Player::new()` 不需要声卡即可构造, 手工从 `SourcesQueueOutput` 抽样本就能让 rodio 的暂停/位置计数/队列切换真的跑起来 | 本次测试方案 |

结论: 缺的不是"能不能重建解码器", 而是①播放线程不知道完整文件在哪、②没有"待跳"这个状态、
③换源后位置怎么算没人管。三件事都在 `ncm-playback` 内部可闭合, 不需要动 service 层。

## 2. 方案(已实现)

新增的语义分层:

```
SourceStatus = Seekable | Growing | GrowingComplete(path) | GrowingFailed
        ↑ resolve_source_status(&PlaySource): File⇒Seekable; Growing 看 done + 完整文件是否存在

SeekPlanner::request(status, target):
    Seekable        ⇒ SeekAction::Direct(target)     // 老路径: rodio try_seek
    Growing         ⇒ SeekAction::Queue(target)      // 登记待跳, 回 SeekOutcome::Queued
    GrowingComplete ⇒ SeekAction::Rebuild(target)    // 换源重建后再跳
    GrowingFailed   ⇒ Err(Unsupported)               // 只有这时才如实报错
```

播放线程(`backend::run`)新增:

- `current: Option<CurrentTrack>` 记住当前曲目的**来源**(路径 / `final_path` / `done`), 换曲或
  stop 时清空;
- `planner: SeekPlanner` 保存待跳位置, 每个 tick 检查一次: 下载完成 → `apply_rebuild` 应用;
  每条待跳**只尝试一次**(失败写 `seek_error` 后清掉, 避免每个 tick 反复重建变成爆音源);
- `pos_base_ms`: 换源时新解码器是**先 seek 到目标再追加**的, rodio 的相对位置从 0 开始,
  所以基准由这里补回。其它路径(开播 / 直接 seek)基准恒为 0, 让 rodio 自己算。

换源(`upgrade_to_complete`)的顺序是刻意的:

1. **先**在旁路上验证"完整文件能打开 + 能 seek 到目标", 失败直接返回, 正在播的源一个字节都不动;
2. 记下播放/暂停态, `player.clear()`(它顺带会 pause), 追加新源后恢复;
3. 新源用 **25ms 淡入** 盖住波形不连续(消爆音);
4. 位置/时长/音量/EQ 链沿用: 位置 = 待跳位置, 时长改用完整文件算出的真值,
   音量在 rodio 的 controls 上(不受 clear 影响), EQ 链按新源的采样率/声道重建;
5. 成功后把 `current.source` 升级成 `PlaySource::File(完整文件)` —— 后续 seek 直接 `try_seek`,
   **同一首歌下载完成后不再需要重播一次才能 seek**。

FFI / UI 契约(只加字段, 不动手写 Dart):

- `PlayerState::pending_seek_ms` / `PlayerStateDto.pending_seek_ms`(Option<u64>): 已排队的待跳位置,
  `null` = 没有挂起的跳转。UI(另一条车道)可据此显示「已排队, 缓存完成后自动跳转」。
- `Player::seek` 返回值从 `Result<(), _>` 变成 `Result<SeekOutcome, _>`, `SeekOutcome = Applied | Queued`。
- `Player::play_stream` 多一个 `final_path` 参数(`ncm-ffi` 传 `ProgressiveFetch.final_path`)。

## 3. 测试覆盖(全部离线, 不依赖网络/声卡)

| 验收点 | 测试 |
|---|---|
| ① 待跳登记后"已排队"而非失败 | `tests::seek_planner_queues_growing_and_directs_seekable` |
| ② 下载完成切换后位置 == pending | `backend::growing_tests::upgrade_applies_pending_position_and_keeps_playing`(还断言换源后**立刻有声**, 证明解码器真从待跳位置开始) |
| ③ 切换不丢播放状态 | 同上 + `upgrade_preserves_paused_state` |
| ④ 无 pending 时行为不变 | planner 的 `Seekable ⇒ Direct` 分支 + `resolve_source_status` 对 `PlaySource::File` 恒 `Seekable` |
| 换源失败不打断当前播放 | `upgrade_keeps_current_source_when_complete_file_is_unusable` |
| 下载失败不能假装排队 | `seek_planner_...` 的 `GrowingFailed ⇒ Unsupported` |

## 4. 未做 / 交给后续

- 桌面**听感**冒烟(真机声卡上是否有可闻接缝): 单测证明了"无爆音"靠 25ms 淡入,
  但实际听感要用户耳朵确认; `SWAP_FADE` 是常量, 想调直接改。
- UI 侧显示「已排队」的文案与交互: 属 `ui/lib` 手写 Dart, 本轮按车道约束不动。
- Windows 仍走"下完再播"(`#[cfg(windows)]` 分支), 不经过渐进路径, 行为不变。
