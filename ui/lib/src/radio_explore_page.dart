// 电台发现页(只读): 顶部分类胶囊(dj_catelist) → 选中分类拉推荐电台(dj_recommend_type),
// 「精选」分类显示 dj_category_recommend 的各分类精选.
// 中部榜单页签: 热门/新晋/付费(电台榜) + 主播(最热主播榜).
// 点行打开已有 showPodcastDetail(由调用方注入 onOpenRadio, 以便复用上层播放回调).
// 只读, 不做订阅等写操作; 全部接口匿名可用.
import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'format.dart' show formatDurationMs;

/// 可注入加载器(测试用 mock)
typedef LoadRadioHome = Future<rust.RadioExploreHome?> Function();
typedef LoadRadioRecommend = Future<List<rust.PodcastRadio>> Function(BigInt cateId);
typedef LoadRadioToplist = Future<rust.RadioToplistDto?> Function(String kind);

/// 点电台行(调用方接 showPodcastDetail + 播放回调)
typedef OnOpenRadio = void Function(BuildContext context, rust.PodcastRadio radio);

/// 播放回调链(与详情页 onPlaySongs 同一签名): 节目榜点行直接播放该节目
typedef OnPlaySongs = void Function(List<rust.SongDto> songs, int index);

class RadioExplorePage extends StatefulWidget {
  const RadioExplorePage({
    super.key,
    this.loadHome,
    this.loadRecommend,
    this.loadToplist,
    this.onOpenRadio,
    this.onPlaySongs,
  });

  final LoadRadioHome? loadHome;
  final LoadRadioRecommend? loadRecommend;
  final LoadRadioToplist? loadToplist;
  final OnOpenRadio? onOpenRadio;

  /// 节目榜点行直接播放该节目(不传则回落打开电台详情)
  final OnPlaySongs? onPlaySongs;

  @override
  State<RadioExplorePage> createState() => _RadioExplorePageState();
}

class _RadioExplorePageState extends State<RadioExplorePage> {
  rust.RadioExploreHome? _home;
  String? _error;
  bool _loading = true;

  /// 当前选中分类: null = 精选(各分类推荐聚合)
  rust.RadioCategory? _selected;
  List<rust.PodcastRadio>? _recommend;
  String? _recommendError;

  /// 当前榜单页签(热门/新晋/付费/主播)
  String _topKind = 'hot';
  rust.RadioToplistDto? _toplist;
  String? _toplistError;

  LoadRadioHome get _loadHome =>
      widget.loadHome ?? () => retryNetwork(() => rust.radioExploreHome());

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final home = await _loadHome();
      if (!mounted) return;
      setState(() {
        _home = home;
        _loading = false;
      });
      _loadToplist(_topKind);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  /// 选中/切回精选时拉推荐电台
  Future<void> _selectCategory(rust.RadioCategory? cat) async {
    setState(() {
      _selected = cat;
      _recommend = null;
      _recommendError = null;
    });
    if (cat == null) return; // 精选用 home.picks, 不再请求
    final loader = widget.loadRecommend ??
        (BigInt id) => retryNetwork(() => rust.radioRecommend(cateId: id));
    try {
      final list = await loader(cat.id);
      if (!mounted) return;
      setState(() => _recommend = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _recommendError = friendlyError(e));
    }
  }

  Future<void> _loadToplist(String kind) async {
    setState(() {
      _topKind = kind;
      _toplist = null;
      _toplistError = null;
    });
    final loader =
        widget.loadToplist ?? (String k) => retryNetwork(() => rust.radioToplist(kind: k));
    try {
      final t = await loader(kind);
      if (!mounted || kind != _topKind) return;
      setState(() => _toplist = t);
    } catch (e) {
      if (!mounted || kind != _topKind) return;
      setState(() => _toplistError = friendlyError(e));
    }
  }

