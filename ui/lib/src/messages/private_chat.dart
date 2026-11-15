import 'package:flutter/material.dart';

import '../cover_art.dart';
import '../net_retry.dart';
import '../rust/api.dart' as rust;
import '../sheet_header.dart';
import '../state_views.dart';
import '../toast.dart' show showToast;
import '../user_nav.dart';
import 'message_shared.dart' show MessageErrorRow;
import 'message_types.dart';

/// 单人私信历史(只读; 官方 App 才允许回复)
Future<void> showPrivateChat(
  BuildContext context, {
  required rust.PrivateSession session,
  required HistoryPageLoader load,
  PrivateSender? send,
  int pageSize = 30,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            SheetHeader(
              title: session.nickname,
              leading: CircleCover(
                url: session.avatarUrl,
                size: 36,
                icon: Icons.person_outline,
              ),
              onClose: () => Navigator.pop(context),
            ),
            const Divider(height: 1),
            Expanded(
              child: _ChatBody(
                session: session,
                load: load,
                send: send,
                pageSize: pageSize,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ChatBody extends StatefulWidget {
  const _ChatBody({
    required this.session,
    required this.load,
    required this.pageSize,
    this.send,
  });

  final rust.PrivateSession session;
  final HistoryPageLoader load;
  final int pageSize;

  /// 发送私信(为 null 时退回只读: 测试/宿主未注入时不显示输入框)
  final PrivateSender? send;

  @override
  State<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<_ChatBody> {
  List<rust.PrivateMessage>? _items;
  String? _error;
  bool _loadingOlder = false;
  bool _noMore = false;
  bool _sending = false;
  final TextEditingController _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  PrivateSender get _sender => widget.send ?? _rustSend;

  Future<bool> _rustSend(BigInt userId, String content) =>
      rust.privateSend(userId: userId, content: content);

  /// 发送一条私信: 成功后重拉最新一页(服务端回显才算数, 不做本地乐观插入)
  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final ok = await _sender(widget.session.userId, text);
      if (!mounted) return;
      if (ok) {
        _input.clear();
        await _load();
      }
    } catch (e) {
      if (!mounted) return;
      showToast(context, friendlyError(e), isError: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items = await retryNetwork(
        () => widget.load(widget.session.userId, widget.pageSize, BigInt.zero),
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _noMore = items.length < widget.pageSize;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  /// 加载更早: 用当前最早一条的 time_ms 当 before_ms, 不重复拉最新一页
  Future<void> _loadOlder() async {
    final items = _items;
    if (items == null || items.isEmpty || _loadingOlder || _noMore) return;
    final before = items.first.timeMs;
    if (before <= BigInt.zero) {
      // 没有可用游标(异常数据), 不再翻页
      setState(() => _noMore = true);
      return;
    }
    setState(() => _loadingOlder = true);
    try {
      final page = await retryNetwork(
        () => widget.load(widget.session.userId, widget.pageSize, before),
      );
      if (!mounted) return;
      final known = items.map((m) => m.id).toSet();
      final fresh = page.where((m) => !known.contains(m.id)).toList();
      setState(() {
        _items = [...fresh, ...items];
        _loadingOlder = false;
        if (page.length < widget.pageSize) _noMore = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingOlder = false;
        _error = friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 列表 + 底部输入框: 输入框只在有真实 uid 时出现(缺 uid 的会话给一句提示)
    return Column(
      children: [
        Expanded(child: _buildList(context)),
        if (UserNav.canOpen(widget.session.userId))
          _buildComposer(context)
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              '这个会话无法回复(缺少用户 id)',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  /// 底部发送框: 空内容/发送中禁用; 成功后重拉最新一页(不做本地乐观插入)
  Widget _buildComposer(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '发私信…',
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '发送',
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      // token-ok: 行内 spinner 的方形尺寸(与 Material 默认 18 一致), 不是间距
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (_error != null) {
      return MessageErrorRow(message: _error!, onRetry: _load);
    }
    final items = _items;
    if (items == null) {
      return const LoadingView();
    }
    if (items.isEmpty) {
      return const EmptyView(icon: Icons.notifications_none, title: '还没有消息');
    }
    final scheme = Theme.of(context).colorScheme;
    // 非分页: 私信按时间倒序锚底 + 向上"加载更早"(reverse + prepend), PagedListView 不支持该形态
    // 注意: 这个方法只负责列表本身, 外层 build 负责「列表 + 底部输入框」的 Column
    // reverse: 列表锚在底部(最新消息在下), 顶部是"加载更早"
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      reverse: true,
      itemCount: items.length + (_noMore ? 0 : 1),
      itemBuilder: (context, i) {
        if (i == items.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: _loadingOlder
                  ? const LoadingView.inline(size: 18)
                  : TextButton(
                      onPressed: _loadOlder,
                      child: const Text('加载更早'),
                    ),
            ),
          );
        }
        final m = items[items.length - 1 - i];
        final mine = m.fromMe;
        return Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72,
            ),
            decoration: BoxDecoration(
              color: mine
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              m.content,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        );
      },
    );
  }
}
