/// Linux **AppImage** 的「集成到应用菜单」首启提示(平台审计 §11.A-2)。
///
/// 背景: `.deb` 由包管理器装 `/usr/share/applications/<id>.desktop`, 装完就在菜单里;
/// AppImage 是**单文件**, 双击能跑但菜单里没有入口, 也没有图标缓存。
/// 这里在首次启动时问一次, 用户同意就写两份**用户级**文件(不需要 root):
///
/// - `~/.local/share/applications/<appId>.desktop`
/// - `~/.local/share/icons/hicolor/256x256/apps/minincm.png`
///
/// 判据与文案都是纯函数([shouldOfferDesktopIntegration] / [buildIntegratedDesktopEntry]
/// / [quoteDesktopExec]), IO 只在 [desktopIntegrationPending] 与
/// [installDesktopIntegration] 里, 便于单测(不碰真实 HOME)。
library;

import 'dart:io';

/// 与 CMake / deb / AppImage / AppStream 共用的 application-id。
/// 改这里必须同步 `ui/linux/CMakeLists.txt`、`packaging/linux/build-appimage.sh`、
/// `packaging/linux/build-deb.sh`(P-18 后已统一到这一份)。
const String kDesktopAppId = 'io.github.xiaquwan1001.MiniNCM';

/// desktop entry 里的图标名(= 装进 hicolor 目录的文件名主干)。
const String kDesktopIconName = 'minincm';

/// 询问过(用户拒绝)之后落的标记文件, 免得每次启动都弹一次。
const String kDesktopIntegrationMarker = 'desktop-integration.asked';

/// 用户级 desktop 文件路径。
String userDesktopEntryPath(String home) =>
    '$home/.local/share/applications/$kDesktopAppId.desktop';

/// 用户级图标路径(hicolor 256x256)。
String userIconPath(String home) =>
    '$home/.local/share/icons/hicolor/256x256/apps/$kDesktopIconName.png';

/// 询问标记文件路径(放项目数据目录, 与 play_state.json 等本地状态同处)。
String desktopIntegrationMarkerPath(String dataDir) =>
    '$dataDir/$kDesktopIntegrationMarker';

/// AppDir 里随包附带的图标路径(基于正在运行的可执行文件)。
///
/// AppRun 执行的是 `$APPDIR/usr/bin/minincm`, 所以 `../share/icons/...` 就是
/// AppDir 内的图标; 非 AppImage(源码运行/deb)时这个路径不存在, 调用方据此降级。
String bundledIconPath(String executablePath) {
  final dir = File(executablePath).parent.path; // .../usr/bin
  return '$dir/../share/icons/hicolor/256x256/apps/$kDesktopIconName.png';
}

/// 是否该弹「集成到应用菜单」:
/// - 只有 AppImage 才问(`APPIMAGE` 环境变量由 AppImage 运行时注入);
/// - 已经装过 desktop 文件就不问(重复启动不骚扰);
/// - 拒绝过(有标记)就不再问。
bool shouldOfferDesktopIntegration({
  required String? appImagePath,
  required bool desktopEntryExists,
  required bool askedBefore,
}) {
  if (appImagePath == null || appImagePath.isEmpty) return false;
  if (desktopEntryExists) return false;
  if (askedBefore) return false;
  return true;
}

/// desktop spec 的 `Exec` 参数转义: 含空格/引号/反斜杠的路径必须整体加双引号。
String quoteDesktopExec(String path) {
  if (path.isEmpty) return '""';
  final needsQuote = path.contains(RegExp(r'[\s"\\$`]'));
  if (!needsQuote) return path;
  final escaped = path
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('`', r'\`')
      .replaceAll(r'$', r'\$');
  return '"$escaped"';
}

/// 生成要装进 `~/.local/share/applications` 的 desktop entry。
///
/// 为什么自己拼而不是照抄 AppDir 里那份: 包内那份写的是 `Exec=minincm %U`,
/// 只有 deb 安装后 `minincm` 才在 PATH 上; AppImage 必须写**绝对路径**,
/// 而绝对路径每台机器都不同(用户把 AppImage 放在哪都有可能)。
String buildIntegratedDesktopEntry({
  required String execPath,
  String? version,
}) {
  final buf = StringBuffer()
    ..writeln('[Desktop Entry]')
    ..writeln('Type=Application')
    ..writeln('Name=轻音 MiniNCM')
    ..writeln('Name[en]=MiniNCM')
    ..writeln('Name[zh_CN]=轻音 MiniNCM')
    ..writeln('GenericName=Music Player')
    ..writeln('GenericName[zh_CN]=音乐播放器')
    ..writeln('Comment=网易云音乐第三方客户端')
    ..writeln('Comment[en]=A third-party NetEase Cloud Music client')
    ..writeln('Exec=${quoteDesktopExec(execPath)} %U')
    ..writeln('Icon=$kDesktopIconName')
    ..writeln('Terminal=false')
    ..writeln('Categories=AudioVideo;Audio;Player;')
    ..writeln('Keywords=music;netease;ncm;')
    ..writeln('StartupWMClass=$kDesktopAppId');
  if (version != null && version.isNotEmpty) {
    buf.writeln('X-AppImage-Version=$version');
  }
  return buf.toString();
}

