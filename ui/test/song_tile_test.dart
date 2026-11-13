import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/song_tile.dart';

rust.SongDto song({
  int id = 1,
  String name = '晴天',
  int fee = 0,
  bool vip = false,
  bool paid = false,
  bool playable = true,
}) => rust.SongDto(
  id: BigInt.from(id),
  name: name,
  artist: '周杰伦',
  artistId: BigInt.one,
  album: '叶惠美',
  albumId: BigInt.from(1),
  coverUrl: null,
  durationMs: BigInt.from(269000),
  fee: fee,
  vip: vip,
  paid: paid,
  playable: playable,
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('无版权曲目: 灰显 + 无版权标, 点击仍回调(由调用方弹提示)', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      host(
        SongTile(
          song: song(playable: false),
          active: false,
          liked: false,
          onTap: () => taps++,
        ),
      ),
    );

    expect(find.text('无版权'), findsOneWidget);
    expect(find.text('VIP'), findsNothing);
    // 名称变灰
    final title = tester.widget<Text>(find.text('晴天'));
    expect(title.style?.color, isNotNull);
    await tester.tap(find.text('晴天'));
    expect(taps, 1);
  });

  testWidgets('VIP 曲目带 VIP 标, 可播曲目不显示无版权', (tester) async {
    await tester.pumpWidget(
      host(
        SongTile(
          song: song(fee: 1, vip: true),
          active: true,
          liked: true,
          onTap: () {},
        ),
      ),
    );
    expect(find.text('VIP'), findsOneWidget);
    expect(find.text('无版权'), findsNothing);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
  });

  testWidgets('红心跟在歌名后面(不做 leading, 保证歌名左对齐)', (tester) async {
    await tester.pumpWidget(
      host(
        Column(
          children: [
            SongTile(
              song: song(id: 1, name: '普通歌曲'),
              active: false,
              liked: false,
              onTap: () {},
            ),
            SongTile(
              song: song(id: 2, name: '已收藏歌曲'),
              active: false,
              liked: true,
              onTap: () {},
            ),
          ],
        ),
      ),
    );
    final plain = tester.getTopLeft(find.text('普通歌曲'));
    final likedName = tester.getTopLeft(find.text('已收藏歌曲'));
    // 两行歌名左边界一致(红心不再是 leading)
    expect(likedName.dx, plain.dx);
    // 红心在歌名右侧
    final heart = tester.getTopLeft(find.byIcon(Icons.favorite));
    expect(heart.dx, greaterThan(likedName.dx));
  });

  testWidgets('付费专辑显示 付费, 会员与非会员标不重复', (tester) async {
    await tester.pumpWidget(
      host(
        SongTile(
          song: song(fee: 4, paid: true),
          active: false,
          liked: false,
          onTap: () {},
        ),
      ),
    );
    expect(find.text('付费'), findsOneWidget);
    expect(find.text('VIP'), findsNothing);
  });

  testWidgets('300dp 窄屏: VIP 标必须可见(徽标固定宽度, 不会被歌名挤掉)', (tester) async {
    tester.view.physicalSize = const Size(300, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Scaffold(
          body: SongTile(
            song: song(fee: 1, vip: true),
            active: false,
            liked: true,
            onTap: () {},
            onToggleLike: () {},
            onMenu: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('VIP'), findsOneWidget, reason: '用户反馈歌曲行看不到 VIP 标记');
  });

  testWidgets('300dp + 1.25 字号不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Scaffold(
          body: SongTile(
            song: song(name: '一个特别长的歌曲名字用来挤窄屏布局'),
            active: true,
            liked: true,
            onTap: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  // v0.7.2: 用户要求徽标位置与推荐页/歌单页统一 —— 在歌名之后, 不在艺人之前。
  testWidgets('VIP 标在歌名之后(与推荐页一致), 不在艺人行', (tester) async {
    await tester.pumpWidget(
      host(
        SongTile(
          song: song(fee: 1, vip: true),
          active: false,
          liked: true,
          onTap: () {},
          onToggleLike: () {},
          onMenu: () {},
        ),
      ),
    );
    final nameRect = tester.getRect(find.text('晴天'));
    final vipRect = tester.getRect(find.text('VIP'));
    final artistRect = tester.getRect(find.text('周杰伦 · 叶惠美'));
    expect(vipRect.left, greaterThan(nameRect.left), reason: 'VIP 标应在歌名右侧');
    expect(
      (vipRect.center.dy - nameRect.center.dy).abs(),
      lessThan(8),
      reason: 'VIP 标应与歌名同一行',
    );
    expect(
      (vipRect.center.dy - artistRect.center.dy).abs(),
      greaterThan(4),
      reason: 'VIP 标不应再出现在艺人那一行',
    );
  });

  testWidgets('歌曲行左右留白收到最小(把横向空间让给文字)', (tester) async {
    await tester.pumpWidget(
      host(
        SongTile(
          song: song(name: '需要更多横向空间的歌名'),
          active: false,
          liked: false,
          onTap: () {},
          onMenu: () {},
        ),
      ),
    );
    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(
      tile.contentPadding,
      const EdgeInsets.fromLTRB(8, 0, 4, 0),
      reason: '默认 16+16 会白白吃掉 32dp; 用户反馈歌曲行左右没占满',
    );
    // 歌名那块文字区域必须占到行宽的绝大部分
    final nameBox = tester.renderObject<RenderBox>(find.text('需要更多横向空间的歌名'));
    expect(nameBox.size.width, greaterThan(120));
  });
}
