import 'package:flutter/material.dart';

import 'src/app_shell.dart';
import 'src/rust/frb_generated.dart';

export 'src/app_shell.dart';
export 'src/back_policy.dart';
export 'src/home/home_page.dart' show HomePage;
export 'src/lyric_source.dart';
export 'src/notification_mode.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MiniNcmApp());
}
