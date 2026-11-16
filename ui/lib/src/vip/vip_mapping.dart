import '../format.dart' show formatDateYmd;
import '../rust/api.dart' as rust;

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
