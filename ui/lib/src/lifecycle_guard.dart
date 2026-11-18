import 'package:flutter/widgets.dart';

/// 帧后回调 + 存活守卫(U-05): 只让**还挂在树上**的页面执行回调。
///
/// 为什么需要: 底部导航 / 播放条 / 全局"正在播放"这些槽位都在 Navigator 之外,
/// 投递必须在帧后(`addPostFrameCallback`)做 —— 在 build 里同步写
/// [ValueNotifier] 等于 markNeedsBuild 祖先, 报 "setState() called during build"。
/// 但帧后回调已经脱离了 build 的上下文: 页面在这之间被销毁时, 回调仍会把
/// **已销毁实例**的闭包写进全局槽位(播放条/列表高亮从此读到死页面的状态)。
///
/// 判据用 [BuildContext.mounted](Element 一旦 unmount 就是 false, 与 `State.mounted`
/// 等价), 所以这里统一收一个 context, 各调用点不再各写一遍守卫。
///
/// 用法(与 [WidgetsBinding.addPostFrameCallback] 同形, 只多一个存活的判据):
/// ```dart
/// runPostFrameIfAlive(context, () => playerBarData.value = data);
/// ```
void runPostFrameIfAlive(BuildContext context, VoidCallback callback) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    callback();
  });
}
