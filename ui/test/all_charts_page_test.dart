import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/all_charts_page.dart';
import 'package:minincm/src/cover_art.dart';
import 'package:minincm/src/layout.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

rust.ToplistCatalogItem item(
  int id,
  String name, {
  bool canPlay = true,
  String freq = '每天更新',
}) => rust.ToplistCatalogItem(
  id: BigInt.from(id),
  name: name,
  coverUrl: null,
  updateFrequency: freq,
  targetType: 'PLAYLIST',
  canPlay: canPlay,
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 长标题走跑马灯(无限循环动画)时 pumpAndSettle 永不收敛, 固定推进若干帧
/// 让 FutureBuilder/布局稳定即可(与 queue_sheet_test 同款处理).
Future<void> pumpFrames(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  testWidgets('按分组渲染, 中文小标题, 点可播条目回调歌单', (tester) async {
    rust.Playlist? opened;
    await tester.pumpWidget(
      host(
        AllChartsPage(
          onOpenPlaylist: (p) => opened = p,
          loadCatalog: () async => [
            rust.ToplistCatalogGroup(
              code: 'OFFICIAL',
              items: [
                item(1, '飙升榜'),
                item(2, '新歌榜', freq: '每周五更新'),
              ],
            ),
            rust.ToplistCatalogGroup(code: 'GLOBAL', items: []),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('官方榜'), findsOneWidget); // GLOBAL 组空, 不渲染标题
    expect(find.text('全球榜'), findsNothing);
    expect(find.text('飙升榜'), findsOneWidget);
    expect(find.text('每周五更新'), findsOneWidget);

    await tester.tap(find.text('飙升榜'));
    expect(opened?.id, BigInt.one);
    expect(opened?.name, '飙升榜');
  });

  testWidgets('canPlay=false 灰显不可点', (tester) async {
    rust.Playlist? opened;
    await tester.pumpWidget(
      host(
        AllChartsPage(
          onOpenPlaylist: (p) => opened = p,
          loadCatalog: () async => [
            rust.ToplistCatalogGroup(
              code: 'MORE',
              items: [item(3, '云音乐古典榜', canPlay: false), item(4, 'ACG 榜')],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('更多'), findsOneWidget);
    await tester.tap(find.text('云音乐古典榜'), warnIfMissed: false);
    expect(opened, isNull);
    await tester.tap(find.text('ACG 榜'));
    expect(opened?.id, BigInt.from(4));
  });

  testWidgets('空态', (tester) async {
    await tester.pumpWidget(
      host(AllChartsPage(onOpenPlaylist: (_) {}, loadCatalog: () async => [])),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂时没有榜单'), findsOneWidget);
  });

  testWidgets('错误 + 重试', (tester) async {
    var fail = true;
    await tester.pumpWidget(
      host(
        AllChartsPage(
          onOpenPlaylist: (_) {},
          loadCatalog: () async {
            if (fail) throw Exception('[network] boom');
            return [
              rust.ToplistCatalogGroup(
                code: 'OFFICIAL',
                items: [item(9, '热歌榜')],
              ),
            ];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('网络不稳定'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('热歌榜'), findsOneWidget);
  });

  testWidgets('300dp 宽 + 1.25 缩放不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 800);
    tester.view.devicePixelRatio = 1.25;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      host(
        AllChartsPage(
          onOpenPlaylist: (_) {},
          loadCatalog: () async => [
            rust.ToplistCatalogGroup(
              code: 'LANGUAGE',
              items: [
                item(11, '华语速爆新歌超长榜单名字测试测试', freq: '每天更新'),
                item(12, '欧美热歌榜', canPlay: false),
              ],
            ),
          ],
        ),
      ),
    );
    // 榜单名允许两行(不滚), 但同页可能挂长标题跑马灯 → 固定帧推进.
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
  });

  // 列表行审计 C 级(2026-11-17): 整页铺满列表里, 分组小标题(12)与行首封面必须
  // 共线 —— 修前行用的是 Material 默认 16/16, 小标题 12 ⇒ 同页两条竖线错开 4dp.
  testWidgets('分组小标题与行首封面共线(12)', (tester) async {
    await tester.pumpWidget(
      host(
        AllChartsPage(
          onOpenPlaylist: (_) {},
          loadCatalog: () async => [
            rust.ToplistCatalogGroup(code: 'OFFICIAL', items: [item(1, '飙升榜')]),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final titleLeft = tester.getRect(find.text('官方榜')).left;
    final coverLeft = tester.getRect(find.byType(CoverArt).first).left;
    expect(titleLeft, moreOrLessEquals(kPagePadding, epsilon: 0.5));
    expect(coverLeft, moreOrLessEquals(kPagePadding, epsilon: 0.5));
    expect(
      tester.getRect(find.text('飙升榜')).left,
      greaterThan(coverLeft + 40),
      reason: '标题在 48dp 封面右侧',
    );
  });
}
