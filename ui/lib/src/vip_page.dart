import 'package:flutter/material.dart';

import 'async_view.dart';
import 'error_views.dart' show FullError;
import 'format.dart' show formatDateYmd;
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'state_views.dart';
import 'toast.dart' show showToast;

/// 黑胶会员只读页 · 视图模型(纯 Dart, 不依赖 Rust 绑定)
/// 数据由注入的 loader 提供, Rust 接入时在外层做 DTO 到 View 的转换。
///
/// 字段语义对齐真实接口(2026-11 CLI 实测):
///   `vip_info_v2`     -> VipProfileView.isVip / expireDate / level
///   vip_growthpoint -> VipProfileView.growthValue / todayGrowthValue / levelName
///   signin_progress -> VipSignView(每日签到: 今日/累计/连续/本周 + 最近记录)
///   vip_tasks       -> `List<VipTaskView>`

class VipProfileView {
  const VipProfileView({
    required this.nickname,
    this.avatarUrl,
    required this.level,
    this.levelName = '',
    required this.isVip,
    this.expireDate,
    required this.growthValue,
    this.todayGrowthValue = 0,
  });

  final String nickname;
  final String? avatarUrl;

  /// redVipLevel / associator.vipLevel (= userLevel.level)
  final int level;

  /// levelCard.levelName(空则退回 userLevel.levelName), 如 "黑胶·叁"
  final String levelName;

  /// associator.expireTime > now
  final bool isVip;

  /// 到期时间, 已格式化 yyyy-MM-dd; 未知为 null
  final String? expireDate;

  /// userLevel.growthPoint
  final int growthValue;

  /// extJson.todayScore(解析失败当 0)
  final int todayGrowthValue;

  /// 展示用等级文案: 有名字用名字, 否则 "Lv.N"
  String get levelLabel => levelName.isNotEmpty ? levelName : 'Lv.$level';
}

/// 签到日历里的一天。接口只回已有记录, 不编造未来日期。
class VipSignDayView {
  const VipSignDayView({
    required this.date,
    required this.label,
    required this.signed,
    this.today = false,
  });

  /// yyyy-MM-dd
  final String date;

  /// 周一..周日短标签("一".."日"); 解析不出日期时退回 dd
  final String label;

  /// score > 0 才算已签(recordId/time 不做判断依据)
  final bool signed;

  /// today == true 的那一项即今天
  final bool today;
}

/// 每日签到(云贝签到)视图模型。
///
/// 数据源是 signin_progress(与官方客户端"今日签到/累计/连续/本周"同源), 不再是
/// vip_sign_info(乐签成长值记录, 用户不参与时恒为 0 —— 2026-11-15 修掉的错源)。
class VipSignView {
  const VipSignView({
    this.days = const <VipSignDayView>[],
    this.signedToday = false,
    this.totalDays = 0,
    this.continuousDays = 0,
    this.weekDays = 0,
  });

  /// 按日期升序的最近若干天(最多 7 天, 可能不足)
  final List<VipSignDayView> days;
  final bool signedToday;

  /// 累计签到天数(不循环)
  final int totalDays;

  /// 连续签到天数(28 天循环内的当前进度)
  final int continuousDays;

  /// 本周(周一~周日)已签天数, 由接口 stats 的 4001 给出
  final int weekDays;

  /// 日历里已签的格数(接口 recent 缺天时以它为准显示)
  int get weekSignedDays => days.where((d) => d.signed).length;
}

class VipTaskView {
  const VipTaskView({
    required this.title,
    this.rewardText = '',
    this.progress = 0,
    this.total = 0,
    this.done = false,
    this.showProgress = true,
  });

  /// name 非空则 name, 否则 action
  final String title;

  /// description, 如 "成长值+3"
  final String rewardText;

  /// taskItems.currentProgress
  final int progress;

  /// targets 长度/数值; targets 为 null -> 0
  final int total;

  /// status == 2 或 (total > 0 && progress >= total)
  final bool done;

  /// 来自 showProgress; total <= 0 时也无进度可显示
  final bool showProgress;

  bool get showBar => showProgress && total > 0;

  double get fraction =>
      total <= 0 ? (done ? 1.0 : 0.0) : (progress / total).clamp(0.0, 1.0);
}

class VipPageData {
  const VipPageData({
    required this.isLoggedIn,
    this.profile,
    this.sign,
    this.tasks = const <VipTaskView>[],
  });

  final bool isLoggedIn;
  final VipProfileView? profile;
  final VipSignView? sign;
  final List<VipTaskView> tasks;
}

