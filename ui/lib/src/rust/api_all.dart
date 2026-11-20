// 手写 barrel(不属于生成物): FFI 面的唯一 import 入口。
//
// 为什么需要(2026-11-20 架构审计 7.2): Rust 侧 `core/crates/ncm-ffi/src/api.rs`
// 按域拆成 `api/*.rs` 后, flutter_rust_bridge 把 Dart 生成物也拆成
// `src/rust/api.dart` + `src/rust/api/<域>.dart`, 且**生成物不做父模块 re-export**;
// 而全仓 116 处调用点只认一个 import(`as rust`)。所以这里手工汇总。
//
// 维护: Rust 侧新增/删除域模块(`core/crates/ncm-ffi/src/api.rs` 的 `mod`/`pub use` 列表)
// 时, 这里补/删一行 export; 生成物本身永远不要手改, 改签名走 codegen 三步。
export 'api.dart';
export 'api/account.dart';
export 'api/artist.dart';
export 'api/cloud.dart';
export 'api/detail.dart';
export 'api/discover.dart';
export 'api/library.dart';
export 'api/lyric.dart';
export 'api/me.dart';
export 'api/playback.dart';
export 'api/plugin.dart';
export 'api/podcast.dart';
export 'api/radio.dart';
export 'api/recommend.dart';
export 'api/search.dart';
export 'api/social.dart';
