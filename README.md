# 轻音 MiniNCM — 网易云音乐第三方客户端(Android + Linux)

极简、可长期维护的双端客户端。

## 架构一句话

**Rust core(协议/身份/缓存/播放控制) + Flutter UI(一份跑双端) + 平台层(Android Media3 / Linux mpv)。**
音源走 Provider 抽象;首版不做脚本插件,但边界已按「将来能插」写好。

## 当前状态(2026-11-05)

| 项 | 状态 |
|---|---|
| Rust core + CLI | ✅ 搜索/取链/歌词/歌单/收藏 + 每日推荐/心动模式/播客/专辑/最近播放 |
| 身份持久化 | ✅ device_id 首启生成后复用 + 设备指纹 cookie 落盘(0600);多账号账号簿 |
| Flutter 双端壳 | ✅ Linux bundle + Android APK 均构建通过;Linux Xvfb + 模拟器 a36 双端闭环(见 `docs/testing-dual-platform.md`) |
| Dart ↔ Rust 桥 | ✅ flutter_rust_bridge 2.13,smoke 测试含真实网络(每日推荐/建议/专辑/播客/历史) |
| 功能 | ✅ 底部四栏(搜索/推荐/我的/设置)、搜索历史+联想+热词榜/猜你想搜、每日推荐(歌曲/歌单/播客)、每日私人 FM、心动模式、我的收藏(我喜欢/歌单/播客/关注艺人/关注动态)、账号与 UI 设置 |
| 测试 | ✅ Rust 单测(31 个 service 测试) + 69 个 Flutter 测试(离线纯函数/widget + 真实网络 smoke);双端实测记录见 `docs/testing-dual-platform.md` |

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
cargo run -p ncm-cli -- heart 210049 --count 10   # 心动模式(需登录, 无歌单上下文时回落"我喜欢的音乐")
cargo run -p ncm-cli -- raw recommend_songs       # 排障: 任意端点打印原始 JSON
```
数据目录默认 `~/.local/share/ncm`(可用 `NCM_DATA_DIR` 覆盖),里面是 `identity.json`(0600)。

## 文档

- `docs/architecture-restart.md` —— 双端架构选型、决策记录、插件边界
- `docs/m0-plan.md` —— M0 落地清单与验收
- `docs/api-channel.md` —— interface / interface3 通道实测
- `docs/PROGRESS.md` —— 进度记录(v1/v2 历史 + 最新功能)
- `docs/testing-dual-platform.md` —— Linux/Android 模拟器双端测试流程、结果与踩坑
- `docs/build-vs-fork.md`、`docs/community-projects.md` —— v1 时代的社区盘点与资源实测
- `.pi/skills/netease-cloud-music-api-reverse/SKILL.md` —— 协议与反爬细节
