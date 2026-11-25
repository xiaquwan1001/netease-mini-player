/// 「当前进程是不是 Android」的唯一入口(D14)。
///
/// 原来 8 个文件各写一份, 组成还各不相同(有的带测试注入开关, 有的特意换成
/// `defaultTargetPlatform`), 于是"加一个平台判定"要改 8 处, 而且必然漏。
///
/// 生产判据是 **dart:io 的 [Platform.isAndroid]**, 不是 Flutter 的
/// `defaultTargetPlatform`: 后者在 widget 测试里默认就是 android, 会把"没有
/// Android 通道/没有 Kotlin 实现"的桌面与测试树误判成手机(设置页「关闭主窗口」
/// 整块就踩过: 测试里整块被当成手机而整段消失)。
///
/// 用法:
/// - 生产判定 → [isAndroidPlatform];
/// - 测试想验 Android 分支 → 置 [debugForceAndroid] = true(host 上
///   `Platform.isAndroid` 恒为 false, 只能靠它; 用完记得复位);
/// - 唯一例外是 [usesDefaultTargetPlatformAndroid](只有 `image_io.dart` 用, 见那里的解释)。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;

/// 测试注入: 在非 Android 宿主上强制走 Android 分支。
@visibleForTesting
bool debugForceAndroid = false;

/// 当前进程是不是 Android(生产判定 `!kIsWeb && Platform.isAndroid`)。
bool get isAndroidPlatform =>
    (!kIsWeb && Platform.isAndroid) || debugForceAndroid;

/// 同上, 但判据换成框架的 [defaultTargetPlatform]。
///
/// 只有 `image_io.dart`(保存图片走哪条路)用它, 而且是**刻意**的: 两个判据在真机/
/// 桌面产物上等价, 差别只在测试 —— [defaultTargetPlatform] 能被
/// `debugDefaultTargetPlatformOverride` 覆盖, 这是「默认保存实现」回归测试
/// (不注入保存实现 + mock `ncm/share` 通道, 见 `test/detail_faces_test.dart`)
/// 能在 Linux 宿主上真正跑到 Android 分支的唯一入口; 否则那条路永远走桌面分支(会写真磁盘)。
///
/// **刻意不读 [debugForceAndroid]**: 那份测试的开关是框架的 override, 两个开关混在
/// 一起就说不清"到底哪条路被强制了"。
bool get usesDefaultTargetPlatformAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
