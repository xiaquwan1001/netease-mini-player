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
