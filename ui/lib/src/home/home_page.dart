import 'dart:async';
import 'dart:io' show Platform, exit;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../album_preview.dart';
import '../app_settings.dart';
import '../app_shell.dart';
import '../auth.dart';
import '../back_policy.dart';
import '../cover_backdrop.dart';
import '../cover_palette.dart';
import '../detail_faces.dart';
import '../desktop_shell.dart';
import '../detail_pane.dart'
    show
        DetailPaneSplit,
        attachDetailPaneHost,
        closeDetailPane,
        detachDetailPaneHost,
        detailPaneSlot;
import '../layout.dart'
    show LayoutTier, kRailWidth, layoutTierFor, rowExtentFor;
import '../library_view.dart';
import '../net_retry.dart';
import '../notification_mode.dart';
import '../playback.dart';
import '../playback_bridge.dart';
import '../player_bar.dart';
import '../queue.dart';
import '../queue_guide.dart';
import '../rust/api_all.dart' as rust;
import '../search_exact_bar.dart';
import '../search_suggest.dart';
import '../sleep_timer.dart';
import '../song_actions.dart';
import '../song_share.dart';
import '../toast.dart' show showToast;
import 'account_actions.dart';
import 'home_wiring.dart';
import 'lyrics_page.dart';
import 'navigation.dart';
import 'lyric_controller.dart';
import 'playback_coordinator.dart';
import 'queue_sheet_controller.dart';
import 'search_bar_host.dart';
import 'search_controller.dart' as search_state;
import 'song_action_wiring.dart';
import 'startup.dart';
import 'tab_builder.dart';

