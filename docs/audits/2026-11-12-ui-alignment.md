# UI 对齐审计（2026-11-12）

> 范围: ui/lib/src。目的: 用户反馈「很多文字左右没对齐」, 归因 leading 图标槽宽/多层缩进。
> 已落地: 动态正文与用户名同列(50dp); 楼层面板 ListTile 收窄 contentPadding+32 槽; 我的页歌曲行与图标行同一栅格(12); 歌单内搜索点歌行为可在设置里切换。


范围: ui/lib/src 主要页面, 只读审计, 未改任何源码。
标注: [必须修] = 同一列表/同页肉眼可见错位; [可接受] = 封面/头像/名次占位属设计意图。
数值推算基础: ListTile M3 默认 contentPadding 16/侧; 默认 leading 槽宽 ~40(24px 图标); kSongRowPadding = (8,0,4,0)。

---

## 1. comment_thread.dart

### C1 [必须修] 主楼评论与"回复"弹层文字左边界差 ~14dp
- 文件: comment_thread.dart:734(:924) vs comment_thread.dart:1293-1320
- 现象: 主楼 _CommentTile 是手写 Row: 外层 Padding(12,16,12,8) + 卡内 padding left:2 + CircleCover(size:32) + SizedBox(8) → 用户名/正文起点 ≈ 12+2+32+8 = **54dp**。楼层面板用 ListTile: 外层 horizontal:12 + ListTile 默认 contentPadding 16 + leading 槽 40 → 文字起点 ≈ 12+16+40 = **68dp**。
- 建议: 楼层面板 ListTile 加 contentPadding: EdgeInsets.symmetric(horizontal: 4), leading 用 SizedBox(width:32, child: CircleCover(size:28)) 对齐 32+8 结构; 或给 _CommentTile 统一提一个 kCommentIndent 常量两处共用。

### C2 [可接受但建议] 行内回复预览再缩进 12dp(4 margin + 8 padding), 三层叠加
- 文件: comment_thread.dart:1010-1011
- 现象: 预览回复文字起点 54+12 = 66dp, 与楼层面板 68dp 接近但属巧合; 缩进语义正确(对话感), 保留。
- 建议: 保留; 若追求严格, margin left 4 改 6, 对齐 68。

### C3 [必须修] 楼层内"展开全部 N 条回复"按钮与回复内容不同缩进
- 文件: comment_thread.dart:1067-1150(区域)
- 现象: 预览回复行有头像(18)+6 起步, 文字在 54+12+18+6=90; 展开按钮/时间行无头像, 起点不同属正常层级; 但 1099/1111/1141 处 SizedBox(width:10) 与预览区的 width 6/18+6 并存, 点赞/时间小行与回复块左对齐不一致(差 ~10dp)。
- 建议: 展开按钮与时间行统一加与预览块相同的 left:12 缩进。

---

## 2. feed_view.dart

### F1 [必须修] 卡片头(头像后文字)与正文/mini 歌卡左边界不一致
- 文件: feed_view.dart:666-713
- 现象: 卡片 padding (8,12,8,12): 用户名起点 = 8+40(头像)+10 = **58**; 正文 Text 直接在卡片 padding 内, 起点 **8**; _MiniSongCard 歌名 = 8+8(卡内 padding)+40(封面)+10 = **66**。三档 8/58/66, 动态正文顶格与头部缩进差 50dp, 视觉上正文"更靠左"很显眼。
- 建议: 正文文字加 EdgeInsets.only(left: 50)(即与头像后文字对齐)或统一给正文块 padding: EdgeInsets.symmetric(horizontal: 8) 再对齐; mini 歌卡歌名起点由卡片结构决定, 可接受其独立缩进(子卡片语义)。

### F2 [可接受] 配图行/操作行顶格(8), 与头部(58)不同
- 文件: feed_view.dart:730-860
- 现象: 图片与点赞/评论行都顶卡片 padding 8, 属社交 feed 常规(图片全宽), 可接受。
- 建议: 不改; 若要对齐头部也可整体 left:8→统一。

