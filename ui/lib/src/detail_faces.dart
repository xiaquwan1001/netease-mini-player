import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'cover_art.dart'
    show
        CoverArt,
        coverRequestPx,
        fetchImageBytes,
        httpsImageUrl,
        showImageViewer;
import 'format.dart' show formatDurationShort;
import 'image_io.dart';
import 'net_retry.dart' show describeError;
import 'state_views.dart' show LoadingView;
import 'toast.dart';

/// 歌曲详情页(歌词页)的**两个面**。
enum DetailFace { lyrics, cover }

/// [face] 的另一面。
///
/// 播放条封面点击 = 在两面之间切换(见 home_page 的 onOpenDetail): 每次点都真的
/// "换个视图", 而不是单纯打开歌词页。翻面是纯函数, 页面与测试共用同一份判定。
DetailFace oppositeDetailFace(DetailFace face) =>
    face == DetailFace.cover ? DetailFace.lyrics : DetailFace.cover;

/// 详情页「歌词 ⇄ 封面」容器: 轻点画面在两面之间切换。
///
/// 为什么单独成一个控件(而不是写进 HomePage):
/// - 它只吃"当前曲目/节目的封面地址 + 一块歌词子树", 与歌词数据、播放器都无关;
///   播客单集播放时进队列的也是同一个 SongDto(见 detail/podcast_detail_page.dart
///   的 _playProgram), 所以**歌曲与播客共用这一份逻辑**, 没有第二套页面;
/// - 切面本身不写持久化设置(控件保持可测): 进面板时的初始面由页面按
///   AppSettings.detailFace 传 [initialFace], 用户切面经 [onFaceChanged] 回灌页面。
///
/// 手势口径(为什么点"歌词区"就等于切面):
/// - 歌词行的点击本来只在多选态才有语义(onLineTap 为 null 时不注册 tap),
///   非多选态的轻点此前什么都不做 —— 这里把它接成"切到封面";
/// - 拖动歌词是 Scrollable 自己的 drag 手势, 拖动成功后 tap 会被手势竞技场判负,
///   所以"滑动歌词"永远不会切面; 长按(多选)同理, 长按胜过轻点;
/// - 右下的翻译/定位按钮与封面面的三个按钮都在更深的层级, 自己的 tap 赢,
///   不会穿透到切面手势;
/// - 多选态由页面传 [tappable] = false 关掉切面手势(那层点击语义是"选中某句")。
///
/// 状态保留: 歌词面用 [Offstage] 常驻(与首页 _buildTabPages 同一手法),
/// 切到封面再切回来时滚动位置、多选、翻译开关都不丢; 播放中自动跟随在封面态
/// 仍然继续, 所以回到歌词时看到的是"当前正在唱的那句"(用户手动滑动过后仍按
/// 用户自己停下的位置)。
class DetailFaces extends StatefulWidget {
  const DetailFaces({
    super.key,
    required this.trackId,
    required this.coverUrl,
    required this.lyrics,
    this.tappable = true,
    this.initialFace = DetailFace.lyrics,
    this.faceController,
    this.onFaceChanged,
    this.onOpenComments,
    this.saveImage,
    this.fetchImage,
    this.positionMs,
    this.durationMs = 0,
  });

  /// 当前曲目/节目 id: 换歌**不再**强制回歌词(面是记忆的), 只用于让大图缓存失效
  final BigInt? trackId;

  /// 当前曲目/节目的封面地址; 空/取图失败时给中性占位, 不留白屏
  final String? coverUrl;

  /// 歌词面(页面自己构建, 这里只负责显隐)
  final Widget lyrics;

  /// 是否允许"轻点画面切面"。多选歌词时页面传 false。
  final bool tappable;

  /// 首帧用哪一面(进面板时的记忆面; 页面按持久化偏好传进来)。只在建树时读一次。
  final DetailFace initialFace;

  /// 外部请求切面(播放条封面点击用): 值变到另一面时本控件跟着翻。
  ///
  /// 用户在这里手动切面时也会同步写回, 于是页面/播放条看到的永远是"当前面"。
  /// 页面可选地持有唯一一份(与 [initialFace] 二选一注入), 测试里可注入自己的。
  final ValueNotifier<DetailFace>? faceController;

  /// 用户手动切面后的回灌(页面据此写回持久化偏好)
  final ValueChanged<DetailFace>? onFaceChanged;

  /// 封面面右下角「查看评论」: null 时不显示按钮(纯控件测试/无当前曲目时不依赖页面)
  final VoidCallback? onOpenComments;

