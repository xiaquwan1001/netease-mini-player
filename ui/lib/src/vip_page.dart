
import 'package:flutter/material.dart';

import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// 黑胶会员只读页 · 视图模型(纯 Dart, 不依赖 Rust 绑定)
/// 数据由注入的 loader 提供, Rust 接入时在外层做 DTO 到 View 的转换。
///
/// 字段语义对齐真实接口(2026-11 CLI 实测):
///   `vip_info_v2`     -> VipProfileView.isVip / expireDate / level
///   vip_growthpoint -> VipProfileView.growthValue / todayGrowthValue / levelName
///   vip_sign_info   -> VipSignView(数组, 只回最近 7 天, 无本月/累计维度)
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

class VipSignView {
  const VipSignView({
    this.days = const <VipSignDayView>[],
    this.signedToday = false,
  });

  /// 按 timeStr 升序的最近 7 天(可能不足 7 天)
  final List<VipSignDayView> days;
  final bool signedToday;

  /// 接口不给本月/累计天数, 用本周维度: 已签天数 / 7
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
  });

  final Future<VipPageData> Function() load;
  final VoidCallback? onBack;
  final VoidCallback? onLogin;

  @override
  State<VipPage> createState() => _VipPageState();
}

class _VipPageState extends State<VipPage> {
  VipPageData? _data;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.load();
      if (!mounted) return;
      setState(() => _data = data);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
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
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return _ErrorView(message: friendlyError(error), onRetry: _reload);
    }
    final data = _data;
    if (data == null) {
      return const Center(child: Text('暂无数据'));
    }
    if (!data.isLoggedIn) {
      return _NotLoggedInView(onLogin: widget.onLogin);
    }
    final sign = data.sign;
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _VipCard(profile: data.profile),
          const SizedBox(height: 12),
          if (sign != null) ...[
            _SignBar(sign: sign),
            const SizedBox(height: 12),
          ],
          if (data.tasks.isNotEmpty) _TaskList(tasks: data.tasks),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotLoggedInView extends StatelessWidget {
  const _NotLoggedInView({this.onLogin});

  final VoidCallback? onLogin;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.workspace_premium_outlined, size: 48),
            const SizedBox(height: 12),
            const Text('登录后可查看会员信息'),
            const SizedBox(height: 16),
            if (onLogin != null)
              FilledButton(onPressed: onLogin, child: const Text('登录')),
          ],
        ),
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
              (p != null && p.nickname.isNotEmpty) ? p.nickname.characters.first : '?',
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

/// 签到日历条: 接口返回的最近 7 天(按 timeStr 升序), 已签高亮, 今天加边框。
/// 不用 DateTime.now() 推算, 只渲染接口给的 days; 不足 7 天就少渲染几格。
class _SignBar extends StatelessWidget {
  const _SignBar({required this.sign});

  final VipSignView sign;

  static const weekLabels = ['一', '二', '三', '四', '五', '六', '日'];

  /// timeStr "yyyy-MM-dd" -> 周几短标签; 解析失败返回空串(调用方退回原串)
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
    final summary = '本周已签 ${sign.weekSignedDays}/7 天'
        '${sign.signedToday ? ' · 今日已签' : ' · 今日未签'}';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(summary, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final d in days)
                  Expanded(
                    child: _SignDay(
                      label: weekdayLabel(d.date).isEmpty ? d.date : weekdayLabel(d.date),
                      signed: d.signed,
                      isToday: d.today,
                      colorScheme: colorScheme,
                    ),
                  ),
              ],
            ),
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
  final s = overview.sign;
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
            days: [
              for (final d in s.days)
                VipSignDayView(
                  date: d.date,
                  label: _dayLabel(d.date),
                  signed: d.signed,
                  today: d.today,
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

/// 毫秒时间戳 -> yyyy-MM-dd(本地时区); 0/非法返回 null.
String? _dateOf(int ms) {
  if (ms <= 0) return null;
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final mm = dt.month.toString().padLeft(2, '0');
  final dd = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$mm-$dd';
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
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: colorScheme.outline),
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
                          borderRadius: BorderRadius.circular(3),
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
