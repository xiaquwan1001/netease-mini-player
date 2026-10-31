---
name: netease-cloud-music-api-reverse
description: "Reverse-engineer NetEase Cloud Music APIs and bypass Android anti-bot."
---

# NetEase Cloud Music API reverse-engineering

Use when building a third-party NetEase Cloud Music client or integrating its
search/login/playback APIs, especially from an Android app where anti-bot is the
hard part.

## Protocol map

| Flow | Protocol | Notes |
|---|---|---|
| Search / login / lyrics | `eapi` | AES-ECB, pure CryptoJS-portable; the sane default |
| Playback URL | `linuxapi` | AES-ECB; `/api/song/enhance/player/url/v1` |
| Legacy | `weapi` | AES-CBC double + RSA; avoid unless required |
| Newest | `xeapi` | X25519 + AES-GCM; hard in browser JS, skip in v1 |

- Responses are plaintext by default (`encryptResponse=false`).
- `login_qr_key`: the key is at the **top level** `res.unikey`, not `res.data.unikey`.
- Community reference implementation: `NeteaseCloudMusicApiEnhanced/api-enhanced`
  (the original `Binaryify/NeteaseCloudMusicApi` was taken down). Run it locally
  as a fallback/control to validate client logic end-to-end.

## Android anti-bot (the core problem)

2024+ NetEase adds `xeapi` + **TLS/JA3 fingerprinting** + an anti-cheat token.
Standard Android TLS stacks (Conscrypt, WebView Chromium, even OkHttp cipher
spoofing) get blocked.

Working approach — **emulate the web client**:
- Host `interface3.music.163.com`, Chrome-on-Windows UA, bare cookies, plaintext
  response → read APIs (unikey/search) connect directly.
- The login API still returns `8821 安全环境风险` in web form. Final solution:
  open the **official web login page in a WebView**, let the user scan the QR,
  then read `MUSIC_U` from `CookieManager`. Official web login has zero anti-bot.
- A remote API service (local api-enhanced) is a useful fallback/control path to
  separate "app logic bugs" from "direct-connection anti-bot".

## Verified on device (2026-10-31, vivo X200 Ultra / Android 16, WebView 138)

- eapi 直连 `interface3.music.163.com` 在真机 WebView 内跑通: 搜索(cloudsearch)、播放地址, 甚至
  api-enhanced 标 `weapi` 的接口(`/api/v1/radio/get` 私人FM、`/api/v3/discovery/recommend/songs` 每日推荐)
  换成 eapi 封装同样 200 → **不需要移植 weapi/RSA**。
- `/eapi/song/enhance/player/url/v1` 的 params 必须含 `encodeType`(`flac`); 缺了返回
  `{"msg":"参数错误","code":400}`, 而且响应是**两个拼接的 JSON**, 前端 `JSON.parse` 直接炸
  (表现为“数据非 json”)→ 解析时按 `}{` 切开取第一个。
- 匿名播放: `fee=1`(VIP)歌曲返回 `data[0].code=-110` 且无 url; `fee=8`/免费歌曲正常返回直链。

## Pitfalls
- **Internal URI ≠ route path**: e.g. `song/url/v1` as a route path 404s; use the
  documented internal URI.
- Prefer separating concerns during debugging: first determine whether a failure is
  app logic or anti-bot, then drill in (systematic debugging).
- Keep crypto libraries tiny and auditable (`crypto-js`, `qrcode`) if the goal is a
  small APK with no AndroidX/Kotlin/Gradle third-party deps.

## Architecture pattern that worked
A thin native shell (WebView + foreground playback service + SharedPreferences +
HTTP/Cookie bridge) plus a JS SPA that holds all UI/crypto/business logic and a
plugin registry (`js/plugins/provider/`). This keeps the APK tiny, makes providers
hot-swappable, and lets content/behaviour be "everything is a plugin".
