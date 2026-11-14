import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 选一个本地音频文件用于云盘上传, 返回**本地绝对路径**(取消/不支持时 null)。
///
/// - Android: 走 `ncm/upload#pickAudio`(MainActivity 里 ACTION_OPEN_DOCUMENT),
///   原生侧把 content:// 复制到 cacheDir/cloud_upload/ 再返回路径 —— Rust 只认本地路径;
/// - Linux: 依次尝试 zenity / kdialog 的文件选择框(发行版通常至少有一个);
/// - Windows: 用 PowerShell 的 System.Windows.Forms.OpenFileDialog;
/// - 都不可用就返回 null, 调用方提示"当前平台不支持选择文件"。
Future<String?> pickAudioFile() async {
  if (kIsWeb) return null;
  if (Platform.isAndroid) {
    const channel = MethodChannel('ncm/upload');
    final path = await channel.invokeMethod<String>('pickAudio');
    return (path == null || path.isEmpty) ? null : path;
  }
  if (Platform.isLinux) {
    final zenity = await _tryRun('zenity', [
      '--file-selection',
      '--title=选择要上传的音频',
      '--file-filter=音频文件 | *.mp3 *.flac *.m4a *.aac *.wav *.ogg',
    ]);
    if (zenity != null) return zenity;
    return _tryRun('kdialog', [
      '--getopenfilename',
      '.',
      '音频文件 (*.mp3 *.flac *.m4a *.aac *.wav *.ogg)',
    ]);
  }
  if (Platform.isWindows) {
    return _tryRun('powershell', [
      '-NoProfile',
      '-Command',
      r"Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.OpenFileDialog; $d.Filter = '音频文件|*.mp3;*.flac;*.m4a;*.aac;*.wav;*.ogg'; if ($d.ShowDialog() -eq 'OK') { Write-Output $d.FileName }",
    ]);
  }
  return null;
}

/// 跑一个系统对话框命令, 成功返回非空 stdout(第一行), 失败/取消返回 null。
Future<String?> _tryRun(String exe, List<String> args) async {
  try {
    final result = await Process.run(exe, args);
    if (result.exitCode != 0) return null;
    final text = (result.stdout as String).trim();
    if (text.isEmpty) return null;
    return text.split('\n').first.trim();
  } on ProcessException {
    return null;
  }
}
