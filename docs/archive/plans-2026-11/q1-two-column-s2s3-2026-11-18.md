# Q1 横屏双列 S2 + S3(2026-11-18)

承 `docs/archive/plans-2026-11/wide-two-column-eval-2026-11-18.md` 的 S0/S1(S0 断点纯函数、S1 歌单详情双列已落地)。
本批: **S2 播客详情双列(做)** + **S3 我的打包式双列(先量后决定: 不做, 见 §2)**。

## 1 S2 播客详情双列(已落地)

### 改动

| 文件 | 改动 |
|---|---|
| `ui/lib/src/detail/podcast_detail_page.dart` | body 二分: `twoColumnFor(MediaQuery.sizeOf(context))` ⇒ 双列, 否则原单列; 抽出 `_buildComments(radio)` 供两分支共用(纯重构, 无几何变化) |
| `ui/test/podcast_detail_two_column_test.dart` | 新增 6 例几何回归 |
| `ui/test/golden_pages_test.dart` | 新增 1 张 `podcast_detail_1280x720.png`(+ 假 FFI `crateApiPodcastPrograms` 与 `_podcastRadio`/`_podcastPrograms` 夹具) |

### 几何口径(与 S1 歌单详情**完全同构**, 共用同一份判据与常量)

- 判据: `twoColumnFor(Size)`(`layout.dart`, 宽 >= `kTwoColumnMinWidth`=900 **且** 高 >= `kTwoColumnMinHeight`=560),
  入参是 **`MediaQuery.sizeOf` 窗口逻辑尺寸**(壳层 `ContentWidthLimit` 把 body 限到 840, 拿实测宽比 900 永远为假)。
- 切分: 左 `kTwoColumnListWidth`=300 / 间距 `kTwoColumnGap`=12 / 右 = 528(840 - 300 - 12)。
- 左栏 = 播客信息卡(封面 120 / 名称 / 主播 / 「N 个节目 · 播放 M 次」/ 简介);右栏 = 筛选框 + 节目列表 + 评论。
  窄档块序(信息卡 → 筛选 → 节目 → 评论)原样保留。
- 滚动: 两列各自滚动。本页此前**没有**「定位正在播放」入口(那是歌单详情专有), 所以右栏暂不挂 controller;
  注释里写明以后加定位时把 controller 挂右栏, 左栏保持无 controller。
- 窄/中档分支: 同一棵 sliver 树、同一顺序, **一行几何未改**。

### 测试(6 例, 全绿)

```
flutter test test/podcast_detail_two_column_test.dart
1280x720 左 300 / 间 12 / 右 528 + 填满居中 840   ✓
1280x720 顶部对齐 + AppBar 整宽 840                ✓
840x800 单列铺满                                    ✓
900x560 双列 / 899x800 单列 / 900x559 单列          ✓
780x360 手机横屏(高度判据)单列                      ✓
300x640 @1.25 字号 单列且不竖溢                     ✓
```

### golden 新增 1 张

- 文件: `ui/test/goldens/podcast_detail_1280x720.png`(1280x720, dpr 1.0, 带 `ContentWidthLimit`)。
- 内容: 左 300 播客信息卡 / 右 528「筛选节目」+ 8 行节目(第 1 行按 song.id 高亮为正在播放)+ 评论首屏。
  两侧 == 壳层 220 留白。
- 只重出这一张: `flutter test test/golden_pages_test.dart --update-goldens --plain-name 'podcast_detail: 1280x720'`。
- 以后动 `kContentMaxWidth` / `kTwoColumnListWidth` / `kTwoColumnGap` 需重出这一张。
- 窄档没有新增基准: 几何由 6 例矩形断言锁, 不再多一张同构图。

## 2 S3 我的打包式双列 —— **先量后决定: 不做**

### 测量方法(临时脚本 `ui/test/_tmp_mine_measure_test.dart`, 已删除)

- 视口 720 高, 外面套真实壳层 `ContentWidthLimit`;窗口宽分别取 **1280 / 900 / 840 / 528 / 300**,
  于是 body 宽 = 840 / 840 / 840 / 528 / 300 —— 正好覆盖「双列左栏 300」「双列右栏 528」「单列 840」。
