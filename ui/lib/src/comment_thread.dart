import 'dart:async';

import 'package:flutter/material.dart';

import 'comment_stats_bar.dart';
import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// 评论线程: 列表 + 点赞 + 楼层回复 + 发回复.
///
/// 两种入口共用一套 UI:
/// - 歌曲/歌单/专辑/播客: 传 [kind] + [resourceId](内部走 rust.comments)
/// - 动态: 传 [threadId](内部走 rust.eventComments)
/// 点赞/回复统一用 CommentPage.threadId。
typedef CommentPageLoader = Future<rust.CommentPage> Function(
    int limit, int offset);
typedef CommentLikeHook = Future<bool> Function(BigInt commentId, bool liked);
typedef CommentRepliesLoader = Future<rust.CommentPage> Function(
    BigInt parentId, int limit);
typedef CommentReplyHook = Future<bool> Function(
    BigInt commentId, String content);
typedef CommentDeleteHook = Future<bool> Function(BigInt commentId);

/// 发表顶层评论: 完全复用 [CommentReplyHook] 的形态 —— commentId 传
/// [BigInt.zero] 表示"评论整个资源"(网易云 comment_reply 接口 commentId=0 即顶层评论),
/// 所以这条链路不需要新增任何 FFI。
typedef CommentSendHook = CommentReplyHook;

class CommentThread extends StatefulWidget {
  const CommentThread({
    super.key,
    this.kind,
    this.resourceId,
    this.threadId,
    this.totalHint = 0,
    this.title = '评论',
    this.pageSize = 10,
    this.loadPage,
    this.loadHot,
    this.like,
    this.loadReplies,
    this.reply,
    this.send,
    this.delete,
    this.myUid,
  });

  /// song | playlist | album | podcast
  final String? kind;
  final BigInt? resourceId;

  /// 动态评论的 threadId(给了它就不看 kind/resourceId)
  final String? threadId;
  final int totalHint;
  final String title;
  final int pageSize;

  final CommentPageLoader? loadPage;

  /// 热门评论加载器(不传就走 rust.hotComments). 动态评论不支持热门, 传空即可
  final CommentPageLoader? loadHot;
  final CommentLikeHook? like;
  final CommentRepliesLoader? loadReplies;
  final CommentReplyHook? reply;

  /// 发表顶层评论(不传则复用 [reply] / rust.replyComment, commentId = 0)
  final CommentSendHook? send;

  /// 删除自己的评论(不传就走 rust.deleteComment)
  final CommentDeleteHook? delete;

  /// 当前账号 uid(测试注入); 不传就向 Rust 要. 决定哪些评论显示"删除".
  final BigInt? myUid;

  @override
  State<CommentThread> createState() => CommentThreadState();
}

/// State 对外公开: 详情页用 `GlobalKey<CommentThreadState>.focusComposer()`
/// 触发「去写评论」(滚到评论区 + 聚焦输入框), 见 [focusComposer]。
class CommentThreadState extends State<CommentThread> {
  final List<rust.Comment> _items = <rust.Comment>[];
  BigInt _total = BigInt.zero;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _moreError;

  /// 点赞/回复/删除都要用它(来自第一页)
  String _threadId = '';
  /// 评论/分享/点赞统计(comment_info_list; 动态评论接口不支持, 保持 null)
  rust.CommentStats? _stats;

  /// false = 全部(精彩评论 + 最新, 接口默认页), true = 只看精彩评论
  bool _hot = false;

  /// 当前账号 uid(0 = 未登录): 只有自己发的评论才给"删除"
  BigInt _myUid = BigInt.zero;

  // ---------------- 发表后定位 ----------------

  /// 刚发表成功的评论 id: 高亮一下就褪(用户找不到自己的评论会以为没发出去)
  BigInt? _highlightId;
  Timer? _highlightTimer;
  /// 每个列表项的 key: 发表后要把它滚进视野(ensureVisible 需要 context)
  final Map<BigInt, GlobalKey> _tileKeys = <BigInt, GlobalKey>{};
  /// 乐观项(id == 0)没有服务端 id, 单独给一个 key
  final GlobalKey _draftKey = GlobalKey();