  /// 保存实现(测试注入假实现, 不落盘); null = 走 [saveImageBytes]
  ///
  /// 类型**必须**与 saveImageBytes 完全一致(`{required String filename}`):
  /// 以前注入项写的是位置参数 `(Uint8List, String)`, `??` 两侧签名不同 ⇒ 推断出的
  /// LUB 退化成裸 `Function`, 静态检查失明, 运行期按位置参数去调命名参数实现
  /// ⇒ `NoSuchMethodError`(线上"保存封面"必崩)。
  final Future<String> Function(Uint8List bytes, {required String filename})?
  saveImage;

  /// 取原图字节实现(测试注入假实现, 不联网); null = 走 [fetchImageBytes]
  final Future<Uint8List> Function(String url)? fetchImage;

  /// 播放位置(毫秒), 封面面左下角「当前进度 / 总时长」显示用。
  ///
  /// 控件自己**不开定时器**: 页面把已有的高频源(歌词页展开期 120ms ticker 驱动的
  /// `LyricController.positionMs`)注进来, 只有这一行随位置重建。null = 位置按 0 显示。
  final ValueListenable<int>? positionMs;

  /// 当前曲目总时长(毫秒)。≤0(未知/无当前曲目)时总时长位显示 `--:--`。
  ///
  /// 时长按曲目静态, 与 [positionMs] 同一份播放态快照里读, 换曲时页面重建即更新,
  /// 所以这里用普通数值而不是第二个 listenable。
  final int durationMs;

  @override
  State<DetailFaces> createState() => _DetailFacesState();
}

/// 封面四周留白(方图不贴边)
const double _kCoverInset = 16;

/// 封面面**首帧小图**复用的逻辑尺寸: 与播放条的 CoverArt(size: 40) 同一档位,
/// 于是请求的是同一个 `?param=NxN` URL, 命中同一份字节缓存/ImageCache ——
/// 切面第一帧就有图, 不用等大图下载+解码(用户反馈"图片加载不跟手")。
const double _kThumbLogicalSize = 40;

/// 大图淡入时长(小图已在位, 只是把清晰的大图叠上来)
const Duration _kBigFade = Duration(milliseconds: 220);

/// 封面面左下角的进度文案: `当前 / 总时长`(如 `1:23 / 4:56`)。
///
/// 口径与 `formatDurationShort` 一致(分钟不补零, 超一小时继续累计), 不用
/// `formatDurationMs` —— 那个会补零成 `01:23`, 且满一小时变成 `1:02:03`.
/// 总时长 ≤0(未知/还没拿到)时给 `--:--`: 显示 `0:00` 会让人以为歌只有 0 秒;
/// 位置未知照常 `0:00`(那是真的还没开始)。
String _progressText(int positionMs, int durationMs) {
  final total = durationMs > 0
      ? formatDurationShort(BigInt.from(durationMs))
      : '--:--';
  return '${_progressClock(positionMs)} / $total';
}

String _progressClock(int ms) =>
    ms > 0 ? formatDurationShort(BigInt.from(ms)) : '0:00';

class _DetailFacesState extends State<DetailFaces> {
  late DetailFace _face = widget.faceController?.value ?? widget.initialFace;
  bool _saving = false;

  /// 大图字节缓存, 键 = `trackId|coverUrl`。
  ///
  /// - 同一首歌来回切面: 直接复用(不重复取图; Image.memory 用同一个 bytes
  ///   实例 ⇒ MemoryImage 相等 ⇒ 命中全局 ImageCache, 不重复解码);
  /// - 换歌/换封面: 键变了, 旧字节丢掉([_bigToken] 让在飞的那次结果作废)。
  Uint8List? _bigBytes;
  String? _bigKey;
  int _bigToken = 0;

  /// 大图淡入跑过一次就不再重放(切面回来瞬间就是清晰大图, 不再抖一下)
  bool _bigFaded = false;

  @override
  void initState() {
    super.initState();
    widget.faceController?.addListener(_onFaceRequested);
    if (_face == DetailFace.cover) _ensureBig();
  }

