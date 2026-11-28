import 'update_checker.dart' show compareVersions;

/// 版本特性公告(给用户看的「这次更新带来了什么」)。
///
/// 为什么不用 GitHub release 正文: 那里是提交流水(commit 标题, 面向开发者、中英
/// 混杂, 一条修复可能拆成三行)。公告是产品语言, 所以单独维护在这里, key 与 tag
/// 同名(`vX.Y.Z`), 值是每行一条的用户可感知变化。
///
/// 两个消费方共用这一份数据(别再各写一份文案):
/// - 发现新版本弹窗(`update_dialog.dart`): 列出**当前版本之后**的所有公告条目;
/// - 更新后首次启动弹窗: 只列当前版本这一条(见 `home/startup.dart`)。
///
/// 发版时在这里加一条即可; 没有条目的版本不显示公告(不是每个 patch 都值得说)。
const Map<String, List<String>> kReleaseHighlights = <String, List<String>>{
  'v0.41.11': <String>[
    '更省电更跟手: 播放位置刷新不再整页重建(只更新播放条), 藏起来的页面不再空转动画',
    '修: 保存/分享图片不再卡界面; 分享图片的类型与图片格式一致(相册不再显示类型错)',
    '修: 登录/选文件/保存过程中页面被系统回收时, 按钮不会永久没反应',
    '修: 播放中改「边听边存/缓存上限」不会再中断当前这首',
    '修: 首次打开播放队列时连点两次不会再叠出两层面板',
    '装包更小: 只打 64 位(arm64/x86_64), release 版 Rust 库开 LTO',
  ],
  'v0.41.10': <String>['大歌单(上千首)重复进入更快、更省内存: 响应缓存命中不再复制整份数据'],
  'v0.41.9': <String>[
    '播放详情页(封面面)不再被底部三个圆钮压住: 封面与进度/按钮成组居中, 封面还大了一点(部分机型原来会压住封面下沿)',
    '点画面在歌词/封面之间切换时是淡入淡出, 不再"跳"一下; 展开歌词页也有淡入',
    '省流量省内存: 换歌不再为背景取色额外下一张原图; 图片缓存有了字节上限, 大图按显示尺寸解码',
    '歌单/「我喜欢的音乐」重复进入走缓存, 不再重复请求; 单曲循环不再每圈重新取一次播放地址',
    '歌词在"进详情页→返回→再进"时直接命中缓存(A→B→A 只取两次), 失败后点重试仍会真的重取',
  ],
  'v0.41.1': <String>[
    '修: 开着「自动跳过 VIP」按「上一首」时, 如果上一首是 VIP 会被弹回刚离开的那首 —— 现在会继续往回退到前一首可播的',
  ],
  'v0.41.0': <String>[
    '歌曲菜单新增「官方 MV」: 这首歌有官方 MV 时菜单里会出现入口, 点开直接看 MV(没有就不显示, 不留灰条)',
    '搜索结果里的 MV 更准: 不再把关键词截短去硬凑, 与搜索词无关的 MV 不再出现(搜不到就不显示这个分区)',
    '「总是在后台播放」下进 MV 不再叠音: 歌曲会立即停而不是慢慢淡出',
    '风险拦截提示更准确: 来自客户端身份/风控的失败不再显示为「服务开小差了」, 而是给出可操作的提示',
    '换曲瞬间进度条不再有一岁空白(总时长立即显示), 拖动/暂停在慢网起播时也不再卡',
  ],
  'v0.40.0': <String>[
    '连点切歌不再播错歌: 取直链慢的那次不会再把你刚点的那首顶掉, 队列、播放条与声音保持一致',
    '缓存与本地历史更稳: 并发写入不再互相覆盖, 同一首歌不会重复下载; 缓存占用把下载中的文件也计入',
    '换歌/慢网起播时暂停·停止·拖进度条立刻生效, 不再卡住等下载',
    '云盘「加载更多」和列表刷新不再跳回顶部; 歌词取失败时给出「重试」',
    '「我的」页消息未读数读完即刷新; 播放量/粉丝数统一按万/亿显示',
  ],
  'v0.39.0': <String>[
    '每日推荐本地缓存改成「只增不减」的索引: 当天不播放也会缓存, 不再出现只存一两首、或者一首都没有的天',
    '历史日推去掉跨天重复: 与更早日期重复的曲目折叠成一行, 点开仍可播放',
    '更新弹窗补上「新特性公告」, 更新后首次启动会告诉你这次改了什么',
  ],
};

/// 版本号归一化: 去掉 `v`/`V` 前缀与 `+build` 段, 只留展示用的 `X.Y.Z[-pre]`。
String normalizeVersionKey(String version) {
  var s = version.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  final plus = s.indexOf('+');
  if (plus >= 0) s = s.substring(0, plus);
  return s;
}

/// 某个版本自己的公告条目; 没有返回空表。
///
/// 表里的 key 带 `v` 前缀(与 tag 同名), 查询时两边都归一化再比, 调用方传
/// `0.39.0` / `v0.39.0` / `v0.39.0+90` 都能命中。
List<String> highlightsFor(String version) {
  final wanted = normalizeVersionKey(version);
  for (final entry in kReleaseHighlights.entries) {
    if (normalizeVersionKey(entry.key) == wanted) return entry.value;
  }
  return const <String>[];
}

/// 比 [currentVersion] 新的公告条目(升序拼接), 供更新弹窗一次列出跨版本变化。
///
/// 只比较公告表里有的版本, 不关心中间的 patch: 用户从 v0.38.8 直接跳到 v0.40.0
/// 时, 中间两条公告都会列出来(按版本号升序, 旧的在上)。
List<String> highlightsSince(String currentVersion) {
  final current = normalizeVersionKey(currentVersion);
  final newer =
      kReleaseHighlights.keys
          .where((tag) => compareVersionKeys(tag, current) > 0)
          .toList()
        ..sort(compareVersionKeys);
  return <String>[for (final tag in newer) ...highlightsFor(tag)];
}

/// `a < b ? -1 : a > b ? 1 : 0`。
///
/// 比版本号本身只有一份实现 —— 直接复用更新检查的 [compareVersions]
/// (semver 口径: `+N` build 段数字大者新、有预发布 < 无、无法解析当相等),
/// 这里只保留本文件"先归一化再比"的预处理: 公告表的 key 带 `v`, 调用方传进来的
/// 可能是 `0.39.0+90`, 两边都归一化后比较器看到的才是纯 `X.Y.Z[-pre]`。
///
/// 改造前这里另写了一份"只比数字段"的实现, 于是 `0.40.0-beta` 与 `0.40.0` 在公告
/// 排序里相等、在更新检查里前者更旧 —— 同一对版本号两个结论(D10)。
int compareVersionKeys(String a, String b) =>
    compareVersions(normalizeVersionKey(a), normalizeVersionKey(b));
