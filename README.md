# 轻音 MiniNCM — 网易云音乐第三方客户端(Android + Linux)

极简、可长期维护的双端客户端。

## 架构一句话

**Rust core(协议/身份/缓存/播放控制) + Flutter UI(一份跑双端) + 平台层(Android Media3 / Linux mpv)。**
音源走 Provider 抽象;首版不做脚本插件,但边界已按「将来能插」写好。

## 当前状态(2026-11-03, v2 M0)

| 项 | 状态 |
|---|---|
| Rust core + CLI | ✅ `ncm search / url / lyric` 在 Linux 真实跑通(取到 320k 直链并下载 5.7MB) |
| 身份持久化 | ✅ device_id 首启生成后复用 + 设备指纹 cookie 落盘(0600) |
| Flutter 双端壳 | ✅ Linux bundle 构建通过;Android 构建中 |
| Dart ↔ Rust 桥 | ✅ flutter_rust_bridge,4 个 smoke 测试全绿(含真实网络搜索) |
| 单元测试 | ✅ 8 个离线用例(映射/身份/错误分类) |

## 目录

```
core/                 Rust workspace
  crates/ncm-domain   领域模型(纯数据)
  crates/ncm-provider Provider trait + 能力声明 + 注册表
  crates/ncm-service  身份持久化 + 网易云 provider(包装 vendor 库)
  crates/ncm-ffi      Flutter 桥(cdylib/staticlib)
  crates/ncm-cli      headless CLI: 无 UI 也能验证全链路
  vendor/ncm-api      api-enhanced 的 Rust 移植(锁定 commit, 见 vendor/UPSTREAM.txt)
ui/                   Flutter 应用(android + linux, 含 rust_builder/cargokit)
platform/             (待建) Android Kotlin 层 / Linux GTK 层
plugins/              (待建) 未来音源脚本
legacy/               v1 WebView 实现(只读存档)
tools/                env.sh / build-linux.sh / build-android.sh / ci.sh
docs/                 架构决策、协议实测、里程碑
```

## 构建

```bash
source tools/env.sh          # JDK21 / Flutter / Android SDK / Rust 全在 ~/android-dev
bash tools/build-linux.sh     # Linux: ui/build/linux/x64/debug/bundle/minincm
bash tools/build-android.sh   # Android: ui/build/app/outputs/flutter-apk/app-debug.apk
bash tools/ci.sh              # 单测 + 桥接测试 + 双端构建
```

命令行(无 UI 验证):

```bash
cd core
cargo run -p ncm-cli -- search 晴天 --limit 5
cargo run -p ncm-cli -- url 3455095614 --download /tmp/a.mp3
cargo run -p ncm-cli -- lyric 186016
cargo run -p ncm-cli -- login-cookie "MUSIC_U=...; __csrf=..."
```
数据目录默认 `~/.local/share/ncm`(可用 `NCM_DATA_DIR` 覆盖),里面是 `identity.json`(0600)。

## 文档

- `docs/architecture-restart.md` —— 双端架构选型、决策记录、插件边界
- `docs/m0-plan.md` —— M0 落地清单与验收
- `docs/api-channel.md` —— interface / interface3 通道实测
- `docs/PROGRESS.md` —— 历史进度(v1 时代)
- `docs/build-vs-fork.md`、`docs/community-projects.md` —— v1 时代的社区盘点与资源实测
- `.pi/skills/netease-cloud-music-api-reverse/SKILL.md` —— 协议与反爬细节
