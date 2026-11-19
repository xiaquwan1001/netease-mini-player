# N4 · 定时关闭(睡眠定时)— 2026-11-18

## 交付

| 文件 | 内容 |
|---|---|
| `ui/lib/src/sleep_timer.dart`(新) | 纯逻辑状态机 `SleepTimer`(ChangeNotifier)+ `SleepTimerMode`(immediate / finishCurrentSong)+ 固定档位 `kSleepTimerPresets = [15,30,45,60,90]` + 剩余时间文案纯函数 `sleepTimerRemainingLabel` + 生产单例 `sleepTimer` |
| `ui/lib/src/settings_sleep_timer_page.dart`(新) | 自包含设置二级页「定时关闭」: 停法分段控件 / 五个时长档 / 当前状态(还剩 mm:ss、等本曲播完、未开启、已到点)+ 取消按钮 |
| `ui/lib/src/settings_view.dart` | 「播放与音质」卡里加一行「定时关闭」入口(单行 ListTile, 无副标题) |
| `ui/lib/src/home/playback_coordinator.dart` | 新增可选 `sleepTimer` 参数; `poll()` 里 `onPlaybackTick(playing:)`(复用既有 500ms 轮询, **不新起轮询**); `_onTrackEnded()` 里 `onTrackEnded()`, 已到点(fired)时不续播下一首 |
| `ui/lib/src/home/home_page.dart` | 注入 `sleepTimer` 单例 + 到点动作 `_onSleepTimerExpired`(停播放 → Android `SystemNavigator.pop` / Linux `DesktopShell.quit` / Windows `exit(0)`); dispose 摘掉回调 |
| `ui/test/sleep_timer_test.dart`(新) | 10 例: 立刻停只触发一次 / 播完这首(到点在播不触发·曲末触发) / 已暂停直接触发 / 取消后不触发 / 改档重置 / 切停法重置 / 文案 / 档位顺序 / 页面 300dp+1.25 不溢出+选档+取消 / 设置页入口点击进页 |

## 口径决策(写进代码注释)

- **档位固定 15/30/45/60/90**: 用户场景是「听完这段/准备睡」, 固定档一眼可选; 自定义时长要滚轮或输入框, 300dp+大字号下还要处理宽度与校验, 收益不抵成本。
- **不跨重启**: 定时只活在当前进程, 不落盘(关掉应用还留着倒计时只会误杀下一次播放)。
- **改档 = 重新计时**: 任何 `start` 都把截止时间重置为「现在 + 档位」; 已开启时切停法也按改档重置。
- **到点动作注入**: 纯逻辑只回调 `onExpire`, 平台 API 全在 home_page 的注入实现里(单测零平台调用)。
- **接线复用既有通道**: 「当前歌播完」走 `PlaybackCoordinator` 已有的 `_onTrackEnded`(原生 trackEnded + 500ms 播完兜底共用临界区), 不另起一套判定。

## 验证(本机实测)

- `cd ui && dart analyze` → **No issues found**。
- `flutter test test/sleep_timer_test.dart` → **10 通过**。
- 全量 `flutter test --exclude-tags network` → **1200 通过 / 0 失败**(基线 1163 + 本车道 10 + 同树其它车道新增; golden 18 张未重出)。
- `dart format`(仅本车道文件)、`check-tokens.sh --strict`、`check-row-padding.sh --strict` 全 OK。

## 注意(给编排者)

- 设置页总高度敏感: `update_checker_test` 的「300dp + 1.25 字号」用例在 300×2800 视口里靠 ListView 缓存区刚刚够到「关于」卡。本车道入口最初带副标题(2 行)时把「检查更新」挤出缓存 ⇒ 该用例红; 改成**单行入口**后恢复绿(当前余量约 65px)。后续车道再往设置页加行(尤其带副标题)时, 很可能会再撞这条 —— 正确修法是让该用例 `scrollUntilVisible`, 不要靠删功能腾高度。
- 未做(按边界): 常驻倒计时浮层、跨重启恢复、Rust/FFI 改动。Kotlin 未改: Android 侧「停服务」用既有 `ncm/player#stop`(c.stop + 清空 MediaItem)后 `SystemNavigator.pop` 结束界面。
