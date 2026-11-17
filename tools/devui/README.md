# devui —— 无窗口模拟器上"看"和"点"的小工具

给 agent/CI 在没有图形界面时驱动 App、核对界面用。全部基于 Flutter 语义树或截图,
不需要 Appium/Playwright。

| 脚本 | 作用 |
|---|---|
| `uix [关键词]` | 列出当前屏的语义节点(content-desc + 中心坐标);失败退出码 3 |
| `uitap <关键词>` | 按文案点击 |
| `uilong <关键词>` | 按文案长按 900ms |
| `shot <out.png>` | 截图 |
| `shotmap <png> [cols] [rows]` | 截图 → 灰度 ASCII(文本里看布局/找红黄条) |
| `cropmap <png> x y w h` | 截图某区域 → RGB 均值表(核对背景色/像素级 A/B) |
| `notif-slots [--pkg P] [--dump F] [--selftest]` | 断言媒体通知的 action 槽位(读 `dumpsys notification --noredact`) |
| `androidtest [gradle args...]` | 只在模拟器上跑 `ui/android/app/src/androidTest` |

前置:

```bash
adb -s emulator-5554 shell settings put secure accessibility_enabled 1   # Flutter 才会上报语义树
DEV=emulator-5554 tools/devui/uix | head
DEV=emulator-5554 tools/devui/uitap "分享这首歌"
```

坑: `uiautomator dump` 报 `could not get idle state` 说明 App 一直在出帧(播放中每 500ms 刷新、
输入框光标闪烁)。先暂停播放、让输入框失焦再 dump;不要用返回键退出 App,那样拿到的是桌面。

## 通知槽位断言(notif-slots)

```bash
DEV=emulator-5554 tools/devui/notif-slots                 # 直接读设备 dumpsys notification
tools/devui/notif-slots --dump /tmp/dump.txt              # 离线解析已保存的 dump
tools/devui/notif-slots --selftest                        # 用例自带样例自测解析器(不碰设备)
```

断言口径(见 `.pi/memory/media-notification-custom-buttons.md`): 5 个 action,顺序
**上一首 → 播放/暂停 → 下一首 → 喜欢/取消喜欢 → 播放顺序**,渠道 `default_channel_id`
且 importance=IMPORTANCE_LOW,`compactActions=[0,1,2]`,`「下一首」只出现一次`。
每条一行 `PASS`/`FAIL`,末尾汇总;退出码 0=全 PASS / 1=有 FAIL / 2=用法或设备纪律 / 3=读不到 dump。

限制:

- **只允许 `emulator-*`**:脚本对 `DEV=10AF...`(用户日常手机)直接拒绝(exit 2);
  物理机上不装包、不清数据、也不读通知内容。
- 读的是**已 post 的通知**,所以必须先让 App 正在播放(暂停也行,停了就没有 NotificationRecord)。
- Android 13+ 需要 App 已授予 `POST_NOTIFICATIONS`,否则通知被系统丢弃 → 报「没找到记录」。
- 为什么不用 `dumpsys media_session`:`PlaybackState.customActions` 是滞后快照(只在播放
  状态变化时重发布),通知里那份才是 SystemUI 真正画的。
- 个别 ROM 的 dumpsys 排版不同(缺 `actions=` 段):用 `--dump` 存原文人工核对;
  `notif-slots-samples/` 里的样例是**按 AOSP 排版手写**的,不是真机 dump。

## 在模拟器上跑 instrumented 测试(androidtest)

```bash
DEV=emulator-5554 tools/devui/androidtest
DEV=emulator-5554 tools/devui/androidtest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.minincm.minincm.NotificationSlotsTest
```

为什么必须走这个脚本: `./gradlew connectedDebugAndroidTest` 会往**所有**在线设备装 APK,
而本机 adb 上平时连着用户的日常手机。脚本先校验 `DEV` 是 `emulator-*`,再把 `ANDROID_SERIAL`
传给 Gradle,保证只碰那一台。首批 case 是 `NotificationSlotsTest`:通知渠道 + 按钮槽位 +
喜欢/模式状态回推,**不需要账号、不需要联网**(断言对象是 Media3 用生产 mediaButtonPreferences
拼出来的 Notification,不是代码常量表)。

