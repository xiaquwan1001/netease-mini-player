/// 歌单/播客(电台)详情页 + 评论面板的公开入口(实现拆在 src/detail/ 下).
///
/// 一页一文件: [showPlaylistDetail] / [showPodcastDetail] / [showCommentsSheet]
/// 各自一个文件, 共用件在 detail_shared.dart。
/// 曲目/节目行定高(基准 kRowExtent = 56, 按系统字号放大); 曲目可见性沿用
/// library_view 的统一规则(无版权且没收藏 → 隐藏, 顶部提示条数)。
/// 评论区独立加载, 失败不拖垮曲目列表。
library;

export 'detail/comments_sheet.dart';
export 'detail/playlist_detail_page.dart';
export 'detail/podcast_detail_page.dart';
