# C3 — MV 播放 接口实测笔记(2026-11-22, ncm raw 实抓)

## mv_detail(`/api/v1/mv/detail`, weapi, 参数 mvid)

id=5436712(莫文蔚/张洪量《广岛之恋》)真实形状:

- 顶层: `code`, `data{...}`, `subed`, `mp{...}`(版权: pl=480 可播档, dl 下载档, fee/mvFee=0 免费)。
- `data` 关键字段:
  - `id`, `name`(标题), `duration`(毫秒), `publishTime`("1997-10-01")
  - `playCount`, `shareCount`, `subCount`, `commentCount`
  - `cover`(http://p4.music.126.net/...jpg 封面), `coverId`
  - `artistName`, `artistId`, `artists[]`{id,name,img1v1Url}
  - `desc`/`briefDesc`(可 null/空), `videoGroup[]`{id,name}
  - `brs[]`: 多清晰度数组 `{br:240,size}`, `{br:480,size}` — 本 MV 最高 480; 新 MV 常见 240/480/720/1080 分档。
- 解析策略: 以 `data.name`/`data.cover`/`data.artistName` 为准, brs 取最大 br 作可用最高清晰度参考。

## mv_url(`/api/song/enhance/play/mv/url`, weapi, 参数 id + r)

请求 r=1080 与 r=480 实测(免费 MV):

- 顶层 `code`=200, `data` 是**单个对象**(不是数组; video 版才是数组)。
- `data.url`: `http://vodkgeyttp8.vod.126.net/cloudmusic/.../<hash>.mp4?wsSecret=<md5>&wsTime=<ts>`
  - **带签名直链, 有效期 `expi`=3600 秒**, 应即取即播, 不持久化。
  - http 与 https 直链都实测可访问(206, video/mp4)。
  - `data.r` 回的是**实际给的档位**(请求 1080 返回 r=480, 该 MV 无 1080)。
  - `data.size` 字节数; `md5` 为空; `code`=200 表示取链成功。
- 无需额外 header/身份即可播; 免登录可用(测试时已登录但该接口匿名通常也可)。

## 播放侧结论

- Android: VideoView 直接吃 http(s) mp4 直链; AndroidManifest 需 `usesCleartextTraffic` 或直接把 http→https 替换(已验证 https 可用, 采用替换)。
- url 带 wsTime 签名, 过期会 403 ⇒ 播放失败时提示「链接过期, 请重试」并重新取链。
- Linux: 无视频能力, 用系统播放器/浏览器打开 url(openUrl), UI 明示。
