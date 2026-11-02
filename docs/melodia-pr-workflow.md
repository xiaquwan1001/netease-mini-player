# 给 Melodia 提 PR 的工作流(2026-11-02)

> 结论先行:功能/修复 PR **一律进 `dev`**;本地副本必须从 `dev` 切分支;
> 真机验证用 `.gaintest` 后缀并存安装,不要卸载用户正式版。

## 1. 分支与远端

| 项 | 值 |
|---|---|
| upstream | `rinchao0721/Melodia`(KMP + Compose,MIT) |
| 目标分支 | `dev`(模板明文:功能/修复/重构都进 dev,预发布从 dev 打 tag,main 只收 dev 合入) |
| 我们的 fork | `xiaquwan1001/Melodia`,本地 remote 名 `fork` |
| 本地副本 | `references/Melodia/`(gitignored,浅克隆) |
| 分支命名 | `feat/…`、`fix/…`、`docs/…` |
| commit 风格 | 中文 conventional:`feat(player): …`、`fix(ui): …` |

## 2. 开工第一步:同步 dev(本轮踩过的坑)

```bash
git fetch --depth 50 origin dev:dev     # 浅克隆只带默认分支,dev 不会自动出现
git checkout -b feat/xxx dev            # 功能分支必须从 dev 切
```

**为什么必须**:2026-11-01 实测 `main`(c42a8b0) 与 `dev`(9c4268e) 差 50 个 commit,
且差异正好在播放器层——`dev` 已有「音量平衡」(`LoudnessPolicy`:每曲增益上限 -12 dB、
2s 平滑 ramp、经 `Player.handleSetVolume` 下发)、「智能过渡」。基于 `main` 写的音量补丁
rebase 到 `dev` 会**二次相乘**并覆盖 ramp。

## 3. dev 播放器音量的事实(改动前必读)

- 音量写入点有五处:`fadeStep`(淡化)、`gainStep`(音量平衡 ramp)、`applyGainImmediately`(直切)、
  `releaseOutgoing`(中止淡化)、`completePendingImmediately`(缓冲接管)。
  任何新增增益都必须收敛到同一个出口(`applyVolumes()`),否则被淡化/ramp 覆盖。
- `outgoingStartGain = previous.volume` 会把已含的增益一起记进去,再加乘就是二次衰减;
  正确做法是把「淡化增益 / 曲目增益 / 播放器增益」分开保存再合成一次。
- `getState()` 对外固定报 `setVolume(1f)`;`COMMAND_SET_VOLUME` 归音量平衡使用,别挪作他用。
- 桌面端(mpv)已有独立 0~100 播放器音量 + 静音记忆;做端上功能要分平台改。

## 4. 本地构建

```bash
export JAVA_HOME=$HOME/android-dev/jdk ANDROID_HOME=$HOME/android-dev/sdk ANDROID_SDK_ROOT=$HOME/android-dev/sdk
./gradlew :app:testDebugUnitTest :shared:desktopTest     # CI 第 1 项
./gradlew :desktopApp:compileKotlin                      # CI 第 2 项
./gradlew :app:assembleRelease                           # CI 第 3 项
```

Gradle wrapper 9.3.1 已在本机缓存,SDK 36 已装;首次全链路约 1~3 分钟。

## 5. 真机验证(不破坏用户正式版)

手机已装正式版 2.1.0-beta.1(release 签名)。直接 `adb install -r` 调试包会
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`(签名不符),**不要卸载正式版**。做法:

```kotlin
// app/build.gradle.kts,临时;提 PR 前 git checkout -- 还原
buildTypes { debug { applicationIdSuffix = ".gaintest"; versionNameSuffix = "-gaintest" } }
```

```bash
adb install -r app/build/outputs/apk/debug/Melodia-v1.0.0-debug.apk   # 包名 …linmusic.gaintest
adb shell pm clear com.lin0721.linmusic.gaintest                      # 造"未登录"状态(只影响测试包)
adb shell monkey -p com.lin0721.linmusic.gaintest -c android.intent.category.LAUNCHER 1
adb shell uiautomator dump /sdcard/ui.xml && adb pull /sdcard/ui.xml /tmp/ui.xml   # 取文案/坐标
adb shell screencap -p /sdcard/a.png && adb pull /sdcard/a.png /tmp/a.png          # 截图
```

注意:覆盖安装不清数据会保留登录态;需要「未登录」场景必须 `pm clear`。

## 6. 截图进 PR

GitHub API 不支持直接上传 PR 图片。可行做法:用 fork 的 release 资产托管,PR 正文引用。

```bash
gh release create pr-assets --repo xiaquwan1001/Melodia --title "PR 截图资产" --notes "不参与代码"
gh release upload pr-assets shot.png --repo xiaquwan1001/Melodia --clobber
# 正文引用: https://github.com/xiaquwan1001/Melodia/releases/download/pr-assets/shot.png
gh pr edit <num> --repo rinchao0721/Melodia --body-file body.md
```

## 7. PR 正文

模板在 `.github/PULL_REQUEST_TEMPLATE/{feature,fix,refactor}.md`,按小节写全(概述/根因/改动/
测试与验证/风险/自检清单)。创建命令:

```bash
gh pr create --repo rinchao0721/Melodia --base dev --head xiaquwan1001:<branch> \
  --title "feat(player): …" --body-file body.md
