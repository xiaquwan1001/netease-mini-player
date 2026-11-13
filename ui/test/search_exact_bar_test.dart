import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/search_exact_bar.dart';

// 全部用 avatarUrl/coverUrl: null, 不触发任何网络请求.

SearchExactView view({
  List<String> orders = const <String>[],
  List<SearchExactArtist> artists = const <SearchExactArtist>[],
  List<SearchExactPlaylist> playlists = const <SearchExactPlaylist>[],
  List<SearchExactRadio> podcasts = const <SearchExactRadio>[],
}) => SearchExactView(
  orders: orders,
  artists: artists,
  playlists: playlists,
  podcasts: podcasts,
);

Widget host(Widget child, {double width = 400, double scale = 1.0}) =>
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

/// 同一父级下按视觉顺序(先 top 再 left)取 Text 的内容.
List<String> visibleTexts(WidgetTester tester) {
  final entries = <(double, double, String)>[];
  for (final e in find.byType(Text).evaluate()) {
    final w = e.widget as Text;
    final content = w.data ?? w.textSpan?.toPlainText() ?? '';
    if (content.isEmpty) continue;
    final box = e.renderObject as RenderBox?;
    final pos = box == null ? Offset.zero : box.localToGlobal(Offset.zero);
    entries.add((pos.dy, pos.dx, content));
  }
  entries.sort((a, b) {
    final dy = a.$1.compareTo(b.$1);
    if (dy != 0) return dy;
    return a.$2.compareTo(b.$2);
  });
  return [for (final e in entries) e.$3];
}

