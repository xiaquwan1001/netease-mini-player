import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/all_charts_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

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
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
