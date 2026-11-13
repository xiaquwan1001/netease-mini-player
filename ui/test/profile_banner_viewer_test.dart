// 点 banner -> 全屏查看器 -> 保存原图 的离线单测(不联网, 不落盘).
//
// 关键点: banner 上显示的是 `?param=WxH` 缩略图, 保存必须是**不带 param 的 CDN 原图**.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/profile_banner.dart';

const String kCover = 'http://p3.music.126.net/a/cover.jpg';

Widget host(Widget child, {double textScale = 1.0}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('点 banner 打开全屏查看器(带保存按钮)', (tester) async {
    await tester.pumpWidget(
      host(
        const ProfileBanner(
          title: '周杰伦',
          imageUrl: kCover,
          fetchOverride: _neverFetch,
          saveOverride: _neverSave,
        ),
      ),
    );
    expect(find.byTooltip('保存原图'), findsNothing);

    await tester.tap(find.byType(ProfileBannerImage));
    await tester.pumpAndSettle();

    expect(find.byTooltip('保存原图'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
  });

  testWidgets('保存原图: 取的是不带 param 的原图字节', (tester) async {
    final fetched = <String>[];
    final saved = <String, int>{};
    await tester.pumpWidget(
      host(
        ProfileBanner(
          title: '周杰伦',
          imageUrl: kCover,
          fetchOverride: (url) async {
            fetched.add(url);
            return Uint8List.fromList(List<int>.filled(4096, 9));
          },
          saveOverride: (bytes, name) async {
            saved[name] = bytes.length;
            return '/tmp/$name';
          },
        ),
      ),
    );

    await tester.tap(find.byType(ProfileBannerImage));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('保存原图'));
    await tester.pumpAndSettle();

    expect(fetched, [
      'https://p3.music.126.net/a/cover.jpg',
    ], reason: '原图直链, 不带 param');
    expect(saved.length, 1);
    final name = saved.keys.first;
    expect(name.endsWith('.jpg'), isTrue);
    expect(saved[name], 4096);
    expect(find.textContaining('原图已保存'), findsOneWidget);
  });

  testWidgets('取图失败: 提示保存失败, 不抛异常', (tester) async {
    await tester.pumpWidget(
      host(
        const ProfileBanner(
          title: '小红',
          imageUrl: kCover,
          fetchOverride: _failFetch,
          saveOverride: _neverSave,
        ),
      ),
    );
    await tester.tap(find.byType(ProfileBannerImage));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('保存原图'));
    await tester.pumpAndSettle();
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有背景图: 点 banner 不弹查看器', (tester) async {
    await tester.pumpWidget(host(const ProfileBanner(title: '小红')));
    await tester.tap(find.byType(ProfileBannerImage));
    await tester.pumpAndSettle();
    expect(find.byTooltip('保存原图'), findsNothing);
  });

  testWidgets('300dp + 1.25 字号: 横幅与身份卡不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        const ProfileBanner(
          title: '这是一个特别特别特别长的昵称用来挤窄屏',
          subtitle: '同样的特别特别长的别名/签名, 验证窄屏大字号下省略号正常不溢出',
          imageUrl: kCover,
          fetchOverride: _neverFetch,
          saveOverride: _neverSave,
        ),
        textScale: 1.25,
      ),
    );
    expect(tester.takeException(), isNull);
  });
}

/// 下面两个只是占位实现(本文件里从不真正取图/落盘)
Future<Uint8List> _neverFetch(String url) async => Uint8List(0);
Future<String> _neverSave(Uint8List bytes, String filename) async => filename;
Future<Uint8List> _failFetch(String url) async =>
    throw const FormatException('boom');
