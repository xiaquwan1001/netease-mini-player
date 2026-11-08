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

前置:

```bash
adb -s emulator-5554 shell settings put secure accessibility_enabled 1   # Flutter 才会上报语义树
DEV=emulator-5554 tools/devui/uix | head
DEV=emulator-5554 tools/devui/uitap "分享这首歌"
```

坑: `uiautomator dump` 报 `could not get idle state` 说明 App 一直在出帧(播放中每 500ms 刷新、
输入框光标闪烁)。先暂停播放、让输入框失焦再 dump;不要用返回键退出 App,那样拿到的是桌面。
