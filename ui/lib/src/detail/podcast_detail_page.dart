import 'package:flutter/material.dart';

import '../app_sheet.dart';
import '../comment_thread.dart';
import '../cover_art.dart';
import '../error_views.dart' show InlineError;
import '../expandable_text.dart';
import '../layout.dart'
    show
        kPagePadding,
        kTwoColumnGap,
        kTwoColumnListWidth,
        rowExtentFor,
        twoColumnFor;
import '../net_retry.dart';
import '../playback_bridge.dart';
import '../podcast.dart' show ProgramDetailSheet, ProgramDetailLoader;
import '../radio_subscribers_page.dart';
import '../rust/api_all.dart' as rust;
import '../toast.dart' show showToast, showUndoToast;
import '../user/user_page.dart' show showUserPage;
import 'detail_shared.dart' show DetailSkeletonList, showResourceShareSheet;
import 'podcast_program_row.dart' show PodcastProgramRow;

/// 播客详情(拉完整详情): 测试可注入; 缺省走 FFI `podcastRadio`
typedef PodcastRadioLoader = Future<rust.PodcastRadio> Function(BigInt radioId);

/// 打开播客/电台详情页(全屏路由)。
///
/// [loggedIn] 只用于「未登录先提示」; null = 不知道, 由 FFI 的 auth 错误兼管。
/// [loadRadioDetail] 用于补齐列表通道没有的收藏态/主播 uid/收藏数(F5)。
Future<void> showPodcastDetail(
  BuildContext context, {
  required rust.PodcastRadio radio,
  ProgramDetailLoader? loadProgramDetail,
  PodcastRadioLoader? loadRadioDetail,
  bool? loggedIn,
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _PodcastDetailPage(
        radio: radio,
        loadProgramDetail:
            loadProgramDetail ?? (id) => rust.podcastProgram(programId: id),
        loadRadioDetail:
            loadRadioDetail ?? (id) => rust.podcastRadio(radioId: id),
        loggedIn: loggedIn,
      ),
    ),
  );
}

class _PodcastDetailPage extends StatefulWidget {
  const _PodcastDetailPage({
    required this.radio,
    required this.loadProgramDetail,
    required this.loadRadioDetail,
    this.loggedIn,
  });

  final rust.PodcastRadio radio;

  /// 单集详情(podcast_program), 测试可注入 mock
  final ProgramDetailLoader loadProgramDetail;

  /// 电台完整详情(podcast_radio): 补收藏态/主播 uid/收藏数
  final PodcastRadioLoader loadRadioDetail;

  /// null = 登录态未知(不拦, 由 FFI 的 auth 错误提示)
  final bool? loggedIn;

  @override
  State<_PodcastDetailPage> createState() => _PodcastDetailPageState();
}

class _PodcastDetailPageState extends State<_PodcastDetailPage> {
  final TextEditingController _filterController = TextEditingController();

  /// 筛选框焦点: AppBar 常驻搜索按钮请求它(筛选条已滚出视野时先滚回来)
  final FocusNode _filterFocus = FocusNode();

  /// 筛选条位置(AppBar 搜索按钮用 ensureVisible 把它滚进视野)
  final GlobalKey _toolbarKey = GlobalKey();

  /// 内联评论区锚点: AppBar 的评论入口经它把评论区滚进视野(F5-F2)
  final GlobalKey _commentsKey = GlobalKey();

  /// 单列 body / 双列右栏的滚动口(AppBar 搜索按钮靠它 ensureVisible;
  /// 左栏不挂 controller, 两列各自滚动互不影响)
  final ScrollController _scroll = ScrollController();
  String _filter = '';

  List<rust.PodcastProgramDto>? _programs;
  String? _programsError;

  /// 列表通道不带收藏态/主播 uid/收藏数 ⇒ 进页时用 podcast_radio 补一次。
  /// 失败不影响页面(就用在列表里拿到的那份), 所以不报错。
  late rust.PodcastRadio _radio = widget.radio;

  /// 收藏态: 先用列表里的(可能 null = 未知), 详情回来后以详情为准
  bool? _subed;

