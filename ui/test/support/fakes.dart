// 测试公共工厂: 只放"确实被多个测试文件重复定义"的 DTO 构造,
// 避免每个测试文件再抄一份 12 个字段的 SongDto 字面量。
//
// 用法:
//   import 'support/fakes.dart';
//   final song = fakeSong(id: 7, name: '晴天');
//
// 默认值取"最常见的测试口径": 艺人/专辑/1 秒/免费/无 VIP/可播。
// 需要的字段用命名参数覆盖, 不要再复制第二份字面量。
import 'package:minincm/src/rust/api.dart' as rust;

/// 歌曲 DTO 假数据。
///
/// 默认: id=1, name='晴天', artist='艺人', album='专辑', 时长 1 秒, 免费可播。
/// [artistId] / [albumId] 为 0 表示"未知"(与 Rust 侧注释一致)。
rust.SongDto fakeSong({
  int id = 1,
  String name = '晴天',
  String artist = '艺人',
  int artistId = 1,
  String album = '专辑',
  int albumId = 1,
  String? coverUrl,
  int durationMs = 1000,
  int fee = 0,
  bool vip = false,
  bool paid = false,
  bool playable = true,
}) => rust.SongDto(
  id: BigInt.from(id),
  name: name,
  artist: artist,
  artistId: BigInt.from(artistId),
  album: album,
  albumId: BigInt.from(albumId),
  coverUrl: coverUrl,
  durationMs: BigInt.from(durationMs),
  fee: fee,
  vip: vip,
  paid: paid,
  playable: playable,
);
