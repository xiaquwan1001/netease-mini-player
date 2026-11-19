# M 车道 · U-04 MV 双音源并发(2026-11-18)

> 只读结论 + 落地实现 + 自验数字(全部本轮实测)。门禁数字权威在 `docs/PROGRESS.md`, 本文件是车道记录。
> 未 commit / 未改 `docs/PROGRESS.md` / 未跑 `dart format` 全仓 / 未跑 `flutter analyze`。

## 1. 最终采用的方案: **两者都做**(Dart 主动暂停 + Kotlin 音频焦点), 并补上歌曲侧焦点

三层, 从"顺滑"到"兜底":

| 层 | 位置 | 作用 |
|---|---|---|
| A 体验层 | `ui/lib/src/mv_page.dart` `_startPlayback` | 起播前真的在播才暂停歌曲; 起播失败立刻回滚; 返回后**不自动恢复**只提示一次 |
| B 兜底层 | `MvPlayerActivity` + `MvAudioFocusPolicy` | MV 自己在 onStart 申请 `AUDIOFOCUS_GAIN`, onStop/onDestroy 放弃, 失去焦点暂停 |
| C 对齐层 | `PlaybackService.buildExoPlayer` | 歌曲 ExoPlayer 打开 `handleAudioFocus = true`(之前是默认 false) |

选"两者都做"的理由(实测证据):

- **B 之前根本没有**, 而 **C 之前也是关的**: media3 1.9.4 的 `ExoPlayer$Builder` 构造函数只写
  `audioAttributes = AudioAttributes.DEFAULT`, **从不写 `handleAudioFocus`** ⇒ 取 JVM 默认 `false`。
  证据: `javap -p -c 'androidx/media3/exoplayer/ExoPlayer$Builder.class'`(从 1.9.4 的 aar 里取 classes.jar),
  构造函数字节码只有 `getstatic AudioAttributes.DEFAULT → putfield audioAttributes`, 没有 putfield handleAudioFocus;
  全仓 grep `setAudioAttributes|handleAudioFocus|AudioFocus` 在 2026-11-18 前 **0 命中**。
  ⇒ 所以"ExoPlayer 会自动暂停"这一假设**不成立**, 只做 B 的话用户从通知栏点播放就会两路又叠起来。
- 只做 A 不够: Dart 的 pause 是异步通道调用, 与 MV 起播有竞态; 且桌面/异常路径下不可靠。
- A + B + C 不会互相抖动: 三方都**只在开始播时**申请焦点(ExoPlayer 在 playWhenReady=true 时申请,
  MV 在 onStart 申请), `abandonAudioFocus` 不广播 ⇒ 谁最后起播谁出声, 不会来回抢。
  实测/代码层面能确认的是"申请时机只有这两处", 真机听感仍需用户确认(见 §5)。

**返回后是否恢复歌曲: 不自动恢复**(口径写进纯函数 `mvReturnPlan`, 带 `autoResumeEnabled` 开关可测),
返回 MV 页时给一条一次性提示「歌曲已暂停(MV 播放时不会叠音), 要接着听请点底部播放条的播放键」,
恢复入口就是常驻播放条(它一直在 Navigator 之外, 不需要新增 UI)。
不自动恢复的理由: 用户按返回多半是看完/顺手退出, 自动出声会打断他; 且不再造一个"我没让它播它自己响了"的投诉面。

## 2. 改动文件:行

Dart
- `ui/lib/src/mv_playback.dart:9-53` 纯逻辑: `mvDuckPlan` / `MvReturnPlan` / `mvReturnPlan`
- `ui/lib/src/mv_playback.dart:55-75` `MvSongGate` 抽象 + `PlaybackSongGate`(生产实现走 `Playback()` 门面)
- `ui/lib/src/mv_playback.dart:105-133` `MvPlayback.duckSong()` / `unduckSong()`(失败只记日志, 不打断播放)
- `ui/lib/src/mv_page.dart:82-131` `WidgetsBindingObserver` + `_duckedSong` + `didChangeAppLifecycleState`(后台→前台一次性提示)
- `ui/lib/src/mv_page.dart:155-175` `_startPlayback`: duck → play, 失败则 unduck + 错误文案
- `ui/test/mv_page_test.dart:68-70`, `ui/test/mv_page_comments_test.dart:14-18`: 假 playback 覆写 `duckSong`
- `ui/test/mv_song_duck_test.dart`(新, 8 例): 4 例纯逻辑 + 4 例接线/顺序/回滚/提示

