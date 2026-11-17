# MiniNCM Linux 打包说明

三个产物: **tar.gz**(纯 bundle 归档) / **deb**(Ubuntu 22.04+) / **AppImage**(通用)。

## id 与数据目录(P-18 后半, 2026-11-17)

桌面端只有**一个**标识串, 四处必须完全一致, 改一处就要改全部:

| 位置 | 值 |
|---|---|
| `ui/linux/CMakeLists.txt` `APPLICATION_ID` | `io.github.xiaquwan1001.MiniNCM` |
| `usr/share/applications/<id>.desktop` 文件名 | `io.github.xiaquwan1001.MiniNCM.desktop` |
| `.desktop` 里 `StartupWMClass`(= WM_CLASS, 见 runner 的 `g_set_prgname`) | `io.github.xiaquwan1001.MiniNCM` |
| `usr/share/metainfo/<id>.metainfo.xml` 的 `<id>` 与 `<launchable>` | `io.github.xiaquwan1001.MiniNCM` |

`build-deb.sh` / `build-appimage.sh` 都会先从 `ui/linux/CMakeLists.txt` 读 `APPLICATION_ID`
并与脚本内的 `APPID` 比对, 不一致直接报错退出(免得打出一个任务栏不归组的包)。

**不动的两个名字**: 二进制名 `minincm`(deb 包名只能是全小写)与 Android 的
`applicationId com.minincm.minincm.dev`。

用户数据目录跟着 id 走: `~/.local/share/io.github.xiaquwan1001.MiniNCM`;
老版本的 `~/.local/share/ncm` 在升级后首次启动时由 `ncm-service::fsutil` **一次性迁移**
(同设备 rename, 跨设备 copy+校验+rename; 成功后在旧目录留 `.migrated` 标记, 失败回退旧目录)。
`NCM_DATA_DIR` 显式指定时不迁移。
全部从 `flutter build linux --release` 的 bundle 打包, 二进制不重链、目录结构原样保留
(minincm 靠 `/proc/self/exe` 找同级的 `data/` 与 `lib/`)。

## 前置

```bash
source tools/env.sh            # Flutter/Rust/镜像环境
cd ui && flutter build linux --release && cd ..
# bundle 在 ui/build/linux/<x64|arm64>/release/bundle
```

Flutter 桌面**不支持交叉编译**: arm64 包必须在 aarch64 机器上原生构建
(编译目录名 `x64`/`arm64` 由主机架构决定)。

## tar.gz

```bash
bash packaging/linux/build-tarball.sh dist     # 产物 MiniNCM-<ver>-linux-<arch>.tar.gz
# 顶层目录就是 bundle/(解压后直接 ./bundle/minincm 可运行)
```

覆盖变量(与 deb/AppImage 同名的 `BUNDLE` 语义一致):

```bash
BUNDLE=/path/to/arm64/bundle bash packaging/linux/build-tarball.sh dist
ARCH=arm64 VER=0.15.0 bash packaging/linux/build-tarball.sh dist   # 手工指定文件名里的架构/版本
```

- `ARCH`: 文件名里的架构(`x64`/`arm64`), 默认按 `uname -m` 推断。
- `VER`: 默认取 `ui/pubspec.yaml`(经 `tools/ci-gates.sh version`, 与 deb/AppImage/tag 校验同一实现)。
- release workflow 的 x64 / arm64 两条腿都直接调这个脚本(以前是两处内联 `tar`)。

## deb

```bash
bash packaging/linux/build-deb.sh dist
# 产物 minincm_<ver>_<amd64|arm64>.deb
```

覆盖变量(例如在 x64 机器上复用别处拷来的 arm64 bundle 打 deb):

```bash
ARCH=arm64 BUNDLE=/path/to/arm64/bundle bash packaging/linux/build-deb.sh dist
```