/// 黑胶会员只读页(纯展示层, loader 由调用方注入)。
class VipPage extends StatefulWidget {
  const VipPage({
    super.key,
    required this.load,
    this.onBack,
    this.onLogin,
    this.onSign,
  });

  final Future<VipPageData> Function() load;
  final VoidCallback? onBack;
  final VoidCallback? onLogin;

  /// 每日签到动作(默认 rust.signIn; 测试注入假实现)。
  final Future<rust.SigninStatus> Function()? onSign;

  @override
  State<VipPage> createState() => _VipPageState();
}

class _VipPageState extends State<VipPage> {
  /// 整页数据由本层持有(而不是交给 AsyncView 的 load): 签到成功后的静默刷新
  /// 要把新数据包成"已完成的 future"换进去, 才不闪整页 loading。
  late Future<VipPageData> _future;
  bool _signing = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// 取数: 网络错误自动退避重试(鉴权/风控立刻抛)。
  /// 用 future 形态喂 AsyncView 时它不会自己套 retryNetwork, 所以这里套一层,
  /// 与 load 形态的口径保持一致。
  Future<VipPageData> _load() => retryNetwork(widget.load);

  /// 重试/换 future 重取(AsyncView 的 onRetry): 会显示整页加载态。
  void _reload() {
    // 必须用块体: 箭头体把 Future 当成 setState 回调的返回值, Flutter 会断言失败。
    setState(() {
      _future = _load();
    });
  }

  /// 静默刷新(签到成功后 / 下拉刷新): 取到数据再换 future, 已渲染内容不闪
  /// 加载态; 失败保留旧内容(签到动作本身已有成功/失败提示)。
  Future<void> _refreshSilently() async {
    try {
      final data = await _load();
      if (!mounted) return;
      setState(() {
        _future = Future<VipPageData>.value(data);
      });
    } catch (_) {
      // 静默刷新失败: 不覆盖已渲染内容
    }
  }

  /// 每日签到: 成功后静默刷新整页(不闪 loading), 失败只弹提示.
  Future<void> _sign() async {
    if (_signing) return;
    setState(() => _signing = true);
    try {
      final status = await (widget.onSign ?? rust.signIn)();
      if (!mounted) return;
      final fresh = status.todayPoint > 0;
      showToast(
        context,
        fresh
            ? '签到成功, 云贝 +${status.todayPoint}(累计 ${status.totalDays} 天)'
            : '今天已经签过了(累计 ${status.totalDays} 天)',
      );
      await _refreshSilently();
    } catch (e) {
      if (!mounted) return;
      showToast(context, '签到失败: ${friendlyError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _signing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.onBack == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              ),
        title: const Text('黑胶会员'),
      ),
      // 整页四态收敛到 AsyncView: 加载中整页 LoadingView, 出错整页
      // FullError(文案走 friendlyError + 重试), 数据态交给 builder。
      // 数据在 data 里而非"空" —— 未登录空态由 _content 自己给。
      body: AsyncView<VipPageData>(
        future: _future,
        onRetry: _reload,
        emptyText: '暂无数据',
        loadingBuilder: (_) => const LoadingView(),
        errorBuilder: (_, error, retry) =>
            FullError(message: friendlyError(error), onRetry: retry),
        builder: (context, data, _) => _content(context, data),
      ),
    );
  }

  Widget _content(BuildContext context, VipPageData data) {
    if (!data.isLoggedIn) {
      // 未登录空态: 有数据但没登录, 不是 AsyncView 口径里的"空", 由页面给
      // 文案 + 登录按钮(视觉走统一 EmptyView)。
      return EmptyView(
        icon: Icons.workspace_premium_outlined,
        title: '登录后可查看会员信息',
        action: widget.onLogin == null
            ? null
            : FilledButton(onPressed: widget.onLogin, child: const Text('登录')),
      );
    }
    final sign = data.sign;
    return RefreshIndicator(
      onRefresh: _refreshSilently,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _VipCard(profile: data.profile),
          const SizedBox(height: 12),
          if (sign != null) ...[
            _SignBar(sign: sign, onSign: _sign, busy: _signing),
            const SizedBox(height: 12),
          ],
          if (data.tasks.isNotEmpty) _TaskList(tasks: data.tasks),
        ],
      ),
    );
  }
}

class _VipCard extends StatelessWidget {
  const _VipCard({this.profile});

