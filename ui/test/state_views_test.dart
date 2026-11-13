import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/state_views.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('LoadingView: 居中 spinner, 可带一行说明', (tester) async {
    await tester.pumpWidget(_host(const LoadingView(message: '正在搜索…')));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('正在搜索…'), findsOneWidget);
  });

  testWidgets('LoadingView: 固定尺寸 + padding 保持列表底部形态', (tester) async {
    await tester.pumpWidget(
      _host(
        const LoadingView(
          size: 22,
          padding: EdgeInsets.symmetric(vertical: 20),
        ),
      ),
    );
    final box = tester.getSize(find.byType(CircularProgressIndicator));
    expect(box.width, 22);
    expect(box.height, 22);
  });

  testWidgets('LoadingView.inline: 不插入居中容器(按钮内可用)', (tester) async {
    await tester.pumpWidget(
      _host(
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              LoadingView.inline(size: 16),
              SizedBox(width: 8),
              Text('发送'),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(CircularProgressIndicator)),
      const Size(16, 16),
    );
    // 行内形态不该再包一层 Center/Column
    final loading = find.byType(LoadingView);
    expect(
      find.descendant(of: loading, matching: find.byType(Center)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('EmptyView: 图标 / 标题 / 提示 / 按钮都渲染', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _host(
        EmptyView(
          icon: Icons.music_note_outlined,
          title: '今天没有推荐歌曲',
          hint: '明天再来看看',
          action: TextButton(
            onPressed: () => tapped = true,
            child: const Text('去登录'),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.music_note_outlined), findsOneWidget);
    expect(find.text('今天没有推荐歌曲'), findsOneWidget);
    expect(find.text('明天再来看看'), findsOneWidget);
    await tester.tap(find.text('去登录'));
    expect(tapped, isTrue);
  });

  testWidgets('EmptyView: 高度被压到 18dp 也不溢出(可滚兜底)', (tester) async {
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            // 模拟 Tab/卡片里的极窄槽位
            const SizedBox(height: 18, child: EmptyView(title: '暂无内容')),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('暂无内容'), findsOneWidget);
  });
}