  @override
  void dispose() {
    widget.faceController?.removeListener(_onFaceRequested);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DetailFaces oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.faceController != widget.faceController) {
      oldWidget.faceController?.removeListener(_onFaceRequested);
      widget.faceController?.addListener(_onFaceRequested);
    }
    // 换歌/换节目: **面不重置**(用户要的是"记住上次看的是哪一面", 见
    // AppSettings.detailFace); 只把上一首的大图缓存作废 —— 否则会看到新歌的
    // 名字配上一张旧封面。
    if (oldWidget.trackId != widget.trackId ||
        oldWidget.coverUrl != widget.coverUrl) {
      _saving = false;
      _bigToken++;
      _bigBytes = null;
      _bigKey = null;
      _bigFaded = false;
      if (_face == DetailFace.cover) _ensureBig();
    }
  }

  /// 外部(播放条封面点击)请求切面: 跟随, 但**不**回灌 onFaceChanged ——
  /// 调用方(页面)是这次变更的来源, 偏好落盘由它自己写(见 home_page.onOpenDetail),
  /// 这里再回灌一次只会重复落盘。
  void _onFaceRequested() {
    final want = widget.faceController?.value;
    if (want == null || want == _face) return;
    setState(() {
      _face = want;
      if (want == DetailFace.cover) _ensureBig();
    });
  }

  void _toggleFace() {
    if (!widget.tappable) return;
    _setFace(oppositeDetailFace(_face));
  }

  /// 切面的唯一出口: 改本地面 → 通知页面(写回偏好) → 同步控制器
  void _setFace(DetailFace next) {
    if (next == _face) return;
    setState(() {
      _face = next;
      if (next == DetailFace.cover) _ensureBig();
    });
    widget.onFaceChanged?.call(next);
    final controller = widget.faceController;
    if (controller != null && controller.value != next) controller.value = next;
  }

  String get _cover => httpsImageUrl(widget.coverUrl);

  String get _bigCacheKey => '${widget.trackId ?? 'null'}|$_cover';

  /// 取当前封面的**大图字节**(每首歌每张封面只取一次)。
  ///
  /// 只改字段、不 setState: 调用点要么在 initState/didUpdateWidget(下一帧就是
  /// build), 要么在 setState 里面。完成后由 [_loadBig] 自己 setState 把大图叠上来。
  void _ensureBig() {
    if (_cover.isEmpty) return;
    final key = _bigCacheKey;
    if (_bigKey == key) return; // 已有字节 / 在飞
    _bigKey = key;
    _bigBytes = null;
    final token = ++_bigToken;
    unawaited(_loadBig(token));
  }

  Future<void> _loadBig(int token) async {
    final url = _cover;
    try {
      final bytes = await (widget.fetchImage ?? fetchImageBytes)(url);
      if (!mounted || token != _bigToken) return;
      setState(() => _bigBytes = bytes);
    } catch (_) {
      // 大图拿不到(403/超时): 保留小图, 不让整块退成占位/白屏。
      // `_bigKey` 仍记成"已尝试", 避免每帧重试导致的风暴; 换歌会重新给机会。
    }
  }

  /// 保存实现的统一入口(两侧签名相同, 这里显式约束类型, 防止 LUB 退化再犯)
  Future<String> Function(Uint8List bytes, {required String filename})
  get _saveBytes => widget.saveImage ?? saveImageBytes;

  Future<void> _save() async {
    if (_saving || _cover.isEmpty) return;
    setState(() => _saving = true);
    try {
      final bytes = await (widget.fetchImage ?? fetchImageBytes)(_cover);
      final where = await _saveBytes(bytes, filename: _filename(_cover));
      if (!mounted) return;
      showToast(context, '封面已保存: $where');
    } catch (e) {
      if (!mounted) return;
      showToast(context, '保存失败: ${describeError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 查看原图 = 复用全屏看图(可缩放 + 右上角"保存原图"), 不另写一份预览
  void _openViewer() {
    if (_cover.isEmpty) return;
    unawaited(
      showImageViewer(
        context,
        urls: [_cover],
        saveOverride: widget.saveImage,
        fetchOverride: widget.fetchImage,
      ),
    );
  }

  /// 保存文件名: 扩展名从 URL 猜(网易云 CDN 基本是 .jpg), 前缀带时间戳防重名
  String _filename(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final m = RegExp(
      r'\.(jpe?g|png|webp|gif)$',
      caseSensitive: false,
    ).firstMatch(path);
    final ext = (m?.group(1) ?? 'jpg').toLowerCase();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return 'MiniNCM_cover_$stamp.$ext';
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 歌词面: Offstage 常驻 —— 切走不销毁, 滚动位置/多选/翻译态都留着
        Positioned.fill(
          child: Offstage(
            offstage: _face == DetailFace.cover,
            child: GestureDetector(
              key: const ValueKey('detail-lyrics-face'),
              behavior: HitTestBehavior.opaque,
              onTap: widget.tappable ? _toggleFace : null,
              child: widget.lyrics,
            ),
          ),
        ),
        if (_face == DetailFace.cover)
          Positioned.fill(child: _buildCoverFace(context)),
      ],
    );
  }

  /// 封面面左下角的「当前进度 / 总时长」(如 `1:23 / 4:56`)。
  ///
  /// 位置来自页面注入的 [DetailFaces.positionMs](歌词页展开期已有的 120ms ticker),
  /// 控件内**没有任何定时器**: null 时只做一个静态行。
  Widget _buildProgress(BuildContext context) {
    final theme = Theme.of(context);
    Widget text(int positionMs) => Text(
      _progressText(positionMs, widget.durationMs),
      key: const ValueKey('detail-cover-progress'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    final position = widget.positionMs;
    if (position == null) return text(0);
    return ValueListenableBuilder<int>(
      valueListenable: position,
      builder: (context, value, _) => text(value),
    );
  }

  Widget _buildCoverFace(BuildContext context) {
    final cover = _cover;
    return GestureDetector(
      key: const ValueKey('detail-cover-face'),
      // 再点一次回歌词(画面任意处); 按钮在更深的层级, 自己的 tap 赢
      behavior: HitTestBehavior.opaque,
      onTap: _toggleFace,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 尽量方形: 取可用空间的短边 —— 方图不裁边, 长边留白
          final side = math.max(
            0.0,
            math.min(constraints.maxWidth, constraints.maxHeight) -
                _kCoverInset * 2,
          );
          return Stack(
            children: [
              Center(
                child: side <= 0
                    ? const SizedBox.shrink()
                    : (cover.isEmpty
                          ? _buildPlaceholder(context, side)
                          : _buildCoverImage(context, side)),
              ),
              Positioned(
                left: _kCoverInset,
                right: _kCoverInset,
                bottom: _kCoverInset,
                child: Row(
                  children: [
                    // 左下角原来的「轻点画面返回歌词」提示改成「当前进度 / 总时长」
                    // (用户 2026-11-20): 切面手势本身已在用, 这行位置给有用的信息。
                    Expanded(child: _buildProgress(context)),
                    // 「查看评论」在「保存封面」左边(用户 2026-11-19 要求);
                    // 没有注入回调(纯控件测试/无当前曲目)时不显示。
                    if (widget.onOpenComments != null) ...[
                      IconButton.filledTonal(
                        key: const ValueKey('detail-cover-comments'),
                        tooltip: '查看评论',
                        icon: const Icon(Icons.forum_outlined, size: 20),
                        onPressed: widget.onOpenComments,
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (cover.isNotEmpty) ...[
                      IconButton.filledTonal(
                        key: const ValueKey('detail-cover-save'),
                        tooltip: '保存封面',
                        icon: _saving
                            ? const LoadingView.inline(size: 20)
                            : const Icon(Icons.download, size: 20),
                        onPressed: _saving ? null : _save,
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        key: const ValueKey('detail-cover-view'),
                        tooltip: '查看原图',
                        icon: const Icon(Icons.zoom_out_map, size: 20),
                        onPressed: _openViewer,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 封面图: **先小图后大图**的两层。
  ///
  /// 底层是播放条/列表已经在用的同一档位缩略图(同一 URL ⇒ 命中同一份字节缓存,
  /// 切面第一帧就有图); 大图字节到了再淡入叠上去。以前直接
  /// CoverArt(url, size: side) ⇒ 切面瞬间去拉 1600px 图再解码, 于是白屏/卡顿。
  Widget _buildCoverImage(BuildContext context, double side) {
    final bytes = _bigBytes;
    final radius = BorderRadius.circular(12);
    return SizedBox(
      width: side,
      height: side,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 圆角由 CoverArt 自己裁(与大图同一半径 12, 两层叠在一起严丝合缝)
          CoverArt(
            key: const ValueKey('detail-cover-thumb'),
            url: widget.coverUrl,
            size: side,
            radius: 12,
            // 小图档位固定为播放条那一档(而不是跟着 side 变大)
            requestPx: coverRequestPx(context, _kThumbLogicalSize),
          ),
          if (bytes != null)
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: _bigFaded ? Duration.zero : _kBigFade,
              onEnd: () => _bigFaded = true,
              builder: (context, opacity, child) =>
                  Opacity(opacity: opacity, child: child),
              child: ClipRRect(
                borderRadius: radius,
                child: Image.memory(
                  bytes,
                  key: const ValueKey('detail-cover-full'),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  // 大图解码失败: 保留底下的小图, 不抛异常也不留白
                  errorBuilder: (context, error, stack) =>
                      const SizedBox.shrink(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 无封面/取图失败的中性占位: 不留白屏, 也不假装有一张图
  Widget _buildPlaceholder(BuildContext context, double side) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const ValueKey('detail-cover-placeholder'),
      width: side,
      height: side,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      // FittedBox: 极小视口(或超大字号)下整体缩, 不溢出
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.music_note, size: 40, color: scheme.outline),
                const SizedBox(height: 8),
                Text(
                  '暂无封面',
                  maxLines: 1,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