```

## 8. 本轮产出(2026-11-02 / 11-03 追加)

| 编号 | 类型 | 内容 |
|---|---|---|
| #141 | fix | 漫游续接只追加不重写队尾 + 相似曲目去重(修复 #132),附 5 例 `SimilarRoamingControllerTest` |
| #142 | feat | 歌单与「推荐歌曲」板块显示序号(#127) |

排障笔记(两条都踩过):

- **`PlaybackQueue.appendAfter` 是"截断+替换"语义**(内部 `originalItems.take(index+1) + items`),
  任何"续接/预取"都别用它,用 `extend`(去重 + 追加)。
- **真机 UI 自动化**:`adb shell input swipe` 在大列表里要持续多轮才滚到大歌单底部
  (`热歌榜` 200 首 ≈ 20 次);`uiautomator dump` 偶发失败重试即可;
  多设备同时连接时所有 adb 命令加 `ANDROID_SERIAL=<序列号>`,否则 `more than one device`。
- 并存安装验证完后 `git checkout -- app/build.gradle.kts` 还原 `.gaintest` 后缀,别带进 PR。

## 9. 上一轮产出(2026-11-02)

| 编号 | 类型 | 内容 |
|---|---|---|
| #139 | feat | 播放器级增益(0~-40 dB,逐档 0.4 dB),与系统音量 × 音量平衡相乘 |
| #140 | fix | 设置入口与登录态解耦:音乐库顶栏常驻设置按钮 |

`#140` 根因:`MelodiaApp.kt` 里 `userProfile?.let { ProfileSidebar(...) }` 把整个侧边栏
(含唯一 `Screen.Settings` 入口)锁在登录态后,且 `isDrawerDraggable` 也要求登录;
设置页 9 个子菜单全是应用侧配置,与账号无关 —— 属于入口挂错层,不是缺功能。
## 10. 本轮产出(2026-11-03) 播放模式合并

| 编号 | 类型 | 内容 |
|---|---|---|
| #144 | feat | 新增顺序播放(`SEQUENCE`),播放模式合并为一个四态轮转按钮并移到操作行 |

四条关键结论(都踩过):

- **默认控制行 5 个按钮在 300dp 宽会溢出**:用户把系统显示密度调到 768dpi 后逻辑宽只有 300dp,
  `shuffle+prev+play+next+repeat` 超出可用宽度,Row 居中越界 → 最右侧按钮只露几像素,
  所以用户只"看见随机播放"。默认布局改为只放传输三键,模式按钮进操作行
  (`ANDROID_ACTIONS` / 旧版 `ActionButtons`);旧布局里的 `shuffle` / `repeat` 令牌继续兼容。
- **顺序播放与漫游冲突**:`SimilarRoamingController.onProgressTick` 在「当前就是队列最后一首
  + 剩余 ≤15s + 自动播放推荐新歌开启」时追加相似曲目,所以"顺序播放不停"不是 bug;
  验证队尾停止必须先关设置里的「自动播放推荐新歌」。
- **`PlayMode` 是共享枚举**:桌面 mpv 与测试用 `SilentPlaybackController` 各有一份轮转 when,
  加模式必须同步改,否则 `:desktopApp:test` 直接挂(现在由 `nextPlayMode()` / `nextRepeatMode()` 统一)。
- **居中别用左右等宽 Spacer 凑数**:实测仍偏约 20dp;改为 `Box(contentAlignment = Center)` 才真正居中,
  模式按钮移走后也不会留下空位。
- **300dp 宽放不下 5 个标准键**(实测密度 768dpi ≈ 4.8px/dp,逻辑宽 300dp):
  `MelodiaIconButton` 实占 48dp、播放键 72dp,五键 + 28dp 间距 + 24dp 边距远超可用宽度,
  末尾按钮会被压到只剩几像素。最终:播放键 56dp、图标 40dp、边距 8dp、`SpaceBetween` 等距,
  实测中心点 134/408/720/1032/1306 px,严格对称。
- **模式配色要统一**:只靠图标形状区分模式;不要"某些模式变红、默认模式白"(会被误读成按下态)。
  仅漫游/心动这类临时特殊状态用主题色。
- **分享/输出设备放封面顶部**「播放自…」行右侧,底栏只留歌词模式与音质标签,避免三个地方重复入口。

真机验证口径(vivo X200 Ultra / Android 16 / 密度 override 768 ≈ 300dp 宽):

- uiautomator 读 `content-desc` 逐次确认四态轮转:列表循环 → 单曲循环 → 随机 → 顺序 → 列表循环;
- 顺序播放最后一首点「下一首」→ `state=PAUSED` + 日志「顺序播放已到队尾，停止续播」;
- 自然播完到队尾的路径受漫游续接影响,需关闭「自动播放推荐新歌」后复测(PR 里已注明未验证)。

