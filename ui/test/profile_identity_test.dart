// 身份覆盖层(名字/别名/签名)与背景图**不相交**的几何回归.
//
// 之前三处横幅都是"白字直接叠在 170 高的背景图上", 背景稍亮就读不出来; 现在身份信息
// 落在图片下方的 surface 卡片里, 这里用 bounding box 把"不压图"钉死.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/profile_banner.dart';

const String kCover = 'https://p1.music.126.net/a/b.jpg';
const String kName = '周杰伦';
const String kAlias = 'Jay Chou / 周董';

Widget host(Widget child, {double textScale = 1.0}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void setView(
  WidgetTester tester, {
  double dpr = 1.0,
  double width = 360,
  double height = 800,
}) {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(width * dpr, height * dpr);
  addTearDown(tester.view.reset);
}

Widget banner({String name = kName, String alias = kAlias}) => ProfileBanner(
  title: name,
  subtitle: alias,
  imageUrl: kCover,
  footer: const Text('关注 44 · 粉丝 11 · Lv.8'),
);

void main() {
  testWidgets('名字/别名/统计与图片区 bounding box 不相交', (tester) async {
    setView(tester);
    await tester.pumpWidget(host(banner()));

    final image = tester.getRect(find.byType(ProfileBannerImage));
    expect(image.height, kProfileBannerHeight);

    for (final finder in [
      find.text(kName),
      find.text(kAlias),
      find.text('关注 44 · 粉丝 11 · Lv.8'),
    ]) {
      expect(finder, findsOneWidget);
      final text = tester.getRect(finder);
      expect(
        text.overlaps(image),
        isFalse,
        reason: '$finder 压在背景图上了: $text vs $image',
      );
      expect(
        text.top,
        greaterThanOrEqualTo(image.bottom),
        reason: '$finder 必须在图片下沿之下',
      );
    }
  });

  testWidgets('身份卡上浮也只在卡片底色层, 文字仍在图下方', (tester) async {
    setView(tester);
    await tester.pumpWidget(host(banner()));
    final image = tester.getRect(find.byType(ProfileBannerImage));
    final card = tester.getRect(find.byType(ProfileIdentity));
    // 卡片本身允许上浮(kProfileIdentityLift)与图片重叠出层次
    expect(card.top, lessThan(image.bottom));
    expect(
      image.bottom - card.top,
      kProfileIdentityLift,
      reason: '只允许上浮一个 lift(不是把整块文字压在图上)',
    );
  });

  testWidgets('300dp + 1.25 字号: 不溢出且文字仍不与图片相交', (tester) async {
    setView(tester, width: 300, height: 700);
    await tester.pumpWidget(
      host(
        banner(
          name: '这是一个特别特别特别长的昵称用来挤窄屏空间',
          alias: '这是一段同样特别特别特别长的别名/签名, 验证窄屏大字号下省略号正常不溢出',
        ),
        textScale: 1.25,
      ),
    );
    expect(tester.takeException(), isNull);

    final image = tester.getRect(find.byType(ProfileBannerImage));
    for (final finder in [
      find.text('这是一个特别特别特别长的昵称用来挤窄屏空间'),
      find.text('这是一段同样特别特别特别长的别名/签名, 验证窄屏大字号下省略号正常不溢出'),
    ]) {
      expect(finder, findsOneWidget);
      expect(tester.getRect(finder).overlaps(image), isFalse);
    }
  });
}
