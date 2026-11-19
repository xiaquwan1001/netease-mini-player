# N3 · Linux 系统托盘菜单增加播放控制(2026-11-18)

用户反馈原文:「对linux端, 系统托盘点击需要能提供除了展示主界面之外的简单按钮, 主要: 播放/暂停, 喜欢/取消, 播放上一首, 播放下一首。」

## 结论(先数字)

- 托盘菜单从 2 项 → **7 项(含 2 条分隔线)**: 显示主界面 · ─ · 播放/暂停 · 上一首 · 下一首 · 喜欢/取消喜欢 · ─ · 退出。
- 端到端实测(dbusmenu 布局抓取, 见下「自验」): 顺序/文案正确; 无当前曲目时 4 项 `enabled=false`(置灰), 有恢复的播放现场后变成可点并推送 `托盘播放态 = 已暂停 / 未喜欢 / 有曲目:是`; 点「播放」经 dbusmenu Event 触发后 Dart 日志 `[NCM-TRAY] 托盘动作 togglePlay 已执行` ⇒ **原生→Dart→已有播放控制入口** 整条链路真的跑通。
- 无新增系统依赖(仍只 dlopen `libayatana-appindicator3.so.1` / `libappindicator3.so.1`), 缺库/缺宿主的降级路径一字未改。
- Dart 新增 **10** 例单测(`test/desktop_tray_actions_test.dart`), 全量 `flutter test` **1201 通过 / 0 失败**(含其它车道在飞改动; 本车道基线 1163 + 他车道增量 + 本车道 10)。
- 门禁: `dart analyze` **0 issue** · `check-tokens --strict` OK · `check-row-padding --strict` OK · `check-write-guard` OK · `dart format --set-exit-if-changed` 干净(只格式化本车道 4 个文件) · `flutter build linux --debug` **真编译通过** · `tools/smoke-desktop-headless` **PASS(63s, 含托盘会话)**。

## 通道协议(两侧注释写同一份表)

复用 `ncm/desktop_shell`(`kDesktopChannelName` / `kDesktopShellChannel`), 新增两个方向:

| 方向 | 方法/事件 | 载荷 |
|---|---|---|
| 原生 → Dart | `trayAction` | 字符串动作名: `togglePlay` / `previous` / `next` / `toggleLike` |
| Dart → 原生 | `setTrayPlaybackState` | `{playing: bool, liked: bool, hasTrack: bool}` → 返回原生托盘菜单是否活着 |

动作名常量: 原生 `kTrayAction*`(my_application.cc) ↔ Dart `TrayActionNames`(desktop_shell.dart), 两边注释互指。

## 改动文件

- `ui/linux/runner/my_application.cc`(+133 行): 4 个菜单项 + 2 条分隔线; `TrayActionBinding` + `g_signal_connect_data` 释放绑定; `send_tray_action()`(通道 invoke, 无通道则丢弃); `apply_tray_menu_state()`(文案/置灰 + AppIndicator 的 `gtk_widget_show` 重绘口径); `setTrayPlaybackState` 方法(缺字段/类型不对按 false); 状态先于托盘到达也能生效(ensure_tray 末尾补刷); dispose 清空 4 个 item 指针。
- `ui/lib/src/desktop_shell.dart`(+160 行): `TrayActionNames` / `TrayAction.tryParse` / `TrayActionHandlers`(可空回调 + `dispatch` 返回是否真执行, 纯函数可单测) / `setTrayActionHandlers` / `setPlaybackState`(按值去重, 失败静默) / `_onNativeCall` 分发 + 留痕。
- `ui/lib/src/home/home_wiring.dart`(+20 行): attach 时把**同一批**已有回调(onTogglePlay/onPrevious/onNext/onToggleLike)注册进托盘动作表, detach 时清空(⇒ 无页面/未登录安全 no-op)。
- `ui/lib/src/home/home_page.dart`(+46 行, 其中 12 行本车道): `onTogglePlay: () => _coordinator.toggle()`(与播放条按钮同一个入口); `_publishPlayerBar` 里推 `setPlaybackState`(playing/liked/hasTrack)。
- `ui/test/desktop_tray_actions_test.dart`(新增, 10 例): 常量表逐字对照 / 未知动作→null / 分发(全注册、部分注册、全空) / 通道推送(字面键 + 幂等 + false 不假装成功 + MissingPlugin 降级) / 原生→Dart 动作落到回调 / 未注册与未知动作不崩。

