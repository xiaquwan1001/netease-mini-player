import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../auth.dart';
import '../detail_faces.dart';
import '../error_views.dart' show InlineError;
import '../lyric.dart';
import '../marquee_text.dart';
import '../rust/api_all.dart' as rust;
import '../song_actions.dart';
import '../word_lyric_view.dart';
import 'account_actions.dart';
import 'lyric_controller.dart';

/// 首页的**歌词全屏页 + 顶栏装配**(拆 `home_page.dart` §7.7 第二刀)。
///
/// 搬的是什么(逐行等价搬运, 不改 widget 顺序/不改四态判定顺序/不改图标与提示):
/// - [buildTopBar](原 `_buildTopBar`): 只在"承载了导航里没有的信息"时出现的
///   AppBar(歌词页曲名 + 收起; 歌单浏览态列表名 + 返回; 其余整条不出现);
/// - [buildBody](原 `_buildLyrics`): 歌词正文 —— 逐字/纯文本/错误/暂无/时间轴
///   五分支的顺序原样保留, 外层 [DetailFaces](歌词 ⇄ 封面)与右下角竖排
///   (翻译开关 / 定位当前歌词)也原样。
///
/// 边界(为什么能搬):
/// - **状态真相不在本类**: 歌词状态机在 [LyricController], 歌单浏览态四件套在
///   [AccountActions], 详情面在页面的 `_detailFace` ValueNotifier —— 这里全部
///   按引用/回调注入, 只读不写(切面写回偏好仍由页面的回调做);
/// - **分享与评论留在页面**: 它们要 sheet/播放器的当前曲目, 按回调注入
///   ([shareSong] / [shareSelectedLyrics] / [openComments]);
/// - **构建期上下文现取**: 两处入口都显式收 `BuildContext`(与拆分前
///   `State.context` 是同一个对象), 本类不缓存上下文。
class HomeLyricsPage {
  HomeLyricsPage({
    required this.lyric,
    required this.account,
    required this.auth,
    required this.infoOf,
    required this.currentOf,
    required this.detailFace,
    required this.storedDetailFace,
    required this.onDetailFaceChanged,
    required this.shareSong,
    required this.shareSelectedLyrics,
    required this.openComments,
  });

  /// 歌词状态机(数据/索引/多选/翻译开关/跟随)
  final LyricController lyric;

  /// 歌单浏览态四件套 + 二级页入口的唯一写入口
  final AccountActions account;

  /// 登录态门面(安卓端才给顶部「登录」按钮)
  final Auth auth;

  /// 登录态快照(顶栏「登录」按钮的可见性读它)
  final rust.InitInfo? Function() infoOf;

  /// 当前曲目(歌词标题 / 封面取图 / 评论入口)
  final rust.SongDto? Function() currentOf;

  /// 详情面板当前是「歌词」还是「封面」面(唯一真相在页面)
  final ValueNotifier<DetailFace> detailFace;

  /// 上次看的详情面(持久化偏好; 缺省/未知值一律 = 歌词)
  final DetailFace Function() storedDetailFace;

  /// 用户手动切面 → 写回偏好(由页面实现)
  final void Function(DetailFace face) onDetailFaceChanged;

  /// 分享当前曲目(卡片带封面 + 歌词 + 二维码)
  final Future<void> Function({List<String>? lyrics}) shareSong;

  /// 分享选中的歌词(多选态右上角)
  final Future<void> Function() shareSelectedLyrics;

  /// 封面面「查看评论」: 打开**当前**曲目的评论面板
  final void Function() openComments;

