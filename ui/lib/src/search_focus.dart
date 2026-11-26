import 'package:flutter/foundation.dart';

/// 全局「聚焦搜索框」请求槽位(Ctrl+F / `/`)。
///
/// 与 `playerBarSlot` 同一类进程级槽位: 键事件在 `HardwareKeyboard` 那一层处理,
/// 那里没有页面 `BuildContext`, 所以 HOME 页把"聚焦搜索"这件事投递到这里
/// (写入方: `home/home_wiring.dart` 的 `_installSlots` / `_clearSlots`,
/// 门禁 tools/check-global-slots.sh 会拦住别处直写)。
///
/// 没有监听者(键事件时才读), 所以不需要帧后投递; 页面销毁时置 null 即可。
final ValueNotifier<VoidCallback?> searchFocusSlot =
    ValueNotifier<VoidCallback?>(null);
