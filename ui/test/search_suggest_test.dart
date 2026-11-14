import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/search_suggest.dart';

rust.SuggestItem item(String kind, String title) => rust.SuggestItem(
  kind: kind,
  id: BigInt.one,
  title: title,
  subtitle: 'sub',
  coverUrl: null,
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('联想按分类 tab 展示, 一次只渲染一个分类', (tester) async {
    rust.SuggestItem? tapped;
    await tester.pumpWidget(
      host(
        SuggestionPanel(
          items: [item('song', '晴天'), item('artist', '周杰伦')],
          onSelected: (v) => tapped = v,
        ),
      ),
    );
    // 需求 3: 分类改成和搜索结果一样的 tab, 默认打开第一条所在分类(单曲)
    expect(find.text('单曲 1'), findsOneWidget);
    expect(find.text('艺人 1'), findsOneWidget);
    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('周杰伦'), findsNothing);

    await tester.tap(find.text('艺人 1'));
    await tester.pumpAndSettle();
    expect(find.text('晴天'), findsNothing);
    expect(find.text('周杰伦'), findsOneWidget);

    await tester.tap(find.text('周杰伦'));
    expect(tapped?.title, '周杰伦');
  });

  testWidgets('联想分类顺序 = 日用频率(歌曲/艺人/专辑/MV/歌单), 单横排横滑', (tester) async {
    await tester.pumpWidget(
      host(
        SuggestionPanel(
          items: [
            item('song', '晴天'),
            item('artist', '周杰伦'),
            item('album', '叶惠美'),
            item('mv', '晴天 MV'),
            item('playlist', '我的歌单'),
          ],
          onSelected: (_) {},
        ),
      ),
    );
    final rects = {
      for (final kind in ['单曲', '艺人', '专辑', 'MV', '歌单'])
        kind: tester.getRect(find.widgetWithText(ChoiceChip, '$kind 1')),
    };
    // 同一横排(单排不换行)
    final tops = rects.values.map((r) => r.top).toSet();
    expect(tops.length, 1, reason: '联想分类必须排在一横排');
    // 顺序: 歌曲 → 艺人 → 专辑 → MV → 歌单
    expect(rects['单曲']!.left, lessThan(rects['艺人']!.left));
    expect(rects['艺人']!.left, lessThan(rects['专辑']!.left));
    expect(rects['专辑']!.left, lessThan(rects['MV']!.left));
    expect(rects['MV']!.left, lessThan(rects['歌单']!.left));
  });

  testWidgets('底部「看全部结果」回调', (tester) async {
    var all = 0;
    await tester.pumpWidget(
      host(
        SuggestionPanel(
          items: [item('song', '晴天')],
          onSelected: (_) {},
          keyword: '晴天',
          onSearchAll: () => all++,
        ),
      ),
    );
    expect(find.textContaining('看全部'), findsOneWidget);
    await tester.tap(find.textContaining('看全部'));
    expect(all, 1);
  });

  testWidgets('空建议不占位', (tester) async {
    await tester.pumpWidget(
      host(SuggestionPanel(items: const [], onSelected: (_) {})),
    );
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('搜索历史 chip 可点击与清空', (tester) async {
    String? chosen;
    var cleared = 0;
    await tester.pumpWidget(
      host(
        SearchHistoryBar(
          history: const ['晴天', '七里香'],
          onSelected: (k) => chosen = k,
          onClear: () => cleared++,
        ),
      ),
    );
    expect(find.text('搜索历史'), findsOneWidget);
    await tester.tap(find.text('七里香'));
    expect(chosen, '七里香');
    await tester.tap(find.text('清空'));
    expect(cleared, 1);
  });

  testWidgets('300dp + 1.25 字号不溢出(建议面板 + 历史 chips)', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final scaled = const MediaQueryData(textScaler: TextScaler.linear(1.25));

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: scaled,
          child: Scaffold(
            body: SuggestionPanel(
              items: [
                item('song', '一首名字特别特别长的歌曲用于小屏回归测试'),
                item('artist', '一个名字特别特别长的艺人用于小屏回归测试'),
              ],
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: scaled,
          child: Scaffold(
            body: SearchHistoryBar(
              history: const ['七里香', '一条很长很长的搜索历史关键词用于小屏回归测试'],
              onSelected: (_) {},
              onClear: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('无历史时不显示', (tester) async {
    await tester.pumpWidget(
      host(
        SearchHistoryBar(history: const [], onSelected: (_) {}, onClear: () {}),
      ),
    );
    expect(find.text('搜索历史'), findsNothing);
  });
}
