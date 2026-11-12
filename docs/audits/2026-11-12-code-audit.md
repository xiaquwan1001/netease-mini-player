# 代码审计（2026-11-12）

> 范围: ui/lib + core/crates(只读)。目的: 找冗余可合并/死代码/逻辑缺陷。
> 已落地: 抽出 CoverCard/CoverRow 去三份重复; 删除死参数 RecommendView.loadCharts; PagedListView 与评论区加代际守卫。


## 范围
- ui/lib/src（除 rust/ 生成代码）+ core/crates
- 优先级：冗余/可合并 > 死代码 > 逻辑缺陷

## 一、冗余/可合并
（调查中）

## 二、死代码
（待查）

## 三、逻辑缺陷
（待查）

### A1 [中] RecommendView.loadCharts 死参数但被测试锁定（概要，详见 D1）
- 位置: ui/lib/src/recommend_view.dart:29,54；生产调用方 ui/lib/main.dart:2911 不传；ui/test 下 8 个测试仍传。
- 建议: 删字段 + 清理测试传参，同一 commit。风险低。

### A2 [低] formatFans 与 formatCompactCount 口径相近（概要，详见 L3）
- 位置: ui/lib/src/new_release_page.dart:301 vs ui/lib/src/comment_stats_bar.dart:41。
- 建议: 抽公共一位小数辅助到 format.dart，不强求合并两函数。风险低。
### A3 [高] _CoverCard 三个文件逐字节重复
- 位置: ui/lib/src/mine_view.dart:646 / ui/lib/src/chart_section.dart:213 / ui/lib/src/recommend_view.dart:942
- 问题: 三个私有 _CoverCard 类字段、build 实现**完全一致**(InkWell+CoverArt(118,radius:8)+两行省略文本), 是复制粘贴产物。
- 建议: 提为公共组件(如 cover_art.dart 或新建 cover_card.dart), 三处替换引用。
- 风险: 低, 纯机械迁移。

### A4 [中] radio_subscribers_page 手写整套分页壳, 与 PagedListView 重复
- 位置: ui/lib/src/radio_subscribers_page.dart:100-215(自维护 _items/_hasMore/_loadingMore/_reload/_loadMore + 错误视图 + 底部按钮)
- 问题: PagedListView(paged_list_view.dart:53) 已封装同一套「首屏三态/下拉刷新/触底预取/失败 SnackBar/去重」; 该页手写复刻, 还少了一个特性(PagedListView 有 keyOf 去重, 手写版没有)。comment_thread.dart:83-299 也手写一份分页(但其带置顶/预览生成号等复杂逻辑, 合并收益低, 可不动)。
- 建议: radio_subscribers_page 改用 PagedListView<UserItem>(对齐 user_list_page.dart:146 的用法); comment_thread 保持现状。
- 风险: 中低(需回归听众页滚动与刷新)。

### A5 [低] SnackBar 手写点绕过统一 showToast
- 位置: ui/lib/main.dart(17 处 showSnackBar) + ui/lib/src/{artist_page,radio_subscribers_page,recommend_view,comment_thread,paged_list_view,feed_view,user_list_page,feed_detail_page}.dart 共 9 处; 统一封装在 ui/lib/src/toast.dart:10(showToast, 先 hideCurrentSnackBar 防连弹)
- 问题: 26 处提示未走统一口径, 连续提示会排队连弹。
- 建议: 逐处替换为 showToast/showToastWith(paged_list_view 内部那处是组件自包含设计, 可保留)。
- 风险: 低。

### A6 [低] main.dart 三重嵌套重复的 showAlbumPreview 闭包
- 位置: ui/lib/main.dart:2924-2952(RecommendView.onOpenAlbum 内 onOpenArtist 内 onOpenAlbum, 同一 5 行 album→showAlbumPreview 闭包写了 3 遍, 且 onOpenNewRelease 分支又复刻一遍)
- 建议: 提局部变量 _openAlbum(album) 复用。
- 风险: 低。

## 二、死代码

