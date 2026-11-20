// 迁移 barrel(审计 §7.8 二批: mine 域): 实体已迁到 `mine/` 下。
// 根目录保留同名文件只为不打断调用方的 import 路径 —— 全仓一律继续 import 本路径,
// 内部实现再互相引用时才用 `mine/xxx.dart`。改功能请去 `mine/` 里的实体文件。
export 'mine/mine_view.dart';
