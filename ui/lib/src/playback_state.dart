import 'dart:convert';
import 'dart:io';

import 'queue.dart' show PlayMode;
import 'rust/api.dart' as rust;

/// 退出 App 时的"播放现场"(队列 + 当前曲 + 位置), 下次启动恢复。
///
/// 为什么单独抽文件: 序列化/反序列化要能被单测覆盖(坏 JSON / 字段缺失 / 越界
/// 下标都不能让启动崩), 而 main.dart 里的 HomePage 太大, 不适合再塞实现细节。
/// 只存"恢复 UI 与续播"必需的东西, 不放直链(直链短时效, 恢复时重新取)。
class SavedPlayback {
  const SavedPlayback({
    required this.songs,
    required this.index,
    required this.positionMs,
    this.mode = PlayMode.repeatAll,
    this.libraryTitle,
  });

  /// 队列快照(顺序即播放顺序)
  final List<rust.SongDto> songs;

  /// 当前曲在 [songs] 里的下标(已钳到合法范围)
  final int index;

  /// 上次退出时的播放位置(毫秒)
  final int positionMs;

  /// 播放顺序(循环/随机/单曲)
  final PlayMode mode;

  /// 列表来源标题("正在播放"/歌单名), 恢复列表时沿用
  final String? libraryTitle;

  rust.SongDto get current => songs[index];

  /// 队列条目上限: 收藏几千首的歌单也不该把状态文件写成几 MB
  static const int maxSongs = 500;
}

/// JSON 里的值一律当字符串解析(null/数字都能吃)
String _asText(Object? value) => value == null ? '' : value.toString();

/// SongDto → JSON(只存恢复所需字段; 直链不存)。
Map<String, Object?> songToJson(rust.SongDto song) => {
  'id': song.id.toString(),
  'name': song.name,
  'artist': song.artist,
  'artistId': song.artistId.toString(),
  'album': song.album,
  'albumId': song.albumId.toString(),
  'coverUrl': song.coverUrl,
  'durationMs': song.durationMs.toString(),
  'fee': song.fee.toInt(),
  'vip': song.vip,
  'paid': song.paid,
  'playable': song.playable,
};

/// JSON → SongDto。缺字段一律给安全默认值(坏条目宁可变成不可播, 也不要抛)。
rust.SongDto? songFromJson(Object? raw) {
  if (raw is! Map) return null;
  final id = BigInt.tryParse(_asText(raw['id']));
  if (id == null || id <= BigInt.zero) return null;
  BigInt big(String key) => BigInt.tryParse(_asText(raw[key])) ?? BigInt.zero;
  final fee = raw['fee'];
  return rust.SongDto(
    id: id,
    name: _asText(raw['name']),
    artist: _asText(raw['artist']),
    artistId: big('artistId'),
    album: _asText(raw['album']),
    albumId: big('albumId'),
    coverUrl: raw['coverUrl'] is String ? raw['coverUrl'] as String : null,
    durationMs: big('durationMs'),
    fee: fee is num ? fee.toInt() : 0,
    vip: raw['vip'] == true,
    paid: raw['paid'] == true,
    playable: raw['playable'] != false,
  );
}

/// 把现场编码成 JSON 文本(纯函数, 单测用)。
String encodePlayback(SavedPlayback state) => jsonEncode({
  'version': 1,
  'index': state.index,
  'positionMs': state.positionMs,
  'mode': state.mode.name,
  'libraryTitle': state.libraryTitle,
  'songs': [
    for (final song in state.songs.take(SavedPlayback.maxSongs))
      songToJson(song),
  ],
});

/// JSON 文本 → 现场。任何异常/空队列都返回 null(启动流程不该被脏文件打断)。
SavedPlayback? decodePlayback(String text) {
  Object? root;
  try {
    root = jsonDecode(text);
  } catch (_) {
    return null;
  }
  if (root is! Map) return null;
  final rawSongs = root['songs'];
  if (rawSongs is! List || rawSongs.isEmpty) return null;
  final songs = <rust.SongDto>[];
  for (final raw in rawSongs) {
    final song = songFromJson(raw);
    // 恢复的是"列表", 重复条目会让队列下标和 UI 对不上, 直接去掉
    if (song != null && !songs.any((s) => s.id == song.id)) songs.add(song);
  }
  if (songs.isEmpty) return null;
  final rawIndex = root['index'];
  final index = rawIndex is num ? rawIndex.toInt().clamp(0, songs.length - 1) : 0;
  final rawPosition = root['positionMs'];
  final positionMs = rawPosition is num
      ? rawPosition.toInt().clamp(0, 1 << 40)
      : 0;
  final modeName = root['mode'];
  final mode = PlayMode.values.firstWhere(
    (m) => m.name == modeName,
    orElse: () => PlayMode.repeatAll,
  );
  final title = root['libraryTitle'];
  return SavedPlayback(
    songs: songs,
    index: index,
    positionMs: positionMs,
    mode: mode,
    libraryTitle: title is String && title.isNotEmpty ? title : null,
  );
}

/// 现场文件读写: dataDir/play_state.json(先写 .tmp 再 rename, 掉电不留半个文件)。
class PlaybackStateStore {
  PlaybackStateStore(this.dataDir);

  final String dataDir;

  static const fileName = 'play_state.json';

  File get _file => File('$dataDir/$fileName');

  /// 读不到/坏文件/未写过都返回 null。
  Future<SavedPlayback?> load() async {
    if (dataDir.isEmpty) return null;
    try {
      if (!await _file.exists()) return null;
      return decodePlayback(await _file.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// 保存(失败静默: 状态记忆是锦上添花, 绝不能因为写盘失败影响播放)。
  Future<void> save(SavedPlayback state) async {
    if (dataDir.isEmpty) return;
    try {
      await Directory(dataDir).create(recursive: true);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(encodePlayback(state), flush: true);
      await tmp.rename(_file.path);
    } catch (_) {}
  }

  /// 用户清空队列/退出登录时抹掉现场。
  Future<void> clear() async {
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {}
  }
}
