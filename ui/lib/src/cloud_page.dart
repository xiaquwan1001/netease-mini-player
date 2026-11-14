import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Uint64List;

import 'adaptive_text.dart';
import 'async_view.dart';
import 'cover_art.dart';
import 'file_pick.dart' show pickAudioFile;
import 'layout.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'toast.dart' show showToast;

/// 音乐云盘页(我的 → 音乐云盘).
///
/// 依赖全部注入(取数/删除/播放), 便于 widget 测试不联网、不碰 FFI:
/// - [loadPage]: 拉一页云盘条目(`limit`/`offset`), 生产走 `rust.userCloud`;
/// - [deleteSongs]: 删除(入参是**云盘条目 id**, 即 [rust.CloudSong.id]), 生产走 `rust.cloudDelete`;
/// - [onPlay]: 点行播放, 由入口(mine_view)注入现有播放器; 不注入则行不可点。
///
/// 上传(NOS 分片)本轮不做, 空态文案直接指路官方 App。

/// 云盘一页的条数(上游 limit).
const int kCloudPageSize = 100;

/// 字节数 → 人能读的大小(`3.8 MB` / `512 KB` / `1.2 GB`)。
///
/// 云盘行副标题要显示文件大小, 而 4 000 000 这种原始字节数用户读不出来。
/// 只保留 1 位小数(1024 进制), 0 字节给空串(老数据没 fileSize 时不要显示 "0 B")。
String formatBytes(int bytes) {
  if (bytes <= 0) return '';
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  // 字节数不带小数(B 档没有意义), 其余档保留 1 位
  final text = unit == 0
      ? value.round().toString()
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// 云盘行副标题: 歌手 · 大小(歌手为空就只显示大小)。
String cloudSubtitle(rust.CloudSong song) {
  final size = formatBytes(song.size.toInt());
  if (song.artist.isEmpty) return size;
  return size.isEmpty ? song.artist : '${song.artist} · $size';
}

typedef CloudPageLoader = Future<rust.CloudPage> Function(int limit, int offset);
typedef CloudDeleter = Future<bool> Function(Uint64List ids);

/// 上传本地文件: 入参是本地绝对路径, 返回新歌 id/歌名(生产走 rust.cloudUpload)。
typedef CloudUploader = Future<rust.CloudUploadResult> Function(String path);

/// 打开音乐云盘页(入口只需一行).
Future<void> showCloudPage(
  BuildContext context, {
  CloudPageLoader? loadPage,
  CloudDeleter? deleteSongs,
  CloudUploader? upload,
  Future<String?> Function()? pickFile,
  void Function(rust.CloudSong song)? onPlay,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => CloudPage(
        loadPage: loadPage,
        deleteSongs: deleteSongs,
        upload: upload,
        pickFile: pickFile,
        onPlay: onPlay,
      ),
    ),
  );
}

class CloudPage extends StatefulWidget {
  const CloudPage({
    super.key,
    this.loadPage,
    this.deleteSongs,
    this.upload,
    this.pickFile,
    this.onPlay,
  });

  final CloudPageLoader? loadPage;
  final CloudDeleter? deleteSongs;

  /// 上传实现(缺省 rust.cloudUpload)
  final CloudUploader? upload;

  /// 选文件实现(缺省跨平台 pickAudioFile); 测试注入固定路径
  final Future<String?> Function()? pickFile;
  final void Function(rust.CloudSong song)? onPlay;

  @override
  State<CloudPage> createState() => _CloudPageState();
}

class _CloudPageState extends State<CloudPage> {
  /// 已加载的条目(翻页是累加, 刷新是清空重来).
  final List<rust.CloudSong> _songs = <rust.CloudSong>[];
  late Future<List<rust.CloudSong>> _future;
  bool _more = false;
  bool _loadingMore = false;
  bool _deleting = false;
  bool _uploading = false;

  /// 云盘容量(第一页带回来的 count/size/maxSize, 只用于 AppBar 下的说明行)
  int _total = 0;
  int _used = 0;
  int _capacity = 0;

  CloudPageLoader get _loader =>
      widget.loadPage ?? (limit, offset) => rust.userCloud(limit: limit, offset: offset);
  CloudDeleter get _deleter =>
      widget.deleteSongs ?? (ids) => rust.cloudDelete(ids: ids);
  CloudUploader get _uploader =>
      widget.upload ?? (path) => rust.cloudUpload(filePath: path);

  @override
  void initState() {
    super.initState();
    _future = _fetch(reset: true);
  }

  /// 取一页: [reset] 为真时清空并从 offset 0 重来(刷新/重试), 否则追加(加载更多)。
  Future<List<rust.CloudSong>> _fetch({required bool reset}) async {
    final offset = reset ? 0 : _songs.length;
    final page = await _loader(kCloudPageSize, offset);
    if (reset) {
      _songs
        ..clear()
        ..addAll(page.songs);
    } else {
      _songs.addAll(page.songs);
    }
    _more = page.more && page.songs.isNotEmpty;
    _total = page.count.toInt();
    _used = page.size.toInt();
    _capacity = page.maxSize.toInt();
    return List<rust.CloudSong>.unmodifiable(_songs);
  }