/// 该不该问 + 要用的 AppImage 路径。null = 什么都不做。
class DesktopIntegrationPending {
  const DesktopIntegrationPending({required this.appImagePath});

  /// 正在运行的 AppImage 绝对路径(`APPIMAGE` 环境变量)。
  final String appImagePath;
}

/// 探测是否需要弹首启提示(只读几个 stat, 不写任何东西)。
///
/// [env] / [home] / [dataDir] 全部可注入, 便于单测。
Future<DesktopIntegrationPending?> desktopIntegrationPending({
  required String dataDir,
  Map<String, String>? env,
  String? home,
}) async {
  if (!Platform.isLinux) return null;
  final e = env ?? Platform.environment;
  final appImage = e['APPIMAGE'];
  if (appImage == null || appImage.isEmpty) return null;
  final h = home ?? e['HOME'];
  if (h == null || h.isEmpty) return null;
  final desktopExists = await File(userDesktopEntryPath(h)).exists();
  final asked = await File(desktopIntegrationMarkerPath(dataDir)).exists();
  if (!shouldOfferDesktopIntegration(
    appImagePath: appImage,
    desktopEntryExists: desktopExists,
    askedBefore: asked,
  )) {
    return null;
  }
  // AppImage 内的图标缺失时也能装(只是菜单里没有图标), 不阻塞提示。
  return DesktopIntegrationPending(appImagePath: appImage);
}

/// 安装结果: 失败不抛异常(首启提示不该因为写文件失败而崩)。
class DesktopIntegrationResult {
  const DesktopIntegrationResult({
    required this.ok,
    required this.desktopPath,
    required this.iconInstalled,
    this.error,
  });

  final bool ok;
  final String desktopPath;
  final bool iconInstalled;
  final String? error;
}

/// 写用户级 desktop 文件 + 图标(幂等), 再尽力刷新桌面数据库。
///
/// 不调用 `desktop-file-install`: 那是 `desktop-file-utils` 的二进制, 各发行版
/// 不保证存在; 写文件 + 可选 `update-desktop-database` 的效果一样且无依赖。
Future<DesktopIntegrationResult> installDesktopIntegration({
  required String appImagePath,
  required String home,
  String? executablePath,
  String? version,
  bool refreshDatabase = true,
}) async {
  final desktopPath = userDesktopEntryPath(home);
  try {
    final desktopFile = File(desktopPath);
    await desktopFile.parent.create(recursive: true);
    await desktopFile.writeAsString(
      buildIntegratedDesktopEntry(execPath: appImagePath, version: version),
      flush: true,
    );

    var iconInstalled = false;
    final src = File(
      bundledIconPath(executablePath ?? Platform.resolvedExecutable),
    );
    if (await src.exists()) {
      final dst = File(userIconPath(home));
      await dst.parent.create(recursive: true);
      await dst.writeAsBytes(await src.readAsBytes(), flush: true);
      iconInstalled = true;
    }

    if (refreshDatabase) {
      // 纯尽力而为: 没有这个命令/超时/非零退出都无所谓, GNOME/KDE 也会自己扫。
      try {
        await Process.run('update-desktop-database', [
          '$home/.local/share/applications',
        ]).timeout(const Duration(seconds: 5));
      } on Object {
        // 忽略
      }
    }
    return DesktopIntegrationResult(
      ok: true,
      desktopPath: desktopPath,
      iconInstalled: iconInstalled,
    );
  } on Object catch (e) {
    return DesktopIntegrationResult(
      ok: false,
      desktopPath: desktopPath,
      iconInstalled: false,
      error: '$e',
    );
  }
}

/// 用户拒绝(或安装失败)后落标记, 保证只问一次。
Future<void> markDesktopIntegrationAsked(String dataDir) async {
  try {
    final f = File(desktopIntegrationMarkerPath(dataDir));
    await f.parent.create(recursive: true);
    await f.writeAsString('asked', flush: true);
  } on Object {
    // 标记写不进去最多再问一次, 不是错误
  }
}
