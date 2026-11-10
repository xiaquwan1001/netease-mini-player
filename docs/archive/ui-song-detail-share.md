# 播放条合并 + 歌曲详情页(分享 / 翻译 / 多选定位)

> 2026-11-08。设备实测: **a34 模拟器**(emulator-5556, API 34, 1080x2400, debug 包)。
> 相关代码: `ui/lib/main.dart`、`ui/lib/src/song_share.dart`、`ui/lib/src/lyric.dart`、
> `ui/lib/src/word_lyric_view.dart`、`ui/android/.../MainActivity.kt`。

## 1. 播放条: 两排 → 一排

| 之前 | 现在 |
|---|---|
| 第一排: 封面 + 曲名/进度 + 红心 + "..." | 封面 + 曲名/进度 + 红心 + 上一首 + 播放/暂停 + 下一首 |
| 第二排: 播放模式 + 上一首 + 播放/暂停 + 下一首 + 心动 + 队列 | (整排取消) |

- 图标统一 40dp 紧凑点击区(`_barIcon`: `visualDensity.compact` + `padding: 0`), 总宽 52 + 4×40 = 212dp,
  300dp 窄屏上文本仍有 ~90dp, 配合 `Expanded` + ellipsis 不会溢出。
- 播放模式 / 心动模式 / 播放队列移到**详情页底部横条**(`_buildDetailActionStrip`, 横向可滚)。
- 行尾 "..."(`SongOverflowButton`)**从播放条移除**, 放进详情页 AppBar。

## 2. 歌曲详情页 = 原歌词叠层

仍是 `_showLyrics` 的叠层(不是新路由), 所以返回键优先级 `resolveHomeBackAction` 不变 ——
唯一变化: 多选歌词时返回键先退多选。

AppBar: `收起歌词 | 曲名(多选时"已选 N 句") | 翻译开关 | ... | 分享`

- **翻译开关**: 只有该曲歌词确实带 tlyric 时才出现; 状态存 `AppSettings.lyricTranslation`。
- **分享(右上角)**: 打开分享面板, 卡片含封面 + 曲名/歌手/专辑 + 选中歌词 + 二维码。
- **歌词长按 → 多选**: 长按进多选并选中该行; 之后点行加减选; 右上角变 `分享所选歌词` / `取消选择`。
- **一键定位**: 右下角圆形按钮 → 恢复跟随 + 滚到当前行。
- **跟随播放**: 换行才自动滚动; `ScrollUpdateNotification.dragDetails != null`(手指拖动)即暂停跟随 ——
  **只认 dragDetails**, 因为自动跟随的 `animateTo` 也会发 ScrollNotification。

## 3. 分享卡片与平台通道

- 二维码: `qr_flutter`(纯 Dart, 依赖 `qr`), 内容 `https://music.163.com/song?id=<trackId>`。
- 卡片是普通 widget(`SongShareCard`), 面板里先**预览**, 再用 `RepaintBoundary.toImage(pixelRatio: 2)`
  导出 PNG —— 预览与导出同一套排版。
- 平台侧不引插件, 自建 `ncm/share` 通道:

| 方法 | Android | 桌面 |
|---|---|---|
| `shareImage` | 写 `cacheDir/shared` → FileProvider → ACTION_SEND + chooser | 落 `~/Pictures/MiniNCM` |
| `saveImage` | MediaStore(Q+) / 公共 Pictures(<=P) | 落 `~/Pictures/MiniNCM` |

坑(实测踩过): ACTION_SEND 只给 `EXTRA_STREAM` 时, 系统选择器(intentresolver)的预览会报
`Permission Denial: opening provider ... FileProvider ... not exported` —— 必须同时
`clipData = ClipData.newRawUri(...)`, 让 URI 授权跟着 clipData 走。

## 4. 走查记录(a34, 2026-11-08)

| 项 | 结果 |
|---|---|
| 播放条合并成一排(喜欢/上一首/播放/下一首) | ✅ 语义树: 曲名+进度+4 个图标, 无"更多操作" |
| 播放条 "..." 消失、详情页出现 | ✅ 详情页 AppBar: 收起歌词 / 曲名 / 关闭翻译 / 更多操作 / 分享这首歌 |
| 详情页"更多操作"打开完整动作面板 | ✅ 12 项(下一首播放/喜欢/收藏/分享/评论/…/下载) |
| 翻译开关 | ✅ 关闭后歌词行不再带翻译文本; 按钮变"显示翻译" |
| 歌词长按多选 → 分享所选 | ✅ 标题变"已选 1 句", 出现"分享所选歌词" |
| 分享面板(封面+歌词+二维码) | ✅ 预览含 "qr code"/歌手/专辑/选中歌词 |
| 保存图片 | ✅ /sdcard/Pictures/MiniNCM/Ed Sheeran - Shape of You (Acoustic).png, 85,980 B, 680x628 |
| 系统分享 | ✅ ChooserActivity 起来, 无 Permission Denial |
| 定位到当前歌词 | ✅ 手动滑走后点定位, 列表回到当前行 |
| logcat | ✅ 无 E/flutter / 无 share_error |

## 5. 顺带修复

- `_pollPlayer` 值没变就不 `setState`(原来暂停时也每 500ms 整页重建, 费电且让
  `uiautomator dump` 永远等不到空闲帧)。
- `adb install` 对 213MB debug APK 的 streamed install 会失败
  (`INSTALL_PARSE_FAILED_NO_CERTIFICATES`), 用 `adb install --no-streaming` 成功。