void main() {
  testWidgets('空命中不占位, 不渲染任何内容', (tester) async {
    await tester.pumpWidget(host(SearchExactBar(view: view())));

    expect(find.byType(SearchExactBar), findsOneWidget);
    expect(find.byType(Text), findsNothing);
    expect(find.byType(ListView), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    // 顶层就是 SizedBox.shrink(): 高度 0, 不占纵向空间
    expect(tester.getSize(find.byType(SearchExactBar)).height, 0);
  });

  testWidgets('artist 命中: 显示名字 + 点击回传 id', (tester) async {
    int? picked;
    await tester.pumpWidget(
      host(
        SearchExactBar(
          view: view(
            orders: const ['artist'],
            artists: const [
              SearchExactArtist(id: 6452, name: '周杰伦', subtitle: '华语男艺人'),
              SearchExactArtist(id: 9621, name: '许嵩'),
            ],
          ),
          onPickArtist: (id) => picked = id,
        ),
      ),
    );

    expect(find.text(kSearchExactTitle), findsOneWidget);
    expect(find.text('周杰伦'), findsOneWidget);
    expect(find.text('艺人'), findsOneWidget); // 分区标题
    expect(find.text('华语男艺人'), findsOneWidget); // 卡片副标题
    expect(find.text('许嵩'), findsOneWidget);

    await tester.tap(find.text('周杰伦'));
    expect(picked, 6452);

    await tester.tap(find.text('许嵩'));
    expect(picked, 9621);
  });

  testWidgets('orders 顺序生效: playlist 在前则歌单分区在前', (tester) async {
    await tester.pumpWidget(
      host(
        SearchExactBar(
          view: view(
            orders: const ['playlist', 'artist'],
            artists: const [SearchExactArtist(id: 1, name: '周杰伦')],
            playlists: const [SearchExactPlaylist(id: 2, name: '周杰伦歌单')],
          ),
        ),
      ),
    );

    final texts = visibleTexts(tester);
    expect(texts, contains('歌单'));
    expect(texts, contains('艺人'));
    expect(texts.indexOf(kSearchExactTitle), 0);
    expect(texts.indexOf('歌单'), lessThan(texts.indexOf('艺人')));
    // 分区内的内容也按顺序排在更下面
    expect(texts.indexOf('周杰伦歌单'), lessThan(texts.indexOf('周杰伦')));

    // 反向 orders 时顺序颠倒
    await tester.pumpWidget(
      host(
        SearchExactBar(
          view: view(
            orders: const ['artist', 'playlist'],
            artists: const [SearchExactArtist(id: 1, name: '周杰伦')],
            playlists: const [SearchExactPlaylist(id: 2, name: '周杰伦歌单')],
          ),
        ),
      ),
    );
    final texts2 = visibleTexts(tester);
    expect(texts2.indexOf('艺人'), lessThan(texts2.indexOf('歌单')));
  });

  testWidgets('orders 里的未知类型被忽略', (tester) async {
    await tester.pumpWidget(
      host(
        SearchExactBar(
          view: view(
            orders: const ['song', 'zzz', 'artist'],
            artists: const [SearchExactArtist(id: 7, name: '陈奕迅')],
          ),
        ),
      ),
    );

    expect(find.text('陈奕迅'), findsOneWidget);
    expect(find.text('song'), findsNothing);
    expect(find.text('zzz'), findsNothing);
    expect(find.byType(ListView), findsOneWidget);
  });

  testWidgets('voice 命中渲染 + 回调', (tester) async {
    int? picked;
    await tester.pumpWidget(
      host(
        SearchExactBar(
          view: view(
            orders: const ['voice'],
            podcasts: const [
              SearchExactRadio(
                id: 3321,
                name: 'Taylor Swift 电台',
                djName: '小宇宙',
                programCount: 24,
              ),
            ],
          ),
          onPickRadio: (id) => picked = id,
        ),
      ),
    );

    expect(find.text('电台'), findsOneWidget);
    expect(find.text('Taylor Swift 电台'), findsOneWidget);
    expect(find.text('小宇宙 · 24期'), findsOneWidget);

    await tester.tap(find.text('Taylor Swift 电台'));
    expect(picked, 3321);
  });

  testWidgets('orders 为空但列表非空时走兜底顺序 artist/playlist/voice', (tester) async {
    await tester.pumpWidget(
      host(
        SearchExactBar(
          view: view(
            artists: const [SearchExactArtist(id: 1, name: '薛之谦')],
            playlists: const [SearchExactPlaylist(id: 2, name: '薛之谦精选')],
            podcasts: const [SearchExactRadio(id: 3, name: '薛之谦电台')],
          ),
        ),
      ),
    );

    final texts = visibleTexts(tester);
    expect(texts.indexOf(kSearchExactTitle), 0);
    expect(texts.indexOf('艺人'), lessThan(texts.indexOf('歌单')));
    expect(texts.indexOf('歌单'), lessThan(texts.indexOf('电台')));
    expect(texts.indexOf('薛之谦'), lessThan(texts.indexOf('薛之谦精选')));
    expect(texts.indexOf('薛之谦精选'), lessThan(texts.indexOf('薛之谦电台')));
  });

  testWidgets('300dp 宽 + 1.25 字号不溢出', (tester) async {
    await tester.pumpWidget(
      host(
        SearchExactBar(
          view: view(
            orders: const ['artist', 'playlist', 'voice'],
            artists: const [
              SearchExactArtist(
                id: 1,
                name: '一个特别特别长的艺人名字用来测试省略号',
                subtitle: '艺人 / 音乐人 / 制作人',
              ),
            ],
            playlists: const [
              SearchExactPlaylist(
                id: 2,
                name: '超长歌单标题也不能把 300dp 的窄屏撑爆',
                creatorName: '某位创作者名字也很长',
                trackCount: 999,
                playCount: 123456789,
              ),
            ],
            podcasts: const [
              SearchExactRadio(
                id: 3,
                name: '超长电台名字超长电台名字超长电台名字',
                djName: '主播名字同样超长',
                programCount: 1024,
              ),
            ],
          ),
        ),
        width: 300,
        scale: 1.25,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final bar = tester.getSize(find.byType(SearchExactBar));
    expect(bar.width, lessThanOrEqualTo(300));
    // 卡片宽度固定 96, 文案单行省略
    for (final e in find.byType(Text).evaluate()) {
      final w = e.widget as Text;
      expect(w.maxLines, 1, reason: '文本 ${w.data} 必须单行');
      expect(w.overflow, TextOverflow.ellipsis);
    }
  });

  testWidgets('关键词兜底条: 空列表不渲染, 点击回传关键词', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: KeywordSuggestBar(keywords: [])),
      ),
    );
    expect(find.text('猜你想搜'), findsNothing);

    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KeywordSuggestBar(
            keywords: const ['晴天周杰伦', '晴天娃娃'],
            onSelected: (k) => picked = k,
          ),
        ),
      ),
    );
    expect(find.text('猜你想搜'), findsOneWidget);
    await tester.tap(find.text('晴天娃娃'));
    expect(picked, '晴天娃娃');
  });
}
