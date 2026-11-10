// 他人主页(只读资料 + 公开歌单)的回归.
//
// 背景: 听众列表/关注粉丝列表早就能列出用户, 但"点不动" —— 没有用户主页这个目的地.
// 数据面 = user_profile(user/detail, 匿名可用) + user_playlists_of(user/playlist).
// 这里用注入 loader 覆盖渲染/空态/失败重试, 不联网、不碰 FFI.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/user_page.dart';

rust.ProfileDetail detail({
  String nickname = '下去玩',
  String signature = '',
}) =>
    rust.ProfileDetail(
      userId: BigInt.from(1822714196),
      nickname: nickname,
      avatarUrl: null,
      backgroundUrl: null,
      signature: signature,
      vip: false,
      follows: BigInt.from(44),
      followeds: BigInt.from(11),
      level: BigInt.from(8),
    );

rust.Playlist playlist(int id, String name, {int count = 2}) => rust.Playlist(
      id: BigInt.from(id),
      name: name,
      coverUrl: null,
      trackCount: BigInt.from(count),
      special: false,
    );

Widget host(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('资料卡 + 公开歌单都渲染', (tester) async {
    await tester.pumpWidget(host(UserPage(
      userId: BigInt.from(1822714196),
      loadProfile: (_) async => detail(signature: '听歌就好'),
      loadPlaylists: (_) async => [
        playlist(1, '想学的指弹曲', count: 2),
        playlist(2, '通勤向/日系R&B', count: 89),
      ],
    )));
    await tester.pumpAndSettle();

    expect(find.text('下去玩'), findsWidgets); // AppBar + 资料卡
    expect(find.text('听歌就好'), findsOneWidget);
    expect(find.textContaining('关注 44'), findsOneWidget);
    expect(find.text('想学的指弹曲'), findsOneWidget);
    expect(find.textContaining('89 首'), findsOneWidget);
  });

  testWidgets('没有公开歌单时给明确空态', (tester) async {
    await tester.pumpWidget(host(UserPage(
      userId: BigInt.from(1),
      loadProfile: (_) async => detail(nickname: '小红'),
      loadPlaylists: (_) async => const [],
    )));
    await tester.pumpAndSettle();
    expect(find.text('没有公开歌单'), findsOneWidget);
  });

  testWidgets('加载失败: 给出错误与重试, 重试成功后正常显示', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(host(UserPage(
      userId: BigInt.from(1),
      loadProfile: (_) async {
        attempts++;
        // 用非 network 错误: retryNetwork 只重试网络错, 这里要的是首屏失败这个状态
        if (attempts == 1) throw Exception('[internal] boom');
        return detail(nickname: '小红');
      },
      loadPlaylists: (_) async => [playlist(1, '一个歌单')],
    )));
    await tester.pumpAndSettle();
    expect(find.text('加载失败'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('一个歌单'), findsOneWidget);
    expect(find.text('加载失败'), findsNothing);
  });

  testWidgets('没有播放回调时点歌单只提示, 不崩', (tester) async {
    await tester.pumpWidget(host(UserPage(
      userId: BigInt.from(1),
      loadProfile: (_) async => detail(nickname: '小红'),
      loadPlaylists: (_) async => [playlist(1, '一个歌单')],
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一个歌单'));
    await tester.pump();
    expect(find.text('当前页面不支持播放'), findsOneWidget);
  });
}
