import 'package:flutter/material.dart';

import '../comment_thread.dart';
import '../cover_art.dart';
import '../error_views.dart' show InlineError;
import '../expandable_text.dart';
import '../layout.dart' show kPagePadding, rowExtentFor;
import '../net_retry.dart';
import '../podcast.dart' show ProgramDetailSheet, ProgramDetailLoader;
import '../radio_subscribers_page.dart';
import '../rust/api.dart' as rust;
import 'detail_shared.dart' show DetailSkeletonList, showResourceShareSheet;
import 'podcast_program_row.dart' show PodcastProgramRow;

// ---------------- 播客(电台)详情 ----------------

/// 打开播客/电台详情页(全屏路由). 电台订阅本轮不做(Rust 侧暂无接口)。
Future<void> showPodcastDetail(
  BuildContext context, {
  required rust.PodcastRadio radio,
  required void Function(List<rust.SongDto> songs, int index) onPlaySongs,
  ProgramDetailLoader? loadProgramDetail,
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _PodcastDetailPage(
        radio: radio,
        onPlaySongs: onPlaySongs,
        loadProgramDetail:
            loadProgramDetail ?? (id) => rust.podcastProgram(programId: id),
      ),
    ),
  );
}

class _PodcastDetailPage extends StatefulWidget {
  const _PodcastDetailPage({
    required this.radio,
    required this.onPlaySongs,
    required this.loadProgramDetail,
  });

  final rust.PodcastRadio radio;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;

  /// 单集详情(podcast_program), 测试可注入 mock
  final ProgramDetailLoader loadProgramDetail;

  @override
  State<_PodcastDetailPage> createState() => _PodcastDetailPageState();
}

class _PodcastDetailPageState extends State<_PodcastDetailPage> {
  final TextEditingController _filterController = TextEditingController();
  String _filter = '';

  List<rust.PodcastProgramDto>? _programs;
  String? _programsError;

  @override
  void initState() {
    super.initState();
    _loadPrograms();
  }

  @override
  void dispose() {
    _filterController.dispose();
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

  /// display 已经过滤掉 song 为空的节目, 行序即可播队列序
  void _playProgram(int index) {
    final songs = [
      for (final p in _display)
        if (p.song != null) p.song!,
    ];
    widget.onPlaySongs(songs, index);
  }

  @override
  Widget build(BuildContext context) {
    final radio = widget.radio;
    return Scaffold(
      appBar: AppBar(
        title: Text(radio.name),
        actions: [
          // 电台头部卡片没有订阅数字段(PodcastRadioDto 无 subCount),
          // 听众入口放 AppBar 图标(与分享并排).
          IconButton(
            tooltip: '听众',
            icon: const Icon(Icons.groups_outlined),
            onPressed: () => showRadioSubscribers(
              context,
              radioId: radio.id,
              radioName: radio.name,
              // 听众 -> 他人主页 -> 歌单, 这条链上要把播放回调带下去
              onPlaySongs: widget.onPlaySongs,
            ),
          ),
          IconButton(
            tooltip: '分享',
            icon: const Icon(Icons.share_outlined),
            onPressed: _showShareSheet,
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _buildHeaderCard(radio)),
          SliverToBoxAdapter(child: _buildToolbar()),
          _buildPrograms(_display),
          SliverToBoxAdapter(
            child: CommentThread(
              kind: 'podcast',
              resourceId: radio.id,
              // 评论分享卡片的语境(需求 10): 来自哪个播客
              shareSourceTitle: radio.name,
              shareSourceKind: commentSourceKindLabel('podcast'),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

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
                          child: Text(
                            radio.djName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${radio.programCount} 个节目 · 播放 ${radio.playCount} 次',
                          style: theme.textTheme.bodySmall,
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
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: TextField(
        controller: _filterController,
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
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
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

// ---------------- 共用件 ----------------

/// 简介: 默认 3 行 + 展开/收起(歌单/播客头部共用)
// 长文本展开/收起已收敛到 expandable_text.dart(与 artist_page 合并为一份)
