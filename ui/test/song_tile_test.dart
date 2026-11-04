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
}) =>
    rust.SongDto(
      id: BigInt.from(id),
      name: name,
      artist: '周杰伦',
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
    await tester.pumpWidget(host(SongTile(
      song: song(playable: false),
      active: false,
      liked: false,
      onTap: () => taps++,
    )));

    expect(find.text('无版权'), findsOneWidget);
    expect(find.text('VIP'), findsNothing);
    // 名称变灰
    final title = tester.widget<Text>(find.text('晴天'));
    expect(title.style?.color, isNotNull);
    await tester.tap(find.text('晴天'));
    expect(taps, 1);
  });

  testWidgets('VIP 曲目带 VIP 标, 可播曲目不显示无版权', (tester) async {
    await tester.pumpWidget(host(SongTile(
      song: song(fee: 1, vip: true),
      active: true,
      liked: true,
      onTap: () {},
    )));
    expect(find.text('VIP'), findsOneWidget);
    expect(find.text('无版权'), findsNothing);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
  });

  testWidgets('红心跟在歌名后面(不做 leading, 保证歌名左对齐)', (tester) async {
    await tester.pumpWidget(host(Column(
      children: [
        SongTile(song: song(id: 1, name: '普通歌曲'), active: false, liked: false, onTap: () {}),
        SongTile(song: song(id: 2, name: '已收藏歌曲'), active: false, liked: true, onTap: () {}),
      ],
    )));
    final plain = tester.getTopLeft(find.text('普通歌曲'));
    final likedName = tester.getTopLeft(find.text('已收藏歌曲'));
    // 两行歌名左边界一致(红心不再是 leading)
    expect(likedName.dx, plain.dx);
    // 红心在歌名右侧
    final heart = tester.getTopLeft(find.byIcon(Icons.favorite));
    expect(heart.dx, greaterThan(likedName.dx));
  });

  testWidgets('付费专辑显示 付费, 会员与非会员标不重复', (tester) async {
    await tester.pumpWidget(host(SongTile(
      song: song(fee: 4, paid: true),
      active: false,
      liked: false,
      onTap: () {},
    )));
    expect(find.text('付费'), findsOneWidget);
    expect(find.text('VIP'), findsNothing);
  });
}