### F3 [必须修] 艺人筛选弹层: 分组标题缩进(16)与 ListTile 文字(12+16+40=68) 无对齐关系
- 文件: feed_view.dart:1126,1162 vs 1113/1136/1172
- 现象: 组标题 Padding left 16, 列表行文字起点 16+40 = 56(弹层无外层 12); 标题与其行首头像左对齐而非与文字对齐, 视觉可接受但若想"标题与行文字同列"应把标题 left 改 56。
- 建议: 低优先级, 视设计意图, 可保留。

---

## 3. mine_view.dart

### M1 [必须修] 顶部分类行(纯图标)与歌曲行(封面)文字左边界不一致
- 文件: mine_view.dart:156(LISTTILETHEME horizontal 12) vs 513/800(kSongRowPadding 8)
- 现象: 消息中心/黑胶/数字专辑/勋章/签到行: 12(页)+12+40(图标槽) → 文字 ≈ **64**; 我喜欢/最近听过行: 12(页)+8(kSongRowPadding)+40(封面)+16(ListTile leading-title 默认 gap) → 文字 ≈ **76**。同一页两个 Card 内文字差 12dp, 肉眼可见。
- 建议: kSongRowPadding 左侧 8→(12-? ) 不动 kSongRowPadding(全局共用), 改在 mine_view 两处歌曲 ListTile 用 SizedBox(width:40) leading 且 contentPadding 同 12, 并把 leading-title gap 用 titlePadding 收齐: titlePadding: EdgeInsets.only(left: 12) 使两种行 title 起点一致(12+12+40+12=76, 再把图标行 titlePadding left 改 24→76)。统一目标 76。

### M2 [可接受] Badge 包裹的消息中心图标视觉宽于普通图标
- 文件: mine_view.dart:887
- 现象: Badge 有未读角标时图标整体仍受 40 槽约束, 文字基线不变。可接受。

---

## 4. settings_view.dart / settings_audio_page.dart / settings_account_page.dart

### S1 [可接受/已对齐] ListTileTheme(horizontal:12) 已统一各 Card 行; 纯图标行(默认槽 40)与"关于"区行一致
- 文件: settings_view.dart:41-48, 129/213/222/234/246/354
- 现象: 图标行文字 = 12+12+40 = 64, 各图标行互相一致, 无问题。

### S2 [必须修] 自定义块(_AccentSettingTile / _SegmentedSettingTile)文字 12+12=24, 与 ListTile 行的 64 差 40dp
- 文件: settings_view.dart:460(主题色 Padding 12) 与 58-108(分段行内部 Padding 同 12) vs 有 leading 的行(播放与音质, :129)
- 现象: "主题色"标题起点 24; 上一行"播放与音质"(leading Icon)标题起点 64。无 leading 的行本来就该顶格, 语义可接受; 但**同一张卡内**若无图标行与有图标行混排(关于卡全是图标行, 界面卡混排 _SegmentedSettingTile(无 leading, 文字 24) 与 OLED 开关(无 leading, 24) —— 界面卡内部一致)。
- 结论: 界面卡内部一致(全无 leading, 24); 关于卡内部一致(全有 leading, 64)。**跨卡 24 vs 64 属设计差异, 可接受**; 唯 [必须修] 点: 主题色块的 Wrap 色点(36px)与 SwitchListTile 的视觉重量不齐, 建议色点行整体加 left:12(=36) 让"内容列"与文字列 24 对齐——已经是 24, 保持。
- 建议: 无需改代码, 记录为可接受; 若用户仍报错位, 统一给全部 Card 行 titlePadding: EdgeInsets.zero + 显式 leading 槽。

