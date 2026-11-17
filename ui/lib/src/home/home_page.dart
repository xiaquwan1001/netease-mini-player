import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../album_preview.dart';
import '../app_settings.dart';
import '../app_shell.dart';
import '../app_meta.dart';
import '../artist_page.dart';
import '../audio_tuning.dart';
import '../auth.dart';
import '../back_policy.dart';
import '../cover_backdrop.dart';
import '../cover_palette.dart';
import '../detail_page.dart';
import '../desktop_integration.dart';
import '../discover.dart';
import '../feed_view.dart';
import '../keystore.dart';
import '../layout.dart' show rowExtentFor;
import '../library_view.dart';
import '../lyric.dart';
import '../marquee_text.dart';
import '../medal_wall.dart';
import '../messages_page.dart';
import '../mine_view.dart';
import '../net_retry.dart';
import '../new_release_page.dart';
import '../notification_mode.dart';
import '../now_playing.dart' show nowPlayingSongId;
import '../platform.dart';
import '../playback.dart';
import '../playback_bridge.dart';
import '../player_bar.dart';
import '../queue.dart';
import '../recommend_view.dart';
import '../rust/api.dart' as rust;
import '../search_exact_bar.dart';
import '../search_landing.dart';
import '../search_loading.dart';
import '../search_results.dart';
import '../search_suggest.dart';
import '../settings_view.dart';
import '../song_actions.dart';
import '../song_share.dart';
import '../song_tile.dart';
import '../toast.dart' show showToast;
import '../update_checker.dart';
import '../update_dialog.dart';
import '../word_lyric_view.dart';
import 'account_actions.dart';
import 'home_wiring.dart';
import 'lyric_controller.dart';
import 'playback_coordinator.dart';
import 'queue_sheet_controller.dart';
import 'search_controller.dart' as search_state;
import 'song_action_wiring.dart';