Kotlin
- `ui/android/app/src/main/kotlin/com/minincm/minincm/MvAudioFocusPolicy.kt`(新): 纯决策 `actionFor(change, pausedByFocus)`
- `ui/android/app/src/main/kotlin/com/minincm/minincm/MvPlayerActivity.kt`
  - `:38-70` 焦点字段 + `focusListener`(LOSS/LOSS_TRANSIENT/CAN_DUCK→暂停, GAIN→只在"被焦点暂停过"时恢复)
  - `:147-186` `requestAudioFocus()`(API 26+ `AudioFocusRequest`, 24/25 旧接口) / `abandonAudioFocus()`
  - `:188-198` `onStart` 申请 / `onStop` 放弃; `:207` `onPause` 置 `inForeground=false`; `:219-232` `onResume` 焦点被抢时回来重新要焦点; `:243-246` `onDestroy` 放弃
- `ui/android/app/src/main/kotlin/com/minincm/minincm/PlaybackService.kt:496-514`: `setAudioAttributes(USAGE_MEDIA/AUDIO_CONTENT_TYPE_MUSIC, handleAudioFocus = true)`
- `ui/android/app/src/test/kotlin/com/minincm/minincm/MvAudioFocusPolicyTest.kt`(新, 4 例)

## 3. 自验数字(本轮实测)

- `cd ui && dart analyze` → **No issues found!**(0)
- 全量 `flutter test --exclude-tags network` → **1163 passed / 0 failed**(41s);
  本车道新增 8 例(`mv_song_duck_test.dart`), 其余用例数不变(另两条并行车道也在这棵树上, 计数含它们的变化)
- `dart format` 只跑本车道改的 5 个 Dart 文件(重排 2 个), 之后 analyze/测试重跑仍绿
- `source tools/env.sh && cd ui/android && ./gradlew :app:testDebugUnitTest :app:lintDebug`
  → BUILD SUCCESSFUL; `MvAudioFocusPolicyTest` **4/4 passed**(+ EQ 夹具 3/3), lint **0 error / 9 warning**(9 条全是既有的依赖版本提示)
- `tools/check-tokens.sh` OK; `tools/check-row-padding.sh --strict` OK(纵向 0:20 处, 6:1 处)

## 4. Kotlin 侧能测到哪

JVM 单测覆盖的是"焦点回调 → 动作"的纯映射(`MvAudioFocusPolicy`), 4 例。
**真正的焦点申请/放弃、VideoView 是否真的停声、与 Media3 的交互只能在真机上听** ——
`AudioManager`/焦点栈/音频路由都无法在 JVM 或模拟器上判定"有没有双声"(模拟器出声也听不到设备混音)。

## 5. 需要用户真机确认的 3 步

1. 播一首歌(确认在响) → 进任意 MV 详情页 → 点「播放」: 应**只剩 MV 声**, 且回到 MV 页前别按手机音量键对比(先听 3 秒)。
2. 在 MV 全屏按返回: 歌声**不会**自动回来(这是本次口径), 详情页底部弹一条「歌曲已暂停…要接着听请点底部播放条的播放键」; 点播放条播放键应立刻续播。
3. 反向验焦点: 播放条放歌 → 打开 MV → 在 MV 播放中从**通知栏**点播放 → 预期被 MV 抢回的焦点压停(MV 停声), 再按返回后点播放条续歌; 全程不应出现两路同时响。

## 6. 已知风险(未验证)

- **蓝牙/耳机**: A2DP 场景焦点行为一致, 但"MV 用听筒路由 / AVRCP 上一首下一首打给歌曲"未验证。
- 打开 `handleAudioFocus = true` 是**全量行为变更**: 来电/其他 App 抢焦点时歌曲会自动暂停
  (transient 丢失后系统回 GAIN 时会自行续播; 永久丢失则不续播)。理论上与"以前完全不响应"相比是修好不是改坏,
  但它改变了所有用户的播放路径, 需要在真机上顺带确认: 接电话后能自动续、其他音乐 App 起播时我们静音。
- 用户在 MV 播放期间手动点播放条续播: 歌曲会抢回焦点、MV 暂停(这是"最后起播者胜"的必然结果, 不是抖动); 是否符合预期待用户判断。
- 模拟器上焦点栈与真机略有差异, 以上全部以真机为准。
