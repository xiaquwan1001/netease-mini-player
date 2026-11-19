// B7/B8 回归(2026-11-19 用户反馈批):
//   B7 顶栏第一格「每日推荐」与下方「每日推荐」区块的「全部」是同一个入口 ⇒
//      改成可自定义的功能入口(浮层单选 + 持久化 + 点击执行);
//   B8 顶栏三个 icon 放大 10%(24 → 26.4), 300dp/1.25 不溢出、文案不被挤掉。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/recommend_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

Widget recommend({
  VoidCallback? onOpenRanking,
  VoidCallback? onOpenDailyHistory,
  VoidCallback? onOpenDaily,
  VoidCallback? onOpenNewRelease,
  void Function(rust.Playlist)? onOpenPlaylist,
  void Function(rust.PodcastRadio)? onOpenPodcast,
}) => RecommendView(
  loggedIn: true,
  loadDailySongs: () async => const <rust.SongDto>[],
  loadDailyPlaylists: () async => const <rust.Playlist>[],
  loadPodcasts: () async => const <rust.PodcastRadio>[],
  loadFm: () async => const <rust.SongDto>[],
  loadStyles: () async => const <rust.StyleTag>[],
  loadNewSongs: () async => const <rust.SongDto>[],
  loadNewAlbums: () async => const <rust.AlbumItem>[],
  onOpenRanking: onOpenRanking,
  onOpenDailyHistory: onOpenDailyHistory,
  onOpenNewRelease: onOpenNewRelease,
  onOpenPlaylist: onOpenPlaylist ?? (_) {},
  onOpenPodcast: onOpenPodcast ?? (_) {},
  onHeartMode: () {},
  onOpenDaily: onOpenDaily ?? () {},
);

void main() {
  setUp(() {
    AppSettings.instance.customQuickAction = CustomQuickAction.ranking;
  });
  tearDown(() {
    AppSettings.instance.customQuickAction = CustomQuickAction.ranking;
  });

  testWidgets('默认动作 = 排行榜: 卡片文案/图标正确, 点击走 onOpenRanking', (tester) async {
    var ranking = 0;
    var daily = 0;
    await tester.pumpWidget(
      host(
        recommend(onOpenRanking: () => ranking++, onOpenDaily: () => daily++),
      ),
    );
    await tester.pumpAndSettle();

    // B7: 第一格不再是「每日推荐」(页面里只剩区块标题那一处)
    expect(find.text('每日推荐'), findsOneWidget);
    expect(find.text('排行榜'), findsOneWidget);
    expect(find.byIcon(Icons.leaderboard), findsOneWidget);

    await tester.tap(find.text('排行榜'));
    await tester.pumpAndSettle();
    expect(ranking, 1);
    expect(daily, 0, reason: '默认动作不能又回到「每日推荐」的入口上');
  });

  testWidgets('B8: 三个快捷卡图标 26.4(24 +10%), 300dp/1.25 不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(recommend()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    for (final icon in const [
      Icons.leaderboard,
      Icons.local_fire_department,
      Icons.radio,
    ]) {
      final widget = tester.widget<Icon>(find.byIcon(icon).first);
      expect(widget.size, 26.4, reason: '$icon 必须放大 10%(24 → 26.4)');
    }
    // 文案也没被挤掉(三格标签都完整渲染)
    expect(find.text('排行榜'), findsOneWidget);
    expect(find.text('心动模式'), findsOneWidget);
    expect(find.text('私人FM'), findsOneWidget);
  });

  testWidgets('改选动作: 角标开浮层 → 选项落盘 → 卡片文案/图标跟着变, 点击执行新动作', (tester) async {
    var ranking = 0;
    var history = 0;
    await tester.pumpWidget(
      host(
        recommend(
          onOpenRanking: () => ranking++,
          onOpenDailyHistory: () => history++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 角标(Icons.tune)是换绑入口; 卡片本体点击是执行动作
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    // 浮层走 app_sheet 的唯一入口, 五个候选动作都在
    expect(find.text('把这一格换成'), findsOneWidget);
    for (final action in CustomQuickAction.values) {
      expect(
        find.widgetWithText(RadioListTile<CustomQuickAction>, action.label),
        findsOneWidget,
        reason: '${action.label} 必须是可选项',
      );
    }

    await tester.tap(
      find.widgetWithText(RadioListTile<CustomQuickAction>, '历史日推'),
    );
    await tester.pumpAndSettle();

    // 选中即持久化, 且卡片立刻换文案/图标
    expect(
      AppSettings.instance.customQuickAction,
      CustomQuickAction.historyDaily,
    );
    expect(find.text('历史日推'), findsOneWidget);
    expect(find.byIcon(Icons.history), findsOneWidget);
    expect(find.text('排行榜'), findsNothing);

    // 点卡片执行新动作(历史日推 = 每日推荐页第三个页签)
    await tester.tap(find.text('历史日推'));
    await tester.pumpAndSettle();
    expect(history, 1);
    expect(ranking, 0);
  });

  testWidgets('持久化读回来的动作(新歌新碟/歌单广场)也能正确执行', (tester) async {
    var more = 0;
    // 模拟「上次选了新歌新碟, 重启后从 settings.json 读回」
    AppSettings.instance.customQuickAction = CustomQuickAction.newRelease;
    await tester.pumpWidget(
      host(recommend(onOpenRanking: () {}, onOpenNewRelease: () => more++)),
    );
    await tester.pumpAndSettle();
    // 文案与下方「新歌新碟」区块标题重名 ⇒ 卡片那处在最上面(.first)
    expect(find.text('新歌新碟'), findsNWidgets(2));
    expect(find.byIcon(Icons.fiber_new), findsOneWidget);
    await tester.tap(find.text('新歌新碟').first);
    await tester.pumpAndSettle();
    expect(more, 1);

    // 歌单广场: 卡片点击直接进「歌单广场」页(与「推荐歌单」区块的「全部」同一个落地页)
    await tester.pumpWidget(const SizedBox.shrink());
    AppSettings.instance.customQuickAction = CustomQuickAction.playlistSquare;
    await tester.pumpWidget(host(recommend()));
    await tester.pumpAndSettle();
    expect(find.text('歌单广场'), findsOneWidget);
    await tester.tap(find.text('歌单广场'));
    // 落地页会真的取数(测试里不联网): 固定推几帧看路由标题, 不用 pumpAndSettle
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.widgetWithText(AppBar, '歌单广场'), findsOneWidget);
  });

  testWidgets('长按卡片同样能进换绑浮层, 选「私人FM」后执行私人FM', (tester) async {
    await tester.pumpWidget(
      host(recommend(onOpenRanking: () {}, onOpenDailyHistory: () {})),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('排行榜'));
    await tester.pumpAndSettle();
    expect(find.text('把这一格换成'), findsOneWidget);

    await tester.tap(
      find.widgetWithText(RadioListTile<CustomQuickAction>, '私人FM'),
    );
    await tester.pumpAndSettle();
    expect(
      AppSettings.instance.customQuickAction,
      CustomQuickAction.personalFm,
    );

    // 浮层关掉后卡片文案是「私人FM」(与右侧第三格同名, 所以是 2 处)
    expect(find.text('私人FM'), findsNWidgets(2));
    expect(find.byIcon(Icons.radio), findsNWidgets(2));
  });
}
