import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment_stats_bar.dart';

CommentStatsView view({
  int commentCount = 0,
  int shareCount = 0,
  int likedCount = 0,
  int hotCount = 0,
}) => CommentStatsView(
  commentCount: commentCount,
  shareCount: shareCount,
  likedCount: likedCount,
  hotCount: hotCount,
);

Widget host(Widget child, {double width = 300, double scale = 1.0}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

void main() {
  test('数字格式 0 / 999 / 1000 / 1234 / 10000 / 12345', () {
    expect(formatCompactCount(0), '0');
    expect(formatCompactCount(999), '999');
    expect(formatCompactCount(1000), '1千');
    expect(formatCompactCount(1234), '1.2千');
    expect(formatCompactCount(10000), '1万');
    expect(formatCompactCount(12345), '1.2万');
    expect(formatCompactCount(-5), '0');
  });

  testWidgets('三个回调各自计数', (tester) async {
    var comments = 0;
    var share = 0;
    var likes = 0;
    await tester.pumpWidget(
      host(
        CommentStatsBar(
          view: view(commentCount: 3, shareCount: 4, likedCount: 5),
          onComments: () => comments = comments + 1,
          onShare: () => share = share + 1,
          onLikes: () => likes = likes + 1,
        ),
      ),
    );

    expect(find.byType(InkWell), findsNWidgets(3));

    await tester.tap(find.text('评论 3'));
    await tester.pump();
    expect(comments, 1);
    expect(share, 0);
    expect(likes, 0);

    await tester.tap(find.text('分享 4'));
    await tester.pump();
    expect(share, 1);

    await tester.tap(find.text('点赞 5'));
    await tester.pump();
    expect(likes, 1);
  });

  testWidgets('三项文案都渲染出来', (tester) async {
    await tester.pumpWidget(
      host(
        CommentStatsBar(
          view: view(commentCount: 12345, shareCount: 342, likedCount: 87),
        ),
      ),
    );
    expect(find.text('评论 1.2万'), findsOneWidget);
    expect(find.text('分享 342'), findsOneWidget);
    expect(find.text('点赞 87'), findsOneWidget);
    expect(find.byIcon(Icons.comment_outlined), findsOneWidget);
    expect(find.byIcon(Icons.share_outlined), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
  });

  testWidgets('hotCount > 0 显示热评角标', (tester) async {
    await tester.pumpWidget(
      host(CommentStatsBar(view: view(commentCount: 100, hotCount: 7))),
    );
    expect(find.text('评论 100'), findsOneWidget);
    expect(find.text('(热评 7)'), findsOneWidget);
  });

  testWidgets('hotCount == 0 不显示热评角标', (tester) async {
    await tester.pumpWidget(
      host(CommentStatsBar(view: view(commentCount: 100, hotCount: 0))),
    );
    expect(find.text('评论 100'), findsOneWidget);
    expect(find.textContaining('热评'), findsNothing);
  });

  testWidgets('回调为 null 时不崩且没有 InkWell', (tester) async {
    await tester.pumpWidget(host(CommentStatsBar(view: view(commentCount: 9))));
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(InkResponse), findsNothing);
    expect(find.text('评论 9'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('300dp + 1.25 字号不溢出', (tester) async {
    await tester.pumpWidget(
      host(
        CommentStatsBar(view: view(commentCount: 123456, shareCount: 9876)),
        width: 300,
        scale: 1.25,
      ),
    );
    expect(tester.takeException(), isNull);
    final bar = tester.getSize(find.byType(CommentStatsBar));
    expect(bar.width, lessThanOrEqualTo(300));
    expect(bar.height, lessThanOrEqualTo(CommentStatsBar.maxHeight));
  });
}
