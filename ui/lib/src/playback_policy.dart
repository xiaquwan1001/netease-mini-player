/// 播放策略的纯函数部分: "这首歌要不要按当前设置跳过"。
///
/// 为什么单独抽出来: 跳过规则原先写在 main.dart 的私有方法里, 只能靠跑整机验证;
/// 抽成纯函数后可以用任意 SongDto 组合做单测(尤其是 fee=1 / fee=4 / playable=false
/// 这几个容易混的口径), 也让 main 的循环只剩"怎么跳"而不含"为什么跳"。
library;

import 'rust/api.dart' as rust;

/// 需要黑胶会员才能完整播放(`fee == 1`), Rust 侧映射成 [rust.SongDto.vip]。
bool requiresVip(rust.SongDto song) => song.vip;

/// 需要单独购买的数字专辑曲目(`fee == 4`), 与 VIP 是两回事, 不在此策略范围内。
bool requiresPurchase(rust.SongDto song) => song.paid;

/// 当前设置下是否要跳过这首歌。
///
/// 只跳"会员曲目": 无版权曲目由 `playable == false` 在取链前就拦掉了,
/// 数字专辑(fee=4)也不跳(用户可能已经买过, 取链会成功)。
bool shouldSkipVipSong(rust.SongDto song, {required bool skipVipEnabled}) =>
    skipVipEnabled && requiresVip(song);
