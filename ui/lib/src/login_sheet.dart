import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'rust/api.dart' as rust;
import 'sheet_header.dart';
import 'state_views.dart';
import 'toast.dart';

/// 桌面端登录弹层(Linux / Windows 共用).
///
/// 为什么不是 WebView: 桌面端没有 Android 那套 CookieManager, 浏览器里 MUSIC_U 是
/// HttpOnly, 读不出来; 而官方网页登录的**扫码通道**会把登录凭据放在轮询响应的
/// Set-Cookie 里, 所以纯 Rust 就能完成整个登录, 也不需要平台代码/系统依赖.
///
/// 四种入口(都在同一弹层里, 不逼用户去命令行):
/// 1. 扫码登录(默认): 手机网易云 App 扫二维码 → 自动轮询 → 成功即落盘;
/// 2. 手机号 + 短信验证码: 走**网页登录**通道(weapi /api/sms/captcha/sent + login/cellphone),
///    与扫码同一族, 不是 App 原生登录族; 命中交互式风控(8821)时提示改回扫码;
/// 3. 导入 Cookie: 浏览器 F12 复制 MUSIC_U(老用户/排查用);
/// 4. 在浏览器打开官方登录页(只是给要手工复制 cookie 的人一个入口).
///
/// 依赖全部注入, 便于 widget 测试(不联网、不碰 FFI).
/// 把 Rust 侧 `ProviderError` 的 `[kind] detail` 文案转成用户能读的一句话.
///
/// 桥那边统一是 `[auth|riskControl|network|notFound|unsupported|internal] detail`,
/// Dart 拿到的是 `Exception: [kind] ...`. 直接把方括号和类型名铺给用户很难看, 但
/// **服务端原文必须留下**(例如「手机号码不符合规范」才是真信息), 所以只换标签、保留前缀
/// (如「发送验证码失败:」)与 detail.
String friendlyLoginError(String raw) {
  const labels = <String, String>{
    'auth': '信息有误',
    'riskControl': '被网易云安全风控拦截',
    'network': '网络不通',
    'notFound': '接口不存在',
    'unsupported': '当前版本不支持',
    'internal': '服务端异常',
  };
  final m = RegExp(r'\[(\w+)\]\s*').firstMatch(raw);
  if (m == null) return raw;
  final label = labels[m.group(1)!];
  if (label == null) return raw;
  // 前缀里 Dart 的 `Exception: ` 是噪声, 去掉; 其余前缀(哪个动作失败)保留
  final before = raw
      .substring(0, m.start)
      .replaceFirst(RegExp(r'Exception:\s*$'), '');
  final detail = raw.substring(m.end).trim();
  return detail.isEmpty ? '$before$label' : '$before$label: $detail';
}

class LoginSheet extends StatefulWidget {
  const LoginSheet({
    super.key,
    this.createQr,
    this.checkQr,
    this.sendSms,
    this.verifySms,
    this.commitCookie,
    this.onLoggedIn,
    this.pollInterval = const Duration(seconds: 2),
    this.resendCooldownSeconds = 60,
    this.openWebLogin,
  });

  /// 申请二维码(默认 rust.loginQrCreate)
  final Future<rust.QrLoginKey> Function()? createQr;

  /// 轮询一次(默认 rust.loginQrCheck)
  final Future<rust.QrLoginCheck> Function(String key)? checkQr;

  /// 发短信验证码(默认 rust.loginSmsSend)
  final Future<rust.SmsCodeSent> Function(String phone, String countryCode)?
  sendSms;

  /// 校验验证码并登录(默认 rust.loginSmsVerify)
  final Future<rust.PhoneLoginResult> Function(
    String phone,
    String code,
    String countryCode,
  )?
  verifySms;

  /// 导入 cookie(默认 rust.loginWithCookie)
  final Future<bool> Function(String cookie)? commitCookie;

  /// 登录成功后的宿主回调(同步账号资料 / 刷新登录态)
  final Future<void> Function()? onLoggedIn;

