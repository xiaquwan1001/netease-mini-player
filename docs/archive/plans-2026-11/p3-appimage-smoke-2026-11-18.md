# P3 · §11.A 桌面端冒烟(AppImage 段)

日期: 2026-11-18 · 基线: v0.23.0(6a9adce) · 只做 AppImage(用户口径: 「11.a 的冒烟可以直接做, 需要控制桌面端的部分本地编译 AppImage 即可」)

结论: **PASS**(静态 39 项 + 运行期 9 项 + 托盘 5 项全绿; 固化脚本 `tools/smoke-appimage.sh`, 无产物时 SKIP=exit 3)。

---

## 1. 构建命令与耗时

只出 AppImage 的最小链路(不需要 cargo test / flutter test, 那是 `tools/build-linux.sh` 的 debug 链路):

```bash
source tools/env.sh
cd ui && flutter pub get && flutter build linux --release && cd ..
bash packaging/linux/build-appimage.sh dist      # 产物 MiniNCM-<ver>-linux-<arch>.AppImage
```

- 实测(T0=…505 → bundle 完成 …538 → AppImage 完成 …539): **bundle 33s + appimagetool 1s ≈ 34s**
  (28 核, cargo registry / pub / flutter 引擎缓存全热; 冷机 cargo 全量编译另计)。
- appimagetool 走 `~/.cache/minincm-packaging/appimagetool-x86_64-1.9.1.AppImage`(脚本自带 sha256 pin 校验), 未下载新依赖。
- **构建落点**: 在 `git worktree add --detach /tmp/p3-appimage-wt v0.23.0` 里构建, 避免主工作区里别的 lane 未提交改动
  (`ui/lib/src/player_bar.dart`, `ui/test/player_bar_tiers_test.dart` 当时是 dirty)污染 v0.23.0 产物。
  另一条等价路径是 `BUILD=1 tools/smoke-appimage.sh`(在**当前工作区**编译, 会把 dirty 改动一起打进去)。

## 2. 产物

| 项 | 值 |
|---|---|
| 路径 | `dist/MiniNCM-0.23.0-linux-x86_64.AppImage`(已复制到主工作区 dist/, `dist/` 在 .gitignore, 不进 git) |
| 大小 | 15,260,152 字节(14.6 MiB);解包后 squashfs-root 43 MB |
| sha256 | `9b648a81117ee38d24b659e30c72224a74bca60e276a6d29eb35d8b8166c6eb1` |
| AppDir 结构 | `AppRun` · `<app-id>.desktop` · `minincm.png` · `.DirIcon→minincm.png` · `usr/bin/{minincm,data,lib}` · `usr/share/{applications,icons/hicolor/256x256/apps,metainfo}` |

## 3. 资产清单要点(解包实测)

- `usr/bin/minincm` 35,456 B,ELF x86-64,`nm -D` **无** `g_once_init_*_pointer` ⇒ GLib 2.72 基线守住(22.04 可启动)。
- `usr/bin/lib/`: `libflutter_linux_gtk.so` 17,256,536 B · `libapp.so` 8,897,416 B(AOT) · `libncm_ffi.so` 17,390,064 B。
- `usr/bin/data/`: `icudtl.dat` 864,880 B;`flutter_assets/` = `AssetManifest.bin`(2 B,空) · `FontManifest.json`(82 B,只有 MaterialIcons) ·
  `fonts/MaterialIcons-Regular.otf` 17,072 B · `NOTICES.Z` 98,845 B · `version.json` 86 B · `shaders/{ink_sparkle,stretch_effect}.frag`。
- **没有 `assets/` 目录、没有自带正文字体**: 与 `ui/pubspec.yaml` 里 assets/fonts 全注释一致;中文字体靠系统 fontconfig(见人工项 4)。
- 元数据: `.desktop` 的 `Exec=minincm %U` / `Icon=minincm` / `StartupWMClass=io.github.xiaquwan1001.MiniNCM` / `X-AppImage-Version=0.23.0`;
  `desktop-file-validate` 无告警;metainfo 的 `<id>`/`<launchable>`/`<release version>` 与 pubspec 版本四处一致;图标 256x256 PNG 8,497 B。

## 4. 冒烟明细(全部自动断言)

脚本: **`tools/smoke-appimage.sh`**(新增;没扩 `smoke-desktop-headless`, 因为后者是 **bundle** 口径且要 60~120s 三段会话,
AppImage 需要的是「产物自检 + 挂载/解包运行」这套不同判据)。用法: `tools/smoke-appimage.sh` / `APPIMAGE=<路径>` /
`BUILD=1` / `STATIC_ONLY=1`;退出码 0 PASS / 1 FAIL / 3 SKIP(无产物或缺工具)。

### A. 静态(解包, 不需 FUSE/root) — 全 OK
AppRun 可执行且指向 `usr/bin/minincm` · `.desktop` 根 + `usr/share/applications` 两份 · Exec/Icon/StartupWMClass/版本/Categories ·
`desktop-file-validate` 无告警 · 图标 256x256 + `.DirIcon` · metainfo id/launchable/version · 10 个运行期资产逐个存在且非 0 字节 ·
ELF 架构与文件名一致 · GLib 符号基线 · 文件名版本。

