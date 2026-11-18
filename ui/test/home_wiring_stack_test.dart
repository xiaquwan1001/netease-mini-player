// U-06 回归: HomeWiring 多实例的所有权交还(实例栈, 不是"最近一次 attach"单指针)。
//
// 背景(arch-audit-ui-overlay-2026-11-18 P2/U-06): 单指针语义下
//   A attach → B attach → B detach
// 时 `_latest` 直接变 null ⇒ 进程级全局槽位("..."动作宿主 / 播放条回调 /
// ArtistNav.onOpenAlbum / 通知栏·托盘回调)全被清空, 而 A 明明还活着(它的
// 监听器一条都没摘), 功能要等下一个 HomePage 实例才恢复。
//
// 修法: attach 顺序入栈, 栈顶是槽位主人; 主人 detach 时把槽位**交还**给仍然
// 活着的上一个。下面两条用例是两种配对顺序, 两条都不能互相退化。
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_shell.dart' show actionsHost, playerBarActions;
import 'package:minincm/src/artist_nav.dart';
import 'package:minincm/src/home/home_wiring.dart';
import 'package:minincm/src/player_bar.dart';
import 'package:minincm/src/song_actions.dart' show SongActionHost;

SongActionHost _host() => SongActionHost(
  loggedIn: false,
  isLiked: (_) => false,
  toggleLike: (_) async {},
  playNext: (_) async {},
  addToPlaylist: (_) async {},
  share: (_) async {},
  comments: (_) async {},
  openArtist: (_) async {},
  openAlbum: (_) async {},
  download: (_) async {},
);

PlayerBarActions _barActions() => PlayerBarActions(
  onSeekStart: (_) {},
  onSeekChanging: (_) {},
  onSeekEnd: (_) {},
  onToggleLyrics: () {},
  onOpenDetail: () {},
  onToggleLike: () {},
  onToggle: () {},
  onPrevious: () {},
  onNext: () {},
  onCycleMode: () {},
  onOpenQueue: () {},
);

/// 每次调用都造一个**新的**闭包对象: 用它做身份断言, 判断全局槽位挂的是谁的。
void Function(BigInt, String, String?) _newAlbumOpener() =>
    (BigInt albumId, String name, String? cover) {};

/// 一个可辨识的实例: 宿主/回调集合/打开专辑回调都是自己那一份。
class Fake {
  Fake() : barActions = _barActions() {
    host = _host();
  }

  late final SongActionHost host;
  final PlayerBarActions barActions;
  final void Function(BigInt, String, String?) openAlbum = _newAlbumOpener();

  HomeWiring wiring() => HomeWiring(
    onNext: () async {},
    onPrevious: () async {},
    onEnded: () {},
    onToggleLike: () async {},
    onCycleMode: () async {},
    onTogglePlay: () {},
    buildActionsHost: () => host,
    barActions: barActions,
    openAlbum: openAlbum,
    onUpdatePrompt: () {},
    onPageDepthChanged: () {},
    onAudioSettingsChanged: () {},
  )..attach();
}

/// 推进一帧并把帧后回调队列跑完。
///
/// `tester.pump()` 只在有帧被调度时才真的推进一帧, 而这里没有脏 widget ——
/// 不先 `scheduleFrame()` 的话播放条回调(帧后投递)永远不会执行, 用例会假绿。
Future<void> flushFrame(WidgetTester tester) async {
  tester.binding.scheduleFrame();
  await tester.pump();
}

void main() {
  tearDown(() {
    // 兜底: 用例中途失败时也别把静态槽位留给下一个文件
    actionsHost.value = null;
    playerBarActions.value = null;
    ArtistNav.onOpenAlbum = null;
  });

  testWidgets('A attach → B attach → B detach ⇒ 槽位交还给 A', (tester) async {
    final a = Fake();
    final b = Fake();
    final wa = a.wiring();
    await flushFrame(tester); // 播放条回调是帧后投递
    expect(identical(actionsHost.value, a.host), isTrue);
    expect(identical(playerBarActions.value, a.barActions), isTrue);

    final wb = b.wiring();
    await flushFrame(tester);
    expect(identical(actionsHost.value, b.host), isTrue, reason: '后建覆盖先建');
    expect(identical(playerBarActions.value, b.barActions), isTrue);

    wb.detach();
    await flushFrame(tester);
    expect(
      identical(actionsHost.value, a.host),
      isTrue,
      reason: 'B 走掉后不能把槽位清空 —— A 还活着(U-06 的原始 bug)',
    );
    expect(identical(playerBarActions.value, a.barActions), isTrue);
    expect(identical(ArtistNav.onOpenAlbum, a.openAlbum), isTrue);

    wa.detach();
    await flushFrame(tester);
    expect(actionsHost.value, isNull);
    expect(playerBarActions.value, isNull);
    expect(ArtistNav.onOpenAlbum, isNull);
  });

  testWidgets('A attach → B attach → A detach ⇒ 槽位仍为 B', (tester) async {
    final a = Fake();
    final b = Fake();
    final wa = a.wiring();
    await flushFrame(tester);
    final wb = b.wiring();
    await flushFrame(tester);

    wa.detach();
    await flushFrame(tester);
    expect(
      identical(actionsHost.value, b.host),
      isTrue,
      reason: '旧实例先销毁时不得清掉新实例的绑定',
    );
    expect(identical(playerBarActions.value, b.barActions), isTrue);
    expect(identical(ArtistNav.onOpenAlbum, b.openAlbum), isTrue);

    wb.detach();
    await flushFrame(tester);
    expect(actionsHost.value, isNull);
    expect(playerBarActions.value, isNull);
  });

  testWidgets('attach 幂等: 重复 attach 不在栈里留重复项', (tester) async {
    final a = Fake();
    final wa = a.wiring();
    wa.attach(); // 第二次 attach 应被 _attached 挡住
    await flushFrame(tester);
    wa.detach();
    await flushFrame(tester);
    expect(actionsHost.value, isNull);
    expect(playerBarActions.value, isNull);
    // 再 attach 一次仍可用(不会因为"已经在栈里"被跳过)
    wa.attach();
    await flushFrame(tester);
    expect(identical(actionsHost.value, a.host), isTrue);
    wa.detach();
  });
}