### S3 [必须修] settings_audio_page: 无 leading 行(24)与 leading Icon 行(64)同卡混排
- 文件: settings_audio_page.dart:254(info_outline 行) vs 55-145 各 _volumeCard/_loudnessCard 自定义块(内部 padding 12 → 文字 12+12=24)
- 现象: EQ 行(293, leading graphic_eq)文字 64, 同页其它卡文字 24, 跨卡差 40dp, 用户滚动时标题列跳变。
- 建议: _eqCard 的 ListTile 去掉 leading(与其它块一致, 都是标题+控件自绘), 或其它块标题统一加 left:40。推荐前者: settings_audio_page.dart:293 删 leading, 标题并入块标题行。

### S4 [可接受] settings_account_page: CircleAvatar(215) 与 Icon 行(255/266/336...)同列
- 文件: settings_account_page.dart:215 vs 255-359
- 现象: 头像行 leading 是 CircleAvatar(默认 radius→约 40 槽内), 图标行槽 40, 文字起点同为 12+12+40=64, 一致。可接受。

---

## 5. detail_page.dart

### D1 [必须修] 区块标题/正文左右留白 12 与 16 混用
- 文件: detail_page.dart:565/618-620/712/1035(padding 12) vs 751/1309(padding 16)
- 现象: 同一详情页内部分块(评论/相关推荐头)外层 12, 另一些块(歌词区 :751, :1309 "padding only left:16") 16, 相邻区块文字差 4dp, 轻微但可感知。
- 建议: 统一 horizontal 12(与 majority 一致), :751 与 :1309 的 16 改 12。

### D2 [可接受] 封面信息卡(padding.all(12))内文字比区外文字缩进多 12
- 文件: detail_page.dart:618-620, 980-982
- 现象: 卡片语义, 可接受。

---

## 6. recommend_view.dart

### R1 [可接受/已修] 页面 padding 已改 0, 歌曲卡铺满; 歌曲行内 kSongRowPadding(8) → 文字 ≈ 8+40+16 = 64, 与其它区块 _hPad(12) 标题 12 对齐逻辑独立
- 文件: recommend_view.dart:100-108, 434-441
- 现象: 区块标题 12, 卡内行文字 64 —— 卡片语义, 可接受。
- 但注意 mine/ranking 同用 kSongRowPadding 时外层还有 12, 文字起点不同页不同页(见 M1)。

### R2 [必须修] 两个使用 CoverArt(40) 的 ListTile 区块 contentPadding 一致(kSongRowPadding), 无内部问题; 跨页与 mine 不一致(同 M1 建议统一 titlePadding)
- 文件: recommend_view.dart:434/747
- 建议: 与 M1 一并处理。

---

## 7. search_results.dart

### SR1 [可接受] 单曲区 padding 已置 0, 行内 SongTile(kSongRowPadding) → 文字 ≈ 64; 区块标题/横滑卡片各自补 12
- 文件: search_results.dart:69/98/184-235
- 现象: 设计上"行铺满、标题缩 12"是明确注释过的意图, 一致性好。可接受。

---

## 8. discover.dart

### DISC1 [必须修] 日推 tab: IconButton leading 行与 CoverArt(48) 行 / Icon(history) 行文字起点三级跳
- 文件: discover.dart:307(IconButton→槽 48) vs 431/545/568/589(CoverArt 48→文字 = 默认 16+48+16 = 80, 本 tab 无页面 padding) vs 364(Icon 默认槽 40 → 56)
- 现象: 同一页三个列表文字左边界分别 ≈ 64(IconButton 行, 返回后) / 80(歌单行) / 56(历史日期行)。IconButton 槽宽 48 与 CoverArt 48 碰巧同级但 IconButton 有 8 视觉边; Icon 行差 24dp 最明显。
- 建议: 日期列表行 leading 改 SizedBox(width:48, child: Icon(Icons.history))(统一 80); IconButton 行包 SizedBox(width:48, child: IconButton(...)) 消除视觉差。