## 设计取舍

- **原生零播放逻辑**: 只发意图, 队列/喜欢/登录态全在 Dart; 托盘文案与置灰由 Dart 推送的状态决定, 原生不猜。
- **不新造旋钮**: 托盘 4 项分别落到 `_coordinator.toggle()`、队列 `_previous`/`_next`、`_songActions.toggleCurrentLike` —— 与播放条/通知栏/耳机键同一批回调。
- **置灰而不是静默失败**: `hasTrack=false`(空队列/未登录/播放条还没出现)时原生 4 项 disabled, 避免"点了没反应的假按钮"; Dart 侧再兜一层 `dispatch` 返回 false。
- **幂等**: `setPlaybackState` 与上次成功推送值相同即短路, 所以每次构建推一次几乎零成本(与 Android `setActionState` 同口径)。

## 自验命令与结果

```
# 1) 原生真编译(必过项)
source tools/env.sh && timeout -k 20 1200 flutter build linux --debug   # ✓ Built .../bundle/minincm
#    (注: tools/build-linux.sh 不接 debug 参数(多余参数当忽略), 它固定跑 cargo test + flutter test + build;
#     本轮先用它跑, 因他车道在飞文件导致 flutter test 4 红而中断在 build 之前, 故直接跑 flutter build linux --debug)

# 2) 静态门
cd ui && dart analyze                        # No issues found!
dart format --output=none --set-exit-if-changed <本车道 4 个文件>   # 0 changed
tools/check-tokens.sh --strict               # OK
tools/check-row-padding.sh --strict          # OK
tools/check-write-guard.sh                   # OK

# 3) 全量测试
cd ui && flutter test --exclude-tags network  # +1201: All tests passed!

# 4) 无头桌面冒烟(debug bundle)
BUNDLE=ui/build/linux/x64/debug/bundle tools/smoke-desktop-headless   # PASS, 63s(含 ⑦c 有假 StatusNotifierWatcher 的托盘会话)

# 5) 托盘菜单端到端探针(一次性脚本 /tmp/n3-tray-probe.sh, 不进仓库)
#    xvfb + dbus-run-session + 假 StatusNotifierWatcher + 预置 settings(closeBehavior=tray) 与 play_state.json,
#    然后 gdbus/PyGObject 读 com.canonical.dbusmenu.GetLayout 并用 Event('clicked') 真的点一下。
#    ⇒ 布局: 显示主界面 / ─ / 播放 / 上一首 / 下一首 / 喜欢 / ─ / 退出
#    ⇒ 无曲目: 4 项 enabled=false; 有曲目: enabled 默认(可点) + 原生日志「托盘播放态 = 已暂停 / 未喜欢 / 有曲目:是」
#    ⇒ 点「播放」: Dart 日志「[NCM-TRAY] 托盘动作 togglePlay 已执行」
```

## 仍需人工验证(本机无桌面会话/无真实托盘宿主)

1. 真机上让托盘图标出现(装了 AppIndicator 扩展的 GNOME / KDE), 右键看菜单是否 7 项、顺序是否与上面一致。
2. 播放一首歌后: 托盘文案应变「暂停」且四项可点; 点「暂停」→ 暂停, 文案回「播放」。
3. 点「上一首 / 下一首」→ 队列切曲(与播放条同一行为), 播放条的曲目名同步变化。
4. 点「喜欢」→ 当前曲红心点亮, 托盘文案变「取消喜欢」; 再点变回。
5. 空队列(刚启动未恢复现场)时四项应为灰色不可点。
6. 卸载 `libayatana-appindicator3` 或没有 StatusNotifier 宿主时: 托盘不出现、应用不崩、关闭行为仍降级为最小化到任务栏。