  final VipProfileView? profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final p = profile;
    final avatarUrl = p?.avatarUrl;
    // 头像统一走 NetworkImage(不传 headers: UA 传双份会被 CDN 403)
    final avatar = (avatarUrl != null && avatarUrl.isNotEmpty)
        ? CircleAvatar(backgroundImage: NetworkImage(avatarUrl))
        : CircleAvatar(
            child: Text(
              (p != null && p.nickname.isNotEmpty)
                  ? p.nickname.characters.first
                  : '?',
            ),
          );
    final metaParts = <String>[
      p?.levelLabel ?? 'Lv.0',
      '成长值 ${p?.growthValue ?? 0}',
      if (p != null && p.todayGrowthValue > 0) '今日 +${p.todayGrowthValue}',
      if (p?.expireDate != null) '到期 ${p!.expireDate}',
    ];
    return Card(
      margin: EdgeInsets.zero,
      color: p?.isVip == true ? colorScheme.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            avatar,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    children: [
                      Text(
                        p?.nickname ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (p?.isVip == true) const VipPageBadge(small: true),
                    ],
                  ),
                  Text(
                    metaParts.join(' · '),
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 黑胶标识(与 song_tile/settings_view 里的 VipBadge 视觉一致;
/// 独立命名, 避免 main.dart 里两个同名导出冲突)
class VipPageBadge extends StatelessWidget {
  const VipPageBadge({super.key, this.small = false});

  final bool small;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? 6 : 8,
        vertical: small ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: colorScheme.primary,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '黑胶VIP',
        style: TextStyle(
          color: colorScheme.onPrimary,
          fontSize: small ? 10 : 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 每日签到卡(云贝签到): 今日状态 + 累计/连续/本周 + 最近几天日历 + 签到按钮。
///
/// 2026-11-15: 取代原先基于 vip_sign_info 的"本周已签 X/7"条 —— 那个数据源是
/// 乐签成长值记录, 用户不参与时恒为 score=0, 于是详情页永远显示"今日未签到/累计 0",
/// 与"我的"页签到卡(云贝签到)自相矛盾。现在两边同源。
class _SignBar extends StatelessWidget {
  const _SignBar({required this.sign, this.onSign, this.busy = false});

  final VipSignView sign;
  final VoidCallback? onSign;
  final bool busy;

  static const weekLabels = ['一', '二', '三', '四', '五', '六', '日'];

  /// "yyyy-MM-dd" -> 周几短标签; 解析失败返回空串(调用方退回日期尾部)
  static String weekdayLabel(String date) {
    final d = DateTime.tryParse(date);
    if (d == null) return '';
    return weekLabels[(d.weekday - 1).clamp(0, 6)];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final days = sign.days;
    final summary =
        '累计 ${sign.totalDays} 天 · 连续 ${sign.continuousDays} 天'
        ' · 本周 ${sign.weekDays} 天';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  sign.signedToday
                      ? Icons.task_alt
                      : Icons.calendar_month_outlined,
                  size: 20,
                  color: sign.signedToday ? colorScheme.primary : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    sign.signedToday ? '今日已签到' : '今天还没签到',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (sign.signedToday)
                  Text('已签', style: TextStyle(color: colorScheme.outline))
                else
                  FilledButton.tonal(
                    onPressed: busy ? null : onSign,
                    child: busy
                        ? const LoadingView.inline(size: 16)
                        : const Text('签到'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(summary, style: theme.textTheme.bodySmall),
            if (days.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final d in days)
                    Expanded(
                      child: _SignDay(
                        label: weekdayLabel(d.date).isEmpty
                            ? d.date
                            : weekdayLabel(d.date),
                        signed: d.signed,
                        isToday: d.today,
                        colorScheme: colorScheme,
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SignDay extends StatelessWidget {
  const _SignDay({
    required this.label,
    required this.signed,
    required this.isToday,
    required this.colorScheme,
  });

  final String label;
  final bool signed;
  final bool isToday;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: signed
                ? colorScheme.primary
                : colorScheme.surfaceContainerHighest,
            border: isToday
                ? Border.all(color: colorScheme.primary, width: 2)
                : null,
          ),
          child: Icon(
            signed ? Icons.check : Icons.radio_button_unchecked,
            size: 16,
            color: signed ? colorScheme.onPrimary : colorScheme.outline,
          ),
        ),
      ],
    );
  }
}

class _TaskList extends StatelessWidget {
  const _TaskList({required this.tasks});

  final List<VipTaskView> tasks;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < tasks.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _TaskTile(task: tasks[i]),
          ],
        ],
      ),
    );
  }
}

/// 打开黑胶会员页(只读). 默认走真实 Rust 数据; 测试可传 load 覆盖.
Future<void> showVipPage(
  BuildContext context, {
  Future<VipPageData> Function()? load,
  VoidCallback? onLogin,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => VipPage(
        load: load ?? loadVipPageData,
        onLogin: onLogin,
        onBack: () => Navigator.of(context).maybePop(),
      ),
    ),
  );
}

const _weekdayLabels = <String>['一', '二', '三', '四', '五', '六', '日'];

/// vip_overview 未登录时返回 loggedIn=false(不抛鉴权错);
/// 昵称/头像额外拉一次 profileDetail, 失败只影响资料卡文案, 不影响会员数据.
Future<VipPageData> loadVipPageData() async {
  final overviewFuture = rust.vipOverview();
  final profileFuture = _tryProfileDetail();
  final overview = await overviewFuture;
  final profile = overview.loggedIn ? await profileFuture : null;
  return mapVipOverview(overview, profile);
}

Future<rust.ProfileDetail?> _tryProfileDetail() async {
  try {
    return await rust.profileDetail();
  } catch (_) {
    return null;
  }
}

/// Rust DTO -> 视图模型(纯函数, 便于单测).
VipPageData mapVipOverview(
  rust.VipOverview overview, [
  rust.ProfileDetail? profile,
]) {
  if (!overview.loggedIn) {
    return const VipPageData(isLoggedIn: false);
  }
  final m = overview.membership;
  final g = overview.growth;
  final s = overview.dailySign;
  final level = (m?.redVipLevel ?? 0) > 0
      ? m!.redVipLevel
      : (m?.level ?? g?.level ?? 0);
  return VipPageData(
    isLoggedIn: true,
    profile: VipProfileView(
      nickname: profile?.nickname ?? '',
      avatarUrl: profile?.avatarUrl,
      level: level,
      levelName: g?.levelName ?? '',
      isVip: m?.isVip ?? false,
      expireDate: _dateOf(m?.expireTimeMs.toInt() ?? 0),
      growthValue: g?.growthPoint.toInt() ?? 0,
      todayGrowthValue: g?.todayScore.toInt() ?? 0,
    ),
    sign: s == null
        ? null
        : VipSignView(
            signedToday: s.signedToday,
            totalDays: s.totalDays,
            continuousDays: s.continuousDays,
            weekDays: s.weekDays,
            // recent 是"新的在前", 日历按日期升序渲染
            days: [
              for (final d in _ascendingDays(s.recent))
                VipSignDayView(
                  date: d.day,
                  label: _dayLabel(d.day),
                  signed: d.signed,
                  today: d.day == _todayYmd(),
                ),
            ],
          ),
    tasks: [
      for (final t in overview.tasks)
        VipTaskView(
          title: t.title,
          rewardText: t.reward,
          progress: t.progress.toInt(),
          total: t.target.toInt(),
          done: t.done,
          showProgress: t.showProgress,
        ),
    ],
  );
}

/// 毫秒时间戳 -> yyyy-MM-dd; 0/非法返回 null(格式化统一走 format.dart).
String? _dateOf(int ms) {
  if (ms <= 0) return null;
  return formatDateYmd(BigInt.from(ms));
}

/// 签到接口的 recent 是"新的在前", 日历按日期升序渲染(纯函数, 单测覆盖)。
List<rust.SigninDay> _ascendingDays(List<rust.SigninDay> recent) {
  final copy = [...recent];
  copy.sort((a, b) => a.day.compareTo(b.day));
  return copy;
}

/// 本地今天(yyyy-MM-dd)。signin_progress 的 recent 不带 today 标记,
/// 日历的"今天"边框靠日期串比较得到。
String _todayYmd() {
  final n = DateTime.now();
  final m = n.month.toString().padLeft(2, '0');
  final d = n.day.toString().padLeft(2, '0');
  return '${n.year}-$m-$d';
}

/// "2026-11-07" -> "六"; 解析失败退回日期尾部(如 "07")
String _dayLabel(String date) {
  final dt = DateTime.tryParse(date);
  if (dt == null) {
    return date.length >= 2 ? date.substring(date.length - 2) : date;
  }
  final idx = dt.weekday - 1;
  return idx >= 0 && idx < _weekdayLabels.length ? _weekdayLabels[idx] : '';
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task});

  final VipTaskView task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final statusText = task.done
        ? '已完成'
        : (task.showBar ? '${task.progress}/${task.total}' : '未完成');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        task.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (task.rewardText.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          task.rewardText,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.outline,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                // targets 为 null(total == 0) 或 showProgress == false: 不渲染进度条
                if (task.showBar)
                  Row(
                    children: [
                      Expanded(
                        child: LinearProgressIndicator(
                          value: task.fraction,
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(statusText, style: theme.textTheme.bodySmall),
                    ],
                  )
                else
                  Text(statusText, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            task.done ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 22,
            color: task.done ? colorScheme.primary : colorScheme.outline,
          ),
        ],
      ),
    );
  }
}