- 左组 = 资料卡 + 我的主页入口 + 消息入口 + 黑胶会员 + 云盘 + 数字专辑 + 等级勋章;
  右组 = 我喜欢 / 收藏歌单 / 收藏专辑+播客 / 最近听过 / 听歌排行。
- `leftH` = 「我喜欢的音乐」标题顶 − 资料卡顶(绝对坐标 = 视口坐标 + 滚动偏移);
  `total` = 滚到底后的 `maxScrollExtent + viewportDimension`;`rightH = total − leftH`。
- 假数据量级取常见值: 8 首喜欢 / 6 个歌单 / 4 个播客 / 4 张专辑 / 6 条最近 / 5 行排行。

### 测量结果(dp)

| 窗口宽 | body 宽 | 左组高 | 单列总高 | 右组高 |
|---|---|---|---|---|
| 1280 | 840 | 812 | 2781 | 1969 |
| 900 | 840 | 812 | 2781 | 1969 |
| 840 | 840 | 812 | 2781 | 1969 |
| 528 | 528 | 812 | 2781 | 1969 |
| 300 | 300 | 885 | 2854 | 1969 |

(右侧横滑条块高度与宽度无关: 528→840 同一数值; 左组只在 300 宽时因文字换行 +73。)

### 判据与结论

- 双列后左右两列**各自**内容高: **左 885 vs 右 1969**, 差 1084 = **55.1%**(以较高列为分母)。
- 阈值 40% ⇒ **55.1% > 40% ⇒ 不做 S3**。
- 另一种读法(未压缩前单列总高 2781 vs 双列后右列高 1969)= **−29.2%**:压缩本身不算差,
  但打包式双列里两列同处一个滚动体, 左列滚到 885 之后就是 1084dp 的空白(占整页 39%),
  正是评估文档 §3 S3 里「空一大截比单列更丑」的画像 ⇒ 维持单列。
- 不做之后的代价为零: `mine_view.dart` 一字未改, 现有 `goldens/mine_360x800.png` 与
  `mine_300x640_s125.png` 不受影响。
- 若以后数据形态变化(例如右列区块变少), 复测成本很低: 重建上面的临时脚本即可, 判据仍是「两列各自高度差 > 40% ⇒ 不做」。

## 3 自验(实测)

| 门 | 结果 |
|---|---|
| `dart analyze`(ui 全量) | **0 issue** |
| `flutter test test/podcast_detail_two_column_test.dart` | **6/6 通过** |
| `test/two_column_breakpoints_test.dart` + `test/playlist_detail_two_column_test.dart`(相邻回归) | **15/15 通过** |
| `tools/check-tokens.sh --strict` | **OK** |
| `tools/check-row-padding.sh --strict` | **OK**(纵向 0: 20 处 / 纵向 6: 1 处, 全在具名口径内) |
| `flutter test --exclude-tags network` | **1256 通过 / 4 失败**, 失败 4 例全在**别的车道在飞的未跟踪文件**里(`test/home_wiring_stack_test.dart` ×3 + `test/post_frame_alive_test.dart` ×1, 依赖新文件 `lib/src/lifecycle_guard.dart` 与改动中的 `lib/src/home/home_wiring.dart`), 与本批改动的播客详情/双列判据无关 |
| golden 变化 | 新增 **1** 张 `podcast_detail_1280x720.png`(19 → 20), 既有 19 张**零变化**(未重出); 只 `--update-goldens --plain-name 'podcast_detail: 1280x720'` |

基线口径: 本批前 Dart 测试 1243 例; 本批 +6(播客双列几何) ⇒ 1249 本批应得;
全量 1256 里另外 +7 来自别的车道的 `post_frame_alive_test.dart` 等新增用例。

### 未触碰(边界)

`feed/` / `player_bar.dart` / `settings_*` / `app_shell.dart` / `popup_routes.dart` / `home/**` /
数据请求层 / `docs/PROGRESS.md` / `docs/remaining-batches.md` 全部未改; `mine_view.dart` 未改(S3 判定不做)。
未 commit。格式只跑了自己改的三个文件。