/// 首页(拆壳 S8 从 main.dart 原样搬出): 五 tab 外壳 + 歌词详情页 + 歌单浏览态
/// 的页面装配与少量胶水。
///
/// 业务协调层都已在 S2–S7 拆到本目录下的 controller:
/// [LyricController] / [search_state.SearchController] / [PlaybackCoordinator] /
/// [SongActionWiring] / [QueueSheetController] / [AccountActions];
/// 进程级静态钩子的注册/解绑在 [HomeWiring]。
/// 本文件只负责: 页面状态(tab/输入框/红心/错误横幅)、生命周期接线、
/// 启动编排, 以及 G11/G12 的页面装配(build/_buildPage/_buildTopBar/...)。
///
/// 搬家用的是纯"函数搬家": 结构、时序、注释一律照旧 —— 见
/// .pi/plans/arch-audit-frontend-2026-11-15.md §1.3 风险 5(build 结构是踩坑史)。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _controller = TextEditingController();
  final _playback = Playback();
  final _auth = Auth();
  final _queue = PlayQueue<rust.SongDto>();

  /// 播放协调器(轮询/续播/现场恢复/预取 + 播放态快照的唯一真相), 见
  /// src/home/playback_coordinator.dart。依赖在 initState 里注入, 不持 BuildContext。
  late final PlaybackCoordinator _coordinator;

  /// 歌曲动作宿主装配(拆壳 S5): 宿主构建与歌曲/艺人/专辑动作闭包都在
  /// src/home/song_action_wiring.dart, 这里只注入页面状态与导航回调。
  late final SongActionWiring _songActions;

  /// 播放队列面板 + 播放模式轮转(拆壳 S6): 面板开关(原 `_queueSheetOpen`)、
  /// 拖拽重排/删除/清空/跳播、存为歌单、模式轮转与顶部浮层都在
  /// src/home/queue_sheet_controller.dart。队列真相仍是本页面的 `_queue`
  /// (注入引用, 不复制); 面板/对话框/浮层需要 BuildContext —— 按回调注入。
  late final QueueSheetController _queueUI;

  /// 账号/登录态动作 + 二级页导航(拆壳 S7): 登录/退出/切号/清凭据/账号簿、
  /// 歌单详情与关注列表这些二级入口, 以及"歌单浏览态"四件套(标题/歌单 id/
  /// 队列来源/来源标记)的唯一写入口, 都在 src/home/account_actions.dart。
  /// 登录态快照 `_info` 与红心集合 `_liked` 仍是本页面的状态(按访问器/回灌
  /// 回调注入); 页面 addListener(→setState) 订阅它的变更。
  late final AccountActions _account;
  rust.InitInfo? _info;
  String? _error;

  /// 出错时可以一键重试的动作(搜索/打开歌单这类幂等操作)
  Future<void> Function()? _retryLast;

  /// 拖动进度条时的临时值(避免每帧都 seek); _dragMax 在拖动开始时冻结,
  /// 否则自动续播换曲会让滑杆量程突跳, 把新曲目 seek 到末尾。
  double? _dragMs;
  double? _dragMax;

  // ---- 歌词 ----
  /// 歌词状态机(数据/索引计算/加载/跟随/多选/翻译开关)在拆壳 S2 搬到
  /// [LyricController]; 这里只留最薄的接线与 [_buildLyrics] 渲染。
  late final LyricController _lyric;

  /// "我喜欢的音乐"里的曲目 id: 红心状态的唯一真相
  Set<BigInt> _liked = <BigInt>{};

  /// 底部导航: 0 搜索 / 1 推荐 / 2 关注 / 3 我的 / 4 设置
  ///
  /// 启动落在「推荐」(2026-11 用户要求): 以前默认停在「搜索」, 而
  /// [PlaybackCoordinator.restoreFromDisk] 又会把上次的队列塞进搜索页的歌单浏览态, 于是冷启动
  /// 第一眼看到的是"正在播放"的歌单列表, 而不是推荐首页。
  int _tab = 1;

  /// 已经打开过的 tab: 只有访问过的页面才进 IndexedStack(惰性构建),
  /// 之后一直保留 State —— 否则每次切 tab 都销毁重建子树,
  /// 图片 Widget 重新解析, 占位符会高频闪烁, 列表滚动位置也会丢
  final Set<int> _tabVisited = <int>{1};

  // ---- 搜索 ----
  /// 搜索状态机(结果/联想/历史/热词/请求代次/联想防抖/忙碌标志)在拆壳 S3 搬到
  /// `search_state.SearchController`; 这里只留输入框与焦点(页面持有, 注入给 controller)。
  late final search_state.SearchController _search;

  final _searchFocus = FocusNode();

  rust.SongDto? get _current => _queue.current;

  /// 当前列表的原始曲目。
  ///
  /// 歌单浏览态("正在播放"/"心动模式")= 播放队列的视图, 直接读 [_queue];
  /// 否则是上一轮搜索结果。浏览态标题的唯一写入口在 AccountActions
  /// (拆壳 S7), 这里只读。
  ///
  /// **不再另存一份曲目**: 这两个浏览态展示的就是播放队列本身, 以前存
  /// `_library` 快照, 队列面板里删/拖/清空之后这一页仍是旧列表, 在这里
  /// 点一首还会把整队重置回旧顺序(用户 2026-11-15 反馈页面重复)。现在
  /// 唯一来源是 _queue.items, 见 [_sourceSongs]。
  List<rust.SongDto> get _sourceSongs => _account.libraryOpen
      ? _queue.items
      : (_search.bundle?.songs ?? const <rust.SongDto>[]);

  /// 真正要显示/入队的曲目: 无版权且没收藏的直接不显示(与官方一致)
  List<rust.SongDto> get _visibleSongs => visibleSongs(_sourceSongs, _liked);

  /// 被隐藏的无版权曲目数量(列表顶部提示用)
  int get _hiddenUnplayable => hiddenUnplayableCount(_sourceSongs, _liked);

  /// 播放条回调集合: 建一次跨帧复用(回调内部读 State 字段, 不持有任何快照)。
  late final PlayerBarActions _playerBarActions;

  /// 进程级静态钩子的注册/解绑配对(拆壳 S8, 见 src/home/home_wiring.dart):
  /// 通知栏回调、动作宿主/播放条回调两个全局槽位、ArtistNav、更新弹窗、
  /// 导航层数、设置监听都在 attach() 里装、detach() 里逐项摘掉。
  late final HomeWiring _wiring;

  /// 已经弹过更新提示的版本 tag(同一次运行只弹一次, 避免重复打扰)
  String? _promptedUpdateTag;

  @override
  void initState() {
    super.initState();
    // 账号/登录态动作 + 二级页导航(拆壳 S7): 浏览态四件套由它持有(唯一写入口),
    // 登录态 `_info`/红心 `_liked` 仍是页面状态 —— 访问器 + 回灌回调注入;
    // 需要 BuildContext 的 sheet/账号页/详情页经 contextOf 在调用瞬间取。
    _account = AccountActions(
      contextOf: () => context,
      isMounted: () => mounted,
      auth: _auth,
      infoOf: () => _info,
      setInfo: (info) => setState(() => _info = info),
      dataDirOf: _playback.dataDir,
      toast: _toast,
      toastError: (message) {
        if (!mounted) return;
        showToast(context, message, isError: true);
      },
      likedOf: () => _liked,
      markLiked: _markLiked,
      setLiked: (ids) => setState(() => _liked = ids),
      clearLiked: () => _liked = <BigInt>{},
      rebuildActionsHost: () => actionsHost.value = _songActions.buildHost(),
      setSearchBusy: (busy) => _search.setBusy(busy),
      currentTrackIdOf: () => _current?.id,
      touchInteraction: _touchInteraction,
    )..addListener(_onAccountChanged);
    _lyric = LyricController(
      player: () => _coordinator.player,
      // 歌词展开期的高频刷新复用协调器的 poll(全仓只有这一处读播放器)
      pollPlayer: () => _coordinator.poll(),
      // 行高跟随系统字号, 与拆分前 _lyric.itemExtent 同一口径(依赖 BuildContext)
      itemExtentOf: () => rowExtentFor(context),
      toast: _toast,
    )..addListener(_onLyricChanged);
    // 播放协调器: 轮询/续播/现场恢复/预取与播放态快照的唯一真相(S4)。
    // 需要 BuildContext 的副作用(toast/封面主色/通知栏按钮/seek/列表态)用回调注入;
    // 播放器门面与队列传的是同一个实例(不复制, 队列真相仍在页面)。
    _coordinator = PlaybackCoordinator(
      playback: _playback,
      queue: _queue,
      lyric: _lyric,
      dataDirOf: () => _info?.dataDir,
      libraryTitleOf: () => _account.libraryTitle,
      toast: _toast,
      toastError: (message) {
        if (!mounted) return;
        showToast(context, message, isError: true);
      },
      dragActive: () => _dragMs != null,
      seekTo: _seekTo,
      onPlaybackStarted: _onPlaybackStarted,
      onRestored: _onPlaybackRestored,
      syncCoverPalette: _syncCoverPalette,
      syncActionState: _syncActionState,
    )..addListener(_onPlaybackChanged);
    // 歌曲动作宿主(拆壳 S5): 红心集合/登录态/队列/当前曲目都是页面状态,
    // 面板与路由跳转要 BuildContext —— 全部按回调注入, 装配逻辑在
    // src/home/song_action_wiring.dart; 宿主刷新时机仍是下面三处
    // actionsHost.value = _songActions.buildHost()。
    _songActions = SongActionWiring(
      contextOf: () => context,
      toast: _toast,
      isMounted: () => mounted,
      loggedIn: () => _info?.loggedIn == true,
      isLiked: _isLiked,
      markLiked: _markLiked,
      rebuild: () => setState(() {}),
      queue: _queue,
      playSongsList: _coordinator.playSongsList,
      currentSong: () => _current,
      playSource: () => _account.playSource,
      syncActionState: _syncActionState,
      openPlaylist: _account.openPlaylist,
    );
    // 队列面板(拆壳 S6): 队列引用与上下文访问器注入, 队列视图/开关状态由它持有;
    // 每次变更 notifyListeners -> 页面 setState(与拆分前每处 setState 一一对应)。
    _queueUI = QueueSheetController(
      contextOf: () => context,
      isMounted: () => mounted,
      queue: _queue,
      libraryTitleOf: () => _account.libraryTitle,
      toast: _toast,
      loggedIn: () => _info?.loggedIn == true,
      playSong: _coordinator.playSong,
      stopPlayback: _coordinator.stopPlayback,
      clearSavedState: _coordinator.clearSavedState,
      setUserStopped: (stopped) => _coordinator.userStopped = stopped,
      heartMode: () => _heartMode(),
      syncActionState: _syncActionState,
    )..addListener(_onQueueChanged);
    _playerBarActions = PlayerBarActions(
      onSeekStart: (v) => setState(() {
        _dragMax = (_coordinator.player?.durationMs ?? BigInt.zero).toDouble();
        _dragMs = v;
      }),
      onSeekChanging: (v) => setState(() => _dragMs = v),
      onSeekEnd: _seekTo,
      // 首页被压住时先回首页再展开歌词: 否则切换的是看不见的那一页,
      // 用户只会觉得"点了没反应"
      onToggleLyrics: () {
        if (pageDepth.value > 1) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
        _lyric.toggle();
      },
      // 播放条封面点击 = 进入播放详情(不是专辑预览, 用户要求)
      onOpenDetail: () {
        if (pageDepth.value > 1) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
        if (!_lyric.visible) _lyric.toggle();
      },
      onToggleLike: _songActions.toggleCurrentLike,
      onToggle: () => _coordinator.toggle(),
      onPrevious: _previous,
      onNext: _next,
      onCycleMode: _queueUI.cycleMode,
      onOpenQueue: _queueUI.open,
    );
    // 进程级静态钩子一次性交给 HomeWiring(拆壳 S8): 注册顺序与拆分前 initState
    // 一致 —— setSkipHandlers 会 flush 排队中的原生动作, 必须先于 setActionHandlers;
    // 播放条回调槽位在这里帧后投递一次(同一实例, 之后不再变)。
    _wiring = HomeWiring(
      onNext: _next,
      onPrevious: _previous,
      onEnded: _coordinator.onNativeTrackEnded,
      onToggleLike: _songActions.toggleCurrentLike,
      onCycleMode: _cycleModeFromNotification,
      buildActionsHost: _songActions.buildHost,
      barActions: _playerBarActions,
      // 头像点击进入用户主页/艺人主页时, 主页里的专辑卡仍要能打开(与播放无关)
      openAlbum: (albumId, albumName, coverUrl) => showAlbumPreview(
        context,
        albumId: albumId,
        albumName: albumName,
        coverUrl: coverUrl,
      ),
      onUpdatePrompt: _onUpdatePrompt,
      onPageDepthChanged: _onPageDepthChanged,
      onAudioSettingsChanged: _onAudioSettingsChanged,
    )..attach();
    // 搜索状态机: 输入框/焦点仍由页面持有, 只把"失败/清错/离开浏览态"三件
    // 需要 setState 的副作用回灌给页面(与原 _search/_clearSearch 一一对应)
    _search = search_state.SearchController(
      text: _controller,
      focus: _searchFocus,
      onSearchFailed: _onSearchFailed,
      onClearSearchError: _onClearSearchError,
      onLeaveLibrary: _onLeaveLibrary,
    );
    // 播放能力只在这里接线一次: 任何页面/任何深度的区块都调
    // PlaybackBridge.instance, 不再有 UserNav/ArtistNav 静态字段与构造参数
    // 两条旁路(见 src/playback_bridge.dart 头注释)。
    PlaybackBridge.instance.bind(
      playSongs: _coordinator.playSongsList,
      appendNext: _songActions.appendSongToQueue,
      openPlaylist: _account.openPlaylist,
    );
    _bootstrap();
    _coordinator.startPolling();
  }

  @override
  void dispose() {
    // 断开播放能力: 避免下一个 HomePage 实例/测试用例误用已销毁的实现
    PlaybackBridge.instance.unbind();
    // 逐项摘掉进程级静态钩子(槽位置 null, 不留旧对象); 见 src/home/home_wiring.dart
    _wiring.detach();
    _coordinator.dispose();
    _queueUI.dispose();
    _account.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _lyric.dispose();
    super.dispose();
  }

  void _onPageDepthChanged() {
    if (mounted) setState(() {});
  }

  /// 歌词状态机有变更时重建(与拆分前每处 setState 一一对应: 一次通知 = 一次重建)。
  void _onLyricChanged() {
    if (mounted) setState(() {});
  }

  /// 播放协调器有变更时重建(与拆分前每处 setState(赋值 _player) 等价)。
  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  /// 队列面板状态有变更时重建(与拆分前队列增删/模式切换的 setState 等价)。
  void _onQueueChanged() {
    if (mounted) setState(() {});
  }

  /// 账号/浏览态有变更时重建(与拆分前登录态/歌单浏览态的 setState 等价)。
  void _onAccountChanged() {
    if (mounted) setState(() {});
  }

  /// 起播一批曲目后的列表态(原 _playSongsList 里的那一处 setState)。
  void _onPlaybackStarted(BigInt? playlistId, SongActionSource source) {
    if (!mounted) return;
    // 浏览态字段的唯一写入口在 AccountActions(拆壳 S7), 这里只转发。
    _account.applyPlaybackStarted(playlistId, source);
  }

  /// 启动恢复播放现场后的页面态: 不进"歌单浏览态"(与原 _restorePlayback 同一批字段)。
  void _onPlaybackRestored() {
    if (!mounted) return;
    _account.applyPlaybackRestored();
  }

  /// 启动自动检查发现新版本时的弹窗(每天/每周/每月由 AppSettings 决定)。
  void _onUpdatePrompt() {
    final info = UpdateCheckHost.pendingPrompt.value;
    if (info == null || !info.isNewer) return;
    if (info.latest == _promptedUpdateTag) return;
    _promptedUpdateTag = info.latest;
    // 立即清掉, 避免同一次通知重入; 红点仍由 pendingUpdate 维护。
    UpdateCheckHost.pendingPrompt.value = null;
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showUpdateDialog(context, info);
    });
  }

  Future<void> _bootstrap() async {
    try {
      final dir = await _playback.dataDir();
      // Android Keystore 凭据桥: 先 restore(幂等, 非 Android/不可用则跳过)再开 Core,
      // 否则 Core::open 选不到后端(见 docs/android-keystore-wiring-design.md).
      await credentialSync.ensureRestored();
      final info = await rust.init(dataDir: dir);
      await AppSettings.instance.load(info.dataDir);
      // 登录期可能产生 pending, 启动点落一次 Keystore
      unawaited(credentialSync.drainPending());
      // 首帧后 3s 后台静默检查更新(节流/开关在 update_checker 内, 失败静默)
      unawaited(runStartupUpdateCheck(AppSettings.instance));
      // 启动时把已保存的播放参数与缓存上限应用一次(默认值 = 不改变现状)
      unawaited(applyAudioTuning());
      unawaited(enforceCacheLimit());
      if (!mounted) return;
      setState(() => _info = info);
      actionsHost.value = _songActions.buildHost();
      // 状态记忆: 恢复上次退出时的队列与曲目(只恢复现场, 不自动出声)
      unawaited(_coordinator.restoreFromDisk(info.dataDir));
      // 本地历史和热词都依赖 init() 建立的 Core, 必须等初始化完成再拉
      unawaited(_search.loadHistory());
      unawaited(_search.loadLanding());
      // AppImage 首启: 问一次「集成到应用菜单」(deb 安装的走不到这条)
      unawaited(_offerDesktopIntegration(info.dataDir));
      // 已登录就把账号记进账号簿(老版本登录过的账号也能被记住)
      if (info.loggedIn) {
        unawaited(_account.syncAccount());
        unawaited(_account.loadLiked());
        unawaited(_account.resolveLikedPlaylistId());
      }
    } catch (e) {
      setState(() => _error = friendlyError(e));
    }
  }

  /// Linux AppImage 首启: 问一次「是否集成到应用菜单」(§11.A-2)。
  ///
  /// 判据全部是纯函数(`desktop_integration.dart`), 这里只负责弹窗、落标记与提示。
  /// 拒绝/失败都落标记 —— 以后不再骚扰; 安装只是用户目录下的两份文件, 不需要 root。
  Future<void> _offerDesktopIntegration(String dataDir) async {
    final pending = await desktopIntegrationPending(dataDir: dataDir);
    if (pending == null || !mounted) return;
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return;
    final agree = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('集成到应用菜单?'),
        content: const Text(
          '当前以 AppImage 方式运行, 系统菜单里还没有轻音 MiniNCM。\n'
          '是否写入菜单入口与图标? (只改你自己的 ~/.local/share, 不需要管理员权限, '
          '以后不想要了直接删掉那两个文件即可)',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('不用了'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('集成'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (agree != true) {
      await markDesktopIntegrationAsked(dataDir);
      return;
    }
    final r = await installDesktopIntegration(
      appImagePath: pending.appImagePath,
      home: home,
      version: kAppVersion,
    );
    if (!mounted) return;
    if (r.ok) {
      showToast(context, r.iconInstalled ? '已添加到应用菜单' : '已添加菜单入口(未找到图标)');
    } else {
      await markDesktopIntegrationAsked(dataDir);
      if (!mounted) return;
      showToast(context, '集成失败: ${r.error ?? '未知错误'}', isError: true);
    }
  }

  /// 播放参数变化时才真的调 FFI(设置页里每拖一格 Slider 都会 notifyListeners)
  AudioTuningRequest? _lastTuning;
  int? _lastCacheLimitMb;
  bool? _lastLoudnessNormalize;
  double? _lastLoudnessTarget;

  void _onAudioSettingsChanged() {
    final settings = AppSettings.instance;
    // 响度均衡的开关/目标电平变化 ⇒ 已算好的每曲增益全部作废, 当前曲目重算
    final loudnessChanged =
        settings.loudnessNormalize != _lastLoudnessNormalize ||
        settings.loudnessTargetLufs != _lastLoudnessTarget;
    _lastLoudnessNormalize = settings.loudnessNormalize;
    _lastLoudnessTarget = settings.loudnessTargetLufs;
    if (loudnessChanged) {
      forgetLoudnessGain();
      final id = _coordinator.player?.trackId?.toInt();
      if (id != null) {
        _coordinator.markLoudnessApplied(id);
        unawaited(applyLoudnessForTrack(id));
      }
      return;
    }
    final request = AudioTuningRequest.fromSettings(settings);
    if (request != _lastTuning) {
      _lastTuning = request;
      unawaited(applyAudioTuning());
    }
    if (settings.cacheLimitMb != _lastCacheLimitMb) {
      _lastCacheLimitMb = settings.cacheLimitMb;
      unawaited(
        enforceCacheLimit(keepTrackId: _coordinator.player?.trackId?.toInt()),
      );
    }
  }

  // ---------------- 搜索(状态机在 SearchController, 见 src/home/search_controller.dart) ----------------

  /// 搜索失败: 顶部横幅展示错误, 重试指回搜索(与原 `_search` 的 catch 等价)。
  /// 注意 `_retryLast` 由 [_onClearSearchError] 一并清空: 横幅只在 `_error != null`
  /// 时可达, 所以"新搜索时旧重试指针未清"这一点在 UI 上不可观测。
  void _onSearchFailed(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _retryLast = _search.search;
    });
  }

  /// 清掉顶部搜索错误(原 setState 里的 `_error = null` / `_retryLast = null`)
  void _onClearSearchError() {
    if (!mounted) return;
    setState(() {
      _error = null;
      _retryLast = null;
    });
  }

  /// 搜索即离开歌单浏览态: 结果列表要保持"这一屏是什么"的唯一来源
  void _onLeaveLibrary() {
    if (!mounted) return;
    _account.leaveLibrary();
  }

  Future<void> _openExactArtist(int id) async {
    for (final a in _search.exact?.artists ?? const <rust.Artist>[]) {
      if (a.id.toInt() != id) continue;
      await showArtistDetail(
        context,
        artistId: a.id,
        name: a.name,
        onOpenAlbum: (albumId, name, cover) => showAlbumPreview(
          context,
          albumId: albumId,
          albumName: name,
          coverUrl: cover,
        ),
      );
      return;
    }
  }

  Future<void> _openExactPlaylist(int id) async {
    for (final p in _search.exact?.playlists ?? const <rust.Playlist>[]) {
      if (p.id.toInt() == id) {
        await _account.openPlaylist(p);
        return;
      }
    }
  }

  void _openExactRadio(int id) {
    for (final r in _search.exact?.podcasts ?? const <rust.PodcastRadio>[]) {
      if (r.id.toInt() == id) {
        _openPodcastRadio(r);
        return;
      }
    }
  }

  // ---------------- 心动模式 / 每日推荐 / 播客 / 最近听过 / 封面预览 ----------------

  /// 心动模式: 以当前曲目为种子, 在当前歌单(0=不限定)里续播一队推荐.
  /// 网易云这个接口需要登录, 未登录会返回 [auth] 错误.
  Future<void> _heartMode({rust.SongDto? seed}) async {
    final current = seed ?? _current;
    final id = current?.id;
    if (id == null) {
      _toast('先播一首歌, 再开启心动模式');
      return;
    }
    _search.setBusy(true);
    try {
      final songs = await retryNetwork(
        () => rust.heartModeSongs(
          songId: id,
          playlistId: _account.libraryPlaylistId ?? BigInt.zero,
          count: 30,
        ),
      );
      if (!mounted) return;
      final seen = <BigInt>{id};
      final list = <rust.SongDto>[?current];
      for (final s in songs) {
        if (s.playable && seen.add(s.id)) list.add(s);
      }
      if (list.length <= 1) {
        _toast('心动模式暂时没有推荐(登录后推荐更准)');
        return;
      }
      _queue.setAll(list, startAt: 0);
      _account.setPlaySource(SongActionSource.other);
      _coordinator.userStopped = false;
      _account.enterHeartMode();
      unawaited(_syncActionState());
      final next = _queue.next();
      if (next != null) await _coordinator.playSong(next);
    } catch (e) {
      if (!mounted) return;
      _toast(friendlyError(e));
    } finally {
      if (mounted) _search.setBusy(false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    showToast(context, message);
  }

  void _openDiscover() {
    showDiscoverPage(
      context,
      onOpenPlaylist: _account.openPlaylist,
      loadPlaylists: _account.dailyPlaylists,
      // 设置里启用缓存后, 历史日推把磁盘上的本地缓存天也列进来(合并去重 + 「本地」标记)
      loadLocalDays: _account.dailyLocalDays,
    );
  }

  /// 直接打开某个播客的详情页(推荐/我的页面的卡片点进来)
  /// 记录"最近一次交互"(我的页收藏栏按它排序, 见 recent_order.dart)。
  /// 打开动作是唯一可靠的信号: 收藏列表本身没有"最近使用"字段。
  void _touchInteraction(String kind, BigInt id) {
    if (id <= BigInt.zero) return;
    unawaited(AppSettings.instance.touchInteraction(kind, id));
  }

  void _openPodcastRadio(rust.PodcastRadio radio) {
    _touchInteraction('podcast', radio.id);
    showPodcastDetail(context, radio: radio);
  }

  void _openRecent() {
    showRecentPage(
      context,
      onOpenPlaylist: _account.openPlaylist,
      onOpenPodcast: _openPodcastRadio,
      onOpenAlbum: (album) => showAlbumPreview(
        context,
        albumId: album.id,
        albumName: album.name,
        coverUrl: album.coverUrl,
      ),
    );
  }

  /// 点列表: 用当前可见列表(搜索/歌单)重置队列, 从被点那首开始
  Future<void> _playFromList(rust.SongDto song) async {
    final songs = _visibleSongs;
    final start = songs.indexWhere((s) => s.id == song.id);
    _queue.setAll(songs, startAt: start < 0 ? 0 : start);
    _account.setPlaySource(SongActionSource.other);
    _coordinator.userStopped = false;
    // 搜索列表点播不算歌单队列
    _account.clearQueuePlaylistId();
    await _coordinator.playSong(song, explicit: true);
  }

  /// 搜索结果里点单曲: 用"可见单曲"重置队列(跳过无版权), 并定位到这首
  Future<void> _playFromSearch(rust.SongDto song) async {
    final songs = visibleSongs(
      _search.bundle?.songs ?? const <rust.SongDto>[],
      _liked,
    );
    final start = songs.indexWhere((s) => s.id == song.id);
    if (songs.isEmpty) return;
    _queue.setAll(songs, startAt: start < 0 ? 0 : start);
    _account.setPlaySource(SongActionSource.other);
    _coordinator.userStopped = false;
    _account.clearQueuePlaylistId();
    await _coordinator.playSong(song, explicit: true);
  }

  /// 搜索结果: 艺人卡片 → 艺人页
  Future<void> _openSearchArtist(rust.SearchArtist artist) async {
    await showArtistDetail(
      context,
      artistId: artist.id,
      name: artist.name,
      onOpenAlbum: (id, name, cover) => showAlbumPreview(
        context,
        albumId: id,
        albumName: name,
        coverUrl: cover,
      ),
    );
  }

  void _openSearchAlbum(rust.SearchAlbum album) {
    showAlbumPreview(
      context,
      albumId: album.id,
      albumName: album.name,
      coverUrl: album.coverUrl,
    );
  }

  /// 搜索结果: 歌单卡片 → 歌单详情
  void _openSearchPlaylist(rust.SearchPlaylistItem item) {
    _account.openPlaylist(
      rust.Playlist(
        id: item.id,
        name: item.name,
        coverUrl: item.coverUrl,
        trackCount: item.trackCount,
        special: false,
        subscribed: false,
      ),
    );
  }

  /// 搜索结果: 播客卡片 → 播客详情
  void _openSearchPodcast(rust.SearchPodcast item) {
    _openPodcastRadio(
      rust.PodcastRadio(
        id: item.id,
        name: item.name,
        coverUrl: item.coverUrl,
        description: '',
        djName: item.djName,
        programCount: item.programCount,
        playCount: item.playCount,
      ),
    );
  }

  // ---------------- 详情页: 分享 ----------------
  // 歌词多选/翻译开关/自动跟随/定位都在 LyricController(拆壳 S2), 这里只留
  // 需要 BuildContext 的分享(sheet)。

  /// 分享(详情页右上角 / 选中歌词后的分享): 卡片带封面 + 歌词 + 二维码
  Future<void> _shareSong({List<String>? lyrics}) async {
    final song = _current;
    if (song == null) {
      _toast('当前没有正在播放的歌曲');
      return;
    }
    await showSongShareSheet(
      context,
      song: song,
      lyricLines: lyrics ?? const <String>[],
    );
  }

  Future<void> _shareSelectedLyrics() async {
    final lines = _lyric.selectedTexts();
    if (lines.isEmpty) {
      _toast('没有可分享的歌词');
      return;
    }
    await _shareSong(lyrics: lines);
  }

  // ---------------- 收藏(红心)与歌单 ----------------

  bool _isLiked(BigInt? trackId) => trackId != null && _liked.contains(trackId);

  /// 动作闭包改红心集合(原动作方法里的 setState; 见 SongActionWiring.markLiked)
  void _markLiked(BigInt trackId, bool liked) {
    if (!mounted) return;
    setState(() {
      if (liked) {
        _liked.add(trackId);
      } else {
        _liked.remove(trackId);
      }
    });
  }

  /// 无版权提示(与官方一致的"点了才告诉你")
  void _notifyUnplayable(rust.SongDto song) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('《${song.name}》暂无版权, 无法播放'),
          duration: const Duration(milliseconds: 1800),
        ),
      );
  }

  // ---------------- 播放控制 ----------------

  Future<void> _next() async {
    final next = _queue.next();
    if (next == null) return;
    await _coordinator.playSong(next);
  }

  Future<void> _previous() async {
    final prev = _queue.previous();
    if (prev == null) return;
    await _coordinator.playSong(prev);
  }

  /// 是否处于心动模式队列(心动不是 PlayMode, 用队列标题识别)
  bool get _heartActive => _queueUI.heartActive;

  /// 当前曲目封面主色(歌词页背景用); null = 回退主题色
  CoverPalette? _coverPalette;

  /// 上一次取色对应的封面 URL, 避免同一封面重复触发
  String? _coverPaletteUrl;

  /// 曲目切换后重算封面主色. 同 URL 命中 cover_palette 的 LRU 缓存, 不会重复计算.
  Future<void> _syncCoverPalette() async {
    final url = _current?.coverUrl;
    if (url == _coverPaletteUrl) return;
    _coverPaletteUrl = url;
    if (url == null || url.isEmpty) {
      if (mounted && _coverPalette != null) {
        setState(() => _coverPalette = null);
      }
      return;
    }
    final palette = await paletteFromUrl(url);
    if (!mounted || _coverPaletteUrl != url) return; // 期间又换曲, 丢弃旧结果
    setState(() => _coverPalette = palette);
  }

  /// 把当前红心/模式状态回传给原生, 刷新通知自定义按钮图标
  Future<void> _syncActionState() async {
    await _playback.setActionState(
      liked: _isLiked(_current?.id),
      modeIcon: notificationModeIcon(_queue.mode, heartActive: _heartActive),
    );
  }

  /// 通知栏「播放顺序」按钮: 列表循环→单曲循环→顺序播放→随机播放→心动模式→(回到)列表循环.
  /// 心动模式那一步调 _heartMode(); 未登录/失败时 _heartMode 会自己 toast, 这里回退列表循环.
  Future<void> _cycleModeFromNotification() async {
    if (_heartActive) {
      setState(() => _queue.mode = PlayMode.repeatAll);
      _toast('列表循环');
    } else {
      final next = nextNotificationMode(_queue.mode);
      if (next == null) {
        await _heartMode();
        if (!mounted) return;
        if (!_heartActive) {
          setState(() => _queue.mode = PlayMode.repeatAll);
          _toast('列表循环');
        }
      } else {
        setState(() => _queue.mode = next);
        _queueUI.toastTop(playModeLabels[next]!);
      }
    }
    await _syncActionState();
  }

  Future<void> _seekTo(double ms) async {
    final target = ms.round();
    // seek 是用户的明确意图: 无论之前是否拖过歌词, seek 后都恢复自动跟随,
    // 否则一次误触/拖动歌词后, 歌词从此不再跟着播放滚动(拖/点进度条都算 seek).
    setState(() {
      _dragMs = null;
      _dragMax = null;
      // notify: false —— 这次 setState 已经会重建, 不重复通知
      _lyric.resumeFollow(notify: false);
    });
    final state = await _playback.seek(BigInt.from(target));
    if (!mounted) return;
    _coordinator.adoptPlayer(state);
    _lyric.syncIndex(state, force: true);
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final backAction = resolveHomeBackAction(
      showLyrics: _lyric.visible,
      tab: _tab,
      libraryOpen: _account.libraryOpen,
    );
    return HomeBackGuard(
      action: backAction,
      onBack: () => _handleBack(backAction),
      // 搜索状态在 [SearchController]: 它的一次通知 = 拆分前的一处 setState,
      // 所以整页重建一次, 重建范围与拆分前一致。
      child: ListenableBuilder(
        listenable: _search,
        builder: (context, _) => _buildPage(context),
      ),
    );
  }

  /// 返回键: 先退一级(歌词 → 非首 tab → 歌单浏览态), 栈底才交还系统退出
  void _handleBack(HomeBackAction action) {
    switch (action) {
      case HomeBackAction.collapseLyrics:
        // 详情页里正在多选歌词时, 返回键先退多选(与常见相册/文件选择一致)
        if (_lyric.selecting) {
          _lyric.clearSelection();
        } else {
          _lyric.toggle();
        }
      case HomeBackAction.resetTab:
        _onTabSelected(0);
      case HomeBackAction.closeLibrary:
        _account.leaveLibrary();
      case HomeBackAction.exitApp:
        // canPop=true 时由系统退出; 走到这里说明确实无可退层级, 兜底交还系统
        SystemNavigator.pop();
    }
  }

  Widget _buildPage(BuildContext context) {
    final player = _coordinator.player;
    final current = _current;
    final topBar = _buildTopBar(context, current);
    // 播放条数据快照 + 底部导航由根布局渲染(MaterialApp.builder 的 PlayerBarHost):
    // 二级路由压上来时播放条仍然在场, 这里只负责把当前数据投递过去.
    _publishPlayerBar(player, current);
    publishBottomBar(_buildBottomBar());
    return Scaffold(
      appBar: topBar,
      // 没有 AppBar 时自己吃掉状态栏安全区(放在最外层, 搜索框/内容都不会顶到状态栏下)
      body: Padding(
        padding: EdgeInsets.only(
          top: topBar == null ? MediaQuery.paddingOf(context).top : 0,
        ),
        child: Column(
          children: [
            if (!_lyric.visible && _tab == 0) _buildSearchBar(),
            // 有输入时给输入联想(原版交互); 历史/热词在搜索落地页里
            if (!_lyric.visible && _tab == 0 && _search.exact != null)
              SearchExactBar(
                view: _search.exactView!,
                onPickArtist: _openExactArtist,
                onPickPlaylist: _openExactPlaylist,
                onPickRadio: _openExactRadio,
              ),
            if (!_lyric.visible &&
                _tab == 0 &&
                _search.suggestions.isEmpty &&
                _search.exact == null &&
                _search.keywordSuggestions.isNotEmpty)
              KeywordSuggestBar(
                keywords: _search.keywordSuggestions,
                onSelected: _search.searchKeyword,
              ),
            if (!_lyric.visible && _tab == 0 && _error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    if (_retryLast != null)
                      TextButton(
                        onPressed: () {
                          final retry = _retryLast;
                          setState(() => _error = null);
                          retry?.call();
                        },
                        child: const Text('重试'),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: Stack(
                children: [
                  // 歌词页盖在上面时 tab 树仍然存活(Offstage), 收起歌词不重建、不闪图
                  Positioned.fill(
                    child: Offstage(
                      offstage: _lyric.visible,
                      child: _buildTabPages(),
                    ),
                  ),
                  if (_lyric.visible)
                    // 背景色由当前曲目封面取色, 无彩/取色失败时完全透明直通主题
                    Positioned.fill(
                      child: CoverBackdrop(
                        palette: _coverPalette,
                        child: _buildLyrics(),
                      ),
                    ),
                  // 输入联想盖在 tab 内容之上并**占满剩余高度**(需求 14):
                  // 以前它是一条 maxHeight 280 的窄条, 联想多了只能在小矩形里滚,
                  // 下面还露出半截结果页。tab 树仍然挂在 Offstage 里, 收起联想不重建。
                  if (!_lyric.visible &&
                      _tab == 0 &&
                      _search.suggestions.isNotEmpty)
                    Positioned.fill(
                      // 不透明底色: 联想面板铺满后, 下面的 tab 内容不该从卡片外边
                      // 那 12dp 的缝里透出来。
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.surface,
                        child: SuggestionPanel(
                          items: _search.suggestions,
                          // 分类 tab 与底部「看全部结果」都要知道当前输入词
                          keyword: _controller.text.trim(),
                          onSelected: (item) =>
                              _search.searchKeyword(item.title),
                          onSearchAll: _search.busy ? null : _search.search,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onTabSelected(int index) {
    if (_tab == index) return;
    _tabVisited.add(index);
    // 切 tab 一律收起歌词: 否则歌词页会一直占着焦点, 切过去看不到目标页面
    final wasLyrics = _lyric.visible;
    setState(() {
      _tab = index;
      _searchFocus.unfocus();
    });
    // 收起歌词 + 停掉展开期的高频刷新; 不额外通知 —— 上面的 setState 已经会重建
    _lyric.collapse();
    // 回到搜索: 按设置决定是否丢弃上一次的输入/结果/错误
    if (index == 0) {
      if (AppSettings.instance.clearSearchOnTabSwitch &&
          (wasLyrics ||
              _controller.text.isNotEmpty ||
              _search.bundle != null ||
              _account.libraryOpen ||
              _error != null)) {
        _search.clear();
      }
      _search.loadHistory();
    }
  }

  /// 五个 tab 都塞进 IndexedStack(访问过的才真正构建), 保留各自的 State.

  /// 顶部栏: **只在它承载了导航里没有的信息时才出现**。
  ///
  /// - 歌词页: 曲名 + 收起按钮;
  /// - 歌单/正在播放/心动模式的浏览态: 当前列表名 + 返回按钮;
  /// - 其它情况(含「搜索」tab 首页、「推荐/关注/我的/设置」): **整条 AppBar 不出现**。
  ///   两处理由: ①这四页标题原本就是底部导航标签, 完全重复;
  ///   ②搜索页顶部的品牌横幅只是装饰, 用户明确要求去掉 —— 省下的 56dp 全给内容。
  ///   没有 AppBar 时也不再有顶部「登录」动作: 未登录引导在「我的」页(mine_view 的登录按钮)
  ///   与资料头点击(审查 P1-7.10 已定: 账号入口 3→1)。
  PreferredSizeWidget? _buildTopBar(
    BuildContext context,
    rust.SongDto? current,
  ) {
    final showBar = _lyric.visible || _account.libraryOpen;
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
        _lyric.visible
            ? (_lyric.selecting
                  ? '已选 ${_lyric.selected.length} 句'
                  : (current?.name ?? '歌词'))
            : (_account.libraryTitle ?? '轻音 MiniNCM'),
      ),
      leading: _lyric.visible
          ? IconButton(
              icon: const Icon(Icons.expand_more),
              tooltip: '收起歌词',
              onPressed: _lyric.toggle,
            )
          : (_account.libraryOpen
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: '返回搜索',
                    onPressed: _account.leaveLibrary,
                  )
                : null),
      actions: [
        // 歌曲详情页(歌词页)的右上角: 分享 / 翻译开关 / "..." 菜单
        if (_lyric.visible) ...[
          if (_lyric.selecting) ...[
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: '分享所选歌词',
              onPressed: _shareSelectedLyrics,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '取消选择',
              onPressed: _lyric.clearSelection,
            ),
          ] else ...[
            // 翻译开关已挪到歌词右下角(「定位当前歌词」上方), 见 _buildLyrics.
            // "..." 从播放条挪到详情页里(播放条只留播放控制)
            if (current != null)
              SongOverflowButton(
                song: current,
                size: 22,
                // 队列来源即菜单来源: 日推/FM 才显示"不感兴趣"
                source: _account.playSource,
              ),
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: '分享这首歌',
              onPressed: () => _shareSong(),
            ),
          ],
        ] else if (_auth.isAndroid && _info?.loggedIn != true)
          // 登录(WebView)只在安卓端(桌面版还没有网页登录宿主)。
          // 审查 P1-7.10: 账号入口 3→1 —— 账号簿/切换/退出登录统一走「我的」页资料头。
          TextButton.icon(
            onPressed: _account.login,
            icon: const Icon(Icons.login, size: 18),
            label: const Text('登录'),
          ),
      ],
    );
  }

  Widget _buildTabPages() {
    return IndexedStack(
      index: _tab,
      children: [
        for (var i = 0; i < 5; i++)
          if (_tabVisited.contains(i))
            _buildTabPage(i)
          else
            const SizedBox.shrink(),
      ],
    );
  }

  Widget _buildTabPage(int index) {
    switch (index) {
      case 1:
        return RecommendView(
          key: ValueKey('recommend-${_info?.loggedIn}-${_info?.vip}'),
          loggedIn: _info?.loggedIn == true,
          // 每日推荐歌单走本地缓存(同一天只拉一次; 设置里可关/改保留天数)
          loadDailyPlaylists: _account.dailyPlaylists,
          onOpenPlaylist: _account.openPlaylist,
          onOpenPodcast: _openPodcastRadio,
          onHeartMode: () => _heartMode(),
          onOpenDaily: _openDiscover,
          onOpenAlbum: (album) => showAlbumPreview(
            context,
            albumId: album.id,
            albumName: album.name,
            coverUrl: album.coverUrl,
          ),
          onOpenNewRelease: () => showNewReleasePage(
            context,
            onOpenAlbum: (album) => showAlbumPreview(
              context,
              albumId: album.id,
              albumName: album.name,
              coverUrl: album.coverUrl,
            ),
            onOpenArtist: (artist) => showArtistDetail(
              context,
              artistId: artist.id,
              name: artist.name,
              onOpenAlbum: (id, name, cover) => showAlbumPreview(
                context,
                albumId: id,
                albumName: name,
                coverUrl: cover,
              ),
            ),
          ),
        );
      case 2:
        return FeedView(
          key: ValueKey('feed-${_info?.loggedIn}'),
          loggedIn: _info?.loggedIn == true,
          onLogin: _account.login,
          onOpenUrl: PlatformBridge.openUrl,
        );
      case 3:
        return MineView(
          key: ValueKey('mine-${_info?.loggedIn}-${_info?.vip}'),
          loggedIn: _info?.loggedIn == true,
          onLogin: _account.login,
          onOpenAccounts: _account.openAccountPage,
          onOpenPlaylist: _account.openPlaylist,
          onOpenPodcast: _openPodcastRadio,
          onOpenFollows: () => _account.openUserList(startOnFans: false),
          onOpenFolloweds: () => _account.openUserList(startOnFans: true),
          onOpenAlbum: (album) => showAlbumPreview(
            context,
            albumId: album.id,
            albumName: album.name,
            coverUrl: album.coverUrl,
            initiallySubscribed: true,
          ),
          onOpenRecent: _openRecent,
          onOpenLiked: _account.openLikedDetail,
          onOpenMessages: () => showMessagesPage(context),
          onOpenMedals: () => showMedalWall(context, isVip: _info?.vip == true),
          onOpenVip: _account.openVip,
          // "我喜欢的音乐"区块点播时的队列来源标记(解析出来之前为 null)
          likedPlaylistId: _account.likedPlaylistId,
          // 简介保存: POST /api/user/profile/update(局部更新, 只改 signature)
          saveSignature: (signature) =>
              rust.updateSignature(signature: signature),
        );
      case 4:
        // 设置只剩下「App 怎么表现」的偏好开关 + 分组入口:
        // 账号管理、诊断与数据都是这里的二级页(账号入口 2026-11 统一收在这里)。
        return SettingsView(
          info: _info,
          onOpenAccounts: _account.openAccountPage,
        );
      default:
        return _buildSearchTab();
    }
  }

  Widget _buildSearchTab() {
    final query = _controller.text.trim();
    // 歌单浏览态优先(从我的/推荐点进来的)
    if (_account.libraryOpen) return _buildList();
    // 有上一轮结果就展示分区结果; 取消按钮会清空它
    if (_search.bundle != null) return _buildSearchResults();
    // 没输入关键词时: 搜索历史 + 猜你想搜 + 热门榜
    if (query.isEmpty) {
      return SearchLanding(
        history: _search.history,
        hot: _search.hotTerms,
        recommended: _search.recommendedKeyword,
        recommendedReason: _search.recommendedReason,
        onSelected: _search.searchKeyword,
        onClearHistory: _search.clearHistory,
        hotLoading: _search.hotLoading,
        hotError: _search.hotError,
        onRetryHot: _search.loadLanding,
        // 排行榜从「推荐」搬到这里(2026-11 用户要求)
        onOpenChartPlaylist: _account.openPlaylist,
      );
    }
    return _buildList();
  }

  /// 综合搜索结果: 单曲/艺人/专辑/歌单/播客分区
  Widget _buildSearchResults() {
    return SearchResultsView(
      bundle: _search.bundle!,
      // 后端 cloudsearch type=1004 的 MV 结果 → UI 的 SearchMv(同构映射)
      mvs: [
        for (final m in _search.bundle!.mvs)
          SearchMv(
            id: m.id,
            name: m.name,
            coverUrl: m.coverUrl,
            artistName: m.artistName,
            playCount: m.playCount,
          ),
      ],
      liked: _liked,
      currentTrackId: _current?.id,
      onPlaySong: _playFromSearch,
      onOpenArtist: _openSearchArtist,
      onOpenAlbum: _openSearchAlbum,
      onOpenPlaylist: _openSearchPlaylist,
      onOpenPodcast: _openSearchPodcast,
      onMenu: (song) => showSongActionsSheet(
        context,
        song,
        _songActions.buildHost(),
        // 综合搜索结果里的单曲
        source: SongActionSource.search,
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _searchFocus,
              decoration: InputDecoration(
                labelText: '搜索',
                border: const OutlineInputBorder(),
                isDense: true,
                // 输入过东西或已有结果时给一个显式的清空按钮
                suffixIcon: (_controller.text.isEmpty && _search.bundle == null)
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: _search.clear,
                      ),
              ),
              textInputAction: TextInputAction.search,
              onChanged: _search.onQueryChanged,
              onSubmitted: (_) => _search.search(),
            ),
          ),
          const SizedBox(width: 8),
          // 不再并排放「取消」: 它与输入框里的清空 suffix 是同一个动作
          // (_search.clear), 两个同义按钮只会让人不知道该按哪个(审查 P1-7.4)
          FilledButton(
            onPressed: _search.busy ? null : _search.search,
            child: Text(_search.busy ? '搜索中' : '搜索'),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    final current = _current;
    if (!_account.libraryOpen) {
      // 搜索请求还没回来时给加载占位: 原来的"输入关键词后搜索"会让用户
      // 以为断网或没有结果(本次回归修复)。错误由顶部横幅展示(带重试)。
      if (_search.busy) return SearchLoading(_controller.text.trim());
      if (_error != null) return const SizedBox.shrink();
      final typed = _controller.text.trim();
      if (typed.isEmpty) {
        return const Center(child: Text('输入关键词后搜索'));
      }
      // 已经输入但还没提交: 上方是联想面板, 这里给一句明确的操作提示
      return Center(
        child: Text(
          '点「搜索」查看「$typed」的结果',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    final songs = _visibleSongs;
    final hidden = _hiddenUnplayable;
    if (songs.isEmpty) {
      // 浏览态现在是队列的视图: 队列被清空时这里要说明白, 不然会读成"歌单空了"
      final emptyText = !_account.libraryOpen ? '这个歌单是空的' : '播放队列是空的';
      return Center(
        child: Text(hidden > 0 ? '这里没有可播放的曲目($hidden 首无版权已隐藏)' : emptyText),
      );
    }
    // 列表顶部一句说明: 无版权且没收藏的曲目按官方行为直接不出现, 但要让用户知道少了什么
    final headerCount = hidden > 0 ? 1 : 0;
    return ListView.builder(
      itemCount: songs.length + headerCount,
      itemBuilder: (context, i) {
        if (headerCount == 1 && i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              '已隐藏 $hidden 首无版权曲目',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        final s = songs[i - headerCount];
        final active = current?.id == s.id;
        // 没版权: 整行灰掉 + "无版权"标, 点了才提示(官方同款行为)
        return SongTile(
          song: s,
          active: active,
          liked: _isLiked(s.id),
          onTap: () {
            if (s.playable) {
              _playFromList(s);
            } else {
              _notifyUnplayable(s);
            }
          },
          onMenu: () => showSongActionsSheet(
            context,
            s,
            _songActions.buildHost(),
            // 库内歌单/列表详情
            source: SongActionSource.playlist,
          ),
        );
      },
    );
  }

  /// 歌曲详情页正文 = 歌词 + (定位当前句 / 底部次要控制)
  Widget _buildLyrics() {
    // 多选态: 点行 = 加/减选; 非多选态点击不做事(避免误改焦点)
    final onTap = _lyric.selecting ? (int i) => _lyric.selectLine(i) : null;
    final onLong = _lyric.selectLine;
    final showTranslation = AppSettings.instance.lyricTranslation;

    final Widget body;
    if (_lyric.wordLines.isNotEmpty) {
      body = WordLyricView(
        lines: _lyric.wordLines,
        positionMs: _lyric.positionMs,
        playing: _lyric.playing,
        controller: _lyric.scroll,
        itemExtent: _lyric.itemExtent,
        showTranslation: showTranslation,
        selected: _lyric.selected,
        onLineTap: onTap,
        onLineLongPress: onLong,
        autoScroll: _lyric.autoFollow,
      );
    } else if (_lyric.plain != null) {
      body = PlainLyricView(
        lines: _lyric.plain!,
        controller: _lyric.scroll,
        selected: _lyric.selected,
        onLineTap: onTap,
        onLineLongPress: onLong,
      );
    } else if (_lyric.error != null) {
      body = Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(_lyric.error!, textAlign: TextAlign.center)),
      );
    } else if (_lyric.lines.isEmpty) {
      body = const Center(child: Text('暂无歌词'));
    } else {
      body = TimedLyricView(
        lines: _lyric.lines,
        activeIndex: _lyric.activeIndex,
        controller: _lyric.scroll,
        itemExtent: _lyric.itemExtent,
        showTranslation: showTranslation,
        selected: _lyric.selected,
        onLineTap: onTap,
        onLineLongPress: onLong,
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
                _lyric.pauseFollow();
              }
              return false;
            },
            child: Stack(
              children: [
                Positioned.fill(child: body),
                // 曾经在这里常驻一行"逐字歌词 · 网易云"来源小字(左下角),
                // 用户反馈那是一条像水印的文本框, 已去掉(2026-11)。
                // 打分/择优的实现与单测仍在 lyricSourceLabel / scoreWordLyric.

                // 右下角竖排: 翻译开关在上, 定位当前歌词在下(用户要求把顶部翻译
                // 开关挪到侧面). 歌词本身没有 tlyric 时不出现翻译键.
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_lyric.hasTranslation)
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
                          onPressed: _lyric.toggleTranslation,
                        ),
                      if (_lyric.hasTranslation) const SizedBox(height: 8),
                      IconButton.filledTonal(
                        tooltip: '定位到当前歌词',
                        icon: const Icon(Icons.my_location, size: 20),
                        onPressed: _lyric.locateCurrent,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 投递播放条数据快照(帧后; 与上一份相等时 ValueNotifier 不通知 → 播放条不重建)。
  ///
  /// 没有曲目时不投(Media3 连接前拿到的是一份空状态, 空态不占位置)。
  void _publishPlayerBar(PlayerView? player, rust.SongDto? current) {
    final showBar =
        player != null && (player.trackId != null || current != null);
    final PlayerBarData? data = !showBar
        ? null
        : PlayerBarData(
            player: player,
            current: current,
            liked: _isLiked(current?.id),
            queueIndex: _queue.isEmpty ? 1 : _queue.index + 1,
            queueLength: _queue.items.length,
            dragMax: _dragMax,
            dragMs: _dragMs,
            mode: _queue.mode,
            heartActive: _heartActive,
          );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      playerBarData.value = data;
      // 全局"正在播放"样本(见 src/now_playing.dart): 所有列表行的播放态高亮
      // 都读它 —— 以前各页自己传 currentTrackId, 少接一处(如完整日推歌单)
      // 就不高亮。帧后写, 避免在 build 期间通知下游 setState。
      nowPlayingSongId.value = showBar ? (current?.id ?? player.trackId) : null;
    });
  }

  /// 首页底部导航栏的构建结果, 由根布局渲染(见 [playerBarSlot])。
  ///
  /// 底部 tab 属于首页: 有全屏页压在首页之上时返回 null(播放条由
  /// [playerBarData] 负责, 此时它自己吃掉系统手势区), 弹层/对话框不算。
  Widget? _buildBottomBar() {
    if (pageDepth.value > 1) return null;
    return NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: _onTabSelected,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.search_outlined),
          selectedIcon: Icon(Icons.search),
          label: '搜索',
        ),
        NavigationDestination(
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore),
          label: '推荐',
        ),
        NavigationDestination(
          icon: Icon(Icons.dynamic_feed_outlined),
          selectedIcon: Icon(Icons.dynamic_feed),
          label: '关注',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: '我的',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: '设置',
        ),
      ],
    );
  }
}