  void _openRadio(rust.PodcastRadio radio) {
    widget.onOpenRadio?.call(context, radio);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('电台广场')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.cloud_off, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text('加载失败: $_error', textAlign: TextAlign.center),
          ),
          const SizedBox(height: 12),
          Center(child: FilledButton(onPressed: _load, child: const Text('重试'))),
        ],
      );
    }
    final home = _home;
    final categories = home?.categories ?? const <rust.RadioCategory>[];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(12, 8, 12, 24 + MediaQuery.viewPaddingOf(context).bottom),
        children: [
          _CategoryChips(
            categories: categories,
            selectedId: _selected?.id,
            onSelected: _selectCategory,
          ),
          const SizedBox(height: 12),
          if (_selected == null) ..._buildPicks(context, home) else ..._buildRecommend(context),
          const SizedBox(height: 16),
          _ToplistTabs(
            kind: _topKind,
            onKindChanged: _loadToplist,
            toplist: _toplist,
            error: _toplistError,
            onRetry: () => _loadToplist(_topKind),
            onOpenRadio: (ctx, radio) => _openRadio(radio),
            onPlaySongs: widget.onPlaySongs,
          ),
        ],
      ),
    );
  }

  List<Widget> _buildPicks(BuildContext context, rust.RadioExploreHome? home) {
    final picks = home?.picks ?? const <rust.RadioPick>[];
    if (picks.isEmpty) {
      return const [
        SizedBox(height: 32),
        Center(child: Text('暂无精选电台')),
        SizedBox(height: 32),
      ];
    }
    return [
      for (final g in picks) ...[
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text(g.categoryName, style: Theme.of(context).textTheme.titleSmall),
        ),
        for (final r in g.radios)
          _RadioRow(
            radio: r,
            trailing: r.playCount > BigInt.zero ? _fmtCount(r.playCount) : '',
            onTap: () => _openRadio(r),
          ),
      ],
    ];
  }

  List<Widget> _buildRecommend(BuildContext context) {
    if (_recommendError != null) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            children: [
              Text('加载失败: $_recommendError', textAlign: TextAlign.center),
              const SizedBox(height: 8),
              FilledButton(onPressed: () => _selectCategory(_selected), child: const Text('重试')),
            ],
          ),
        ),
      ];
    }
    final list = _recommend;
    if (list == null) {
      return const [Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))];
    }
    if (list.isEmpty) {
      return const [
        SizedBox(height: 32),
        Center(child: Text('该分类暂无推荐电台')),
        SizedBox(height: 32),
      ];
    }
    return [
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Text('「${_selected!.name}」推荐电台', style: Theme.of(context).textTheme.titleSmall),
      ),
      for (final r in list)
        _RadioRow(
          radio: r,
          trailing: r.playCount > BigInt.zero ? _fmtCount(r.playCount) : '',
          onTap: () => _openRadio(r),
        ),
    ];
  }
}

// ---------------- 分类胶囊 ----------------

class _CategoryChips extends StatelessWidget {
  const _CategoryChips({required this.categories, required this.selectedId, required this.onSelected});

