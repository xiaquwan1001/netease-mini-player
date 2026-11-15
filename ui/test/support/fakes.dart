// 测试公共工厂: 只放"确实被多个测试文件重复定义"的 DTO 构造,
// 避免每个测试文件再抄一份 SongDto / Playlist / PodcastRadio 字面量。
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

/// 歌单 DTO 假数据(7 个测试文件各自抄过一份同形状的 playlist())。
///
/// 默认: id=1, name='歌单', 3 首, 非"我喜欢"、非收藏。
rust.Playlist fakePlaylist({
  int id = 1,
  String name = '歌单',
  String? coverUrl,
  int trackCount = 3,
  bool special = false,
  bool subscribed = false,
}) => rust.Playlist(
  id: BigInt.from(id),
  name: name,
  coverUrl: coverUrl,
  trackCount: BigInt.from(trackCount),
  special: special,
  subscribed: subscribed,
);

/// 电台 DTO 假数据(4 个测试文件各自抄过一份同形状的 radio())。
///
/// 默认: id=1, name='电台', 主播'主播', 2 期节目, 0 播放。
rust.PodcastRadio fakeRadio({
  int id = 1,
  String name = '电台',
  String? coverUrl,
  String description = '',
  String djName = '主播',
  int programCount = 2,
  int playCount = 0,
}) => rust.PodcastRadio(
  id: BigInt.from(id),
  name: name,
  coverUrl: coverUrl,
  description: description,
  djName: djName,
  programCount: BigInt.from(programCount),
  playCount: BigInt.from(playCount),
);