### B. 运行期(xvfb-run + dbus-run-session + 临时 HOME) — 全 OK, 40s / 39s 两次复跑一致
- 本机有 FUSE(libfuse.so.2 + /dev/fuse)⇒ 走**真实挂载**路径(`APPIMAGE_EXTRACT_AND_RUN=0`);无 FUSE 机器自动退 extract 路径。
- 进程存活 8s(两次启动都验);默认数据目录 `$HOME/.local/share/io.github.xiaquwan1001.MiniNCM` 自动创建,
  `identity.json` 落盘;第二次启动 **identity.json 内容不变**(device_id 不重建)。
- `NCM_DATA_DIR` 显式指定时优先生效(指定目录被创建)。
- 三次运行日志无 `segfault/core dumped/GLib-ERROR/Gtk-ERROR/panic`;仅有 `libEGL warning: DRI3`(xvfb 无 GPU, 与产物无关)。
- 备注: `settings.json` 在 8s 窗口内不落盘(默认设置不写盘)⇒ 该条降级为 INFO, 不算失败。

### C. 托盘(dbusmenu 回读, 自建假 StatusNotifierWatcher) — 全 OK
`closeBehavior=tray` ⇒ 启动即建托盘(日志 `托盘已就绪(图标 minincm)`),SNI 注册到 `/org/ayatana/NotificationItem/io_github_xiaquwan1001_MiniNCM`,
菜单路径 `/…/Menu`,dbusmenu 回读结构:

| # | type | enabled | label |
|---|---|---|---|
| 1 | standard | 1 | 显示主界面 |
| 2 | separator | – | – |
| 3 | standard | **0** | 播放 |
| 4 | standard | **0** | 上一首 |
| 5 | standard | **0** | 下一首 |
| 6 | standard | **0** | 喜欢 |
| 7 | separator | – | – |
| 8 | standard | 1 | 退出 |

顺序与 `ui/linux/runner/my_application.cc::ensure_tray` 完全一致;未登录/无曲目时四个播放控制项 `enabled=0`(置灰, 符合预期)。
**口径差异**: 记忆与计划里写「托盘 7 项(含 2 条分隔线)」, 实现实际导出 **8 个 dbusmenu 子项 = 6 个文案项 + 2 条分隔线**。
按「可点项」数 = 6;按「含分隔线的条目」数 = 8。脚本按实现断言 8, 口径待用户拍板(人工项 6)。

### 复跑方式
```bash
tools/smoke-appimage.sh            # 自动用 dist/*.AppImage; 全绿 ⇒ exit 0
STATIC_ONLY=1 tools/smoke-appimage.sh
KEEP_TMP=1 tools/smoke-appimage.sh # 失败时保留临时目录/日志
```

## 5. 本轮修掉的两个脚本级坑(可复用经验)

1. `set -uo pipefail` 下写 `ldconfig -p | grep -q …`: grep 命中即退出 ⇒ ldconfig 吃 SIGPIPE(141) ⇒ 整条流水线非 0,
   **FUSE / libayatana-appindicator3 检测全部假阴性**(第一版就因此把托盘段误 SKIP)。改法: 先落 `ldconfig.txt` 再 grep。
2. 假 StatusNotifierWatcher 必须**先**占住 well-known name, 再启动应用: 原生探测只在 `ensure_tray` 时做一次,
   宿主还没 owner ⇒ 直接降级「没有托盘宿主」。脚本里改成轮询 `WATCHER_READY` 后再起 AppImage。
   (另外 `Gio.BusNameOwnerFlags` 拼错成 `DBusNameOwnerFlags` 会让 watcher 静默崩溃 —— 用 `KEEP_TMP=1` 才看得到。)

## 6. 仍需人工确认(5 条)

1. **真实桌面双击启动**: xvfb 里只验进程/数据目录,没验窗口真的画在屏幕上。需在有会话的机器上双击,看到主窗口 + 任务栏图标
   (WM_CLASS=`io.github.xiaquwan1001.MiniNCM` 归组)且无 `dlopen libfuse.so.2` 报错。
2. **无 FUSE 机器兜底**(Ubuntu 24.04 默认没 libfuse2): 是否必须 `--appimage-extract` / 装 `libfuse2t64`, 报错文案是否可读。
3. **真实托盘宿主**(GNOME AppIndicator 扩展 / KDE / Xfce): 图标是否显示为 minincm(本机 hicolor 没装时退回 `audio-x-generic`),
   四个播放控制项点了是否真的作用到播放/喜欢(无头只验了结构 + 置灰)。
4. **中文字体**: AppImage 不自带字体, 只有 MaterialIcons;极简环境(无 Noto CJK)会出方块 —— 需在最小桌面看一次, 决定要不要把字体打进 AppImage。
5. **业务功能在 AppImage 下**: 登录/取链/播放/MV/定时关闭都没在本轮覆盖(无账号、无声卡), 需真机点一遍。

## 7. 边界与不做的事

- 未 sudo、未装系统包、未下载新依赖(appimagetool 用既有缓存 + sha256 pin)。
- 未 commit;未改 `docs/PROGRESS.md` / `docs/remaining-batches.md`。
- 大产物只在 `dist/`(.gitignore), 不进 git;`/tmp/p3-appimage-wt` 构建工作区用完已 `git worktree remove`。
- `BUILD=1` 分支已实现但本轮**未实测**(会在当前工作区编译, 会把其他 lane 的 dirty 改动打进去)。