### D1 [中] RecommendView.loadCharts 是死参数(生产不传, 仅测试在喂)
- 位置: 声明 ui/lib/src/recommend_view.dart:29,54(注释自认「旧参数, 排行榜已移到搜索页, 保留只为不打断调用方」); 生产唯一调用方 ui/lib/main.dart:2911 **不传**; 排行榜现由 search_landing.dart:41,219 承载。
- 问题: 字段在 build 中不渲染任何东西, 但 ui/test 下 8 个测试仍在传(recommend_view_test.dart:81,177、song_action_source_test.dart:169,207、style_tiles*_test、ui_batch_*_test、narrow_width_audit_test.dart:237), 形成误导(读测试会以为榜单还在推荐页)。
- 建议: 删字段 + 同 commit 清理测试传参。
- 风险: 低。
- 反证已排除: dart analyze(ui, 含 unused_import/unused_element 规则)零 unused 告警; ui/lib/src 所有文件均被引用(逐文件统计引用数 ≥1); core/crates 无 allow(dead_code)。**除 loadCharts 外未发现其他死公开符号。**

### D2 [低] legacy/ 目录为只读存档, 无代码引用(符合 AGENTS.md 定位, 非问题, 仅记录)

## 三、逻辑缺陷

### L1 [中] PagedListView: 下拉刷新与在途 loadMore 竞态, 可能把旧页数据拼进新列表
- 位置: ui/lib/src/paged_list_view.dart:113-131(_reload 清空 _items 后 await loader) 与 139-159(_loadMore 只有 mounted 守卫, 无代际守卫)
- 证据: _loadMore 在 await widget.loader(cursor) 期间, 用户下拉触发 _reload 清空列表并重置 _cursor=0; _loadMore 随后完成, setState 把**旧 cursor 请求到的页** addAll 进新列表, 并用旧页的 hasMore 覆盖 _hasMore。列表短于 300px 预取距离或快速下拉时可能复现。
- 建议: 加自增 _generation; _reload 时 ++, _loadMore await 后比对不一致即丢弃。同理 comment_thread.dart:275 的 _loadMore 与 silent _reload 也无互斥(其 _previewGen 只护预览, 不护列表), 可一并修。
- 风险: 修复极小; 不修则是偶发数据错乱。

### L2 [低] artist_page._rebuildTabs 在异步回调中 dispose 正在使用的 TabController
- 位置: ui/lib/src/artist_page.dart:152-157(_tabController.dispose() 后立刻重建并恢复 index)
- 问题: MV 首页加载完成(_loadMvs 的 then 链)时 dispose 旧 controller; 因 dispose 与重建在同一同步块、下一帧前完成, TabBar/TabBarView 重建后即换新 controller, 常规时序安全; 但若 dispose 瞬间 tab 切换动画在途, 动画被取消、listener 被移除, 依赖 controller 重建前不再有 tick——属于**脆弱但当前成立**的写法。
- 建议: 改为「先 setState 换 length 再重建」或用 didUpdateWidget 模式; 至少加注释说明同帧约束。
- 风险: 低, 可只加注释。

### L3 [低] formatFans 自带缩写实现, 与 formatCompactCount 的 _oneDecimal 口径重复
- 位置: ui/lib/src/new_release_page.dart:301 vs ui/lib/src/comment_stats_bar.dart:37-46(_oneDecimal 私有)
- 建议: _oneDecimal 提升到 format.dart 公共, formatFans 复用; 文案后缀(「万粉丝」)保留各自包装。
- 风险: 低。

## 审计方法与覆盖说明
- 静态: rg 全量扫(setState/mounted/Timer/addListener/firstWhere/_loadMore/firstWhere 等 12 组模式); 逐文件统计 src/*.dart 被引用次数; dart analyze(ui) 全量跑, 零 unused/dead 告警。
- 已读确认: paged_list_view.dart 全文、comment_thread 结构、cover_art、main.dart 搜索建议防抖段(1020-1080, 有 _controller.text.trim()!=q 陈旧守卫, 正确)、artist_page、recommend_view、search_landing、radio_subscribers、format/comment_stats/song_tile 相关段。
- core/crates: ncm-ffi/api.rs 转换函数(song_dto/song_from_dto/word_lyric_dto 等)各一处定义, 无跨 crate 复制的 DTO 转换; ncm-service/retry 无重复实现。未发现 core 侧冗余。
DONE

