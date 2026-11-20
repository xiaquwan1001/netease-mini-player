// 推荐页顶栏回归(2026-11-20 用户口径):
//   ① 顶栏第一格**固定**为「歌单广场」(点卡片进歌单广场页), 与「推荐歌单」区块
//      标题右侧的「全部」同一落地页;
//   ② 原「自定义选择」机制(右上角设置角标 / 长按换绑浮层 / AppSettings.customQuickAction
//      持久化)已整体删除 —— 这里断言"没有角标、长按也不弹浮层";
//   ③ 顶栏三个 icon 仍是 26.4(24 +10%), 300dp/1.25 不溢出、文案不被挤掉。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/recommend_view.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

Widget recommend({
  VoidCallback? onOpenDaily,
  void Function(rust.Playlist)? onOpenPlaylist,
  VoidCallback? onHeartMode,
}) => RecommendView(
  loggedIn: true,
  loadDailySongs: () async => const <rust.SongDto>[],
  loadDailyPlaylists: () async => const <rust.Playlist>[],
  loadPodcasts: () async => const <rust.PodcastRadio>[],
  loadFm: () async => const <rust.SongDto>[],
  loadStyles: () async => const <rust.StyleTag>[],
  loadNewSongs: () async => const <rust.SongDto>[],
  loadNewAlbums: () async => const <rust.AlbumItem>[],
  // 传了 onOpenAlbum 才会渲染「新碟上架」次级列表(否则那一块整段不出现)
  onOpenAlbum: (_) {},
  onOpenPlaylist: onOpenPlaylist ?? (_) {},
  onOpenPodcast: (_) {},
  onHeartMode: onHeartMode ?? () {},
  onOpenDaily: onOpenDaily ?? () {},
);

void main() {
  testWidgets('第一格固定「歌单广场」: 文案/图标正确, 点击进歌单广场页', (tester) async {
    var daily = 0;
    await tester.pumpWidget(host(recommend(onOpenDaily: () => daily++)));
    await tester.pumpAndSettle();

    expect(find.text('歌单广场'), findsOneWidget);
    expect(find.byIcon(Icons.grid_view), findsOneWidget);
    // 「每日推荐」只剩区块标题那一处(顶栏不再重复入口)
    expect(find.text('每日推荐'), findsOneWidget);

    await tester.tap(find.text('歌单广场'));
    // 落地页会真的取数(测试里不联网): 固定推几帧看路由标题, 不用 pumpAndSettle
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.widgetWithText(AppBar, '歌单广场'), findsOneWidget);
    expect(daily, 0);
  });

  testWidgets('「自定义选择」已删除: 没有设置角标, 长按也不弹换绑浮层', (tester) async {
    await tester.pumpWidget(host(recommend()));
    await tester.pumpAndSettle();

    // 角标(Icons.tune)与浮层标题都不该再出现
    expect(find.byIcon(Icons.tune), findsNothing);
    expect(find.text('把这一格换成'), findsNothing);

    // 卡片只剩 onTap 一个手势(没有 onLongPress): 长按既不弹浮层, 也不会出现
    // 单选列表; 松开后按 tap 处理, 直接进歌单广场页(与单击同一条路径)。
    await tester.longPress(find.text('歌单广场'));
    await tester.pumpAndSettle();
    expect(find.text('把这一格换成'), findsNothing);
    expect(find.byType(RadioListTile<Object>), findsNothing);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.widgetWithText(AppBar, '歌单广场'), findsOneWidget);
  });

  testWidgets('心动模式 / 私人FM 两格保持原样, 点击回调仍生效', (tester) async {
    var heart = 0;
    await tester.pumpWidget(host(recommend(onHeartMode: () => heart++)));
    await tester.pumpAndSettle();

    expect(find.text('心动模式'), findsOneWidget);
    expect(find.text('私人FM'), findsOneWidget);
    // 与播放条心动档同一图标(local_fire_department), 全 App 唯一
    expect(find.byIcon(Icons.local_fire_department), findsOneWidget);
    expect(find.byIcon(Icons.radio), findsOneWidget);

    await tester.tap(find.text('心动模式'));
    await tester.pumpAndSettle();
    expect(heart, 1);

    // 私人FM: 测试里 loggedIn=true 但 loadFm 返回空 ⇒ 只出提示, 不抛异常
    await tester.tap(find.text('私人FM'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
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
      Icons.grid_view,
      Icons.local_fire_department,
      Icons.radio,
    ]) {
      final widget = tester.widget<Icon>(find.byIcon(icon).first);
      expect(widget.size, 26.4, reason: '$icon 必须放大 10%(24 → 26.4)');
    }
    // 文案也没被挤掉(三格标签都完整渲染)
    expect(find.text('歌单广场'), findsOneWidget);
    expect(find.text('心动模式'), findsOneWidget);
    expect(find.text('私人FM'), findsOneWidget);
  });

  testWidgets('栏目图标: 各区块标题左侧都有语义图标(内置 Material Icons)', (tester) async {
    // 用一整屏高度渲染: ListView 是懒构建的, 矮视口下底部区块(新歌新碟/推荐播客)
    // 根本不会被建出来, 断言会误报"图标缺失"。
    tester.view.physicalSize = const Size(360, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(recommend()));
    await tester.pumpAndSettle();

    for (final icon in const [
      Icons.wb_sunny_outlined, // 每日推荐
      Icons.category_outlined, // 风格推荐
      Icons.fiber_new_outlined, // 新歌新碟
      Icons.queue_music_outlined, // 推荐歌单
      Icons.podcasts_outlined, // 推荐播客
      Icons.new_releases_outlined, // 次级小标题: 新歌速递
      Icons.album_outlined, // 次级小标题: 新碟上架
    ]) {
      expect(
        find.byIcon(icon),
        findsWidgets,
        reason: '$icon 必须作为该栏目的图标出现在标题左侧',
      );
    }
  });
}
