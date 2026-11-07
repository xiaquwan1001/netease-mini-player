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
  testWidgets('建议面板展示条目并回调', (tester) async {
    rust.SuggestItem? tapped;
    await tester.pumpWidget(host(SuggestionPanel(
      items: [item('song', '晴天'), item('artist', '周杰伦')],
      onSelected: (v) => tapped = v,
    )));
    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('周杰伦'), findsOneWidget);
    expect(find.text('单曲'), findsOneWidget);
    expect(find.text('歌手'), findsOneWidget);
    await tester.tap(find.text('晴天'));
    expect(tapped?.title, '晴天');
  });

  testWidgets('空建议不占位', (tester) async {
    await tester.pumpWidget(host(SuggestionPanel(
      items: const [],
      onSelected: (_) {},
    )));
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('搜索历史 chip 可点击与清空', (tester) async {
    String? chosen;
    var cleared = 0;
    await tester.pumpWidget(host(SearchHistoryBar(
      history: const ['晴天', '七里香'],
      onSelected: (k) => chosen = k,
      onClear: () => cleared++,
    )));
    expect(find.text('搜索历史'), findsOneWidget);
    await tester.tap(find.text('七里香'));
    expect(chosen, '七里香');
    await tester.tap(find.text('清空'));
    expect(cleared, 1);
  });

  testWidgets('无历史时不显示', (tester) async {
    await tester.pumpWidget(host(SearchHistoryBar(
      history: const [],
      onSelected: (_) {},
      onClear: () {},
    )));
    expect(find.text('搜索历史'), findsNothing);
  });
}
