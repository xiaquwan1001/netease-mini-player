// ProfileBanner 取图尺寸/占位/失败兜底的离线单测(不联网).
//
// 背景: 三处横幅原先都是 `NetImage(width: double.infinity, height: 170)`,
// imageCandidates 丢掉非有限宽度后只剩 `param=170y170` —— 一张 170px 的方图被放大
// 铺满 1080x510 物理像素. 这里锁死"按真实像素矩形 x 清晰度档位取图".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/cover_art.dart';
import 'package:minincm/src/profile_banner.dart';

const String kCover = 'https://p1.music.126.net/a/b.jpg';

/// 把测试窗口设成"逻辑 width x height, DPR = dpr"
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

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 当前渲染出来的 Image provider 描述(含实际请求的 URL)
String? renderedImage(WidgetTester tester) {
  final images = find.byType(Image).evaluate().toList();
  if (images.isEmpty) return null;
  return (images.first.widget as Image).image.toString();
}

void main() {
  setUp(() {
    AppSettings.instance.coverQuality = CoverQuality.standard;
  });

  group('neteaseSizedUrl: 矩形 param', () {
    test('宽高分别写进 param(不再是方图)', () {
      expect(
        neteaseSizedUrl(kCover, widthPx: 1080, heightPx: 660),
        '$kCover?param=1080y660',
      );
      expect(
        neteaseSizedUrl('$kCover?x=1', widthPx: 900, heightPx: 550),
        '$kCover?x=1&param=900y550',
      );
    });

    test('单边有效时补正方形; 两边都无效原样返回', () {
      expect(neteaseSizedUrl(kCover, widthPx: 700), '$kCover?param=700y700');
      expect(neteaseSizedUrl(kCover, heightPx: 700), '$kCover?param=700y700');
      expect(neteaseSizedUrl(kCover), kCover);
      expect(
        neteaseSizedUrl(kCover, widthPx: double.infinity, heightPx: 0),
        kCover,
      );
      expect(neteaseSizedUrl('', widthPx: 100, heightPx: 100), '');
    });
  });

  group('bannerRequestPx: 屏宽 x DPR x 档位, 上限 1080', () {
    Future<({int widthPx, int heightPx})> pxAt(
      WidgetTester tester, {
      required double dpr,
      CoverQuality? quality,
      double logicalWidth = 360,
      double logicalHeight = 220,
    }) async {
      setView(tester, dpr: dpr);
      late ({int widthPx, int heightPx}) px;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) {
              px = bannerRequestPx(
                context,
                logicalWidth: logicalWidth,
                logicalHeight: logicalHeight,
                quality: quality,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return px;
    }

    testWidgets('360dp @3x 超清: 宽 2160 被 clamp 到 1080, 高按比例', (tester) async {
      final px = await pxAt(tester, dpr: 3, quality: CoverQuality.ultra);
      expect(px.widthPx, 1080, reason: '2160 -> 上限 1080');
      expect(px.heightPx, 660, reason: '220/360 比例等比: 1320 x 0.5');
    });

    testWidgets('省流 0.75x / 标准 1x / 超清 2x 都在宽高两个方向生效', (tester) async {
      final saver = await pxAt(tester, dpr: 3, quality: CoverQuality.dataSaver);
      expect(saver.widthPx, 810, reason: '360x3x0.75');
      expect(saver.heightPx, 495, reason: '220x3x0.75');
      final std = await pxAt(tester, dpr: 3, quality: CoverQuality.standard);
      expect(std.widthPx, 1080, reason: '360x3x1.0 = 1080, 恰好不裁');
      expect(std.heightPx, 660);
      final ultra = await pxAt(tester, dpr: 3, quality: CoverQuality.ultra);
      expect(ultra.widthPx, 1080, reason: '2160 被 clamp');
      expect(ultra.heightPx, 660, reason: '等比缩到上限内, 不是方图');
      expect(saver.heightPx < std.heightPx, isTrue);
    });

    testWidgets('逻辑尺寸无效时不抛异常, 返回 0', (tester) async {
      final px = await pxAt(tester, dpr: 2, logicalWidth: double.infinity);
      expect(px.widthPx, 0);
      expect(px.heightPx, 0);
    });
  });

  group('ProfileBannerImage 实际请求的 URL', () {
    testWidgets('360dp @3x 超清: 请求 param=1080y660, 不再是 170y170', (tester) async {
      setView(tester, dpr: 3);
      AppSettings.instance.coverQuality = CoverQuality.ultra;
      await tester.pumpWidget(host(const ProfileBannerImage(url: kCover)));
      final rendered = renderedImage(tester);
      expect(rendered, isNotNull);
      expect(rendered!, contains('param=1080y660'));
      expect(rendered, isNot(contains('170y170')));
      expect(rendered, isNot(contains('param=170')));
    });

    testWidgets('切档位后同一个 banner 立刻改请求尺寸(不重启)', (tester) async {
      setView(tester, dpr: 2);
      AppSettings.instance.coverQuality = CoverQuality.dataSaver;
      await tester.pumpWidget(host(const ProfileBannerImage(url: kCover)));
      expect(renderedImage(tester)!, contains('param=540y330'));

      AppSettings.instance.coverQuality = CoverQuality.standard;
      await tester.pump();
      expect(renderedImage(tester)!, contains('param=720y440'));
    });

    testWidgets('没有 URL: 灰底占位, 不请求图片也不抛异常', (tester) async {
      setView(tester, dpr: 3);
      await tester.pumpWidget(host(const ProfileBannerImage(url: null)));
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(ProfileBannerImage)).height,
        kProfileBannerHeight,
      );
    });

    testWidgets('图片加载失败: 走占位不抛异常', (tester) async {
      setView(tester, dpr: 3);
      await tester.pumpWidget(host(const ProfileBannerImage(url: kCover)));
      final element = tester.element(find.byType(Image).first);
      final image = tester.widget<Image>(find.byType(Image).first);
      // 直接调 errorBuilder, 模拟 CDN 403/空 body
      final built = image.errorBuilder!(element, Exception('boom'), null);
      expect(built, isNotNull);
      expect(tester.takeException(), isNull);
    });
  });

  // 2026-11 用户报: 「我的」页昵称/关注数的横条下面还遮着一条横条, 点漏出来的
  // 部分也进账号管理。根因是身份卡用 Transform.translate 上浮(不改布局占位)后,
  // 又补了一条 12dp 的 surface 色块 ⇒ 卡片底部实际多出 12dp, 且整块都在 InkWell 里。
  group('ProfileBanner 叠层: 底部不得多出可点横条', () {
    testWidgets('身份卡底部 = 卡片底部, 高度 = 图 - 上浮 + 身份卡高', (tester) async {
      setView(tester);
      await tester.pumpWidget(
        host(
          const ProfileBanner(
            title: '小明',
            subtitle: '签名',
            imageUrl: null,
            footer: Text('关注 1 · 粉丝 2'),
          ),
        ),
      );
      final banner = tester.getRect(find.byType(ProfileBanner));
      final identity = tester.getRect(find.byType(ProfileIdentity));

      expect(
        identity.top,
        moreOrLessEquals(
          banner.top + kProfileBannerHeight - kProfileIdentityLift,
          epsilon: 0.5,
        ),
        reason: '身份卡要压在图下沿 12dp 上',
      );
      expect(
        identity.bottom,
        moreOrLessEquals(banner.bottom, epsilon: 0.5),
        reason: '身份卡下方不许再有补色横条',
      );
      expect(
        banner.height,
        moreOrLessEquals(
          kProfileBannerHeight - kProfileIdentityLift + identity.height,
          epsilon: 0.5,
        ),
      );
    });
  });
}