  /// 顶部栏: **只在它承载了导航里没有的信息时才出现**。
  ///
  /// - 歌词页: 曲名 + 收起按钮;
  /// - 歌单/正在播放/心动模式的浏览态: 当前列表名 + 返回按钮;
  /// - 其它情况(含「搜索」tab 首页、「推荐/关注/我的/设置」): **整条 AppBar 不出现**。
  ///   两处理由: ①这四页标题原本就是底部导航标签, 完全重复;
  ///   ②搜索页顶部的品牌横幅只是装饰, 用户明确要求去掉 —— 省下的 56dp 全给内容。
  ///   没有 AppBar 时也不再有顶部「登录」动作: 未登录引导在「我的」页(mine_view 的登录按钮)
  ///   与资料头点击(审查 P1-7.10 已定: 账号入口 3→1)。
  PreferredSizeWidget? buildTopBar(
    BuildContext context,
    rust.SongDto? current,
  ) {
    final showBar = lyric.visible || account.libraryOpen;
    if (!showBar) return null;
    return AppBar(
      // 大字号 + 动作图标会把默认 22sp 的标题挤成 "轻音 Mi…"(vivo 1440px 实测),
      // 标题固定用 titleMedium, 让品牌字至少完整显示
      // 详情页(歌词页)标题: 保留 titleLarge 的字重观感, 但显式 20sp + height 1.25。
      // 22sp 默认行高下中文歌名在 56dp AppBar 里下半段会被裁掉(用户反馈);
      // 20sp 仍明显大于 titleMedium(16sp), 不会退回"字号特别小"。
      titleTextStyle: Theme.of(context).textTheme.titleLarge
          ?.copyWith(fontSize: 20, height: 1.25, fontWeight: FontWeight.w600),
      // 长歌名横向滚动播放(marquee); 放不下不再 FittedBox 缩成小字
      title: MarqueeText(
        lyric.visible
            ? (lyric.selecting
                  ? '已选 ${lyric.selected.length} 句'
                  : (current?.name ?? '歌词'))
            : (account.libraryTitle ?? '轻音 MiniNCM'),
      ),
      leading: lyric.visible
          ? IconButton(
              icon: const Icon(Icons.expand_more),
              tooltip: '收起歌词',
              onPressed: lyric.toggle,
            )
          : (account.libraryOpen
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: '返回搜索',
                    onPressed: account.leaveLibrary,
                  )
                : null),
      actions: [
        // 歌曲详情页(歌词页)的右上角: 分享 / 翻译开关 / "..." 菜单
        if (lyric.visible) ...[
          if (lyric.selecting) ...[
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: '分享所选歌词',
              onPressed: shareSelectedLyrics,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '取消选择',
              onPressed: lyric.clearSelection,
            ),
          ] else ...[
            // 翻译开关已挪到歌词右下角(「定位当前歌词」上方), 见 buildBody.
            // "..." 从播放条挪到详情页里(播放条只留播放控制)
            if (current != null)
              SongOverflowButton(
                song: current,
                size: 22,
                // 队列来源即菜单来源: 日推/FM 才显示"不感兴趣"
                source: account.playSource,
              ),
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: '分享这首歌',
              onPressed: () => shareSong(),
            ),
          ],
        ] else if (auth.isAndroid && infoOf()?.loggedIn != true)
          // 登录(WebView)只在安卓端(桌面版还没有网页登录宿主)。
          // 审查 P1-7.10: 账号入口 3→1 —— 账号簿/切换/退出登录统一走「我的」页资料头。
          TextButton.icon(
            onPressed: account.login,
            icon: const Icon(Icons.login, size: 18),
            label: const Text('登录'),
          ),
      ],
    );
  }

  /// 歌曲详情页正文 = 歌词 + (定位当前句 / 底部次要控制)
  Widget buildBody(BuildContext context) {
    // 多选态: 点行 = 加/减选; 非多选态点击不做事(避免误改焦点)
    final onTap = lyric.selecting ? (int i) => lyric.selectLine(i) : null;
    final onLong = lyric.selectLine;
    final showTranslation = AppSettings.instance.lyricTranslation;

    final Widget body;
    if (lyric.wordLines.isNotEmpty) {
      body = WordLyricView(
        lines: lyric.wordLines,
        positionMs: lyric.positionMs,
        playing: lyric.playing,
        controller: lyric.scroll,
        itemExtent: lyric.itemExtent,
        showTranslation: showTranslation,
        selected: lyric.selected,
        onLineTap: onTap,
        onLineLongPress: onLong,
        autoScroll: lyric.autoFollow,
      );
    } else if (lyric.plain != null) {
      body = PlainLyricView(
        lines: lyric.plain!,
        controller: lyric.scroll,
        selected: lyric.selected,
        onLineTap: onTap,
        onLineLongPress: onLong,
      );
    } else if (lyric.error != null) {
      // 错误态要给出路: 只给一行错误文本时, 同一首只能切歌才可能恢复。
      // 「重试」走 [LyricController.retryLoad](重新发一次取数, 不是另造四态)。
      body = Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: InlineError(message: lyric.error!, onRetry: lyric.retryLoad),
        ),
      );
    } else if (lyric.lines.isEmpty) {
      body = const Center(child: Text('暂无歌词'));
    } else {
      body = TimedLyricView(
        lines: lyric.lines,
        activeIndex: lyric.activeIndex,
        controller: lyric.scroll,
        itemExtent: lyric.itemExtent,
        showTranslation: showTranslation,
        selected: lyric.selected,
        onLineTap: onTap,
        onLineLongPress: onLong,
        // 超长当前行只在播放中横向滚动(与逐字歌词同一口径)
        playing: lyric.playing,
      );
    }

    return Column(
      children: [
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              // 只认"手指拖动启动"(ScrollStartNotification.dragDetails != null):
              // - 这个 NotificationListener 只包住歌词列表, 子树里能带 dragDetails 的
              //   ScrollStart 只可能来自列表自身的拖动(播放条/进度条在子树外);
              // - 自动跟随的 animateTo 发出的 ScrollStart/ScrollUpdate 都没有
              //   dragDetails, 不会被误判成用户滑动.
              if (n is ScrollStartNotification && n.dragDetails != null) {
                lyric.pauseFollow();
              }
              return false;
            },
            // 歌词面 ⇄ 封面面: 轻点画面切换(再点回歌词); 歌词面用 Offstage 常驻,
            // 切回来滚动位置不丢。播客单集播放时进队列的也是 SongDto, 同一个控件。
            child: DetailFaces(
              trackId: currentOf()?.id,
              coverUrl: currentOf()?.coverUrl,
              // 多选态里点行 = 选中某句, 不是切面
              tappable: !lyric.selecting,
              // 面记忆: 面板按偏好里的记忆面初始化(控件只在建树时读 initialFace),
              // 用户切面立刻写回偏好 —— 换歌不再强制回歌词。
              initialFace: storedDetailFace(),
              faceController: detailFace,
              onFaceChanged: onDetailFaceChanged,
              // 封面面左下角「当前进度 / 总时长」: 位置搭歌词页已有的高频源
              // (展开期 120ms ticker 驱动的 positionMs), 控件自己不开定时器;
              // 总时长与它同源(播放态快照), 换曲时页面的重建会刷新。
              positionMs: lyric.positionMs,
              durationMs: lyric.player()?.durationMs.toInt() ?? 0,
              // 封面面右下角「查看评论」: 与歌曲"..."菜单里的查看评论同一条链路;
              // 没有当前曲目(纯占位/未播放)时不显示按钮。
              onOpenComments: currentOf() == null ? null : openComments,
              lyrics: Stack(
                children: [
                  Positioned.fill(child: body),
                  // 曾经在这里常驻一行"逐字歌词 · 网易云"来源小字(左下角),
                  // 用户反馈那是一条像水印的文本框, 已去掉(2026-11)。
                  // 打分/择优规则在 Rust(ncm-service::ttml_source), 文案在 lyricSourceLabel.

                  // 右下角竖排: 翻译开关在上, 定位当前歌词在下(用户要求把顶部翻译
                  // 开关挪到侧面). 歌词本身没有 tlyric 时不出现翻译键.
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (lyric.hasTranslation)
                          IconButton.filledTonal(
                            tooltip: AppSettings.instance.lyricTranslation
                                ? '关闭翻译'
                                : '显示翻译',
                            icon: Icon(
                              Icons.translate,
                              size: 20,
                              color: AppSettings.instance.lyricTranslation
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                            onPressed: lyric.toggleTranslation,
                          ),
                        if (lyric.hasTranslation) const SizedBox(height: 8),
                        IconButton.filledTonal(
                          tooltip: '定位到当前歌词',
                          icon: const Icon(Icons.my_location, size: 20),
                          onPressed: lyric.locateCurrent,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