### DISC2 [必须修] _SongRow leading 是 Row(22 名次 + CoverArt 40) 直接塞 leading, 无 gap
- 文件: discover.dart:708-716
- 现象: leading Row 宽 62, ListTile 在 62 与 title 间用默认 16 gap → 文字 78; 而歌单行(CoverArt 48)文字 80, 差 2dp; 名次行 ranking_view 是 68 槽+gap(见 RK1), 两处"名次+封面"结构不同(22 vs 22+4)。
- 建议: _SongRow 名次后加 SizedBox(width:4) 且 leading 包 SizedBox(width:68), 与 ranking_view 统一。

---

## 9. messages_page.dart

### MSG1 [可接受] 会话/@我/转发 tab: leading CircleCover(44), Divider indent 68 —— 头像 44 但 indent 68 是 ListTile 默认(contentPadding 16 + leading 40?)推算文字 60, indent 68 与文字不完全对齐, 差 8dp, 轻微。
- 文件: messages_page.dart:556/635(分隔线 indent:68) 与 ListTile 默认
- 现象: 分隔线比文字起点偏右 ~8dp, 肉眼弱可见。
- 建议: indent 改 60(16+44) 或给 ListTile 显式 contentPadding 12 + leading SizedBox(width:48), indent 同步 72。

### MSG2 [可接受] 联系人横滑(44 头像, 68 槽)为独立布局, 不参与对齐。

---

## 10. ranking_view.dart

### RK1 [必须修] _RankRow leading 槽 68(名次 22+4+封面 40), contentPadding kSongRowPadding(8) → 文字 = 页 12+8+68+16 = **104**; 而 mine_view 同款歌曲行(无名次)文字 ≈ **76**。跨页同结构行文字边界差 28dp 属"名次列"设计, 可接受; 但**榜内**: 无问题。
- 文件: ranking_view.dart:304-306
- 结论: [可接受] 名次列本应占位。建议: 无需改。

---

## 汇总(按影响面排序, ≤15 条)

| # | 级别 | 位置 | 一句话 |
|---|---|---|---|
| 1 | 必须修 | feed_view.dart:713 | 动态正文顶格 8 vs 头部文字 58, 差 50dp, 首页最显眼 |
| 2 | 必须修 | mine_view.dart:513/800 vs 180-213 | 歌曲行文字 76 vs 入口行 64, 同页差 12dp |
| 3 | 必须修 | discover.dart:364 vs 431 vs 708 | 日推页三档文字边界 56/78/80 |
| 4 | 必须修 | comment_thread.dart:924 vs 1293 | 主楼文字 54 vs 楼层面板 68, 差 14dp |
| 5 | 必须修 | settings_audio_page.dart:293 vs 55-145 | EQ 行 64 vs 其它卡 24, 滚动标题列跳变 |
| 6 | 必须修 | detail_page.dart:751/1309 vs 565/712 | 区块缩进 16 vs 12 混用, 差 4dp |
| 7 | 必须修 | comment_thread.dart:1099-1150 | 展开按钮与预览回复块缩进差 ~10dp |
| 8 | 建议 | discover.dart:708 | 名次 Row 无统一 68 槽, 与 ranking_view 结构漂移 |
| 9 | 建议 | messages_page.dart:556/635 | Divider indent 68 与文字 60 差 8dp |
| 10 | 建议 | feed_view.dart:1126 | 筛选弹层组标题 16 与行文字 56 不成列 |
| 11 | 可接受 | ranking_view.dart:304 | 名次列占位, 保留 |
| 12 | 可接受 | settings_view.dart:460/58 | 自定义块 24 vs 图标行 64, 卡内各自一致 |
| 13 | 可接受 | search_results.dart:184 | 行铺满+标题 12 已是有意设计 |
| 14 | 可接受 | comment_thread.dart:1010 | 回复预览缩进语义正确 |
| 15 | 可接受 | recommend_view.dart:434 | 卡片语义缩进 |

统一手法建议(全局): ① 定义 kLeadingSlot = 40/48 两档常量, leading 一律 SizedBox(width:kLeadingSlot, child: ...); ② 跨页同构行(歌曲行)用 titlePadding 显式收齐 leading→title gap, 替代依赖 ListTile 默认 16; ③ detail_page 区块外距统一 12。

DONE
