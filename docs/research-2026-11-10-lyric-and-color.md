# 歌词滚动跟随与封面取色调研（2026-11-10）

> 只读调研，为 MiniNCM 两个待办提供实现参考。未改动本仓库任何代码。
> 调研基线：SPlayer-Next `a8716df`（2026-11-05）、node-vibrant `ed86836`（2026-01-27）、Mei `a690938`（2026-11-05）。

## 1. 仓库清单与许可证

| 仓库 | 全名 | stars | 主要语言 | license | 对我们的可用性 |
|---|---|---|---|---|---|
| SPlayer-Next | SPlayer-Dev/SPlayer-Next | 1592 | TypeScript (Electron+Vue) | **AGPL-3.0** | 只借鉴思路，**代码不可抄**（AGPL 传染，且它是 Electron DOM 方案，与 Flutter 不兼容） |
| lyric-dom | SPlayer-Dev/lyric-dom（SPlayer 的歌词渲染引擎，npm 包 `lyric-dom@0.3.1`） | - | TypeScript | **AGPL-3.0** | 同上，只看思路 |
| node-vibrant | Vibrant-Colors/node-vibrant | 2455 | TypeScript (monorepo) | **MIT**（packages/*/package.json 均 `"license": "MIT"`） | 算法可**直接移植**（我们本来就是自己用 Dart 复刻，引的是算法思想） |
| Mei | ljyh223/Mei | 226 | Kotlin (Android) | **Apache-2.0** | 代码可借鉴（保留版权声明即可），但它是 Android Compose 体系，Flutter 需改写 |

（stars 为 2026-11-10 GitHub API 数值。）

## 2. 歌词自动滚动跟随

### 2.0 SPlayer-Next（含 lyric-dom 引擎）

SPlayer-Next 自己不写滚动逻辑，`DefaultLyrics.vue` 只是配置壳，真正引擎是同作者的独立库 **lyric-dom**（`src/components/player/Lyrics/DefaultLyrics.vue:5`）。

架构要点（lyric-dom `src/engine/index.ts`，sha `6ab316f`）：

- **根本不用原生滚动**：整个歌词列表是一个绝对定位容器，每行用 `transform: translateY() scale()` 摆放（index.ts:770、1228），滚动=重算每行 y 的弹簧插值（`engine/spring.ts`，252 行手写弹簧）。没有 scrollTop、没有 scrollIntoView，天然绕开了 ScrollController 暂停/恢复那类问题。
- **时间驱动**：宿主以 ~帧率推送 `setCurrentTime(ms)`（SPlayer `PlayerLyric.vue:33`：`setCurrentTime(currentMs + status.lyricOffsetMs, player.isSeeking())`）；引擎在 `processTime` 里对比行 startTime/endTime 激活/停用行（index.ts:826-935）。
- **seek 自动识别**：不依赖宿主传 isSeeking——引擎记录 `lastProcessedTime`，时间倒退 >100ms 或前进 >2000ms 即判为 seek（`DEFAULTS.seekBackwardThreshold: 100 / seekForwardThreshold: 2000`，constants.ts:59-62；index.ts:819-828）。**注意它对“宿主传入的 isSeeking 参数”直接忽略（`_isSeeking`）**——靠时间跳变判 seek 更鲁棒。
- **seek 后重定位**：`handleSeek` 无条件 `userScrollOffset = 0; isUserScrolling = false; clearTimeout(scrollResetTimerId)`（index.ts:899-903），即 **seek 覆盖一切用户滚动状态，强制回中**；然后重扫激活行、无激活行时定位到下一个未来行（index.ts:922-928）。
- **用户滚动暂停**：wheel/touch 事件直接被引擎拦截（`preventDefault`，index.ts:1453-1482），累加到 `userScrollOffset` 并置 `isUserScrolling=true`，同时启动 `scrollResetDelay`（默认 **5000ms**）定时器；到时自动把 offset 归零、弹簧动画滑回激活行。判据只有 wheel/touchmove 输入事件，**没有任何滚动位置/速度判定**。
- **歌词整体替换（切歌）时**：走 `freeze()/resume()`（cancel rAF、断开 observer、暂停全部行动画；resume 时置 `snapNextSeek=true`，恢复后首次推送若检测到时间跳变则直接瞬移布局，index.ts:302-330）。
- **逐字歌词**：高亮不是逐字变色 DOM，而是每行一个 **CSS mask**（`linear-gradient(to right, ...)` 遮罩按 `gradientStart/gradientRatio` 平移），逐字时间在帧循环里按 `(currentTime - word.startTime)/duration` 求进度，批量写 mask 样式且缓存 `maskKey` 避免重复写（`engine/word-builder.ts:307-380`）。滚动与逐字高亮共用同一次 `setCurrentTime` 推送。

（待补：Mei、node-vibrant、共性总结、与我们现状差异）

### 2.1 Mei（ljyh223/Mei，`a690938`）

Mei 也是「壳 + 独立歌词库」：UI 层 `LyricScreen.kt` 只做时间采样与布局，滚动跟随全在作者自己的 **accompanist-lyrics-ui**（`com.mocharealm.accompanist`，Apache-2.0，ljyh223/accompanist-lyrics-ui）里，为 Compose Multiplatform 实现。

Mei 壳层要点（`app/src/main/java/com/ljyh/mei/ui/component/player/LyricScreen.kt`）：

- **帧级时间采样**：`LaunchedEffect` + `withFrameNanos` 每帧用 `SmoothPlaybackPosition.sample(rawPosition, speed, isPlaying)` 外推位置（LyricScreen.kt:185-199）——不依赖播放器回调频率。
- **seek 处理**：注册 `Player.Listener.onPositionDiscontinuity` → `playbackClock.reset()`（LyricScreen.kt:104-113）；切歌（lyricData 变化）时 `key(lyricData.lyricLine)` 重建 listState，先 `scrollToItem(初始行)` **无动画瞬移**，再打开跟随动画，「避免从第 0 行滚下来」（LyricScreen.kt:115-131）。
- 点行跳转：`player.seekTo(line.start)`（LyricScreen.kt:251-254）。

accompanist-lyrics-ui 要点（`src/src/commonMain/.../lyrics/KaraokeLyricsView.kt`，449 行）：

- **LazyColumn + animateScrollBy**（不是完全自绘）：焦点行变化时计算目标 item 的 `offset` 差值，可见则 `listState.animateScrollBy(delta, tween(400, EaseOut))`，不可见/跨太远才 `animateScrollToItem(index, -stableOffsetPx)`（KaraokeLyricsView.kt:229-246）——**animateBy 而非 animateTo**，滚动被打断也不会跳。
- **用 `scrollInCode` 标志区分程序滚动与用户滚动**（KaraokeLyricsView.kt:226/241/244）：程序滚动期间不再触发新的跟随动画（try/finally 复位）；用户手动滚动**没有定时回弹**，但下次焦点行变化仍会被拉回（无 pause 状态机，实现比 SPlayer 粗糙）。
- **模糊抑制**：`blurRadius` 只在 `(!listState.isScrollInProgress || scrollInCode.value)` 时生效（KaraokeLyricsView.kt:325）——用户滚动期间关掉距离模糊，滚完自动恢复。
- **逐字高亮**：Karaoke 行内每 syllable 按时间比例画高亮（KaraokeLineText.kt），间奏 >5s 插入呼吸圆点动画（KaraokeLyricsView.kt:255-266，阈值与 SPlayer 的 minInterludeGap=4000ms 类似）。
- **背景渐变（Mei）**：`AmbientBackground.kt` 用 AndroidX Palette 取 vibrant/darkVibrant/lightVibrant/dominant 四色 → 4 个 `animateColorAsState(1200ms)` → Canvas 画 3 个不同频率漂移的大圆（FluidCanvasImproved）+ 100dp RenderEffect 镜像模糊 + 底部 0→0.7 黑色渐变遮罩（AmbientBackground.kt:65-190）。灰度兜底：`isGrayscale(S<0.15)` 时 `boostSaturation(3.0)`，黑白封面直接给深蓝种子色（AmbientBackground.kt:219-259）。取色在 `Dispatchers.IO`， Coil 请求 `size(ArtworkSize.Small)`（AmbientBackground.kt:47-62）。

### 2.2 共性做法总结（可执行结论）

1. **seek 判定不要依赖播放器回调的 isSeeking 参数，也不要依赖滚动事件**：直接比较两次推送的时间差（SPlayer/lyric-dom：倒退 >100ms 或前进 >2000ms 判 seek，constants.ts:59-62）。播放进度跳变是唯一可靠信号；我们的 `player.isSeeking()` 这类标志可能错过 seek 完成时机。
2. **seek/切歌必须同时重置三个状态**：用户滚动偏移、用户滚动标志、回弹定时器（lyric-dom `handleSeek` index.ts:899-903 一次性清空）。seek 覆盖用户滚动状态，无条件回中。我们现状里 seek 后若 `_autoFollowLyric` 仍为 false，歌词会停在被用户滚走的位置——应把 seek 事件直接置回 follow。
3. **用户滚动暂停的判据只认真实输入事件**（wheel/touch/pointer down），不要用 `ScrollUpdateNotification.dragDetails` 之外的位置/速度推断；SPlayer 干脆拦截输入事件自己记 offset，Mei 用 `scrollInCode` 标志区分「我滚的」和「用户滚的」。**关键机制是双标志**：程序触发的 animateTo 也会产生 ScrollUpdateNotification，如果不区分来源，程序滚动会被误判为用户滚动并永久关闭跟随——`dragDetails != null` 恰好能区分（程序滚动无 dragDetails），这点我们现有实现方向是对的，但要保证「程序滚动期间不再重复触发 animateTo」（对应 Mei 的 scrollInCode try/finally）。
4. **暂停后要定时自动恢复**：SPlayer 默认 5s（`scrollResetDelay=5000`，constants.ts:23）；Mei 不恢复（体验差一截）。恢复时把偏移清零、直接动画回激活行，不要试图记住用户滚到哪。
5. **可见性即节能**：歌词页不可见时冻结渲染/停止推送时间（SPlayer `PlayerLyric.vue` syncActivity + lyric-dom `freeze/resume` index.ts:302-330）。Flutter 对应：歌词页 `TickerMode`/`Visibility` 关掉时停掉逐字驱动。
6. **恢复/切歌首次推送要允许瞬移**：lyric-dom 用 `snapNextSeek` 标志让恢复后的第一次跳变直接 snap 而不是弹簧动画（index.ts:325-330）；Mei 切歌先 `scrollToItem` 无动画再开跟随（LyricScreen.kt:128-131）。Flutter 里等价做法：切歌后首帧用 `jumpTo`，之后才 `animateTo`。
7. **滚动定位用「算 delta 再 animateScrollBy」而不是每次 animateToItem**：可见时按目标 item 实际 offset 差值动画（Mei, KaraokeLyricsView.kt:236-243），被用户打断也只是停在原地；只有目标行不在可视列表才整段 scrollToItem。Flutter 的 `Scrollable.ensureVisible` 或手算 `RenderBox` offset 均可。若日后换 `scrollable_positioned_list`，其 `itemScrollController.scrollTo(index, alignment)` 是瞬时、`scrollTo` 无动画版本+`animateTo` 组合可用，但注意它不支持监听打断。
8. **逐字歌词与滚动共用同一时间源**：一次 `setCurrentTime(t)` 推送同时驱动行激活、滚动和逐字进度；不要让逐字 view 自己再起时钟（SPlayer PlayerLyric.vue:33 单点推送，含 lyricOffsetMs 偏移）。逐字高亮推荐 mask/遮罩式（整行一个渐变遮罩随进度平移）而不是逐字 span 重着色（lyric-dom word-builder.ts:307-380，批量写+缓存避免每帧 N 次重绘；Flutter 可用 ShaderMask + progress 动画实现）。
9. **歌词整体替换（切歌）走重建/冻结路径**，不要在旧列表上原位换数据（Mei `key(lyricData.lyricLine)` 重建 state；SPlayer freeze + pendingLyrics 缓冲）。

### 2.3 与我们现状（MiniNCM main.dart `_autoFollowLyric` + `ScrollUpdateNotification.dragDetails` + `animateTo`；逐字走 WordLyricView）的差异

| 点 | 我们现状 | 参考 | 建议 |
|---|---|---|---|
| seek 判定 | （依赖状态栏时间跳变的隐式行为，未见显式阈值） | lyric-dom 100ms/2000ms 阈值 | 在时间推送处显式检测跳变 → `jumpTo` 定位 + 重置 follow 标志 |
| seek 后 follow | 未重置则可能停在用户滚动位 | handleSeek 清空 userScroll | seek 事件无条件恢复 `_autoFollowLyric = true` 并取消回弹 timer |
| 暂停判据 | `ScrollUpdateNotification.dragDetails`（方向正确） | Mei scrollInCode 双标志 | 保留 dragDetails 判据，另加 `isProgrammaticScroll` 标志：自己 animateTo 时置位，完成/打断后复位，程序滚动不关 follow |
| 恢复 | 未见定时恢复 | scrollResetDelay=5s | 用户滚动停止 5s 后 animateTo 回当前行，offset/Timer 一并清 |
| 切歌 | 未区分 | snapNextSeek / key 重建 | 切歌首帧 jumpTo 当前行，再恢复跟随；不要从旧位置滑过去 |
| 逐字 | WordLyricView（逐字驱动） | lyric-dom CSS mask / Mei KaraokeLineText | 评估改为行级 ShaderMask 渐变遮罩，一次推送驱动，减少逐字重绘 |
| 节能 | 未知 | freeze/resume | 歌词页不可见时停时间推送与动画 |

## 3. 封面取色：node-vibrant 算法拆解 + Dart 复刻方案

（node-vibrant `ed86836`，MIT；引用路径均相对 repo 根）

### 3.0 流水线（packages/node-vibrant/src/pipeline/index.ts:5-16）

```
image → scaleDown(降采样) → applyFilters(过滤像素) → MMCQ 量化(中位切分) → DefaultGenerator(选 6 色板)
```

- 降采样 `scaleDown`（packages/vibrant-image/src/index.ts:64-78）：`maxDimension<=0` 时按 `quality=5` 缩到 1/5 边长；`quality=1` 表示不缩。默认参数 `colorCount=64, quality=5, filters=["default"]`（packages/vibrant-core/src/index.ts:22-26）。
- 默认过滤器（pipeline/index.ts:9-12）：`alpha >= 125 && !(r>250 && g>250 && b>250)`——丢弃近透明与近白像素；被过滤像素 alpha 置 0，后续直方图跳过（packages/vibrant-image/src/histogram.ts:53-54）。

### 3.1 量化：MMCQ 中位切分（packages/vibrant-quantizer-mmcq/src/）

- 直方图：RGB 各取高 5 位（`SIGBITS=5`，vbox.ts:16），32³=32768 个 bin 的 `Uint32Array`，`index = (r<<10)|(g<<5)|b`（histogram.ts:25-26），并记录每维 min/max。
- 切分策略（index.ts:30-52）：
  1. 先按 **population（像素数）** 优先队列切到 `0.75 * colorCount`（`fractByPopulations=0.75`）个盒子；
  2. 换按 **count × volume** 排序继续切到 `colorCount`（64）个盒子；
  3. 每个 VBox 的 swatch = 盒内平均色，population = 盒内像素数（index.ts:55-66）。
- 切分维度：取盒内最长的通道，按该通道中位数二分。

### 3.2 色板定义与阈值（packages/vibrant-generator-default/src/index.ts）

打分公式（`_createComparisonValue`，同文件 :73-99）：
`score = weightedMean( 1-|S-targetS| , wS=3 , 1-|L-targetL| , wL=6.5 , population/maxPopulation , wPop=0.5 )`，取分最高且未被占用者。

| swatch | 目标 L | L 范围 | 目标 S | S 范围 | 典型用途 |
|---|---|---|---|---|---|
| Vibrant | 0.50 | [0.30, 0.70] | 1.0 | [0.35, 1.0] | 主强调色/主题色 |
| DarkVibrant | 0.26 | [0, 0.45] | 1.0 | [0.35, 1.0] | 深色背景基色 |
| LightVibrant | 0.74 | [0.55, 1.0] | 1.0 | [0.35, 1.0] | 亮色文字/高光 |
| Muted | 0.50 | [0.30, 0.70] | 0.3 | [0, 0.40] | 次级背景 |
| DarkMuted | 0.26 | [0, 0.45] | 0.3 | [0, 0.40] | 深色渐变端 |
| LightMuted | 0.74 | [0.55, 1.0] | 0.3 | [0, 0.40] | 亮色渐变端 |

注意 S/L 是 **HSL** 的 S/L（`Swatch.hsl`）。权重 饱和:明度:population = 3 : 6.5 : 0.5（明度最重，饱和次之，population 只做弱偏置——即“贴近目标色相/明度”比“面积大”更重要）。

兜底 `_generateEmptySwatches`（同文件 :262-300）：某色板缺位时，用已有同族色**保持 hue、改写 L** 合成（如无 DarkVibrant → 取 Vibrant 把 L 改成 0.26）；Vibrant 全缺时从 DarkMuted/LightMuted 提 L 合成。**六个槽位永远非空**（纯灰度图也能出全色板）。我们复刻必须带上这一步，否则灰度封面会拿到 null。

### 3.3 建议的 Flutter 实现步骤（ui.Image → 深色背景色组）

```
输入: ui.Image（封面解码后）
1. 降采样: Canvas.drawImageRect 缩到 max 边 128~256px（node-vibrant 默认 1/5 边长，
   600px 原图约 120px；建议固定 128，比 SPlayer 的 64 抗噪好、仍 <10ms）
   → toImage → 读 RGBA bytes
2. 过滤像素: 跳过 alpha<125 与 (r>250&&g>250&&b>250)（MIT 可直接照抄）
3. 直方图: sigBits=5, Uint32List(32768), index=(r>>3)<<10 | (g>>3)<<5 | (b>>3)
4. MMCQ 中位切分: fractByPopulations=0.75, colorCount=64
   （Dart 用 List<VBox> + sort 即可，不必优先队列；128px 图 <5ms）
5. 生成 6 色板: 按 3.2 表打分选色（wS=3, wL=6.5, wPop=0.5）
6. 空 swatch 兜底（保持 hue、改写 L）
7. 派生深色背景:
   - 主背景基色取 DarkVibrant（缺则 Vibrant）
   - 灰度判定: 若 Vibrant+DarkVibrant 的饱和度都 <0.15（或按 SPlayer 的
     “彩色像素占比 <12%”，color.ts:25/50-58），回退默认主题色
   - 背景 = DarkMuted→DarkVibrant 线性渐变，或把主色 HSL 的 L 压到 0.12~0.20
   - 文字/强调用 Vibrant 或 LightVibrant
```

伪代码（量化核心，可直接翻成 Dart）：

```dart
List<Swatch> mmcq(Uint8List rgba, {int colorCount = 64}) {
  final hist = Uint32List(1 << 15);
  int rmin=255,rmax=0,gmin=255,gmax=0,bmin=255,bmax=0;
  for (var i = 0; i < rgba.length; i += 4) {
    final a = rgba[i+3]; if (a < 125) continue;
    final r=rgba[i],g=rgba[i+1],b=rgba[i+2];
    if (r>250 && g>250 && b>250) continue;
    final hr=r>>3, hg=g>>3, hb=b>>3;
    hist[(hr<<10)|(hg<<5)|hb]++;
    // ... 维护各维 min/max
  }
  var boxes = [VBox.fromHistogram(hist, rmin,rmax,gmin,gmax,bmin,bmax)];
  void split(List<VBox> bs, bool byPop, int target) {
    while (bs.length < target) {
      bs.sort(byPop
          ? (a,b)=>b.count.compareTo(a.count)
          : (a,b)=>(b.count*b.volume).compareTo(a.count*a.volume));
      final v = bs.removeLast();            // 取最大盒
      if (v.count == 0) break;
      final parts = v.splitAtMedian();      // 最长通道中位数二分
      bs..add(parts.$1); if (parts.$2.count>0) bs.add(parts.$2);
    }
  }
  split(boxes, true, (0.75*colorCount).round());
  split(boxes, false, colorCount);
  return boxes.where((b)=>b.count>0).map((b)=>Swatch(b.avgColor, b.count)).toList();
}
```

打分（照抄 index.ts:73-99）：

```dart
double score(Swatch s, double targetS, double targetL, double maxPop) {
  double inv(double v, double t) => 1 - (v - t).abs();
  return (inv(s.saturation, targetS) * 3 +
          inv(s.lightness, targetL) * 6.5 +
          (s.population / maxPop) * 0.5) / 10;
}
```

### 3.4 性能与缓存

- **何时算**：歌曲切换 / 封面 URL 变化时。SPlayer-Next 用竞态 token（`coverColorToken++`，src/utils/color.ts:15/191/203）防止快速切歌时旧结果覆盖新封面——我们必须有（封面 A 慢于 B 到达时丢弃 A）。
- **缓存 key = 封面 URL**，值 = 色板；内存 Map/LRU 即可，进阶可随媒体库存 DB（跨启动秒出）。
- **isolate**：128px 输入 + MMCQ 约几毫秒，主 isolate 可接受；稳妥用 `compute()` 跑 `rgba→色板`（ui.Image 不能跨 isolate，先在主 isolate 缩放并取 bytes）。
- **失败兜底**：封面下载/解码失败 → 保持主题色并重试下一首；不要卡住换歌流程（异步 apply，不 await）。

补充参考：SPlayer-Next 自己没有用 node-vibrant，而是用 `@material/material-color-utilities` 的 QuantizerCelebi + HCT 自研取色（src/utils/color.ts:1-110），其中「中心加权采样（外圈权重 1 / 中圈 2 / 核心 3）」与「彩色像素占比 <12% 判灰度」的兜底值得借鉴。
## 4. 可直接抄的代码片段与不能抄的部分

**可以抄（MIT，注明出处）**：

- node-vibrant 的 MMCQ 量化、6 色板打分参数（全部阈值见 §3.2 表格）、默认像素过滤器 `a>=125 && !(r>250&&g>250&&b>250)`（packages/node-vibrant/src/pipeline/index.ts:9-12）、空 swatch 兜底逻辑（packages/vibrant-generator-default/src/index.ts:262-300）。出处注明 `Vibrant.js by Jariz (MIT)`。
- SPlayer-Next `src/utils/color.ts` 里的**思想**（中心加权采样、彩色占比 12% 灰度判据、竞态 token）——注意该文件整体是 AGPL，思路可借鉴、代码不可抄。
- Mei `ColorExtractionUtils.kt` 的 HSL 工具函数（boostSaturation/darken/isGrayscale，Apache-2.0）——逻辑简单，Dart 重写约 30 行，需在发行物 THIRD-PARTY 里声明 Apache-2.0 及版权（我们只参考思路的话可不带）。灰度封面「给深蓝种子色而不是灰背景」的兜底策略值得直接采用。

**不能抄**：

- **SPlayer-Next 与 lyric-dom 的任何代码（AGPL-3.0）**：包括 DefaultLyrics.vue 的配置结构、word-builder 的 mask 渐变公式实现、spring.ts。只能读源码理解行为后在 Flutter 里独立实现（不同语言/不同框架，且我们不做动态链接，AGPL 传染风险仅在我们逐行翻译时存在；为稳妥起见只参考参数与行为，不逐行翻译）。
- Mei 的 Kotlin/Compose 代码理论可抄（Apache-2.0），但 AmbientBackground 的 RenderEffect/FluidCanvas 是 Android 专属实现，Flutter 端要用 `BackdropFilter`+自定义 `CustomPainter` 重写，逐行翻译无意义。
- node-vibrant 的 **浏览器/Node 图片加载层**（vibrant-image-browser/node）：与 Dart 无关，我们只需要算法层。

## 附：可复现链接

- SPlayer-Next：https://github.com/SPlayer-Dev/SPlayer-Next @ `a8716df8f1a2cd08db3307ad592669df24bc05f4`（2026-11-05）
  - 歌词壳：`src/components/player/Lyrics/DefaultLyrics.vue`、`src/components/player/Lyrics/index.vue`、`src/components/player/FullPlayer/shared/PlayerLyric.vue`、`src/utils/color.ts`
  - permalink 前缀：`https://github.com/SPlayer-Dev/SPlayer-Next/blob/a8716df8f1a2cd08db3307ad592669df24bc05f4/`
- lyric-dom：https://github.com/SPlayer-Dev/lyric-dom @ `6ab316fea8388d71110b2def512b867e2a53c124`
  - `src/engine/index.ts`（seek/滚动/freeze）、`src/engine/constants.ts`（全部默认参数）、`src/engine/word-builder.ts`（逐字 mask）
  - permalink 前缀：`https://github.com/SPlayer-Dev/lyric-dom/blob/6ab316fea8388d71110b2def512b867e2a53c124/`
- node-vibrant：https://github.com/Vibrant-Colors/node-vibrant @ `ed86836150aeef6c8171f1485d5264a6d95ba2c8`（2026-01-27，MIT）
  - `packages/node-vibrant/src/pipeline/index.ts`、`packages/vibrant-core/src/index.ts`、`packages/vibrant-quantizer-mmcq/src/{index,vbox}.ts`、`packages/vibrant-image/src/{index,histogram}.ts`、`packages/vibrant-generator-default/src/index.ts`
- Mei：https://github.com/ljyh223/Mei @ `a69093833c486a23f3eae380b89bd0c383b46d35`（2026-11-05，Apache-2.0）
  - `app/src/main/java/com/ljyh/mei/ui/component/player/LyricScreen.kt`、`.../player/cover/AmbientBackground.kt`、`.../utils/color/ColorExtractionUtils.kt`
- accompanist-lyrics-ui：https://github.com/ljyh223/accompanist-lyrics-ui（main 分支 tarball，Apache-2.0；git clone 未成功仅取得 tarball，未记 sha）
  - `src/src/commonMain/kotlin/com/mocharealm/accompanist/lyrics/ui/composable/lyrics/KaraokeLyricsView.kt`
- Mei 仓库名确认：GitHub API `users/ljyh223/repos` 列出 42 个仓库，确为 `Mei`（「一个网易云音乐的第三方音乐软件」，226 stars，Kotlin，Apache-2.0）；无 Mei-lyric/MeiMusic 等歧义名。

## 5. AMLL / TTML 逐字歌词(2026-11-10 补充调研)

> 只读调研,基线 commit: a61f9876beeef31b4b57c45a9d07f13f44516a91 (amll-dev/amll-ttml-db)。

### 5.1 仓库定位

- **定位**:AMLL 生态的**逐词歌词数据库**——存储人工制作/审核的 Apple Music 风格 TTML 逐词歌词,不是格式规范文档(规范在 wiki「格式规范」),也不是渲染器。配套工具:amll-ttml-tool / amll-editor(编辑器)、amll-ttml-api(官方 HTTP API,同组织)、amll-player / applemusic-like-lyrics(播放与渲染核心)。
- **目录结构**(commit `a61f9876`):`am-lyrics/`(按 Apple Music ID 命名, 2818 个 .ttml)、`ncm-lyrics/`(按网易云 ID 命名, 3775)、`qq-lyrics/`(3236)、`spotify-lyrics/`(2635);每首歌同目录附 `.lrc/.lys/.qrc/.eslrc` 导出。另有 `raw-lyrics/`(3431, 文件名 `<时间戳>-<作者ID>-<hash>.ttml`)、`metadata/raw-lyrics-index.jsonl`(检索索引)、`metadata/contributors.jsonl`(170 人)、`scripts/`(Rust 校验 bot)。全仓 .ttml 共 **15912 个**。
- **License**:`LICENSE` = **CC0 1.0**(公有领域)。
- **审核**:提交需带至少一个平台 ID,经审核团人工审核(wiki 上传歌词/审核细则)。


### 5.2 格式与样例

标准单行结构(真实片段,ncm-lyrics/0.ttml,`a61f9876`):

- 根元素带 `itunes:timing="Word"`;`<head>` 内 `<ttm:agent xml:id="v1" type="person"/>` 与 `v2`(type="other")表主/副声,`<p ttm:agent="v1|v2">` 标声部;15912/15912 个文件都用 `ttm:agent`。
- 元数据用 AMLL 扩展 `<amll:meta key="..." value="..."/>`:`musicName/artists/album` 可多语言重复;ID 类:`ncmMusicId`(156358 处)/`appleMusicId`/`spotifyId`/`qqMusicId`/`isrc`(18174 处);作者:`ttmlAuthorGithub(Login)`。

样例 1(主声+翻译行):
```xml
<p begin="0.835" end="6.598" itunes:key="L1" ttm:agent="v1">
  <span begin="0.835" end="1.401">A</span> <span begin="1.401" end="2.287">lu</span><span begin="2.287" end="3.126">na,</span>
  <span ttm:role="x-translation" xml:lang="zh-CN">我的月亮呀，我亲爱的歌</span>
</p>
```
- 翻译/罗马音是**无时间戳的行内 span**:`ttm:role="x-translation"`(可带 xml:lang)、`ttm:role="x-roman"`(3201 个文件,粤语例:ncm-lyrics/86849.ttml `kei4 sat6 zi6 ...`)。
- 背景和声:`ttm:role="x-bg"` 包裹的子 span(1890 个文件,如 spotify-lyrics/ac56491a2aa44057.ttml);AMLL parser 另识别 `tts:ruby` 容器注音。
- 段落标签:`itunes:songPart="Verse|PreChorus|Chorus|Hook|Bridge"`(1078 个文件,如 spotify-lyrics/7sG4hU8FpyjNhGBSBDNjU0.ttml)。
- 间奏表达:不做空 span,直接在 `<p>` 之间留时间空隙(0.ttml 1:25.573 → 2:21.676);全库"空 span"仅 233 处(ncm-lyrics/725692.ttml 的 5ms 哨兵,非间奏表达)。
- 双声并行:0.ttml L31(v1)与 L32(v2)时间重叠(3:07.6 / 3:08.1 起),渲染为双层行。


### 5.3 粒度与对齐

- **粒度是音节/词块,不保证单字**:日英按音节切(`lu`/`na,`/`can`/`ti`/`ca`),中文多为 1 字 1 span,但也见 2-3 字(`<span>lucem al</span>`,0.ttml L12)。**不要假设 span==单字**,按 span 文本渲染渐变即可,粒度与 yrc"逐字"等价。
- **词内空格**是 span 之间的**裸文本节点**(`</span> <span>`),非空 span;AMLL parser 记为 `endsWithSpace`(ttml/src/parser.ts processElementNode)。少数文件把空格写进 span 尾部。
- **时间**:相对时钟字符串,两种形式混用——纯秒 `begin="0.835"` 与 `m:ss.mmm` `begin="1:02.520"`(行 p 上常见);毫秒精度 3 位。**begin/end 必带;span 不用 dur**(全库 0 处 span-dur),但 `<body dur="4:10.610">` 存在总时长。
- **衔接规则**:span 时间相邻衔接(end=next begin),词间可有停顿(0.ttml L8 `i` 48.047 → `a` 48.736,空 0.689s);官方 parser(ttml/src/parser.ts)对缺失 begin/end 用相邻词推算并 clamp 到 p 范围,begin==end==0 的 fallback 词丢弃。


### 5.4 最小 Dart 解析器草案

Flutter 侧只需 `xml` 包把 span 压平成与 yrc 等价的行/字结构:

```dart
// WordLine { t0, t1, words: [Word{t0, t1, text}], translation?, roman? }
List<WordLine> parseTtml(String xml) {
  final doc = xml.XmlDocument.parse(xml);
  double t(String? s) { // 兼容 "12.345" 与 "1:02.520"
    if (s == null || s.isEmpty) return 0;
    if (s.endsWith('s')) s = s.substring(0, s.length - 1);
    final parts = s.split(':');
    var v = double.parse(parts.last);
    if (parts.length > 1) v += double.parse(parts[parts.length - 2]) * 60;
    if (parts.length > 2) v += double.parse(parts[0]) * 3600;
    return v;
  }
  return doc.findAllElements('p').map((p) {
    final words = <Word>[];
    String? translation;
    for (final node in p.children) {
      if (node.nodeType == XmlNodeType.ELEMENT && node.name.local == 'span') {
        final role = node.getAttribute('ttm:role');
        if (role == 'x-translation') { translation = node.innerText; continue; }
        if (role == 'x-roman' || role == 'x-bg') continue; // 可选:存 roman/背景声
        words.add(Word(t(node.getAttribute('begin')),
                       t(node.getAttribute('end')), node.innerText));
      } else if (node.nodeType == XmlNodeType.TEXT && node.value!.trim().isEmpty) {
        if (words.isNotEmpty) words.last.text += ' '; // 词间空格
      }
    }
    return WordLine(t(p.getAttribute('begin')), t(p.getAttribute('end')), words, translation);
  }).toList();
}
```

**质量/可用性启发式**(任一不过就回退 yrc/普通 LRC):
1. span 覆盖率:带时间的 span / span 总数 ≥ 0.9,单行至少 1 个 span。
2. 时间单调:行内 begin 非降、span.end ≥ span.begin、行区间不倒退。
3. 首行 begin 与音频起始偏差 < 5s;行间空隙 < 60s(防整段错位)。
4. span 时长 > 0 且 < 30s;零时长 span 丢弃。
5. 元数据匹配:检索返回的 ncmMusicId/isrc 与当前曲目一致(API 检索天然保证)。
6. 精度粗检:时间小数位 ≤ 3;若全部尾数只有 0/500ms,疑似机打时间轴,降权。


### 5.5 数据可用性与许可

- **官方 HTTP API 存在**(amll-dev/amll-ttml-api,Rust,Apache/MIT 双许可):base `https://api.amll.dev`,CORS 全开,限速 50 req/s/IP。接口文档:https://amll.dev/reference/http-api/overview 与 OpenAPI https://amll.dev/api/ttml/openapi.yaml。
  - `GET /v1/lyrics/get?ncmMusicId=186016`(也支持 `id`(53 位文件名哈希,优先级最高)/`filename`/`qqMusicId`/`appleMusicId`/`spotifyId`/`isrc`,多 ID 取交集 AND)→ 200 返回 `{id, filename, musicNames, artistNames, albumNames, ncmMusicIds, isrcs, authorUsernames, lyrics:"<tt ...>"}`,**lyrics 内联完整 TTML**(实测"晴天" 186016 命中,返回含 isrc TWK970300503)。
  - `GET /v1/lyrics/search?musicName=晴天&artistName=周杰伦&limit=N`(或 `q` 模糊/`albumName`/`lyricText`/`authorId`)→ `{items:[...]}`;另有 `/v1/lrclib/search|get` 代理与 `/v1/status`、`/v1/version`。
  - 官方缓存建议:按 `id`/`filename` 取到的内容**永久不变**,建议永久缓存;平台 ID / 模糊检索结果会随词库更新,只做短缓存。
- **License:CC0 1.0**——无署名义务、可内置进 App、可商用。受限点不在数据许可而在**服务**:api.amll.dev 是社区服务(无 SLA),客户端必须本地/永久缓存 + 多源回退(yrc 优先、TTML 兜底),不要硬依赖其可用性;另外**歌词文本本身可能仍有第三方歌词版权**,不要把歌词打进安装包,缓存应可清除。


### 5.6 与现有结论的差异与建议

- **渲染跟随暂停**(applemusic-like-lyrics@`f3228586`,packages/core/src/lyric-player/base/scroll.ts):交互期间置 `isInteracting` 暂停自动对齐;松手记 `scrollEndTime`,**延迟仅 500ms**(`AUTO_ALIGN_RESUME_DELAY_MS`)后 `canResumeAutoAlign=true` 恢复跟随;惯性滚动用 rAF 逐帧衰减并每帧发 `onScrollUpdate(true)`。与既有结论(常见 1-3s 固定恢复)相比,AMLL 恢复窗口更短且以"惯性结束"为锚点,可借鉴:用**滚动速度/惯性归零**而非固定 timer 决定恢复。
- **逐字渲染差异**:AMLL 是 **span(syllable)级**渐变,并带行内翻译/罗马音/背景声三路附属层,比我们 word_lyric_view 的整行渐变更细;其 parser(ttml/src/parser.ts)对 span 时间缺失有推算兜底,Dart 解析器应做同等容错。
- **建议**:1) yrc 仍为主源;2) 新增 TTMLProvider 作第二逐字源,走 `api.amll.dev/v1/lyrics/get?ncmMusicId=`(我们天然有网易云 ID,零映射成本),按 ncmMusicId 永久缓存;3) 解析后跑 5.4 启发式,合格才切换逐字渲染,否则回退;4) TTML span 与 yrc word 同构,现有逐字管线可直接复用;5) 不把歌词打进安装包,缓存可清除。