/// 首页(拆壳 S8 从 main.dart 原样搬出): 五 tab 外壳 + 歌词详情页 + 歌单浏览态
/// 的页面装配与少量胶水。
///
/// 业务协调层都已在 S2–S7 拆到本目录下的 controller:
/// [LyricController] / [search_state.SearchController] / [PlaybackCoordinator] /
/// [SongActionWiring] / [QueueSheetController] / [AccountActions];
/// 进程级静态钩子的注册/解绑在 [HomeWiring]。
/// 本文件只负责: 页面状态(tab/输入框/红心/错误横幅)、生命周期接线, 以及
/// G11/G12 的骨架装配(build/_buildPage/_buildTabArea/底部导航)。
///
/// §7.7 第二刀把三块装配搬到同级文件(同样是纯"函数搬家"):
/// [HomeStartup](src/home/startup.dart) 启动/外壳编排、
/// [HomeLyricsPage](src/home/lyrics_page.dart) 歌词全屏页与顶栏、
/// [HomeSearchBarHost](src/home/search_bar_host.dart) 搜索输入条。
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

  /// 导航类动作(拆 §7.7 第一刀): 输入联想的精确实体、搜索结果五类卡片、每日推荐/
  /// 最近听过/播客详情。纯导航, 不持状态 —— 见 src/home/navigation.dart。
  late final HomeNavigation _nav;

  /// 五个 tab 的正文构建(拆 §7.7 第二刀): IndexedStack / 五个 tab / 搜索落地页 /
  /// 结果分区 / 曲目列表。只读页面状态, 播放与搜索条仍归本页面 ——
  /// 见 src/home/tab_builder.dart。
  late final HomeTabBuilder _tabs;

  /// 启动/外壳编排(拆 §7.7 第二刀): 冷启动恢复、桌面壳/窗口行为接线、
  /// AppImage 菜单集成、更新提示、设置变更后的播放参数节流 ——
  /// 见 src/home/startup.dart。构造零副作用, 在 initState 末尾(所有依赖就位后)建。
  late final HomeStartup _startup;

  /// 歌词全屏页 + 顶栏装配(拆 §7.7 第二刀), 见 src/home/lyrics_page.dart。
  late final HomeLyricsPage _lyrics;

  /// 搜索输入条(拆 §7.7 第二刀), 见 src/home/search_bar_host.dart。
  late final HomeSearchBarHost _searchBar;

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

  /// 「关闭主窗口」行为的最终分流点(didRequestAppExit); 仅 Linux 会有非退出结果。
  late final DesktopCloseObserver _desktopClose;

  /// 详情面板当前是「歌词」还是「封面」面 —— **唯一真相**, 三处共享:
  /// - DetailFaces 用它当控制器(值变了就跟着翻面, 也会把用户手动切面写回);
  /// - 播放条封面点击把它翻到另一面(于是"点封面"每次都是真的换视图);
  /// - 偏好落盘: 用户切面 → AppSettings.detailFace, 下次进面板按记忆面初始化
  ///   (换歌不重置, 用户 2026-11-19 口径)。
  late final ValueNotifier<DetailFace> _detailFace;

  @override
  void initState() {
    super.initState();
    // 账号/登录态动作 + 二级页导航(拆壳 S7): 浏览态四件套由它持有(唯一写入口),
    // 登录态 `_info`/红心 `_liked` 仍是页面状态 —— 访问器 + 回灌回调注入;
    // 需要 BuildContext 的 sheet/账号页/详情页经 contextOf 在调用瞬间取。
    _detailFace = ValueNotifier<DetailFace>(_storedDetailFace());
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
      rebuildActionsHost: () =>
          publishActionsHost(context, _songActions.buildHost()),
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
      // 引导态(心动模式/私人FM): 播完一首不看 PlayMode, 由页面续播(见 _guideNext)
      guideOf: () => _queueUI.guide,
      guideNext: _guideNext,
      // 必须包一层闭包: 直接写 `_queueUI.queueChanged` 会在 initState 里**立刻**
      // 解引用 _queueUI(它在这行之后才初始化)⇒ LateInitializationError。
      queueChanged: () => _queueUI.queueChanged(),
      syncCoverPalette: _syncCoverPalette,
      syncActionState: _syncActionState,
      // 定时关闭: 同一个状态机既给设置页显示, 也在轮询/曲末里判定到点
      sleepTimer: sleepTimer,
    )..addListener(_onPlaybackChanged);
    // 到点动作必须由页面注入(纯逻辑不碰平台 API): 停播放 + 退出应用
    sleepTimer.onExpire = _onSleepTimerExpired;
    // 歌曲动作宿主(拆壳 S5): 红心集合/登录态/队列/当前曲目都是页面状态,
    // 面板与路由跳转要 BuildContext —— 全部按回调注入, 装配逻辑在
    // src/home/song_action_wiring.dart; 宿主刷新时机仍是三处, 但一律走
    // publishActionsHost(context, ...)(帧后 + 存活守卫, 见 app_shell.dart)。
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
      toast: _toast,
      playSong: _coordinator.playSong,
      stopPlayback: _coordinator.stopPlayback,
      clearSavedState: _coordinator.clearSavedState,
      setUserStopped: (stopped) => _coordinator.userStopped = stopped,
      leaveHeartMode: _account.exitHeartMode,
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
      // 播放条封面点击 = 在「歌词 ⇄ 封面」两面之间切换(用户 2026-11-19 口径:
      // 每次点都真的"换个视图", 不是单纯打开歌词页)。面板已显示时直接翻面;
      // 未显示时先显示面板 —— 面板按记忆面初始化, 所以先把记忆面翻成相反的一面。
      // 歌词按钮(onToggleLyrics)语义不变, 仍然是"展开/收起歌词"。
      onOpenDetail: () {
        if (pageDepth.value > 1) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
        final next = oppositeDetailFace(_detailFace.value);
        _detailFace.value = next;
        // 播放条点封面同样算"用户切面" ⇒ 写回记忆面(否则重启后回到旧的那一面)
        _onDetailFaceChanged(next);
        if (!_lyric.visible) _lyric.toggle();
      },
      onToggleLike: _songActions.toggleCurrentLike,
      onToggle: () => _coordinator.toggle(),
      onPrevious: _previous,
      onNext: _next,
      onCycleMode: _queueUI.cycleMode,
      onOpenQueue: _queueUI.open,
      // 播放条右键 = 当前曲目的「歌曲操作」菜单: 与列表行右键/行尾「...」同一个
      // 面板(`showSongActionsSheet` + 现成的动作宿主), 不另写菜单；
      // source 跟着当前队列来源(决定「不感兴趣」等项是否出现)。
      onMenu: () {
        final song = _current;
        if (song == null) return;
        showSongActionsSheet(
          context,
          song,
          _songActions.buildHost(),
          source: _account.playSource,
        );
      },
    );
    // 进程级静态钩子一次性交给 HomeWiring(拆壳 S8): 注册顺序与拆分前 initState
    // 一致 —— setSkipHandlers 会 flush 排队中的原生动作, 必须先于 setActionHandlers;
    // 播放条回调槽位在这里帧后投递一次(同一实例, 之后不再变)。
    _wiring = HomeWiring(
      onNext: _next,
      onPrevious: _previous,
      onEnded: _coordinator.onNativeTrackEnded,
      onToggleLike: _songActions.toggleCurrentLike,
      // Linux 托盘「播放/暂停」= 播放条上那个按钮(同一个控制器入口, 不新造旋钮)
      onTogglePlay: () => _coordinator.toggle(),
      onCycleMode: _queueUI.cycleMode,
      buildActionsHost: _songActions.buildHost,
      barActions: _playerBarActions,
      // 头像点击进入用户主页/艺人主页时, 主页里的专辑卡仍要能打开(与播放无关)
      openAlbum: (albumId, albumName, coverUrl) => showAlbumPreview(
        context,
        albumId: albumId,
        albumName: albumName,
        coverUrl: coverUrl,
      ),
      // 两个回调都走 _startup 的方法: 间接一层是为了让 _startup(它要 _search/
      // _desktopClose)在所有依赖就位后、在同一次 initState 末尾才构造,
      // 而 HomeWiring 的注册顺序(含 setSkipHandlers 先于 setActionHandlers)不变。
      onUpdatePrompt: () => _startup.onUpdatePrompt(),
      onPageDepthChanged: _onPageDepthChanged,
      onAudioSettingsChanged: () => _startup.onAudioSettingsChanged(),
      onFocusSearch: _focusSearch,
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
    // 返回键判定要跟着"搜索框文本 / 搜索状态机"走(两者都不经过页面 setState)
    _backListenable = Listenable.merge([_controller, _search]);
    // 导航 + tab 正文构建(拆 §7.7): 两者都只**读**页面状态, 状态写入仍在页面
    // (浏览态四件套在 AccountActions、队列在 _queue、搜索结果在 SearchController);
    // 传的是现取回调而不是快照, 与拆分前每次 build 现读 State 字段等价。
    _nav = HomeNavigation(
      contextOf: () => context,
      exactOf: () => _search.exact,
      openPlaylist: _account.openPlaylist,
      dailyPlaylists: _account.dailyPlaylists,
      dailyLocalDays: _account.dailyLocalDays,
      touchInteraction: _touchInteraction,
      // 每日推荐「推荐歌单」的 auth 错误主按钮 = 「去登录」, 走现成登录入口
      onLogin: _account.login,
    );
    _tabs = HomeTabBuilder(
      contextOf: () => context,
      infoOf: () => _info,
      account: _account,
      search: _search,
      navigation: _nav,
      queryOf: () => _controller.text,
      tabOf: () => _tab,
      tabVisitedOf: () => _tabVisited,
      currentOf: () => _current,
      visibleSongsOf: () => _visibleSongs,
      hiddenUnplayableOf: () => _hiddenUnplayable,
      likedOf: () => _liked,
      errorOf: () => _error,
      isLiked: _isLiked,
      playFromList: _playFromList,
      playFromSearch: _playFromSearch,
      notifyUnplayable: _notifyUnplayable,
      buildActionsHost: _songActions.buildHost,
      openHeartMode: () => _heartMode(),
    );
    // 播放能力只在这里接线一次: 任何页面/任何深度的区块都调
    // PlaybackBridge.instance, 不再有 UserNav/ArtistNav 静态字段与构造参数
    // 两条旁路(见 src/playback_bridge.dart 头注释)。
    PlaybackBridge.instance.bind(
      playSongs: _coordinator.playSongsList,
      appendNext: _songActions.appendSongToQueue,
      openPlaylist: _account.openPlaylist,
    );
    // Linux 桌面「点关闭 = 退出 / 隐藏到托盘」的分流点(Flutter 官方 System.requestAppExit
    // → WidgetsBindingObserver.didRequestAppExit)。其它平台恒退出, 与旧版一致。
    _desktopClose = DesktopCloseObserver(
      shell: DesktopShell.instance,
      settings: AppSettings.instance,
    );
    WidgetsBinding.instance.addObserver(_desktopClose);
    // 主从分栏的右栏由本页渲染(方案 B · S4): 登记"宿主在场", openDetail 才知道
    // 该填右栏还是照旧 push。计数而非 bool —— 换树时新旧页面的 init/dispose 顺序不保证。
    attachDetailPaneHost();
    // 三块装配(拆 §7.7 第二刀): 启动编排 / 歌词页(含顶栏) / 搜索条。
    // 构造本身零副作用(只存引用与回调), 所以放在依赖全部就位的 initState 末尾,
    // 与拆分前"这些方法直接长在 State 上"的时机一致。
    _startup = HomeStartup(
      playback: _playback,
      coordinator: _coordinator,
      account: _account,
      search: _search,
      buildActionsHost: _songActions.buildHost,
      desktopClose: _desktopClose,
      contextOf: () => context,
      isMounted: () => mounted,
      setInfo: (info) => setState(() => _info = info),
      setError: (message) => setState(() => _error = message),
    );
    _lyrics = HomeLyricsPage(
      lyric: _lyric,
      account: _account,
      auth: _auth,
      infoOf: () => _info,
      currentOf: () => _current,
      detailFace: _detailFace,
      storedDetailFace: _storedDetailFace,
      onDetailFaceChanged: _onDetailFaceChanged,
      shareSong: _shareSong,
      shareSelectedLyrics: _shareSelectedLyrics,
      openComments: _openComments,
    );
    _searchBar = HomeSearchBarHost(
      controller: _controller,
      focusNode: _searchFocus,
      search: _search,
    );
    _startup.bootstrap();
    _coordinator.startPolling();
  }

  @override
  void dispose() {
    detachDetailPaneHost();
    // 睡眠定时的到点动作属于本页面实例: 摘掉, 免得销毁后的 State 被回调
    sleepTimer.onExpire = null;
    WidgetsBinding.instance.removeObserver(_desktopClose);
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
    _detailFace.dispose();
    super.dispose();
  }

  void _onPageDepthChanged() {
    if (mounted) setState(() {});
  }

  /// 会改变返回键判定的外部状态: 搜索框文本(输入框直接改 controller, 不经过页面)
  /// + 搜索状态机(结果/联想/错误)。给 [HomeBackGuard] 用来重建 PopScope。
  late final Listenable _backListenable;

  /// 搜索页当前有没有"值得先清掉"的东西(2026-11-26 交互审计: 有输入/有结果时,
  /// 返回键必须先清搜索, 不能直接退出 App)。
  bool get _searchActive =>
      _controller.text.trim().isNotEmpty ||
      _search.bundle != null ||
      _search.exact != null;

  /// 现取的返回键优先级(歌词 → 右栏 → tab → 歌单浏览态 → 搜索态 → 退出)。
  /// 现取的返回键优先级(歌词 → 右栏 → tab → 歌单浏览态 → 搜索态 → 退出)。
  HomeBackAction _resolveBackAction() => resolveHomeBackAction(
    showLyrics: _lyric.visible,
    tab: _tab,
    libraryOpen: _account.libraryOpen,
    // 宽档主从分栏的右栏优先级**高于** resetTab(见 back_policy.dart)
    detailPaneOpen: detailPaneSlot.value != null,
    searchActive: _searchActive,
  );

  /// 桌面 Ctrl+F / `/` 的落点: 把用户送到搜索框(2026-11-26 审查, 用户拍板要做)。
  ///
  /// 顺序 = "干净地回到搜索页": 先退全屏页(否则聚焦的是看不见的那一页), 再收掉浮层
  /// (弹层的 ModalBarrier 会挡住输入框), 再收起歌词页, 再切到搜索 tab(同 tab 时
  /// [_onTabSelected] 自己 early return, 不会平白清空搜索结果), 最后聚焦输入框。
  void _focusSearch() {
    if (!mounted) return;
    if (pageDepth.value > 1) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    dismissAllPopups();
    if (_lyric.visible) _lyric.collapse();
    if (_tab != 0) _onTabSelected(0);
    _searchFocus.requestFocus();
  }

  /// 歌词状态机有变更时重建(与拆分前每处 setState 一一对应: 一次通知 = 一次重建)。
  void _onLyricChanged() {
    // 展开歌词时补一次封面主色: 换曲时若歌词页没开, [_syncCoverPalette] 会跳过
    if (_lyric.visible) unawaited(_syncCoverPalette());
    if (mounted) setState(() {});
  }

  /// 上次看的详情面(持久化偏好; 缺省/未知值一律 = 歌词)。
  static DetailFace _storedDetailFace() =>
      AppSettings.instance.detailFace == DetailFace.cover.name
      ? DetailFace.cover
      : DetailFace.lyrics;

  /// 用户手动切面 → 立刻写回偏好(异步落盘, 不阻塞手势)。
  ///
  /// 走 [AppSettings.update] 而不是裸 setter: setter 只改内存不落盘, 重启就丢
  /// (这正是"切面没有记忆"的症状)。该字段与交互记录同域, 通知不会重建整棵树。
  void _onDetailFaceChanged(DetailFace face) {
    unawaited(AppSettings.instance.update(detailFace: face.name));
  }

  /// 封面面「查看评论」: 打开**当前**曲目(而不是切面瞬间的快照)的评论面板
  void _openComments() {
    final song = _current;
    if (song == null) return;
    unawaited(_songActions.openComments(song));
  }

  /// 播放协调器有变更时重建(与拆分前每处 setState(赋值 _player) 等价)。
  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  /// 定时关闭到点: 停止播放 + 退出应用。
  ///
  /// 平台分流(2026-11 用户需求「定时停止播放并退出」):
  /// - Android: [Playback.stop] 先停播放器并清空 MediaItem(服务随之退到空闲),
  ///   再 [SystemNavigator.pop] 结束界面;
  /// - Linux: 走桌面壳的 quit(与点窗口关闭选「直接退出」同一条实现);
  /// - Windows: 没有桌面壳通道, 直接退出进程(播放现场已按 5s 节流落盘)。
  Future<void> _onSleepTimerExpired() async {
    try {
      await _playback.stop();
    } catch (_) {
      // 播放后端已不可用(未就绪/已停止): 不挡住退出
    }
    if (!mounted) return;
    if (Platform.isAndroid) {
      await SystemNavigator.pop();
      return;
    }
    if (Platform.isLinux) {
      await DesktopShell.instance.quit();
      return;
    }
    exit(0);
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
  ///
  /// 同时同步**引导态**: 只有"私人FM 起播"才进 fm 引导态, 其它任何起播(歌单/
  /// 日推/搜索/单曲)都把引导态清掉 —— 否则播完那批歌还会被 FM 续播接管。
  void _onPlaybackStarted(BigInt? playlistId, SongActionSource source) {
    if (!mounted) return;
    // 浏览态字段的唯一写入口在 AccountActions(拆壳 S7), 这里只转发。
    _account.applyPlaybackStarted(playlistId, source);
    final nextGuide = source == SongActionSource.personalFm
        ? QueueGuide.fm
        : QueueGuide.none;
    if (nextGuide != _queueUI.guide) _queueUI.enterGuide(nextGuide);
  }

  /// 启动恢复播放现场后的页面态: 不进"歌单浏览态"(与原 _restorePlayback 同一批字段)。
  void _onPlaybackRestored() {
    if (!mounted) return;
    _account.applyPlaybackRestored();
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
      // 引导态 + 歌单浏览态标题一起改: 引导态决定"下一首怎么来"(不受 PlayMode 约束),
      // 标题决定列表/播放条显示什么。只改一处会出现图标/列表对不上的老问题。
      _queueUI.enterGuide(QueueGuide.heart);
      _account.enterHeartMode();
      unawaited(_syncActionState());
      // 顺序前进一首(种子曲就是 list[0], 从第一条推荐开始播); 不能用 queue.next(),
      // 随机播放下它会随机挑一首, 心动模式的"顺序"就没了
      final next = _queue.advanceSequential();
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

  /// 记录"最近一次交互"(我的页收藏栏按它排序, 见 recent_order.dart)。
  /// 打开动作是唯一可靠的信号: 收藏列表本身没有"最近使用"字段。
  void _touchInteraction(String kind, BigInt id) {
    if (id <= BigInt.zero) return;
    unawaited(AppSettings.instance.touchInteraction(kind, id));
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
    // 引导态(心动/私人FM): 下一首按 provider 的顺序走, 不许随机/单曲循环接管
    if (_queueUI.guide != QueueGuide.none) {
      final song = await _guideNext();
      if (song != null) await _coordinator.playSong(song);
      return;
    }
    final next = _queue.next();
    if (next == null) return;
    // 下标变了 ⇒ 队列面板的高亮/「正在播放」要跟着走(用户反馈: 切歌列表不跟随)
    _queueUI.queueChanged();
    await _coordinator.playSong(next);
  }

  Future<void> _previous() async {
    final prev = _queueUI.guide == QueueGuide.none
        ? _queue.previous()
        : _queue.previousSequential();
    if (prev == null) return;
    _queueUI.queueChanged();
    // backward: 若这一首(或再往前几首)是 VIP/不可播, 跳过方向也必须继续往后**退**,
    // 否则会顺着 queue.next() 被弹回用户刚离开的那首(用户反馈 2026-11-25)
    await _coordinator.playSong(prev, backward: true);
  }

  /// 引导态续播取料(心动模式/私人FM 各一批; 逻辑在 queue_guide.dart)。
  late final GuideQueueAdvance _guideAdvance = GuideQueueAdvance(
    fetchFm: () => retryNetwork(() => rust.personalFm(limit: 30)),
    fetchHeart: (seed) => retryNetwork(
      () => rust.heartModeSongs(
        songId: seed.id,
        playlistId: _account.libraryPlaylistId ?? BigInt.zero,
        count: 30,
      ),
    ),
    // 续一批 = 连取 2 次: 接口一次只回 2 首, 2 次够下一首立刻有货且只多花一个请求
    fmBatches: 2,
  );

  /// 引导态的"下一首": 顺序前进一首, 到这段队列末尾就向 provider 续一批再前进。
  /// 返回 null = 没有更多(播放器停在当前这首)。
  ///
  /// 队列是页面持有的普通对象(不是 ChangeNotifier), 队列面板订阅的是
  /// [QueueSheetController], 所以每次续播/追加后都要显式 [queueChanged]
  /// (用户反馈: FM 切下一首时列表不跟随刷新)。
  Future<rust.SongDto?> _guideNext() async {
    final guide = _queueUI.guide;
    if (guide == QueueGuide.none) return null;
    final next = await _guideAdvance.next(_queue, guide);
    _queueUI.queueChanged();
    return next;
  }

  /// 当前曲目封面主色(歌词页背景用); null = 回退主题色
  CoverPalette? _coverPalette;

  /// 上一次取色对应的封面 URL, 避免同一封面重复触发
  String? _coverPaletteUrl;

  /// 曲目切换后重算封面主色. 同 URL 命中 cover_palette 的 LRU 缓存, 不会重复计算.
  ///
  /// **只为歌词页背景服务 ⇒ 歌词页没开就不算**(2026-11-28 审计: 旧实现在换曲时无条件
  /// 跑, 每个新曲目都多一次图片下载 + 解码)。跳过时不写 [_coverPaletteUrl],
  /// 于是展开歌词时的 [_onLyricChanged] 重新调一次就能补上。
  Future<void> _syncCoverPalette() async {
    if (!_lyric.visible) return;
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
      // 引导态优先(fm > heart): 通知栏图标要说清"现在在哪个引导态",
      // 因为此时按播放顺序按钮 = 退出引导
      modeIcon: notificationModeIcon(
        _queue.mode,
        heartActive: _queueUI.heartActive,
        fmActive: _queueUI.fmActive,
      ),
    );
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
    // 如实反馈(P-10 方案 B 的另一半): 排队成功有「已排队→mm:ss」在播放条上,
    // 而**真的被拒**(下载失败等硬不可跳)只会回传 seek_error —— 不说一句用户
    // 会当成「播放器又卡了」。排队/成功时 seek_error 被 Rust 清空, 不会误报。
    if (state.seekError != null && state.pendingSeekMs == null) {
      _toast(seekFailedHint);
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    // 右栏/搜索态的读取都在 [_resolveBackAction] 里**现取**; HomeBackGuard 自己
    // 监听 _backListenable 重建 PopScope(右栏由 DetailPaneSplit 自己监听)。
    return HomeBackGuard(
      // **现取**优先级(不是快照): 搜索框里的文本/搜索结果不经过页面 setState,
      // 传值会让 canPop 停在旧值上 —— 那正是"有搜索态按返回直接退出 App"的根因
      // (2026-11-26 Android 交互审计 P1)。[listenable] 让 PopScope 跟着这两份
      // 状态重建, 但 child 是同一实例, 页面本身不会因此重排。
      action: () => _resolveBackAction(),
      listenable: _backListenable,
      // 用当帧的优先级回调: 槽位在读屏/动画帧之间变化时也不会退错层级
      onBack: () => _handleBack(_resolveBackAction()),
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
      case HomeBackAction.closeDetailPane:
        // 宽档: 只清右栏, 页面与左栏都不动(**不** pop 页面);
        // 窄档的详情是一整页, 由系统返回键 pop, 永远走不到这个分支
        closeDetailPane();
      case HomeBackAction.resetTab:
        _onTabSelected(0);
      case HomeBackAction.closeLibrary:
        _account.leaveLibrary();
      case HomeBackAction.clearSearch:
        // 与搜索框右侧的「取消」同一个入口: 清关键词/上一轮结果/联想/错误, 回到落地页
        _search.clear();
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
    _publishPlayerBar(context, player, current);
    publishBottomBar(context, _buildBottomBar(context));
    return Scaffold(
      appBar: topBar,
      // 主从分栏(方案 B · S4): 右栏有详情时**整页正文都在左栏**(搜索框/联想/tab 树),
      // 让位给 420 的右栏; 没有右栏时 [DetailPaneSplit] 原样返回 —— 几何零变化。
      // AppBar(歌词页/歌单浏览态才有)仍通栏, 与页内双列(S1)同一口径。
      body: DetailPaneSplit(
        master: (context, selectedKey) => Padding(
          // 没有 AppBar 时自己吃掉状态栏安全区(放在最外层, 搜索框/内容都不会顶到状态栏下)。
          // 左右也一律吃: 横屏刘海/扶着孔在左/右时, 纵向 inset 为 0 而 left/right
          // 非 0, 只吃 top 会把搜索框与列表压到挖孔下面。
          padding: EdgeInsets.only(
            top: topBar == null ? MediaQuery.paddingOf(context).top : 0,
            left: MediaQuery.paddingOf(context).left,
            right: MediaQuery.paddingOf(context).right,
          ),
          child: Column(
            children: [
              if (!_lyric.visible && _tab == 0) _buildSearchBar(),
              // 有输入时给输入联想(原版交互); 历史/热词在搜索落地页里
              if (!_lyric.visible && _tab == 0 && _search.exact != null)
                SearchExactBar(
                  view: _search.exactView!,
                  onPickArtist: _nav.openExactArtist,
                  onPickPlaylist: _nav.openExactPlaylist,
                  onPickRadio: _nav.openExactRadio,
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
              // 左栏 = tab 区(歌词页/输入联想都盖在它上面); 槽位一变它跟着重建,
              // 才能画出"右栏正在看哪一条"的选中外框。
              Expanded(child: _buildTabArea(context, selectedKey)),
            ],
          ),
        ),
      ),
    );
  }

  /// 首页 tab 区(歌词页与输入联想都盖在它上面), 作为 [DetailPaneSplit] 的左栏。
  ///
  /// [selectedKey] = 右栏正在看的详情锚点(歌单 id); null = 没有右栏。
  Widget _buildTabArea(BuildContext context, Object? selectedKey) => Stack(
    children: [
      // 歌词页盖在上面时 tab 树仍然存活(Offstage), 收起歌词不重建、不闪图
      Positioned.fill(
        child: Offstage(
          offstage: _lyric.visible,
          child: _tabs.buildPages(selectedKey),
        ),
      ),
      if (_lyric.visible)
        // 背景色由当前曲目封面取色, 无彩/取色失败时完全透明直通主题。
        // 展开时淡入 180ms(审计 2026-11-28 4.3): 旧实现与 AppBar 同时硬出现,
        // 第一帧整页"哺"一下。Tween 两端是常量 ⇒ 父层每帧重建(ticker)不会重放,
        // 只有"重新插入"(收起再展开)才会从头跑。
        Positioned.fill(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            builder: (context, t, child) => Opacity(opacity: t, child: child),
            child: CoverBackdrop(palette: _coverPalette, child: _buildLyrics()),
          ),
        ),
      // 输入联想盖在 tab 内容之上并**占满剩余高度**(需求 14):
      // 以前它是一条 maxHeight 280 的窄条, 联想多了只能在小矩形里滚,
      // 下面还露出半截结果页。tab 树仍然挂在 Offstage 里, 收起联想不重建。
      if (!_lyric.visible && _tab == 0 && _search.suggestions.isNotEmpty)
        Positioned.fill(
          // 不透明底色: 联想面板铺满后, 下面的 tab 内容不该从卡片外边
          // 那 12dp 的缝里透出来。
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: SuggestionPanel(
              items: _search.suggestions,
              // 分类 tab 与底部「看全部结果」都要知道当前输入词
              keyword: _controller.text.trim(),
              onSelected: (item) => _search.searchKeyword(item.title),
              onSearchAll: _search.busy ? null : _search.search,
            ),
          ),
        ),
    ],
  );

  void _onTabSelected(int index) {
    // 桌面: 导航是窗口常驻外壳, 点它时可能有全屏页压着(pageDepth > 1)。
    // 先退回首页再走原有切 tab 逻辑 —— 包括点的是**当前** tab 的情况:
    // 下面的 `_tab == index` early return 会吞掉这次点击, 表现为「点导航没反应」。
    // 手机上的导航在全屏页期间仍然让位, 走不到这里。
    if (isDesktopPlatform && pageDepth.value > 1) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    if (_tab == index) return;
    // 切 tab = 一个"干净的新视图": 收掉**所有**浮层(底部面板 / 对话框)。
    //
    // 弹层是 modal route, 不会随 tab 切换自己消失, 会一直挂在旧页面上
    // (用户 2026-11-17 登录弹层 / 2026-11-18 队列面板反馈)。以前这里逐类手写
    // (`dismissLoginSheet()` + `_queueUI.close()`), 只补了 2 类 —— 歌曲动作面板 /
    // 收藏到歌单 / 分享面板 / 关注页艺人筛选 / 更新弹窗 都还挂着。
    // 现在只有一个入口: 按 NavigatorObserver 的浮层登记表逐条摘除
    // (见 app_shell.dart 的 dismissAllPopups / popup_routes.dart)。
    dismissAllPopups();
    // 右栏详情属于"上一屏的左栏": 切 tab 等于换一个干净视图, 右栏一并清掉
    // (与收浮层同一个语义 —— 否则右栏会挂在新 tab 上, 左栏却已经不是它的列表)
    closeDetailPane();
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
      // 「猜你想搜」不再是一块长期不变的内容: 每次进搜索页按 TTL 决定是否换新
      unawaited(_search.refreshRecommended());
    }
  }

  /// 五个 tab 都塞进 IndexedStack(访问过的才真正构建), 保留各自的 State.

  /// 顶部栏: 只在它承载了导航里没有的信息时才出现(歌词页 / 歌单浏览态),
  /// 其余情况整条不出现。装配在 [HomeLyricsPage.buildTopBar](src/home/lyrics_page.dart)。
  PreferredSizeWidget? _buildTopBar(
    BuildContext context,
    rust.SongDto? current,
  ) => _lyrics.buildTopBar(context, current);

  /// 搜索输入条(装配在 [HomeSearchBarHost.build], 见 src/home/search_bar_host.dart)
  Widget _buildSearchBar() => _searchBar.build();

  /// 歌曲详情页正文 = 歌词 + (定位当前句 / 底部次要控制)
  ///
  /// 装配在 [HomeLyricsPage.buildBody](src/home/lyrics_page.dart, 拆 §7.7 第二刀):
  /// 逐字/纯文本/错误/暂无/时间轴五分支的顺序与"歌词 ⇄ 封面"面板原样搬过去。
  Widget _buildLyrics() => _lyrics.buildBody(context);

  /// 投递播放条数据快照(帧后; 与上一份相等时 ValueNotifier 不通知 → 播放条不重建)。
  ///
  /// 没有曲目时不投(Media3 连接前拿到的是一份空状态, 空态不占位置)。
  ///
  /// 写入走 app_shell.dart 的 publishPlayerBarSnapshot(帧后 + 存活守卫, U-05):
  /// 首页在这一帧之后被销毁时, 旧实例的数据/播放态不准再写进全局槽位(播放条、
  /// 列表高亮会读到死页面的状态)。帧后投递与"同帧一次通知"的口径都在那里。
  void _publishPlayerBar(
    BuildContext context,
    PlayerView? player,
    rust.SongDto? current,
  ) {
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
            heartActive: _queueUI.heartActive,
            fmActive: _queueUI.fmActive,
          );
    // Linux 系统托盘菜单的按钮态: 文案(播放/暂停、喜欢/取消喜欢)与置灰全由
    // 这里推过去。幂等(值没变不跨通道), 所以每次构建推一次几乎零成本;
    // 非 Linux 平台直接 return false, 不碰通道。
    unawaited(
      DesktopShell.instance.setPlaybackState(
        playing: showBar && player.playing,
        liked: _isLiked(current?.id),
        hasTrack: showBar,
      ),
    );
    // 快照 + 全局"正在播放"样本(见 src/now_playing.dart): 所有列表行的播放态
    // 高亮都读它 —— 以前各页自己传 currentTrackId, 少接一处(如完整日推歌单)
    // 就不高亮。帧后写, 避免在 build 期间通知下游 setState。
    publishPlayerBarSnapshot(
      context,
      data: data,
      nowPlayingId: showBar ? (current?.id ?? player.trackId) : null,
    );
  }

  /// 首页底部导航栏的构建结果, 由根布局渲染(见 [playerBarSlot])。
  ///
  /// 底部 tab 属于首页: **手机上**有全屏页压在首页之上时返回 null(播放条由
  /// [playerBarData] 负责, 此时它自己吃掉系统手势区), 弹层/对话框不算。
  Widget? _buildBottomBar(BuildContext context) {
    // 桌面(Linux/Windows)上导航是**窗口常驻外壳**, 全屏页压上来时不让位:
    // 让位会让根布局(_PlayerBarChrome)在转场第一帧从 Row(rail + 右列) 换成 Column,
    // 一级页内容横向跳 kRailWidth、播放条从 (窗口宽 - rail) 变成窗口宽 ——
    // 就是用户 2026-11-26 反馈的「进二级页闪一下 / 内外排版重排 / 播放条边界长度变化」。
    // 手机上全屏页仍让位: 那里是全屏阅读, 导航不该常驻占一条。
    if (pageDepth.value > 1 && !isDesktopPlatform) return null;
    // 宽档(>= 900)把导航搬到左侧 NavigationRail, 中/窄档保持底部 NavigationBar。
    // 档位只由可用宽度决定(不看设备类型): 桌面窗口缩窄就退回底部导航。
    // 语义与 NavigationBar 一一对应: 同一 selectedIndex / 同一回调 / 标签常显
    // (alwaysShow ↔ labelType.all) / 同一 pageDepth 让位(上面那行仍然先判, 且只手机上让)。
    if (layoutTierFor(MediaQuery.sizeOf(context).width) == LayoutTier.wide) {
      return NavigationRail(
        selectedIndex: _tab,
        onDestinationSelected: _onTabSelected,
        labelType: NavigationRailLabelType.all,
        minWidth: kRailWidth,
        // 窗口矮(如横屏手机 700~900 高 < 450 时不算宽档, 但桌面小窗会)时
        // 让目的地组自己滚: NavigationRail 默认不滚, 五个目的地会竖溢。
        scrollable: true,
        destinations: const [
          NavigationRailDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: Text('搜索'),
          ),
          NavigationRailDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore),
            label: Text('推荐'),
          ),
          NavigationRailDestination(
            icon: Icon(Icons.dynamic_feed_outlined),
            selectedIcon: Icon(Icons.dynamic_feed),
            label: Text('关注'),
          ),
          NavigationRailDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: Text('我的'),
          ),
          NavigationRailDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: Text('设置'),
          ),
        ],
      );
    }
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