  /// 轮询间隔(测试可缩短)
  final Duration pollInterval;

  /// 短信重发冷却秒数(测试可设为 0)
  final int resendCooldownSeconds;

  /// 用系统浏览器打开官方登录页(可空: 测试/无实现时不显示按钮)
  final Future<void> Function()? openWebLogin;

  @override
  State<LoginSheet> createState() => LoginSheetState();
}

class LoginSheetState extends State<LoginSheet> {
  // 0 = 扫码, 1 = 手机号验证码, 2 = 导入 cookie
  int _tab = 0;

  rust.QrLoginKey? _qr;
  rust.QrLoginState _state = rust.QrLoginState.pending;
  String? _error;
  bool _creating = false;
  bool _committing = false;
  Timer? _timer;
  final _cookieCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _ccCtrl = TextEditingController(text: '86');
  final _codeCtrl = TextEditingController();
  bool _sending = false;
  bool _verifying = false;
  int _cooldown = 0;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    _startQr();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _cooldownTimer?.cancel();
    _cookieCtrl.dispose();
    _phoneCtrl.dispose();
    _ccCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<rust.QrLoginKey> Function() get _createQr =>
      widget.createQr ?? rust.loginQrCreate;

  Future<rust.QrLoginCheck> Function(String key) get _checkQr =>
      widget.checkQr ?? (key) => rust.loginQrCheck(key: key);

