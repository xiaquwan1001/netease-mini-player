import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/playback_state.dart';
import 'package:minincm/src/queue.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/settings_view.dart';

rust.SongDto _song(int id, {String? cover}) => rust.SongDto(
  id: BigInt.from(id),
  name: '歌曲 $id',
  artist: '歌手 $id',
  artistId: BigInt.from(1000 + id),
  album: '专辑 $id',
  albumId: BigInt.from(2000 + id),
  coverUrl: cover,
  durationMs: BigInt.from(200000 + id),
  fee: 0,
  vip: id.isOdd,
  paid: false,
  playable: true,
);

void main() {
  group('状态记忆: 播放现场序列化', () {
    test('往返: 队列/下标/位置/模式/标题都保住', () {
      final state = SavedPlayback(
        songs: [
          _song(1),
          _song(2, cover: 'http://p1.music.126.net/a.jpg'),
        ],
        index: 1,
        positionMs: 42000,
        mode: PlayMode.shuffle,
        libraryTitle: '我喜欢的音乐',
      );
      final back = decodePlayback(encodePlayback(state))!;
      expect(back.songs.length, 2);
      expect(back.current.id, BigInt.from(2));
      expect(back.current.coverUrl, 'http://p1.music.126.net/a.jpg');
      expect(back.current.vip, isFalse);
      expect(back.songs.first.vip, isTrue);
      expect(back.index, 1);
      expect(back.positionMs, 42000);
      expect(back.mode, PlayMode.shuffle);
      expect(back.libraryTitle, '我喜欢的音乐');
    });

    test('坏 JSON / 空队列 / 非对象 一律返回 null(启动流程不能被打断)', () {
      expect(decodePlayback(''), isNull);
      expect(decodePlayback('{'), isNull);
      expect(decodePlayback('[1,2,3]'), isNull);
      expect(decodePlayback('{"songs":[]}'), isNull);
      expect(decodePlayback('{"songs":[{"name":"没有 id"}]}'), isNull);
    });

    test('下标越界 / 负数位置被钳住; 重复曲目去重; 未知模式回落列表循环', () {
      final json =
          '{"index":99,"positionMs":-5,"mode":"nope",'
          '"songs":[{"id":"7","name":"a"},{"id":"7","name":"a"},{"id":"8","name":"b"}]}';
      final back = decodePlayback(json)!;
      expect(back.songs.length, 2, reason: '重复 id 要去掉, 否则队列下标对不上');
      expect(back.index, 1);
      expect(back.positionMs, 0);
      expect(back.mode, PlayMode.repeatAll);
    });

    test('缺字段的曲目按不可播处理, 不抛异常', () {
      final back = decodePlayback('{"songs":[{"id":"5"}]}')!;
      final song = back.current;
      expect(song.name, '');
      expect(song.durationMs, BigInt.zero);
      expect(song.vip, isFalse);
      expect(song.playable, isTrue);
    });

    test('落盘/读取/清除: play_state.json 往返', () async {
      final dir = await Directory.systemTemp.createTemp('ncm-play-state');
      addTearDown(() => dir.delete(recursive: true));
      final store = PlaybackStateStore(dir.path);
      expect(await store.load(), isNull);

      await store.save(
        SavedPlayback(songs: [_song(3)], index: 0, positionMs: 1234),
      );
      final back = await store.load();
      expect(back, isNotNull);
      expect(back!.current.id, BigInt.from(3));
      expect(back.positionMs, 1234);
      expect(File('${dir.path}/play_state.json').existsSync(), isTrue);

      await store.clear();
      expect(await store.load(), isNull);
    });
  });

  group('设置: 主题模式三档 + 独立「纯黑 (OLED)」开关', () {
    final settings = AppSettings.instance;
    late ThemeMode beforeMode;
    late bool beforeOled;
    setUp(() {
      beforeMode = settings.themeMode;
      beforeOled = settings.oledDark;
    });
    tearDown(() {
      settings.update(themeMode: beforeMode, oledDark: beforeOled);
    });

    test('三档 → themeMode 映射与回读一致, 且切档不覆写 oledDark', () {
      settings.update(themeMode: ThemeMode.dark, oledDark: true);

      applyThemeChoice(settings, ThemeChoice.system);
      expect(settings.themeMode, ThemeMode.system);
      expect(themeChoiceOf(settings), ThemeChoice.system);
      // 关键回归: 切到「跟随系统」不得把纯黑关掉(二者正交)
      expect(settings.oledDark, isTrue);

      applyThemeChoice(settings, ThemeChoice.light);
      expect(settings.themeMode, ThemeMode.light);
      expect(themeChoiceOf(settings), ThemeChoice.light);
      expect(settings.oledDark, isTrue);

      applyThemeChoice(settings, ThemeChoice.dark);
      expect(settings.themeMode, ThemeMode.dark);
      expect(themeChoiceOf(settings), ThemeChoice.dark);
      expect(settings.oledDark, isTrue);
    });

    test('跟随系统 + 纯黑可同时为真', () {
      applyThemeChoice(settings, ThemeChoice.system);
      settings.update(oledDark: true);
      expect(themeChoiceOf(settings), ThemeChoice.system);
      expect(settings.oledDark, isTrue);
    });

    test('旧配置(oledDark=true 且 themeMode=dark)显示为「深色 + 纯黑开」', () {
      settings.update(themeMode: ThemeMode.dark, oledDark: true);
      expect(themeChoiceOf(settings), ThemeChoice.dark);
      expect(settings.oledDark, isTrue);
    });

    test('纯黑只在深色基底生效, 浅色档不改 themeMode', () {
      // 深色基底(深色档 / 跟随系统且系统深色)才吃 oledDark
      expect(
        isOledDarkEffective(
          themeMode: ThemeMode.dark,
          platformBrightness: Brightness.light,
        ),
        isTrue,
      );
      expect(
        isOledDarkEffective(
          themeMode: ThemeMode.system,
          platformBrightness: Brightness.dark,
        ),
        isTrue,
      );
      expect(
        isOledDarkEffective(
          themeMode: ThemeMode.system,
          platformBrightness: Brightness.light,
        ),
        isFalse,
      );
      expect(
        isOledDarkEffective(
          themeMode: ThemeMode.light,
          platformBrightness: Brightness.dark,
        ),
        isFalse,
      );

      // 浅色 + 纯黑: 开关保持开, 主题档仍是浅色(不静默改成深色)
      settings.update(themeMode: ThemeMode.light, oledDark: true);
      expect(themeChoiceOf(settings), ThemeChoice.light);
      expect(settings.oledDark, isTrue);
      expect(oledDarkLabel(effective: false), contains('仅在深色时生效'));
      expect(oledDarkLabel(effective: true), contains('#000000'));
    });
  });
}
