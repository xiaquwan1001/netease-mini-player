# ui/ —— Flutter 双端壳

一份 Dart 代码跑 Android + Linux。Rust 侧通过 `ui/rust_builder`(cargokit)在构建时编译并打包。

## 目录

| 路径 | 内容 |
|---|---|
| `lib/main.dart` | 根页面 `HomePage`:五个 tab(搜索/推荐/关注/我的/设置)、播放队列驱动、播放条、歌词/详情页叠层 |
| `lib/src/rust/` | flutter_rust_bridge **生成代码**(不要手改;改 `core/crates/ncm-ffi/api.rs` 后重新 codegen) |
| `lib/src/*.dart` | 业务 UI:各页面视图、播放(`playback.dart`)、平台桥(`platform.dart`)、分享(`song_share.dart`)、歌词(`lyric.dart`/`word_lyric_view.dart`)等 |
| `android/` | Kotlin 平台层:Media3 播放服务(`PlaybackService`)、登录 WebView(`LoginActivity`)、`ncm/player`·`ncm/auth`·`ncm/open`·`ncm/share` 通道 |
| `linux/` | Linux runner(GLFW,无系统播放器依赖;播放走 Rust rodio) |
| `test/` | 离线 widget/纯函数测试 + 少量真实网络 smoke(见 `frb_smoke_test.dart`) |

## 常用命令

```bash
source ../tools/env.sh
flutter test                          # 全量单测(离线为主,362 例)
flutter test test/song_share_test.dart  # 单个文件
dart analyze                          # 本机 flutter analyze 会 SIGSEGV,用 dart analyze
flutter build linux --debug           # 或 ../tools/build-linux.sh
```

## 约定

- 平台差异只允许出现在 `lib/src/playback.dart`(`Playback`)与 `lib/src/platform.dart`(`PlatformBridge`)两处。
- 不引第三方平台插件:外部链接/下载/分享都用自建 MethodChannel(`ncm/open`、`ncm/share`)。
- 分享相关的卡片排版见 `lib/src/song_share.dart`,通道契约见 `docs/archive/ui-song-detail-share.md`。