  // ---------------- 楼层回复行内预览 ----------------

  /// 每个父评论只预取 1 页(够按点赞选出前 K 条), 并发上限 [_previewMaxConcurrent],
  /// 失败静默: 预览缺席不影响主列表, 「展开全部 N 条回复」仍可看全量。
  static const _previewLimit = 4;
  static const _previewMaxConcurrent = 2;

  final Map<BigInt, List<rust.Comment>> _replyPreviews =
      <BigInt, List<rust.Comment>>{};

  /// 预览拉取失败的楼层: 静默跳过不再排队(整页重载后清空重来)
  final Set<BigInt> _previewFailed = <BigInt>{};
  final Set<BigInt> _previewActive = <BigInt>{};
  final List<BigInt> _previewQueue = <BigInt>[];
  int _previewInFlight = 0;

  /// 整页重载时自增, 旧 gen 的在途预览响应直接作废
  int _previewGen = 0;

  /// 用户刚回复过的楼层: 预览兜底带上 timeMs 最新的一条(通常就是刚发的回复,
  /// 避免"发了看不见"; 按赞排序时新回复是 0 赞会被挤掉)
  final Set<BigInt> _justReplied = <BigInt>{};

  CommentPageLoader get _loadPage =>
      widget.loadPage ??
      (limit, offset) {
        final tid = widget.threadId;
        if (tid != null) {
          return rust.eventComments(threadId: tid, limit: limit, offset: offset);
        }
        return rust.comments(
          kind: widget.kind!,
          resourceId: widget.resourceId!,
          limit: limit,
          offset: offset,
        );
      };

  CommentPageLoader get _loadHotPage =>
      widget.loadHot ??
      (limit, offset) => rust.hotComments(
            threadId: _threadId,
            limit: limit,
            offset: offset,
          );

  /// 当前页签对应的加载器: 全部走默认页, 热门走 comment_hot
  CommentPageLoader get _fetchPage =>
      _hot ? _loadHotPage : _loadPage;

  CommentLikeHook get _like =>
      widget.like ??
      (commentId, liked) => rust.likeComment(
            threadId: _threadId,
            commentId: commentId,
            liked: liked,
          );

  CommentRepliesLoader get _loadReplies =>
      widget.loadReplies ??
      (parentId, limit) => rust.commentReplies(
            threadId: _threadId,
            parentCommentId: parentId,
            limit: limit,
          );

  CommentReplyHook get _reply =>
      widget.reply ??
      (commentId, content) => rust.replyComment(
            threadId: _threadId,
            commentId: commentId,
            content: content,
          );

  CommentSendHook get _send => widget.send ?? _reply;

  CommentDeleteHook get _delete =>
      widget.delete ??
      (commentId) => rust.deleteComment(
            threadId: _threadId,
            commentId: commentId,
          );

  @override
  void initState() {
    super.initState();
    _threadId = widget.threadId ?? '';
    final injected = widget.myUid;
    if (injected != null && injected != BigInt.zero) _myUid = injected;
    _reload();
    if (injected == null) _loadMyUid();
  }

  Future<void> _loadMyUid() async {
    try {
      final uid = await rust.myUid();
      if (!mounted || uid == BigInt.zero) return;
      setState(() => _myUid = uid);
    } catch (_) {
      // 未登录: 不显示删除入口
    }
  }

