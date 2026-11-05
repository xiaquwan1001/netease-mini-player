# 功能包: 搜索分板块 / 图片 / 歌曲操作 / 关注 tab / 我喜欢的顺序

> 2026-11-06 立项。用户提出的 7 项需求, 按"后端契约 → UI 组件 → 集成 → 验证"推进。

## 需求 → 实现映射

| # | 需求 | 后端 | UI |
|---|---|---|---|
| 1 | 搜索结果分板块(单曲/专辑/歌手/播客/歌单) | `search_all` (cloudsearch type=1/10/100/1000/1009) → SearchBundle | 新 `search_results.dart`: 分区标题 + 横滑卡片 + 单曲列表 |
| 2 | 所有实例展示图片; 动态图片/视频; 个人主页背景/头像 | SongDto.artist_id; FeedEvent.video_url; ProfileDetail(background/avatar) | SongTile 封面; 艺人圆形头像; 播客/专辑封面; FeedView 图片+视频卡; Mine 顶部资料卡 |
| 3 | 非 VIP 被标 VIP | `is_vip` 只认 fee=1 (fee=8 是"低音质免费") | 无需改 |
| 4 | 我喜欢的音乐按时间新→旧 | 新 `liked_songs_ordered`: playlist detail trackIds 按 `at` 倒序 | 详情页/我的页直接用 |
| 5 | "关注"拆成独立底部 tab | 复用 feed_events | 新 `feed_view.dart`; 底部 5 栏 |
| 6 | 搜索显式取消/清空 | — | 搜索框 clear 按钮 + "取消"按钮, 清结果/联想/错误 |
| 7 | 每首歌 ... 菜单(下一首/喜欢/收藏到歌单/分享/评论/歌手/专辑/下载) | `add_to_playlist`; FFI artist/profile; 平台下载通道 | 新 `song_actions.dart` + `app_actions.dart` (InheritedWidget) |

## API 事实(实测 2026-11-06)

- `cloudsearch` type: 1 单曲 / 10 专辑 / 100 歌手 / 1000 歌单 / 1009 播客(电台);
  **type=2000(声音/节目) 返回空 result, 本接口不支持节目搜索** → 不放出"电台节目"板块。
- type=10 albums[]: `{id,name,picUrl,blurPicUrl,artist{name},artists[],size,companyId}`
- type=100 artists[]: `{id,name,picUrl,alias[],albumSize,musicSize,followed}`
- type=1000 playlists[]: `{id,name,coverImgUrl,creator{nickname},trackCount,playCount,subscribed}`
- type=1009 djRadios[]: `{id,name,picUrl,programCount,playCount,dj{nickname,avatarUrl},desc}`
- `artist/detail` → `data.artist{id,name,avatar,cover,briefDesc,alias[],albumSize,musicSize}`
- `artist/top/song` → `songs[]`; `artist/album` → `hotAlbums[]{id,name,picUrl,size,publishTime,artist{name}}`
- playlist detail `/api/v6/playlist/detail` 的 `playlist.trackIds[]{id,at}` → `at` 为加入时间(ms),
  可用来实现"新→旧"; 不用 `likelist` 的 id 顺序(实测体感随机)。
- fee 语义: 0 免费 / 1 VIP / 4 付费专辑 / 8 **低音质免费(不是 VIP)**。
  当前 `is_vip` 把 8 算进来, 导致 21/30 首免费歌被标 VIP。

## 实施顺序

1. **Rust 契约层**(本会话): domain DTO + Provider trait + netease 实现 + FFI + codegen + 单测。
2. **并行 UI 组件**(子代理, 只写新文件, 不改共享文件):
   - U1 `search_results.dart` (分区结果页)
   - U2 `song_actions.dart` + `app_actions.dart` (省略号菜单/动作面板)
   - U3 `feed_view.dart` + `artist_page.dart` + `profile_header.dart`
3. **集成**(本会话): main.dart(搜索/5 栏/播放条菜单/AppActions) / mine_view / detail_page /
   discover / podcast / song_tile / album_preview / cover_art / Kotlin 平台通道。
4. **验证**: `cargo test` + `flutter analyze` + `flutter test` + a36 模拟器截图。

## 状态(2026-11-06 完成)

- 全部 7 项已落地; Rust 单测/Flutter 76 用例通过, Linux + APK debug 构建通过。
- 验证: CLI `ncm searchall/artist/likedorder`; Linux Xvfb 截图(搜索五区、封面、菜单、歌手页、取消);
  a36 模拟器五栏/搜索/取消/菜单可用。
- 已知环境限制: 模拟器 NAT 对 CDN 图片偶发 403(Dart UA 已修, 同 URL Linux 正常), 真机不受影响。

## 风险

- FRB 改结构体影响 Dart 生成代码与 7 个测试里的 SongDto 构造 → 统一补 `artistId`。
- `profile_detail` 需要登录; 匿名时 Mine 资料卡只显示默认背景 + 本地昵称占位。
- 下载: Android 用 DownloadManager(免存储权限); Linux 用 curl 到 ~/Downloads。不引第三方包。
- 动态视频只做"封面 + 播放角标 + 点击系统打开", 不做内嵌播放器。
