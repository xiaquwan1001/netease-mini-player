<div align="center">

# 轻音 MiniNCM

**网易云音乐第三方客户端 · Android · Linux · Windows**

[**中文**](README.md) · [English](README.en.md)

Rust core(协议/身份/缓存/播放) + Flutter UI(一份代码跑三端) + 平台层(Android Media3 / Linux·Windows rodio+CPAL)

[![Flutter](https://img.shields.io/badge/Flutter-3.47-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Rust](https://img.shields.io/badge/Rust-core-DEA584?logo=rust&logoColor=white)](https://www.rust-lang.org)
[![Android](https://img.shields.io/badge/Android-14%2B-3DDC84?logo=android&logoColor=white)](#)
[![Linux](https://img.shields.io/badge/Linux-desktop-FCC624?logo=linux&logoColor=black)](#)
[![Windows](https://img.shields.io/badge/Windows-x64-0078D4?logo=windows&logoColor=white)](https://github.com/xiaquwan1001/netease-mini-player/actions/workflows/windows.yml)
[![CI](https://github.com/xiaquwan1001/netease-mini-player/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/xiaquwan1001/netease-mini-player/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![tests](https://img.shields.io/badge/tests-Dart%20536%20%2B%20Rust%20249-brightgreen)](#测试与门禁)

<img src="docs/images/hero.png" alt="轻音 MiniNCM 界面" width="100%">

</div>

## 这是什么

一个**极简、可长期维护**的网易云音乐客户端:播放条只有一行、点开就是歌词详情页,
不喜欢的歌一律不推;协议、加解密、风控与身份都在 Rust 里,UI 只负责"好看好用"。

- **一份 UI 跑三个平台**:`ui/` 的 Dart 代码同时构建 Android APK、Linux 桌面与 Windows x64;
  平台差异收敛在 `playback.dart` / `platform.dart` 与播放后端两个 `cfg`。
- **协议不自研**:加解密/风控/接口形态全部来自 `core/vendor/ncm-api`(api-enhanced 的 Rust 移植,
  锁定 commit),我们只做身份注入、DTO 转换与缓存。
- **身份纪律**:`device_id` 首启生成后永久复用,设备 cookie(`_ntes_nuid/_ntes_nnid/NMTID/WNMCID`)
  落盘 0600,禁止每进程随机 —— 少一次"莫名其妙被风控"。

## 界面

<table>
<tr>
<td width="33%"><img src="docs/images/phone-recommend.png" alt="推荐"></td>
<td width="33%"><img src="docs/images/phone-lyric-i18n.png" alt="歌曲详情页"></td>
<td width="33%"><img src="docs/images/phone-share-sheet.png" alt="分享"></td>
</tr>
<tr>
<td align="center">推荐:每日推荐 / 排行榜 / 风格</td>
<td align="center">歌曲详情页:逐行歌词 + 翻译开关</td>
<td align="center">歌词多选 → 分享卡片</td>
</tr>
<tr>
<td width="33%"><img src="docs/images/phone-search.png" alt="搜索结果"></td>
<td width="33%"><img src="docs/images/phone-lyric-select.png" alt="多选歌词"></td>
<td width="33%"><img src="docs/images/phone-audio.png" alt="播放与音质"></td>
</tr>
<tr>
<td align="center">搜索:单曲/歌单/播客分类</td>
<td align="center">长按歌词 → 多选</td>
<td align="center">播放与音质:响度均衡 / AutoEQ</td>
</tr>
</table>

### 分享卡片

歌词长按进多选,选中后右上角「分享所选歌词」→ 生成带封面、歌词与二维码的卡片
(二维码指向官方网页,任何扫码器可打开),可系统分享或存图库:

<img src="docs/images/share-card.png" alt="分享卡片" width="360">

## 功能一览

| 分组 | 已实现 |
|---|---|
| 播放 | 一行播放条、播放队列(跳转/拖拽排序/清空/存为歌单)、播放模式(含心动档)、MV 播放(Android 内嵌 VideoView / 桌面系统播放器)、边听边存 + 缓存上限 LRU、自动检查更新(off/每日/每周/每月) |
| 长文字 | 统一 `AdaptiveText`:歌名/歌单名/专辑名/艺人名放不下时**单向跑马灯**(放得下不动),副标题走 ellipsis,封面卡标题 2 行 |
| 歌词 | 行级滚动高亮、**逐字歌词带字内进度渐变**(双层裁剪 + 行内 60fps 插值)、yrc + AMLL TTML 双来源自动择优、翻译开关、歌词多选 → 分享卡片、封面取色背景 |
| 歌单 | 歌单广场/排行榜、收藏/新建/编辑/删除、批量加曲、歌单内搜索点歌策略(全列表/追加队列)、我喜欢按收藏时间排序、最近播放四分类 |
| 社区 | 评论(热门/全部/楼层回复/点赞/删除/IP 归属)、私信与 @我(只读)、关注动态、关注/粉丝列表、签到 |
| 桌面 | Linux(deb/AppImage/tar.gz)与 Windows(setup.exe/zip)同一套 rodio 后端(ALSA/WASAPI)、OLED 纯黑主题、精细音量 -40..0 dB |
| 主页 | 艺人与用户共用同一套主页骨架:高清横幅(按屏宽×DPR×清晰度档位取图, 点开全屏可保存原图)、身份卡、统计行、声明式 tab(歌曲/专辑/MV · 歌单/关注/粉丝) |
| 会员只读 | 黑胶会员卡/成长值/本周签到/任务、数字专辑已购、云贝签到(只读展示, 不碰支付) |
| 搜索与发现 | 搜索(历史/联想/热词榜/多板块)、每日推荐、私人 FM、心动模式、新歌新碟分地区、风格推荐 |
| 音质 | 响度均衡(EBU R128 + ReplayGain 2.0)、AutoEQ 曲线导入(PK·LS·HS)、淡入淡出、硬解/软解、封面清晰度三档 |

> 会员/签到/评论等写操作均只做经实测验证的子集, 支付与兑换明确不做(见 `docs/remaining-batches.md` §11 E)。

## 架构

```text
┌─────────────── Flutter UI(ui/, 一份 UI 跑三端)───────────────┐
│  页面/组件 · 播放条 · 歌曲详情页 · 分享卡片                 │
└───────────┬───────────────────────────────┬──────────────┘
            │ flutter_rust_bridge 2.13        │ ncm/player (MethodChannel)
┌───────────▼───────────────┐      ┌─────────▼──────────────┐
│ Rust core (core/)          │      │ Android 平台层 (Kotlin) │
│  ncm-domain   纯模型        │      │  Media3 ExoPlayer       │
│  ncm-provider Provider 抽象 │      │  MediaSessionService    │
│  ncm-service  身份 + 网易云  │      │  登录 WebView / 分享    │
│  ncm-ffi      Flutter 桥    │      └────────────────────────┘
│  ncm-cli      headless 验证 │      ┌────────────────────────┐
│  vendor/ncm-api 协议(锁定)  │      │ 桌面平台层(纯 Rust)     │
└────────────────────────────┘      │  rodio + CPAL + symphonia│
                                     │  Linux=ALSA / Win=WASAPI │
                                     └────────────────────────┘
```

- 跨层只传 `ncm-domain` 里可序列化的类型;provider 错误统一转
  `ProviderError{kind, retryable, detail}`,UI 按 `kind` 决策。
- Linux 与 Windows 端**零系统播放器依赖**(不用 mpv/MPRIS,同一套 rodio:Linux 走 ALSA、Windows 走 WASAPI),
  Linux 桌面包解压即用,Windows 包解压后运行 `minincm.exe`。

## 下载(三端)

从 [**GitHub Releases**](https://github.com/xiaquwan1001/netease-mini-player/releases/latest) 获取:

| 平台 | 资产 | 安装方式 |
|---|---|---|
| Android arm64 | `MiniNCM-<ver>-android-arm64.apk` | 直接安装(固定正式签名, 可覆盖升级) |
| Linux | `*.tar.gz` / `.deb` / `*.AppImage` | 解压运行 / `apt install ./minincm_*.deb` / chmod +x 直接跑 |
| Windows x64 | `*-setup.exe` / `*-x64.zip` | 安装向导 / 解压运行 `minincm.exe` |
| 校验 | `SHA256SUMS.txt` | `sha256sum -c SHA256SUMS.txt` |

每次打 tag 由 Release 流水线统一产出六种资产(v0.3.2 实测: APK 28.5 MB / tar.gz 15.0 MB / AppImage 14.6 MB / deb 11.1 MB / Windows zip 17.0 MB / setup.exe 13.7 MB)。

## 快速开始

```bash
git clone https://github.com/xiaquwan1001/netease-mini-player.git
cd netease-mini-player
source tools/env.sh          # 用户级 JDK21 / Flutter / Android SDK / Rust(按需改成本机路径)

bash tools/build-linux.sh    # → ui/build/linux/x64/debug/bundle/minincm
bash tools/build-android.sh  # → ui/build/app/outputs/flutter-apk/app-x86_64-debug.apk(模拟器)
                             #   ui/build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk(真机)
bash tools/ci.sh             # 单测 + 桥接测试 + Linux/Android 构建
```

不想本地编译? CI 每次 push 都产可直接安装的调试包:
**Actions → CI → 最新一次运行 → Artifacts → `minincm-debug-apk`**
(内含 `MiniNCM-debug-x86_64.apk` 给模拟器、`MiniNCM-debug-arm64.apk` 给真机; 包名带 `.dev` 后缀, 可与正式包并存)。

**桌面分发物**(本地也能打, 脚本在 [`packaging/`](packaging/)):

```bash
bash packaging/linux/build-deb.sh       # → dist/minincm_<ver>_amd64.deb(装到 /opt/minincm + /usr/bin/minincm)
bash packaging/linux/build-appimage.sh   # → dist/MiniNCM-<ver>-linux-x86_64.AppImage(免安装单文件)
# Windows 安装包(Inno Setup)只能在 Windows 上编:
#   iscc /DAppVersion=<ver> /Odist packaging\windows\installer.iss
```

Windows 桌面版**只能在 Windows 上构建**(Flutter 桌面端不支持交叉编译),因此没有本地脚本;
由 [`.github/workflows/windows.yml`](.github/workflows/windows.yml) 在 `windows-latest` 上产出
`MiniNCM-<version>-windows-x64.zip`(已验证约 17 MB)。在 Windows 上手工构建则是:
`flutter config --enable-windows-desktop` → `flutter build windows --release`(cargokit 会自动编 Rust 侧 `ncm_ffi`)。

### 发布产物(每次打 tag 由 Release 流水线产出)

| 平台 | 文件 | 安装方式 |
|---|---|---|
| Android arm64 | `MiniNCM-<ver>-android-arm64.apk` | 直接安装(固定正式签名, 可覆盖升级) |
| Linux 通用 | `MiniNCM-<ver>-linux-x64.tar.gz` | 解压运行 `bundle/minincm` |
| Debian/Ubuntu | `minincm_<ver>_amd64.deb` | `sudo apt install ./minincm_*_amd64.deb` |
| Linux 免安装 | `MiniNCM-<ver>-linux-x86_64.AppImage` | `chmod +x` 后直接运行(无 FUSE 时加 `--appimage-extract-and-run`) |
| Windows x64 | `MiniNCM-<ver>-windows-x64-setup.exe` | 安装包(开始菜单/桌面快捷方式 + 卸载项) |
| Windows 免安装 | `MiniNCM-<ver>-windows-x64.zip` | 解压运行 `minincm.exe` |
| 校验 | `SHA256SUMS.txt` | `sha256sum -c SHA256SUMS.txt` |

Linux 产物运行时基线(glibc ≥ 2.34、GLib ≥ 2.72、GTK 3): Ubuntu 22.04 jammy 及更新的发行版都能直接跑。
构建机头文件再新也不会把 GLib 2.80 的符号带进产物 —— `ui/linux/CMakeLists.txt` 把
`GLIB_VERSION_{MIN,MAX}_ALLOWED` 钉在 2.72, CI 与 `packaging/linux/build-deb.sh` 各有一道符号回归门
(见 issue #2)。

无 UI 也能验证链路(headless CLI):

```bash
cd core
cargo run -p ncm-cli -- search 晴天 --limit 5
cargo run -p ncm-cli -- url 186016 --download /tmp/a.mp3
cargo run -p ncm-cli -- lyric 186016
```

## 测试与门禁

| 门禁 | 现状 |
|---|---|
| `cargo test --offline --workspace` | **272** 通过(不含 vendor 248;vendor 24 例里 4 例联网 smoke 离线自跳过) |
| `cargo clippy --workspace --all-targets` | **0 warning** |
| `flutter test --exclude-tags network` | **746** 通过(离线口径; 真实网络 smoke 单列 `@Tags(['network'])`, 本地/CI 都不跑) |
| `dart analyze` | **0 issue**(error / warning / info 全清) |
| `tools/check-write-guard.sh` | OK(测试里不直连评论/点赞/转发/分享/歌单写, CI 不触网) |
| 构建 | Linux bundle + Android APK 本地通过; Windows x64 zip 由 `windows.yml` CI 构建并实测通过 |
| 设备走查 | a34/a36 模拟器(API 34 / 36)全流程 + 真机听感验收;记录见 `docs/testing-dual-platform.md` |

## 项目进度(当前版本 v0.9.0)

| 阶段 | 内容 | 状态 |
|---|---|---|
| M0 | Rust workspace 分层、Provider 抽象、headless CLI | ✅ |
| 协议 | vendor 移植 + 裁剪(382 → 118 个 endpoint,现覆盖 123,LOC 12k → 4k) | ✅ |
| 三端壳 | Flutter Android/Linux/Windows、FRB 2.13 桥、三端构建链路(Windows 走 CI) | ✅ |
| 播放 | Media3(Android)/ rodio(Linux ALSA · Windows WASAPI)、响度均衡、AutoEQ、缓存 | ✅ |
| UI | 五栏 IA、推荐/搜索/关注/我的/设置、播放条一行、歌曲详情页、分享卡片 | ✅ |
| 真机验收 | 听感项(EQ 削波 / 淡入手感 / 响度均衡 A/B / 硬解)与 MV 播放均已于 2026-11-10 在真机通过 | ✅ |
| 待办 | 视觉人工过目、AppImage 桌面集成、打包后冒烟(deb/keyring)、L 级立项(云盘/一起听/听歌识曲) —— 清单见 [`docs/remaining-batches.md`](docs/remaining-batches.md) **§11** | ⏳ |

进度明细与每批验收证据见 `docs/PROGRESS.md`。

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/README.md`](docs/README.md) | **文档总索引**(每个文件一行用途与状态) |
| [`docs/PROGRESS.md`](docs/PROGRESS.md) | 进度记录(版本时间线 + 按日期批次 + 专题小节;v1 历史在 `docs/archive/`) |
| [`docs/architecture-restart.md`](docs/architecture-restart.md) | 架构选型、决策记录、插件边界 |
| [`docs/archive/`](docs/archive/README.md) | 已完工车道的执行记录(索引见该目录 README) |
| [`docs/testing-dual-platform.md`](docs/testing-dual-platform.md) | 多端(Android/Linux/Windows)测试流程、语义驱动自测法、踩坑速查 |
| [`docs/api-channel.md`](docs/api-channel.md) | 接口通道(interface / interface3)实测 |
| [`docs/remaining-batches.md`](docs/remaining-batches.md) | **待办与分批规划(最新在 §11)** |
| [`docs/b7-playlist-write-notes.md`](docs/b7-playlist-write-notes.md) | 歌单写接口的真实响应形状与踩坑 |
| [`packaging/`](packaging/) | deb / AppImage / Windows 安装包的打包脚本 |
| [`tools/devui/`](tools/devui/README.md) | 无窗口模拟器自测脚本(按语义树点击/截图/像素核对) |

## 许可

本项目代码以 **MIT** 发布,见 [`LICENSE`](LICENSE)。第三方组件与许可(WTFPL / MIT / MPL-2.0 / BSD-3-Clause)
逐项列在 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md),其中网易云接口实现
(`core/vendor/ncm-api`,WTFPL)由 api-enhanced(MIT, © 2013-2022 Binaryify)移植而来。

## 声明

仅供学习与研究,请支持正版。本项目不提供、不存储任何音频内容,播放直链由官方接口按需获取;
登录态只保存在本机(0600 文件),不上传任何服务器。