  /// [silent] = 发表后回填用: 不显示整页 loading(列表不闪), 失败也不把列表打成错误页
  Future<void> _reload({bool silent = false}) async {
    setState(() {
      if (!silent) _loading = true;
      _error = null;
      _moreError = null;
      // 整页重载: 预览缓存一并作废, 旧 gen 的在途响应会被丢弃
      _previewGen++;
      _replyPreviews.clear();
      _previewFailed.clear();
      _previewQueue.clear();
    });
    try {
      final page = await retryNetwork(() => _fetchPage(widget.pageSize, 0));
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.comments);
        _total = page.total;
        _hasMore = page.hasMore;
        if (page.threadId.isNotEmpty) _threadId = page.threadId;
        // 列表换了就丢掉旧项的 key, 免得 _tileKeys 无限增长
        final ids = _items.map((c) => c.id).toSet();
        _tileKeys.removeWhere((k, _) => !ids.contains(k));
        _loading = false;
      });
      _loadStats();
      _schedulePreviews();
    } catch (e) {
      if (!mounted) return;
      // 静默重载失败: 保留现状(乐观项还在), 不要把整页打成错误
      if (silent) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  /// 统计条: 只有资源类评论有(动态评论 threadId 带 uid, 接口不认), 失败静默.
  Future<void> _loadStats() async {
    final tid = _threadId;
    if (tid.isEmpty || widget.threadId != null) return;
    try {
      final s = await rust.commentStats(threadId: tid);
      if (!mounted || _threadId != tid) return;
      setState(() => _stats = s);
    } catch (_) {
      // 统计是锦上添花, 失败不打扰用户
    }
  }

  /// "全部"页的 offset 只能数"最新评论"(接口的 offset 作用在 latest 上,
  /// 精彩评论每次都随首页一起返回; 用 items.length 会把位置算多, 还会重复拉热评)
  int get _nextOffset =>
      _hot ? _items.length : _items.where((c) => !c.hot).length;

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final page = await retryNetwork(
        () => _fetchPage(widget.pageSize, _nextOffset),
      );
      if (!mounted) return;
      setState(() {
        // 兜底去重: 同一页里热评可能再次出现
        final seen = _items.map((c) => c.id).toSet();
        _items.addAll(page.comments.where((c) => seen.add(c.id)));
        _total = page.total;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
      _schedulePreviews();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _moreError = friendlyError(e);
      });
    }
  }

  /// 行内预览懒加载调度: 只给 replyCount > 0、还没数据、没在拉、没失败过的楼层排队。
  void _schedulePreviews() {
    for (final c in _items) {
      if (c.replyCount <= BigInt.zero) continue;
      if (_replyPreviews.containsKey(c.id) ||
          _previewFailed.contains(c.id) ||
          _previewActive.contains(c.id) ||
          _previewQueue.contains(c.id)) {
        continue;
      }
      _previewQueue.add(c.id);
    }
    _pumpPreviews();
  }

  void _pumpPreviews() {
    while (_previewInFlight < _previewMaxConcurrent &&
        _previewQueue.isNotEmpty) {
      final id = _previewQueue.removeAt(0);
      if (_previewActive.contains(id)) continue;
      _previewInFlight++;
      unawaited(_fetchPreview(id, _previewGen));
    }
  }

  Future<void> _fetchPreview(BigInt parentId, int gen) async {
    _previewActive.add(parentId);
    try {
      // 预览是 best-effort: 不套 retryNetwork, 失败直接静默
      final page = await _loadReplies(parentId, _previewLimit);
      if (!mounted || gen != _previewGen) return;
      setState(() {
        _replyPreviews[parentId] = page.comments;
        _previewFailed.remove(parentId);
      });
    } catch (_) {
      if (!mounted || gen != _previewGen) return;
      setState(() => _previewFailed.add(parentId));
    } finally {
      _previewActive.remove(parentId);
      _previewInFlight--;
      if (mounted) {
        if (gen != _previewGen) {
          _schedulePreviews(); // 整页已重载, 给新 gen 重新排队
        } else {
          _pumpPreviews();
        }
      }
    }
  }

  /// 楼层回复刚发成功: 丢掉旧预览重拉一次, 让新回复立刻出现在行内预览里。
  void _refreshPreview(BigInt parentId) {
    _previewFailed.remove(parentId);
    _justReplied.add(parentId);
    if (_previewActive.contains(parentId) || _previewQueue.contains(parentId)) {
      return; // 在拉的话这页大概率不含新回复, 但兜底标记会让下一轮把它带上
    }
    _replyPreviews.remove(parentId);
    _previewQueue.add(parentId);
    _pumpPreviews();
  }

  /// 行内预览选取规则(简单可解释, 单测 comment_reply_preview_test.dart 固化):
  /// - 名额 K = replyCount >= 3 ? 2 : 1 —— 楼层厚给 2 条, 薄楼层只给 1 条;
  /// - 候选按点赞数降序取前 K(互动优先), 同赞保持接口返回的时间序;
  /// - 行宽放不下ellipsis截断, 全量走「展开全部 N 条回复」入口。
  List<rust.Comment> _previewFor(rust.Comment parent) {
    final replies = _replyPreviews[parent.id];
    if (replies == null || replies.isEmpty) return const [];
    final k = parent.replyCount >= BigInt.from(3) ? 2 : 1;
    final order = List<int>.generate(replies.length, (i) => i)
      ..sort((a, b) {
        final byLikes = replies[b].likedCount.compareTo(replies[a].likedCount);
        return byLikes != 0 ? byLikes : a.compareTo(b);
      });
    final picked = [for (final i in order.take(k)) replies[i]];
    if (_justReplied.contains(parent.id)) {
      var newest = replies.first;
      for (final r in replies) {
        if (r.timeMs > newest.timeMs) newest = r;
      }
      if (!picked.any((r) => r.id == newest.id)) {
        if (picked.length >= k) {
          picked[picked.length - 1] = newest;
        } else {
          picked.add(newest);
        }
      }
    }
    return picked;
  }

  /// 点赞: 先本地乐观翻转, 失败回滚
  Future<void> _toggleLike(int index) async {
    final c = _items[index];
    final target = !c.liked;
    final delta = target ? 1 : -1;
    setState(() {
      _items[index] = _copy(c, liked: target, likedDelta: delta);
    });
    try {
      await _like(c.id, target);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items[index] = _copy(c, liked: c.liked, likedDelta: 0);
      });
      _snack('点赞失败: ${friendlyError(e)}');
    }
  }

  rust.Comment _copy(
    rust.Comment c, {
    required bool liked,
    required int likedDelta,
  }) {
    final count = c.likedCount + BigInt.from(likedDelta);
    return rust.Comment(
      id: c.id,
      userId: c.userId,
      userName: c.userName,
      avatarUrl: c.avatarUrl,
      content: c.content,
      timeMs: c.timeMs,
      likedCount: count < BigInt.zero ? BigInt.zero : count,
      liked: liked,
      replyCount: c.replyCount,
      ipLocation: c.ipLocation,
      hot: c.hot,
      repliedTo: c.repliedTo,
      parentId: c.parentId,
    );
  }

  /// [focusComposer] = 直接进写回复(「回复」按钮): 面板打开即聚焦输入框。
  /// 预览行/「展开全部」入口走默认 false = 浏览模式, 不抢输入框焦点。
  Future<void> _openReplies(
    rust.Comment comment, {
    bool focusComposer = false,
  }) async {
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _RepliesSheet(
        parent: comment,
        load: _loadReplies,
        reply: _reply,
        focusComposer: focusComposer,
      ),
    );
    if (sent != true || !mounted) return;
    final index = _items.indexWhere((c) => c.id == comment.id);
    if (index < 0) return;
    setState(() {
      final c = _items[index];
      _items[index] = rust.Comment(
        id: c.id,
        userId: c.userId,
        userName: c.userName,
        avatarUrl: c.avatarUrl,
        content: c.content,
        timeMs: c.timeMs,
        likedCount: c.likedCount,
        liked: c.liked,
        replyCount: c.replyCount + BigInt.one,
        ipLocation: c.ipLocation,
        hot: c.hot,
        repliedTo: c.repliedTo,
        parentId: c.parentId,
      );
    });
    // 刚发的回复要立刻出现在行内预览里: 丢缓存重拉一次并打上兜底标记
    _refreshPreview(comment.id);
  }

  /// 删除自己发的评论: 先确认, 成功后本地移除(不整页刷新)
  Future<void> _deleteComment(int index) async {
    final comment = _items[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这条评论?'),
        content: Text(
          comment.content.length > 60
              ? '${comment.content.substring(0, 60)}...'
              : comment.content,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _delete(comment.id);
      if (!mounted) return;
      setState(() {
        _items.removeAt(index);
        if (_total > BigInt.zero) _total -= BigInt.one;
      });
      _snack('已删除');
    } catch (e) {
      _snack('删除失败: ${friendlyError(e)}');
    }
  }

  // ---------------- 发表顶层评论 ----------------

  /// 能不能发评论: 需要 threadId(评论列表第一页返回, 资源类/动态都有)
  bool get _canCompose => _threadId.isNotEmpty;

  /// 新评论插在热评之后(与接口"精彩评论 + 最新"的顺序一致)
  int get _draftIndex {
    final at = _items.indexWhere((c) => !c.hot);
    return at < 0 ? _items.length : at;
  }

  /// 打开"写评论"面板。面板负责输入/发送/失败重试, 这里负责本地插入与回滚。
  Future<void> _openCompose() async {
    if (!_canCompose) {
      _snack('评论暂时不可用, 请先重试加载评论');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ComposeSheet(submit: _submitComment),
    );
  }

  /// 外部入口: 动态详情页的「评论」按钮经 `GlobalKey<CommentThreadState>` 调到这里。
  /// 先把评论区滚到可见, 再打开写评论面板 —— 面板里的 TextField 自带 autofocus,
  /// 所以「打开面板」就是「聚焦输入框」(本组件不常驻输入框, 见 _ComposerBar 注释)。
  void focusComposer() {
    Scrollable.ensureVisible(context);
    _openCompose();
  }

  /// 发顶层评论: 先乐观插入(无头像 / "刚刚"), 失败回滚并把异常抛回面板。
  /// 走 [CommentSendHook](= rust.replyComment + commentId 0), 没有新增 FFI。
  Future<void> _submitComment(String content) async {
    final at = _draftIndex;
    final draft = rust.Comment(
      // 服务端还没回 id: 这一项不给"删除"入口(id == 0 时不显示删除)
      id: BigInt.zero,
      userId: _myUid,
      userName: '我',
      avatarUrl: null,
      content: content,
      timeMs: BigInt.from(DateTime.now().millisecondsSinceEpoch),
      likedCount: BigInt.zero,
      liked: false,
      replyCount: BigInt.zero,
      ipLocation: '',
      hot: false,
      parentId: BigInt.zero,
    );
    setState(() {
      _items.insert(at, draft);
      _total += BigInt.one;
    });
    try {
      await _send(BigInt.zero, content);
    } catch (e) {
      // 回滚乐观项: 用对象身份定位, 不受相同文案的其它评论影响
      if (mounted) {
        setState(() {
          final i = _items.indexWhere((c) => identical(c, draft));
          if (i >= 0) _items.removeAt(i);
          if (_total > BigInt.zero) _total -= BigInt.one;
        });
      }
      rethrow; // 面板据此显示 friendlyError 并保留已输入文本
    }
    if (!mounted) return;
    // 乐观项是「我 / 刚刚 / 无头像」: 发表成功后静默重取一页, 用服务端的真实
    // 昵称/头像/时间/评论 id 替换掉, 并把这条滚进视野 + 高亮一下。
    // 不做这一步, 用户看到的就是一条假头像的"我", 得退出重进才正常。
    await _reload(silent: true);
    if (!mounted) return;
    final posted = _items.where((c) =>
        c.id != BigInt.zero && c.userId == _myUid && c.content == content);
    if (posted.isNotEmpty) {
      // 同文案的旧评论可能有多条, 取最新发的那条
      final newest = posted.reduce((a, b) => a.timeMs >= b.timeMs ? a : b);
      _revealComment(newest.id);
    } else {
      // 服务端偶尔还没把新评论带进第一页(缓存/延迟): 保留乐观项,
      // 否则用户会看到自己刚发的评论凭空消失
      setState(() {
        // 重载已经把列表换掉了(乐观项不在了)才补回去; 还在就别插第二次,
        // 否则同一个 draft 会有两个 key → "Duplicate keys found"
        if (!_items.any((c) => identical(c, draft))) {
          _items.insert(at.clamp(0, _items.length), draft);
          _total += BigInt.one;
        }
      });
    }
    _snack('已发表');
  }

  /// 把某条评论滚进视野并高亮 ~1.8s.
  ///
  /// 用 Scrollable.ensureVisible(不假设外层是哪种滚动容器), 对齐到视口上部 1/4;
  /// 高亮用列表项的 key 定位, 拿不到 context(被虚拟化/已销毁)时静默跳过。
  void _revealComment(BigInt id) {
    setState(() => _highlightId = id);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _highlightId = null);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _tileKeys[id]?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.25,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
      );
    });
  }

  /// 只有资源类评论(歌曲/歌单/专辑/播客)能查热门; 动态评论的 threadId 带 uid, 接口不认
  bool get _supportsHot => widget.kind != null || widget.loadHot != null;

  bool get _canHot => _threadId.isNotEmpty || widget.loadHot != null;

  /// 切"全部/热门": 换加载器并整页重载
  void _switchMode(bool hot) {
    if (_hot == hot) return;
    setState(() {
      _hot = hot;
      _items.clear();
      _total = BigInt.zero;
      _hasMore = false;
    });
    _reload();
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _relative(BigInt timeMs) {
    if (timeMs <= BigInt.zero) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(timeMs.toInt());
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = (_loading || _error != null) && _total == BigInt.zero
        ? BigInt.from(widget.totalHint)
        : _total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                widget.title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              // 有统计条时不再重复显示裸评论数(统计条里已是紧凑格式)
              if (count > BigInt.zero && _stats == null) ...[
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
          if (_stats != null) ...[
            const SizedBox(height: 4),
            CommentStatsBar(
              view: CommentStatsView(
                commentCount: _stats!.commentCount.toInt(),
                shareCount: _stats!.shareCount.toInt(),
                likedCount: _stats!.likedCount.toInt(),
              ),
            ),
          ],
          if (_supportsHot) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: !_hot,
                  onSelected: (_) => _switchMode(false),
                ),
                ChoiceChip(
                  label: const Text('热门'),
                  selected: _hot,
                  onSelected: _canHot ? (_) => _switchMode(true) : null,
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_error != null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(color: scheme.error, fontSize: 12),
                  ),
                ),
                TextButton(onPressed: _reload, child: const Text('重试')),
              ],
            )
          else if (_items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('还没有评论', style: theme.textTheme.bodySmall),
            )
          else
            for (var i = 0; i < _items.length; i++)
              _CommentTile(
                // 乐观项(id == 0)没有服务端 id, 共用一个 key; 其余按 id 缓存
                key: _items[i].id == BigInt.zero
                    ? _draftKey
                    : _tileKeys.putIfAbsent(
                        _items[i].id, () => GlobalKey()),
                highlight: _highlightId != null &&
                    _highlightId == _items[i].id,
                comment: _items[i],
                timeText: _relative(_items[i].timeMs),
                onToggleLike: () => _toggleLike(i),
                previewReplies: _previewFor(_items[i]),
                onExpandReplies: () => _openReplies(_items[i]),
                onReply: () => _openReplies(_items[i], focusComposer: true),
                // 刚发表的乐观项(id == 0)还没有服务端 id, 不给删除入口
                onDelete: _myUid != BigInt.zero &&
                        _items[i].userId == _myUid &&
                        _items[i].id != BigInt.zero
                    ? () => _deleteComment(i)
                    : null,
              ),
          if (!_loading && _error == null && _items.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_loadingMore)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (_moreError != null)
                  TextButton(
                    onPressed: _loadMore,
                    child: Text(
                      '${_moreError!} (重试)',
                      style: TextStyle(color: scheme.error, fontSize: 12),
                    ),
                  )
                else if (_hasMore)
                  TextButton(onPressed: _loadMore, child: const Text('加载更多评论')),
              ],
            ),
          ],
          // 底部"写评论"入口: 点开才是 TextField(见 _ComposeSheet)。
          // 不常驻输入框的两个理由: 楼层回复面板里已有一个 TextField,
          // 常驻会让"写评论/发回复"在语义与测试上互相歧义;
          // 且评论区常嵌在 75% 高的弹层里, 常驻输入框会被键盘压住。
          _ComposerBar(enabled: _canCompose, onTap: _openCompose),
        ],
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    super.key,
    required this.comment,
    required this.timeText,
    required this.onToggleLike,
    required this.onExpandReplies,
    required this.onReply,
    this.previewReplies = const [],
    this.onDelete,
    this.highlight = false,
  });

  /// 刚发表的那条: 短暂高亮底色, 让人一眼看到自己发的评论
  final bool highlight;

  final rust.Comment comment;
  final String timeText;
  final VoidCallback onToggleLike;

  /// 看全部回复: 预览行与「展开全部 N 条回复」入口共用
  final VoidCallback onExpandReplies;

  /// 直接进写回复(面板打开即聚焦输入框)
  final VoidCallback onReply;

  /// 行内预览的前 K 条回复(顶层 tile 专用; 楼层预览失败时为空)
  final List<rust.Comment> previewReplies;

  /// 只有自己发的评论才给(别人的评论官方也不允许删)
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      // 刚发表的那条淡出一层底色, 1.8s 后由父级把 highlight 置回 false
      decoration: BoxDecoration(
        color: highlight
            ? scheme.primaryContainer.withValues(alpha: 0.45)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.only(bottom: 12, top: 2, left: 2, right: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleCover(
            url: comment.avatarUrl,
            size: 32,
            icon: Icons.person_outline,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.userName.isEmpty ? '匿名用户' : comment.userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: scheme.primary),
                      ),
                    ),
                    // 楼层里的回复: 不显示"回复 @某人"就跟独立评论长得一样
                    if ((comment.repliedTo ?? '').isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '回复 @${comment.repliedTo}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                    if (comment.hot) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '热门',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onPrimaryContainer,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                    if (timeText.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        timeText,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.outline),
                      ),
                    ],
                    if (comment.ipLocation.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        comment.ipLocation,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.outline),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(comment.content, style: theme.textTheme.bodyMedium),
                // 行内回复预览: 点任意一条 → 打开楼层详情(与「回复」动作分离见下)
                for (final r in previewReplies)
                  InkWell(
                    onTap: onExpandReplies,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '${r.userName.isEmpty ? '匿名用户' : r.userName}：${r.content}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                // 独立的展开入口: 只要楼层有回复就给, 预览失败也能从这进详情
                if (comment.replyCount > BigInt.zero)
                  InkWell(
                    onTap: onExpandReplies,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '展开全部 ${comment.replyCount} 条回复',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.primary),
                      ),
                    ),
                  ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    InkWell(
                      onTap: onToggleLike,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              comment.liked
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              size: 14,
                              color: comment.liked
                                  ? scheme.primary
                                  : scheme.outline,
                            ),
                            if (comment.likedCount > BigInt.zero) ...[
                              const SizedBox(width: 3),
                              Text(
                                '${comment.likedCount}',
                                style: theme.textTheme.labelSmall
                                    ?.copyWith(color: scheme.outline),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // 「回复」= 写回复动作本体(打开面板并聚焦输入框);
                    // 数量与浏览全量回复由预览行/「展开全部」承担, 不再混在一个按钮里。
                    InkWell(
                      onTap: onReply,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.mode_comment_outlined,
                                size: 14, color: scheme.outline),
                            const SizedBox(width: 3),
                            Text(
                              '回复',
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: scheme.outline),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (onDelete != null) ...[
                      const SizedBox(width: 10),
                      InkWell(
                        onTap: onDelete,
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.delete_outline,
                                  size: 14, color: scheme.outline),
                              const SizedBox(width: 3),
                              Text(
                                '删除',
                                style: theme.textTheme.labelSmall
                                    ?.copyWith(color: scheme.outline),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 楼层: 某条评论的回复列表 + 底部输入框发回复
class _RepliesSheet extends StatefulWidget {
  const _RepliesSheet({
    required this.parent,
    required this.load,
    required this.reply,
    this.focusComposer = false,
  });

  final rust.Comment parent;
  final CommentRepliesLoader load;
  final CommentReplyHook reply;

  /// true = 「回复」动作打开: 直接聚焦输入框进写回复
  final bool focusComposer;

  @override
  State<_RepliesSheet> createState() => _RepliesSheetState();
}

class _RepliesSheetState extends State<_RepliesSheet> {
  static const _limit = 20;
  final TextEditingController _controller = TextEditingController();
  List<rust.Comment>? _replies;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final page = await retryNetwork(() => widget.load(widget.parent.id, _limit));
      if (!mounted) return;
      setState(() => _replies = page.comments);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _send() async {
    final content = _controller.text.trim();
    if (content.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.reply(widget.parent.id, content);
      if (!mounted) return;
      _controller.clear();
      FocusScope.of(context).unfocus();
      await _load();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final replies = _replies;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '回复',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.parent.userName}: ${widget.parent.content}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: replies == null
                  ? (_error == null
                      ? const Center(child: CircularProgressIndicator())
                      : Center(
                          child: Text(
                            _error!,
                            style: TextStyle(color: scheme.error, fontSize: 12),
                          ),
                        ))
                  : replies.isEmpty
                      ? Center(
                          child: Text('还没有回复', style: theme.textTheme.bodySmall),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: replies.length,
                          itemBuilder: (context, i) {
                            final r = replies[i];
                            return ListTile(
                              dense: true,
                              leading: CircleCover(
                                url: r.avatarUrl,
                                size: 28,
                                icon: Icons.person_outline,
                              ),
                              title: Text(
                                r.userName.isEmpty ? '匿名用户' : r.userName,
                                style: theme.textTheme.labelMedium
                                    ?.copyWith(color: scheme.primary),
                              ),
                              subtitle: Text(
                                (r.repliedTo ?? '').isEmpty
                                    ? r.content
                                    : '回复 @${r.repliedTo}：${r.content}',
                              ),
                            );
                          },
                        ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        autofocus: widget.focusComposer,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '回复这条评论…',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _sending ? null : _send,
                      child: _sending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('发送'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 评论区底部"写评论"入口(点击打开输入面板)。
class _ComposerBar extends StatelessWidget {
  const _ComposerBar({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.edit_outlined,
                    size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    enabled ? '写评论…' : '评论暂时不可用',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                Icon(Icons.send,
                    size: 18,
                    color: enabled ? scheme.primary : scheme.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 发表顶层评论的输入面板: TextField + 发送(不新增 FFI, 发送走 [submit])。
///
/// 键盘避让: 面板整体按 MediaQuery.viewInsets.bottom 抬升。它是
/// isScrollControlled 的 bottom sheet, 高度随内容撑开, 底部再垫键盘高度,
/// 所以输入框始终贴在键盘上沿 —— 从详情页的评论区弹层里打开也一样。
class _ComposeSheet extends StatefulWidget {
  const _ComposeSheet({required this.submit});

  /// 真正的发送动作(父级做乐观插入 + 失败回滚); 抛异常 = 失败
  final Future<void> Function(String content) submit;

  @override
  State<_ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends State<_ComposeSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 空文本 / 发送中都不给发
  bool get _canSend => !_sending && _controller.text.trim().isNotEmpty;

  Future<void> _send() async {
    if (!_canSend) return;
    final content = _controller.text.trim();
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.submit(content);
      if (!mounted) return;
      _controller.clear();
      FocusScope.of(context).unfocus();
      Navigator.of(context).pop();
    } catch (e) {
      // 失败: 保留已输入文本, 原地给 friendlyError, 按钮恢复可点(= 重试)
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      // 键盘避让(弹层内打开同样生效)
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '写评论',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                maxLength: 140,
                textInputAction: TextInputAction.newline,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '说点什么…',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(
                  _error!,
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        _sending ? null : () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _canSend ? _send : null,
                    child: _sending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('发送'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