  Future<void> _refresh() async {
    final next = _fetch(reset: true);
    // 用块体: 箭头体把 Future 当 setState 回调返回值, Flutter 会断言失败
    setState(() {
      _future = next;
    });
    // RefreshIndicator 要等取数结束才收起转圈
    await next.catchError((_) => <rust.CloudSong>[]);
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_more) return;
    setState(() {
      _loadingMore = true;
    });
    try {
      final next = _fetch(reset: false);
      await next;
      if (mounted) {
        setState(() {
          _future = next;
        });
      }
    } catch (e) {
      if (mounted) showToast(context, '加载更多失败: ${friendlyError(e)}', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _loadingMore = false;
        });
      }
    }
  }

  /// 上传: 选文件 → 调 Rust 五步流程(查重/取 token/上传/转码/发布)。
  /// Rust 是阻塞式一次调用(最长约 1 分钟), 所以这里用不可取消的进度对话框。
  Future<void> _upload() async {
    if (_uploading) return;
    final String? path;
    try {
      path = await (widget.pickFile ?? pickAudioFile)();
    } catch (e) {
      if (mounted) showToast(context, '选择文件失败: ${friendlyError(e)}', isError: true);
      return;
    }
    if (path == null || !mounted) return;
    final upload = _uploader;
    setState(() => _uploading = true);
    final navigator = Navigator.of(context, rootNavigator: true);
    var dialogShown = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _UploadingDialog(),
      ).then((_) => dialogShown = false),
    );
    try {
      final result = await upload(path);
      if (dialogShown) navigator.pop();
      if (!mounted) return;
      showToast(
        context,
        result.instant
            ? '云盘里已有同一文件, 已直接收录「${result.name}」'
            : '已上传「${result.name}」, 正在刷新列表',
      );
      await _refresh();
    } catch (e) {
      if (dialogShown) navigator.pop();
      if (mounted) showToast(context, '上传失败: ${friendlyError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _delete(rust.CloudSong song) async {
    if (_deleting) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从云盘删除'),
        content: Text('「${song.name}」删除后需要重新上传才能恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _deleting = true;
    });
    try {
      final done = await _deleter(Uint64List.fromList(<int>[song.id.toInt()]));
      if (!mounted) return;
      if (!done) {
        showToast(context, '删除失败，请稍后重试', isError: true);
        return;
      }
      setState(() {
        _songs.removeWhere((s) => s.id == song.id);
        _future = Future<List<rust.CloudSong>>.value(
          List<rust.CloudSong>.unmodifiable(_songs),
        );
      });
      showToast(context, '已从云盘删除');
    } catch (e) {
      if (mounted) showToast(context, '删除失败: ${friendlyError(e)}', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _deleting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('音乐云盘'),
        actions: [
          IconButton(
            tooltip: '上传音频到云盘',
            icon: _uploading
                // token-ok: 进度图标固定 18dp, 与 IconButton 图标同档
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.upload_file_outlined),
            onPressed: _uploading ? null : _upload,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: AsyncView<List<rust.CloudSong>>(
          future: _future,
          onRetry: _refresh,
          emptyText: '云盘还没有歌曲, 点右上角上传音频',
          builder: (context, songs, reload) => _list(context, songs, reload),
        ),
      ),
    );
  }

  Widget _list(
    BuildContext context,
    List<rust.CloudSong> songs,
    VoidCallback reload,
  ) {
    final bodySmall = Theme.of(context).textTheme.bodySmall;
    return ListView.builder(
      // 内容不足一屏时也要能下拉刷新
      physics: const AlwaysScrollableScrollPhysics(),
      padding: kPageInsets,
      itemCount: songs.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) return _capacityLine(context, bodySmall);
        if (index == songs.length + 1) return _footer(context, songs, bodySmall);
        final song = songs[index - 1];
        return ListTile(
          contentPadding: kCardRowPadding,
          leading: CoverArt(url: song.coverUrl, size: 48, radius: 6),
          title: AdaptiveText(song.name),
          subtitle: Text(
            cloudSubtitle(song),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: _deleting ? null : () => _delete(song),
          ),
          onTap: widget.onPlay == null ? null : () => widget.onPlay!(song),
        );
      },
    );
  }

  /// AppBar 下面的容量/条数说明行(上游没给就整行不显示, 不占位)
  Widget _capacityLine(BuildContext context, TextStyle? style) {
    final parts = <String>[
      if (_total > 0) '$_total 首',
      if (_used > 0) '已用 ${formatBytes(_used)}',
      if (_capacity > 0) '共 ${formatBytes(_capacity)}',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: kSectionHeaderPadding,
      child: Text(parts.join(' · '), style: style),
    );
  }

  Widget _footer(
    BuildContext context,
    List<rust.CloudSong> songs,
    TextStyle? style,
  ) {
    if (songs.isEmpty) return const SizedBox.shrink();
    if (_more) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: kSectionHeaderGap),
        child: Center(
          child: TextButton(
            onPressed: _loadingMore ? null : _loadMore,
            child: Text(_loadingMore ? '加载中…' : '加载更多'),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kSectionHeaderGap),
      child: Center(child: Text('已全部加载', style: style)),
    );
  }
}

/// 上传进度对话框: 上传+转码+发布是 Rust 里一次调用, 只能给不确定进度。
class _UploadingDialog extends StatelessWidget {
  const _UploadingDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: const Row(
        children: [
          // token-ok: 对话框内进度圈固定 22dp, 不参与页面栅格
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(width: kSectionGap),
          Expanded(
            child: Text(
              '正在上传并等待云端转码…\n(大文件可能需要几十秒)',
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}