  /// 收藏数(头部「N 人收藏」+ 听众列表入口)
  late int _subCount = widget.radio.subCount.toInt();
  bool _subBusy = false;

  @override
  void initState() {
    super.initState();
    _subed = widget.radio.subed;
    _loadPrograms();
    _loadRadioDetail();
  }

  Future<void> _loadRadioDetail() async {
    try {
      final detail = await widget.loadRadioDetail(widget.radio.id);
      if (!mounted) return;
      setState(() {
        _radio = detail;
        _subed = detail.subed ?? _subed;
        _subCount = detail.subCount.toInt();
      });
    } catch (_) {
      // 详情拉不到不影响节目列表: 页面仍用入参那份(收藏按钮保持未知态)
    }
  }

  /// 收藏/取消收藏电台(与歌单收藏同款口径: 成功后本地切换, 取消给 5 秒撤销;
  /// 未登录先提示而不发请求)。
  Future<void> _toggleSubscribe() async {
    if (_subBusy) return;
    if (widget.loggedIn == false) {
      _toast('收藏需要先登录');
      return;
    }
    final target = !(_subed ?? false);
    setState(() => _subBusy = true);
    try {
      final ok = await rust.setPodcastSubscribed(
        radioId: _radio.id,
        subscribed: target,
      );
      if (!mounted) return;
      if (ok) {
        setState(() {
          _subed = target;
          _subCount = target
              ? _subCount + 1
              : (_subCount > 0 ? _subCount - 1 : 0);
        });
        if (target) {
          _toast('已收藏播客');
        } else {
          showUndoToast(
            context,
            message: '已取消收藏播客',
            onUndo: () => _toggleSubscribe(),
          );
        }
      } else {
        _toast('操作未生效, 请稍后重试');
      }
    } catch (e) {
      _toast(friendlyError(e));
    } finally {
      if (mounted) setState(() => _subBusy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    showToast(context, message);
  }

  @override
  void dispose() {
    _filterController.dispose();
    _filterFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadPrograms() async {
    setState(() => _programsError = null);
    try {
      final programs = await retryNetwork(
        () => rust.podcastPrograms(
          radioId: widget.radio.id,
          limit: 100,
          offset: 0,
        ),
      );
      if (!mounted) return;
      // song 为空的节目没有音频本体, 不进列表(点了也没法播)
      setState(() {
        _programs = [
          for (final p in programs)
            if (p.song != null) p,
        ];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _programsError = friendlyError(e));
    }
  }

  /// 搜索框本地过滤: 节目名 contains, 大小写不敏感
  List<rust.PodcastProgramDto> get _display {
    final programs = _programs ?? const <rust.PodcastProgramDto>[];
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return programs;
    return [
      for (final p in programs)
        if (p.name.toLowerCase().contains(q)) p,
    ];
  }

  void _showShareSheet() {
    showResourceShareSheet(
      context,
      kind: 'djradio',
      resourceId: widget.radio.id,
      message: widget.radio.name,
      link: 'https://music.163.com/#/djradio?id=${widget.radio.id}',
    );
  }

  /// AppBar 常驻搜索按钮: 把筛选条滚进视野后聚焦弹键盘(节目列表滚下去时也能一步
  /// 回到筛选框)。
  Future<void> _focusFilter() async {
    final toolbarContext = _toolbarKey.currentContext;
    if (toolbarContext != null) {
      await Scrollable.ensureVisible(
        toolbarContext,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    }
    if (!mounted) return;
    _filterFocus.requestFocus();
  }

  /// AppBar 的评论入口: 把末尾的内联评论区滚进视野(与歌单详情同一套模式)。
  /// 评论在节目列表之后, 可能整块在视口外 —— ensureVisible 会沿外层滚动位置走
  /// (单列/双列右栏都是 [_scroll])。
  Future<void> _scrollToComments() async {
    final anchor = _commentsKey.currentContext;
    if (anchor == null) return;
    await Scrollable.ensureVisible(
      anchor,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  /// display 已经过滤掉 song 为空的节目, 行序即可播队列序
  void _playProgram(int index) {
    final songs = [
      for (final p in _display)
        if (p.song != null) p.song!,
    ];
    PlaybackBridge.instance.playSongs(songs, index);
  }

  @override
  Widget build(BuildContext context) {
    final radio = _radio;
    return Scaffold(
      appBar: AppBar(
        // 电台名只在头部卡片里(用户反馈 F5-F3: 固定栏里的长名挤成两个字); 固定栏只放动作。
        actions: [
          IconButton(
            tooltip: '查看评论',
            icon: const Icon(Icons.mode_comment_outlined),
            onPressed: _scrollToComments,
          ),
          IconButton(
            tooltip: '搜索本页',
            icon: const Icon(Icons.search),
            onPressed: _focusFilter,
          ),
          // 用户反馈 F5: 顶部那个「听众」icon 换成「收藏」; 听众入口挪进头部卡片的
          // 「N 人收藏」(同一个集合, 可点看列表)。
          IconButton(
            tooltip: (_subed ?? false) ? '取消收藏' : '收藏播客',
            icon: Icon(
              (_subed ?? false) ? Icons.favorite : Icons.favorite_border,
              color: (_subed ?? false)
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            onPressed: _subBusy ? null : _toggleSubscribe,
          ),
          IconButton(
            tooltip: '分享',
            icon: const Icon(Icons.share_outlined),
            onPressed: _showShareSheet,
          ),
        ],
      ),
      // 双列判据用**窗口逻辑尺寸**(MediaQuery.sizeOf), 不是 body 的实测宽:
      // 壳层 ContentWidthLimit 把 body 限到 840, 拿它比 900 永远为假。
      // 窗口 >= 900 时 body 恰好 840 = 300 + 12 + 528, 两栏不挤压。
      // 与歌单详情(detail/playlist_detail_page.dart)共用同一个判据与切分口径。
      body: twoColumnFor(MediaQuery.sizeOf(context))
          ? _buildTwoColumnBody(radio)
          : _buildSingleColumnBody(radio),
    );
  }

  /// 单列 body(窄/中档): 与双列改造前**逐像素一致** —— 同一棵 sliver 树、同一顺序。
  Widget _buildSingleColumnBody(rust.PodcastRadio radio) => CustomScrollView(
    controller: _scroll,
    slivers: [
      SliverToBoxAdapter(child: _buildHeaderCard(radio)),
      SliverToBoxAdapter(child: _buildToolbar()),
      _buildPrograms(_display),
      _buildComments(radio),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ],
  );

  /// 双列 body(窗口 >= [kTwoColumnMinWidth] 且 >= [kTwoColumnMinHeight])。
  ///
  /// 切分点取「播客信息 / 节目相关的一切」: 左栏只有电台信息卡(封面/标题/主播/统计/
  /// 简介), 右栏是筛选框 + 节目列表 + 评论 —— 与歌单详情同构, 窄档里这些块的相对
  /// 顺序原样保留(信息卡 -> 筛选 -> 节目 -> 评论)。
  ///
  /// 滚动口径与歌单详情双列一致: **两列各自滚动**。
  /// 右栏挂 [_scroll] —— AppBar 常驻搜索按钮靠 ensureVisible 把筛选条滚回视野;
  /// 左栏保持无 controller, 两列互不影响。
  Widget _buildTwoColumnBody(rust.PodcastRadio radio) {
    final info = ListView(
      key: const Key('podcast-detail-info-column'),
      padding: EdgeInsets.zero,
      children: [_buildHeaderCard(radio)],
    );
    final programs = CustomScrollView(
      key: const Key('podcast-detail-programs-column'),
      controller: _scroll,
      slivers: [
        SliverToBoxAdapter(child: _buildToolbar()),
        _buildPrograms(_display),
        _buildComments(radio),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
    return Row(
      // stretch: 两列同高, 顶部/底部严格对齐(顶部对齐是双列的第一条几何断言)
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: kTwoColumnListWidth, child: info),
        const SizedBox(width: kTwoColumnGap),
        Expanded(child: programs),
      ],
    );
  }

  Widget _buildComments(rust.PodcastRadio radio) => SliverToBoxAdapter(
    child: CommentThread(
      key: _commentsKey,
      kind: 'podcast',
      resourceId: radio.id,
      // 评论分享卡片的语境(需求 10): 来自哪个播客
      shareSourceTitle: radio.name,
      shareSourceKind: commentSourceKindLabel('podcast'),
    ),
  );

  Widget _buildHeaderCard(rust.PodcastRadio radio) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        radio.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (radio.djName.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: _DjLine(
                            djName: radio.djName,
                            onTap: radio.djId > BigInt.zero
                                ? () => showUserPage(
                                    context,
                                    userId: radio.djId,
                                    fallbackNickname: radio.djName,
                                  )
                                : null,
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${radio.programCount} 个节目 · 播放 ${radio.playCount} 次',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      // 「N 人收藏」可点 = 原来的「听众」入口(用户反馈 F5: 不要两个 icon 堆在
                      // AppBar 上)。收藏数未知(0)时不渲染这一行, 不留一个空的 0。
                      if (_subCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: InkWell(
                            onTap: () => showRadioSubscribers(
                              context,
                              radioId: radio.id,
                              radioName: radio.name,
                            ),
                            child: Text(
                              '$_subCount 人收藏',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                                decoration: TextDecoration.underline,
                                decorationColor: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                CoverArt(url: radio.coverUrl, size: 120, radius: 8),
              ],
            ),
            if (radio.description.trim().isNotEmpty)
              ExpandableText(text: radio.description, topPadding: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      key: _toolbarKey,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: TextField(
        controller: _filterController,
        focusNode: _filterFocus,
        onChanged: (value) => setState(() => _filter = value),
        decoration: InputDecoration(
          isDense: true,
          hintText: '筛选节目',
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _filter.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _filterController.clear();
                    setState(() => _filter = '');
                  },
                ),
        ),
      ),
    );
  }

  /// 单集详情: 列表数据先占位, 弹层自己再拉一次完整简介(podcast_program)
  Future<void> _openProgramDetail(int index) async {
    final display = _display;
    if (index < 0 || index >= display.length) return;
    final p = display[index];
    // isScrollControlled / showDragHandle 迁移前就是 true(= 入口默认), 省略
    await showAppSheet<void>(
      context,
      builder: (_) => ProgramDetailSheet(
        program: p,
        loadDetail: widget.loadProgramDetail,
        onPlay: p.song == null
            ? null
            : () {
                Navigator.pop(context);
                _playProgram(index);
              },
      ),
    );
  }

  Widget _buildPrograms(List<rust.PodcastProgramDto> display) {
    if (_programs == null && _programsError == null) {
      return const SliverToBoxAdapter(child: DetailSkeletonList());
    }
    if (_programsError != null) {
      // 错误行统一走 InlineError(与歌单曲目列表同一份实现)
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kPagePadding,
            vertical: 20,
          ),
          child: InlineError(message: _programsError!, onRetry: _loadPrograms),
        ),
      );
    }
    if (display.isEmpty) {
      final message = _filter.trim().isNotEmpty
          ? '没有匹配 "${_filter.trim()}" 的节目'
          : '这个播客还没有节目';
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kPagePadding,
            vertical: 32,
          ),
          child: Center(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
      );
    }
    return SliverFixedExtentList(
      itemExtent: rowExtentFor(context),
      delegate: SliverChildBuilderDelegate((context, i) {
        final p = display[i];
        return PodcastProgramRow(
          program: p,
          onTap: () => _playProgram(i),
          onInfo: () => _openProgramDetail(i),
        );
      }, childCount: display.length),
    );
  }
}

/// 「主播: xxx」一行: 有 uid 时是链接(主色 + 下划线, 点进他人主页), 没有就普通文字。
class _DjLine extends StatelessWidget {
  const _DjLine({required this.djName, this.onTap});

  final String djName;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    final label = Text(
      '主播: $djName',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: onTap == null
          ? style
          : style?.copyWith(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: theme.colorScheme.primary,
            ),
    );
    if (onTap == null) return label;
    return InkWell(onTap: onTap, child: label);
  }
}

// ---------------- 共用件 ----------------

/// 简介: 默认 3 行 + 展开/收起(歌单/播客头部共用)
// 长文本展开/收起已收敛到 expandable_text.dart(与 artist_page 合并为一份)
