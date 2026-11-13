// 详情页曲目行(_SongRow)窄宽回归: 300dp + font_scale 1.25 下,
// 超长曲名 + VIP/付费/无版权徽标不再出现 Flexible(Text) 被压到 0 宽/竖排的问题
// (修复后走共享组件 AdaptiveTextRow: Expanded + 单行, 窄宽整组收起徽标).
//
// 说明: _SongRow 为私有且数据来自 Rust FFI(测试无法注入假 loader),
// 与 narrow_width_audit_test.dart 同口径, 这里按 detail_page.dart 的实际排版结构
// (26 序号 + 10 间距 + Expanded 列 AdaptiveTextRow + 副标题 + 时长 + 红心)镜像验证.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/adaptive_text_row.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/song_tile.dart';

const _longName = '魔法未来2019主题歌Magia[Quartet]Live.Ver超长歌名继续加长再加长一点直到溢出为止啊';
const _longSub = '一条超级超级长的艺人名组合名称 · 一张同样很长的专辑名称Magia Album Deluxe Edition 豪华版';

rust.SongDto song({
  required bool vip,
  required bool paid,
  required bool playable,
}) => rust.SongDto(
  id: BigInt.one,
  name: _longName,
  artist: '某艺人',
  artistId: BigInt.from(9),
  album: '某专辑',
  albumId: BigInt.from(8),
  coverUrl: null,
  durationMs: BigInt.from(269000),
  fee: vip ? 1 : 0,
  vip: vip,
  paid: paid,
  playable: playable,
);

/// 与 detail_page.dart _SongRow 同构的行(修复后: 行尾整组封顶 + 紧凑图标按钮).
Widget rowOf(rust.SongDto song) {
  // 与 detail_page.dart 同构: LayoutBuilder 取可用宽, 行尾最多吃 45%
  return LayoutBuilder(
    builder: (context, constraints) {
      final maxTrailingWidth = constraints.maxWidth.isFinite
          ? constraints.maxWidth * 0.45
          : double.infinity;
      return Row(
        children: [
          const SizedBox(
            width: 26,
            child: Text('01', textAlign: TextAlign.right),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AdaptiveTextRow(title: song.name, marquee: false),
                const SizedBox(height: 2),
                // 徽标在副标题行(与 detail_page.dart _SongRow 同构): 300dp 下也可见
                Row(
                  children: [
                    if (song.playable && song.vip) const VipBadge(small: true),
                    if (song.playable && !song.vip && song.paid)
                      const PaidBadge(),
                    if (!song.playable) const UnplayableBadge(),
                    const Expanded(
                      child: Text(
                        _longSub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxTrailingWidth),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 时长是弹性项: 行尾触到上限时先截断它
                const Flexible(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '4:29',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                // 红心: 40dp 紧凑命中区(高仍 48)
                IconButton(
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  style: const ButtonStyle(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 48,
                  ),
                  onPressed: null,
                  icon: const Icon(Icons.favorite_border),
                ),
                // SongOverflowButton 无 host 时是 SizedBox.shrink; 这里按最坏情况
                // 换成默认 48dp IconButton(真实 SongOverflowButton 的默认尺寸)
                const IconButton(onPressed: null, icon: Icon(Icons.more_vert)),
              ],
            ),
          ),
        ],
      );
    },
  );
}

Future<void> pumpCase(
  WidgetTester tester, {
  required double width,
  required double scale,
  required rust.SongDto song,
}) async {
  tester.view.physicalSize = Size(width, 700);
  tester.view.devicePixelRatio = 1;
  tester.view.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 700),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(
          body: Padding(
            // 与 detail_page 的 Container(fromLTRB(12, 0, 4, 0)) 同留白
            padding: const EdgeInsets.only(left: 12, right: 4),
            // 不写死行高: 这里只验证**横向**排版(A6), 竖向高度由
            // detail_page 的 itemExtent(SliverFixedExtentList)决定
            child: rowOf(song),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
}

void main() {
  final cases = <(String, rust.SongDto)>[
    ('VIP', song(vip: true, paid: false, playable: true)),
    ('付费', song(vip: false, paid: true, playable: true)),
    ('无版权', song(vip: false, paid: false, playable: false)),
  ];

  // A6 回归: 300dp 下的两档字号(1.25 与 1.625)都跑, 后者是审计里未覆盖的一档
  for (final scale in const [1.25, 1.625]) {
    for (final (label, s) in cases) {
      testWidgets('300dp×$scale $label 超长曲名: 无 overflow、单行、行尾封顶', (
        tester,
      ) async {
        await pumpCase(tester, width: 300, scale: scale, song: s);
        expect(tester.takeException(), isNull, reason: '不允许 overflow/布局异常');
        final title = find.text(_longName).first;
        expect(title, findsOneWidget);
        final box = tester.renderObject<RenderBox>(title);
        expect(box.size.width, greaterThan(0), reason: '曲名被徽标压到 0 宽(竖排根因)');
        // 单行阈随字号放大(1.25 档为 30dp, 与修复前的断言同值):
        // 竖排(每字一行)会远超这个高度
        expect(
          box.size.height,
          lessThan(24 * scale),
          reason: '曲名必须单行(竖排会远高于行高)',
        );
        // 行尾整组(时长 + 红心 + 更多)必须封顶在可用宽的 45%: 不封顶时
        // 标题区在 300dp 下只剩 ~117dp, 大字号下更少
        // 行宽 = 300 - 左 12 - 右 4
        const rowWidth = 300.0 - 12 - 4;
        final duration = tester.getRect(find.text('4:29'));
        const durationPad = 4.0;
        expect(
          duration.left - durationPad,
          greaterThanOrEqualTo(rowWidth * 0.55 - 0.5),
          reason: '行尾整组超出版面 45% 上限, 标题区被吃窄',
        );
        expect(duration.width, greaterThan(0), reason: '时长被压到 0 宽');
        // 徽标在副标题行: 300dp 窄屏也必须看得见(用户反馈"歌曲没有 VIP 标记")
        expect(
          find.byType(VipBadge),
          label == 'VIP' ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(PaidBadge),
          label == '付费' ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(UnplayableBadge),
          label == '无版权' ? findsOneWidget : findsNothing,
        );
      });
    }
  }

  testWidgets('400dp 宽屏 VIP 曲目: 徽标照常显示(未被误隐藏)', (tester) async {
    await pumpCase(
      tester,
      width: 400,
      scale: 1.25,
      song: song(vip: true, paid: false, playable: true),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(VipBadge), findsOneWidget);
    final box = tester.renderObject<RenderBox>(find.text(_longName).first);
    expect(box.size.width, greaterThan(0));
  });

  testWidgets('400dp 宽屏无版权曲目: 无版权徽标照常显示', (tester) async {
    await pumpCase(
      tester,
      width: 400,
      scale: 1.25,
      song: song(vip: false, paid: false, playable: false),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(UnplayableBadge), findsOneWidget);
  });

  testWidgets('300dp×1.25 无徽标曲目: 曲名单行正常', (tester) async {
    await pumpCase(
      tester,
      width: 300,
      scale: 1.25,
      song: song(vip: false, paid: false, playable: true),
    );
    expect(tester.takeException(), isNull);
    final box = tester.renderObject<RenderBox>(find.text(_longName).first);
    expect(box.size.width, greaterThan(0));
    expect(box.size.height, lessThan(30));
  });
}
