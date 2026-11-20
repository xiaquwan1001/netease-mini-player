// 迁移 barrel(审计 §7.8 三批: artist 域): 实体已迁到 `artist/` 下。
// 根目录保留同名文件只为不打断调用方的 import 路径 —— 全仓一律继续 import 本路径,
// 内部实现再互相引用时才用 `artist/xxx.dart`。改功能请去 `artist/` 里的实体文件。
export 'artist/artist_nav.dart';