- `ARCH`: deb 架构名(`amd64`/`arm64`), 默认按 `uname -m` 推断。
- `BUNDLE`: bundle 目录, 默认 `ui/build/linux/<FLUTTER_ARCH>/release/bundle`。
- deb 脚本会先用 `nm -D` 检查 minincm 是否引用 GLib 2.80 才有的符号
  (`g_once_init_*_pointer`), 有则拒绝打包(Ubuntu 22.04 起不来, 见 issue #2)。

### 托盘 / 关闭到托盘的运行期依赖(lane/tray-close)

「点关闭按钮隐藏到系统托盘」需要 **libayatana-appindicator3**(StatusNotifier 客户端库):

- **deb**: 已放进 `Recommends: libayatana-appindicator3-1`(apt 默认会装)。
  `Depends` 里**故意没有**它 —— runner 是运行期 `dlopen` 的(见
  `ui/linux/runner/my_application.cc`), 没有该库应用照常启动, 只是"关闭到托盘"
  降级为"最小化到任务栏", 设置页也会如实写明会降级。
- **AppImage / tar.gz**: 不 bundle 该库, 用宿主系统的(几乎所有桌面发行版都自带;
  没有就降级)。这也是不把它塞进 AppImage 的原因: 库在容器里还得跟宿主打包版本对齐,
  而它缺失时的降级路径是安全的。
- **托盘宿主**: 还需要会话总线上有 `org.kde.StatusNotifierWatcher`
  (KDE Plasma 自带; GNOME 需装 AppIndicator 扩展; 裸窗口管理器通常没有)。
  没有宿主时同样降级为"最小化到任务栏", 并在日志里留
  `close-to-tray: 无托盘宿主, 降级为最小化到任务栏`。
- 构建期**零依赖**: CMake 不 `pkg_check_modules(ayatana...)`, 没装
  `libayatana-appindicator3-dev` 的 CI 机器也能编出带托盘功能的二进制。

## AppImage

```bash
bash packaging/linux/build-appimage.sh dist
# 产物 MiniNCM-<ver>-linux-<x86_64|aarch64>.AppImage
```

覆盖变量:

```bash
APPIMAGE_ARCH=x86_64 BUNDLE=/path/to/x64/bundle bash packaging/linux/build-appimage.sh dist
```

- `APPIMAGE_ARCH`: 发行架构名(`x86_64`/`aarch64`), 默认按 `uname -m` 推断。
- `BUNDLE`: 同上。
- `APPIMAGETOOL`: 直接指定 appimagetool 可执行文件; 否则优先 PATH 里的 `appimagetool`,
  最后自动下载到 `~/.cache/minincm-packaging/appimagetool-<ARCH>.AppImage`。
- 无 FUSE 的容器/CI 环境脚本自动用 `--appimage-extract-and-run`。
- 脚本会用 `readelf -h` 校验 bundle 里 minincm 的 ELF 架构与目标 AppImage 架构一致,
  不匹配(比如 `APPIMAGE_ARCH=aarch64` 配了 x64 bundle)直接报错退出,
  避免打出"x86_64 内容的 aarch64.AppImage"。

### aarch64 机器上的注意事项

1. AppImage 构建路径在 arm64 上**未端到端验证过**(目前 release workflow 只在 x64 上出 AppImage)。
   首次验证时重点看: `appimagetool-aarch64.AppImage` 下载后能否运行(它自己也依赖
   FUSE 或 `--appimage-extract-and-run`), 以及打出的 AppImage 能否直接启动。
2. 运行 AppImage 需要内核支持 `user namespaces`(或已装 FUSE); 主流发行版默认没问题。
3. 如 `readelf`/`file` 不在, 安装 `binutils`(推荐)。
4. 手动验证流程:

```bash
cd ui && flutter build linux --release && cd ..
bash packaging/linux/build-appimage.sh dist
file dist/MiniNCM-*-linux-aarch64.AppImage          # 应显示 ARM aarch64
./dist/MiniNCM-*-linux-aarch64.AppImage             # 应能启动
# 反例自检(应报"架构不匹配"退出):
APPIMAGE_ARCH=x86_64 bash packaging/linux/build-appimage.sh "$PWD/dist-badarch"
```

### CI 资产对应关系(v0.4.0)

| 产物 | job / runner | 状态 |
|---|---|---|
| tar.gz (x64) | linux x64 job | ✅ release workflow 自动 |
| tar.gz (arm64) | ubuntu-24.04-arm | ✅ release workflow 自动 |
| deb (amd64) | linux x64 job | ✅ release workflow 自动 |
| deb (arm64) | ubuntu-24.04-arm | ✅ release workflow 自动 |
| AppImage (x86_64) | linux x64 job | ✅ release workflow 自动 |
| AppImage (aarch64) | — | ⚠️ **未进 release workflow**, 只能本地手动构建; arm64 上构建/运行未验证, 验证通过后再加 CI job |