  Future<void> _startQr() async {
    _timer?.cancel();
    setState(() {
      _creating = true;
      _error = null;
      _state = rust.QrLoginState.pending;
    });
    try {
      final key = await _createQr();
      if (!mounted) return;
      setState(() {
        _qr = key;
        _creating = false;
      });
      _timer = Timer.periodic(widget.pollInterval, (_) => _tick());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error = '申请二维码失败: $e';
      });
    }
  }

  Future<void> _tick() async {
    final key = _qr;
    // 弹层已关闭 / 还没拿到 key / 用户切到别的登录方式时不再轮询
    if (key == null || !mounted || _tab != 0) return;
    try {
      final check = await _checkQr(key.key);
      if (!mounted) return;
      // 期间用户重新申请了新码: 丢弃这次结果
      if (_qr?.key != key.key) return;
      setState(() => _state = check.state);
      switch (check.state) {
        case rust.QrLoginState.confirmed:
          _timer?.cancel();
          await _finishLogin();
        case rust.QrLoginState.expired:
          _timer?.cancel();
        case rust.QrLoginState.failed:
          _timer?.cancel();
          setState(() => _error = '扫码失败(code=${check.code})');
        case rust.QrLoginState.pending:
        case rust.QrLoginState.scanned:
          break;
      }
    } catch (e) {
      if (!mounted) return;
      // 轮询失败(网络抖动)不当成登录失败, 下一轮继续; 连续失败由用户手动刷新
      setState(() => _error = null);
    }
  }

  Future<void> _finishLogin() async {
    try {
      await widget.onLoggedIn?.call();
    } catch (_) {
      // 同步资料失败不影响登录态(凭据已落盘)
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop(true);
    if (messenger != null) {
      showToastWith(messenger, '登录成功');
    }
  }

  Future<rust.SmsCodeSent> Function(String phone, String countryCode)
  get _sendSms =>
      widget.sendSms ??
      (phone, cc) => rust.loginSmsSend(phone: phone, countryCode: cc);

  Future<rust.PhoneLoginResult> Function(
    String phone,
    String code,
    String countryCode,
  )
  get _verifySms =>
      widget.verifySms ??
      (phone, code, cc) =>
          rust.loginSmsVerify(phone: phone, code: code, countryCode: cc);

  void _startCooldown(int seconds) {
    _cooldownTimer?.cancel();
    if (seconds <= 0) return;
    setState(() => _cooldown = seconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _cooldown -= 1);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _sendCode() async {
    final phone = _phoneCtrl.text.trim();
    if (phone.isEmpty) {
      setState(() => _error = '先填手机号');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final sent = await _sendSms(phone, _ccCtrl.text.trim());
      if (!mounted) return;
      setState(() => _sending = false);
      // 服务端说多久有效就按多久冷却, 下限用 resendCooldownSeconds(默认 60s,
      // 免得连点把号码打进频率限制; 测试传 0 时关掉冷却)
      final min = widget.resendCooldownSeconds;
      _startCooldown(
        min <= 0 ? 0 : (sent.expiresIn >= min ? sent.expiresIn : min),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = '发送验证码失败: $e';
      });
    }
  }

  Future<void> _phoneLogin() async {
    final phone = _phoneCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    if (phone.isEmpty) {
      setState(() => _error = '先填手机号');
      return;
    }
    if (code.isEmpty) {
      setState(() => _error = '先填收到的短信验证码');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      await _verifySms(phone, code, _ccCtrl.text.trim());
      if (!mounted) return;
      setState(() => _verifying = false);
      await _finishLogin();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = '登录失败: $e';
      });
    }
  }

  Future<void> _importCookie() async {
    final text = _cookieCtrl.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '先粘贴 cookie(MUSIC_U=...)');
      return;
    }
    setState(() {
      _committing = true;
      _error = null;
    });
    try {
      final commit = widget.commitCookie ?? rust.loginWithCookie;
      final ok = await commit(text);
      if (!mounted) return;
      setState(() => _committing = false);
      if (!ok) {
        setState(() => _error = 'cookie 里没有 MUSIC_U, 登录未生效');
        return;
      }
      await _finishLogin();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _committing = false;
        _error = '导入失败: $e';
      });
    }
  }

  String get _statusText {
    switch (_state) {
      case rust.QrLoginState.scanned:
        return '已扫码, 请在手机上点「确认登录」';
      case rust.QrLoginState.expired:
        return '二维码已过期, 点「刷新二维码」重来';
      case rust.QrLoginState.failed:
        return '扫码失败, 请重试';
      case rust.QrLoginState.confirmed:
        return '登录成功';
      case rust.QrLoginState.pending:
        return '等待扫码…';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      // 键盘避让: 导入 cookie 时输入框不被挡住
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SheetHeader(
                title: '登录网易云账号',
                onClose: () => Navigator.of(context).pop(false),
              ),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('扫码登录')),
                  ButtonSegment(value: 1, label: Text('手机号登录')),
                  ButtonSegment(value: 2, label: Text('导入 Cookie')),
                ],
                selected: {_tab},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _tab = v.first),
              ),
              const SizedBox(height: 16),
              if (_tab == 0)
                ..._qrTab(theme)
              else if (_tab == 1)
                ..._phoneTab(theme)
              else
                ..._cookieTab(theme),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  friendlyLoginError(_error!),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _qrTab(ThemeData theme) {
    final qr = _qr;
    return [
      Center(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: _creating || qr == null
              ? const SizedBox(width: 200, height: 200, child: LoadingView())
              : Opacity(
                  // 过期/失败时灰掉二维码, 避免用户扫一个无效码
                  opacity:
                      (_state == rust.QrLoginState.expired ||
                          _state == rust.QrLoginState.failed)
                      ? 0.25
                      : 1,
                  child: QrImageView(
                    data: qr.url,
                    size: 200,
                    padding: EdgeInsets.zero,
                    backgroundColor: Colors.white,
                  ),
                ),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        _statusText,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium,
      ),
      const SizedBox(height: 4),
      Text(
        '手机打开网易云音乐 → 右上角「扫一扫」. 这是官方网页登录通道, 不在本机保存密码.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 12),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton.icon(
            onPressed: _creating ? null : _startQr,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新二维码'),
          ),
          if (widget.openWebLogin != null)
            TextButton.icon(
              onPressed: widget.openWebLogin,
              icon: const Icon(Icons.open_in_browser),
              label: const Text('在浏览器打开登录页'),
            ),
        ],
      ),
    ];
  }

  List<Widget> _phoneTab(ThemeData theme) {
    final busy = _sending || _verifying;
    final hint = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // 命中风控(8821)时不要只甩一个 code, 直接把用户引回已知稳路径
    final risk = (_error ?? '').contains('riskControl');
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: TextField(
              controller: _ccCtrl,
              enabled: !busy,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              decoration: const InputDecoration(
                labelText: '区号',
                prefixText: '+',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _phoneCtrl,
              enabled: !busy,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(15),
              ],
              decoration: const InputDecoration(
                labelText: '手机号',
                hintText: '13800138000',
                helperText: '区号 + 号码, 只填数字',
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _codeCtrl,
              enabled: !busy,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(8),
              ],
              onSubmitted: (_) => _phoneLogin(),
              decoration: const InputDecoration(
                labelText: '短信验证码',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 56,
            child: OutlinedButton(
              onPressed: (_sending || _cooldown > 0 || _verifying)
                  ? null
                  : _sendCode,
              child: Text(
                _cooldown > 0
                    ? '${_cooldown}s 后重发'
                    : (_sending ? '发送中…' : '获取验证码'),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _verifying ? null : _phoneLogin,
        child: _verifying
            ? const LoadingView.inline(size: 18)
            : const Text('登录'),
      ),
      const SizedBox(height: 8),
      Text(
        '验证码由网易云下发, 本机不保存密码; 走的是官方网页登录通道(与扫码同一族), 不是 App 原生登录.',
        textAlign: TextAlign.center,
        style: hint,
      ),
      if (risk) ...[
        const SizedBox(height: 6),
        Text(
          '这次命中网易云的安全风控(8821), 手机号登录暂时走不通 —— 请改用「扫码登录」, 那条路是已知稳路径.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ],
    ];
  }

  List<Widget> _cookieTab(ThemeData theme) {
    return [
      TextField(
        controller: _cookieCtrl,
        minLines: 3,
        maxLines: 6,
        enabled: !_committing,
        smartQuotesType: SmartQuotesType.disabled,
        smartDashesType: SmartDashesType.disabled,
        autocorrect: false,
        enableSuggestions: false,
        style: theme.textTheme.bodySmall,
        decoration: const InputDecoration(
          labelText: 'Cookie',
          hintText: 'MUSIC_U=...; __csrf=...',
          border: OutlineInputBorder(),
          helperText:
              '浏览器登录 music.163.com 后, F12 → Application → Cookies 复制 MUSIC_U',
          helperMaxLines: 2,
        ),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _committing ? null : _importCookie,
        child: _committing
            ? const LoadingView.inline(size: 18)
            : const Text('导入并登录'),
      ),
    ];
  }
}

/// 打开登录弹层; 返回是否登录成功.
Future<bool> showLoginSheet(
  BuildContext context, {
  Future<rust.QrLoginKey> Function()? createQr,
  Future<rust.QrLoginCheck> Function(String key)? checkQr,
  Future<rust.SmsCodeSent> Function(String phone, String countryCode)? sendSms,
  Future<rust.PhoneLoginResult> Function(
    String phone,
    String code,
    String countryCode,
  )?
  verifySms,
  Future<bool> Function(String cookie)? commitCookie,
  Future<void> Function()? onLoggedIn,
  Future<void> Function()? openWebLogin,
  Duration pollInterval = const Duration(seconds: 2),
  int resendCooldownSeconds = 60,
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => LoginSheet(
      createQr: createQr,
      checkQr: checkQr,
      sendSms: sendSms,
      verifySms: verifySms,
      commitCookie: commitCookie,
      onLoggedIn: onLoggedIn,
      openWebLogin: openWebLogin,
      pollInterval: pollInterval,
      resendCooldownSeconds: resendCooldownSeconds,
    ),
  );
  return ok == true;
}