  final List<rust.RadioCategory> categories;
  final BigInt? selectedId;
  final void Function(rust.RadioCategory? cat) onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: const Text('精选'),
              selected: selectedId == null,
              onSelected: (_) => onSelected(null),
            ),
          ),
          for (final c in categories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(c.name),
                selected: selectedId == c.id,
                onSelected: (_) => onSelected(c),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------- 推荐电台行 ----------------

class _RadioRow extends StatelessWidget {
  const _RadioRow({required this.radio, required this.onTap, this.trailing});

  final rust.PodcastRadio radio;
  final VoidCallback onTap;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (radio.djName.isNotEmpty) radio.djName,
      if (radio.programCount > BigInt.zero) '${radio.programCount} 集',
      if (trailing != null && trailing!.isNotEmpty) trailing!,
    ].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CoverArt(url: radio.coverUrl, size: 48, radius: 6),
      title: Text(radio.name, overflow: TextOverflow.ellipsis, maxLines: 1),
      subtitle: subtitle.isEmpty ? null : Text(subtitle, overflow: TextOverflow.ellipsis, maxLines: 1),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

// ---------------- 榜单页签 ----------------

class _ToplistTabs extends StatelessWidget {
  const _ToplistTabs({
    required this.kind,
    required this.onKindChanged,
    required this.toplist,
    required this.error,
    required this.onRetry,
    required this.onOpenRadio,
    this.onPlaySongs,
  });

  final String kind;
  final void Function(String kind) onKindChanged;
  final rust.RadioToplistDto? toplist;
  final String? error;
  final VoidCallback onRetry;
  final OnOpenRadio onOpenRadio;
  final OnPlaySongs? onPlaySongs;

  static const _kinds = [
    ('hot', '热门'),
    ('new', '新晋'),
    ('pay', '付费'),
    ('popular', '主播'),
    ('program', '节目'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('电台榜单', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final (k, label) in _kinds)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: kind == k,
                    onSelected: (_) => onKindChanged(k),
                  ),
                ),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              children: [
                Text('加载失败: $error', textAlign: TextAlign.center),
                const SizedBox(height: 8),
                FilledButton(onPressed: onRetry, child: const Text('重试')),
              ],
            ),
          )
        else if (toplist == null)
          const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
        else ..._buildEntries(context, toplist!),
      ],
    );
  }

  /// 节目榜点行: 有音频直接播放(走注入的 onPlaySongs 回调链);
  /// 无音频本体回落打开所属电台详情(只读榜单接口部分节目不带 song).
  void _openProgram(BuildContext context, rust.PodcastProgramDto p) {
    final song = p.song;
    final play = onPlaySongs;
    if (song != null && play != null) {
      play([song], 0);
      return;
    }
    onOpenRadio(
      context,
      rust.PodcastRadio(
        id: p.radioId,
        name: p.radioName.isEmpty ? p.name : p.radioName,
        description: p.description,
        djName: p.djName,
        programCount: BigInt.zero,
        playCount: BigInt.zero,
      ),
    );
  }

  List<Widget> _buildEntries(BuildContext context, rust.RadioToplistDto t) {
    if (t.radios.isEmpty && t.djs.isEmpty && t.programs.isEmpty) {
      return const [
        SizedBox(height: 24),
        Center(child: Text('该榜单暂无数据')),
        SizedBox(height: 24),
      ];
    }
    return [
      // 节目榜: 排名 + 节目名 + 电台名 + 主播 + 时长, 点行直接播放
      for (final pr in t.programs)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _rankBadge(pr.rank, pr.program.coverUrl ?? ''),
          title: Text(pr.program.name, overflow: TextOverflow.ellipsis, maxLines: 1),
          subtitle: Text(
            [
              if (pr.program.radioName.isNotEmpty) pr.program.radioName,
              if (pr.program.djName.isNotEmpty) pr.program.djName,
              formatDurationMs(pr.program.durationMs),
            ].join(' · '),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          trailing: Icon(
            pr.program.song != null ? Icons.play_arrow : Icons.chevron_right,
          ),
          onTap: () => _openProgram(context, pr.program),
        ),
      for (final r in t.radios)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _rankBadge(r.rank, r.coverUrl),
          title: Text(r.name, overflow: TextOverflow.ellipsis, maxLines: 1),
          subtitle: Text(
            [r.djName, if (r.programCount > BigInt.zero) '${r.programCount} 集', _fmtCount(r.playCount)]
                .where((s) => s.isNotEmpty)
                .join(' · '),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => onOpenRadio(
            context,
            rust.PodcastRadio(
              id: r.radioId,
              name: r.name,
              coverUrl: r.coverUrl.isEmpty ? null : r.coverUrl,
              description: r.rcmdText,
              djName: r.djName,
              programCount: r.programCount,
              playCount: r.playCount,
            ),
          ),
        ),
      // 主播榜: 用户行, 不跳详情(电台详情需要 radioId)
      for (final d in t.djs)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _rankBadge(d.rank, d.avatarUrl),
          title: Text(d.nickname, overflow: TextOverflow.ellipsis, maxLines: 1),
          subtitle: Text(
            '热度 ${_fmtCount(d.score)} · 粉丝 ${_fmtCount(d.followedCount)}',
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
    ];
  }

  Widget _rankBadge(int rank, String imageUrl) {
    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        children: [
          CoverArt(url: imageUrl, size: 48, radius: 6),
          Positioned(
            left: 0,
            top: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: rank <= 3 ? Colors.deepOrange : Colors.black54,
                borderRadius: const BorderRadius.only(bottomRight: Radius.circular(6)),
              ),
              child: Text(
                '$rank',
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


String _fmtCount(BigInt n) {
  final v = n.toInt();
  if (v < 10000) return '$v';
  final w = v / 10000;
  final s = w >= 100 ? w.round().toString() : w.toStringAsFixed(1).replaceAll('.0', '');
  return '$s万';
}
