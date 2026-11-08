<div align="center">

# MiniNCM · 轻音

**An unofficial NetEase Cloud Music client — Android + Linux**

[中文](README.md) · **English**

Rust core (protocol / identity / cache / playback) + Flutter UI (one codebase, two platforms)

[![Flutter](https://img.shields.io/badge/Flutter-3.47-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Rust](https://img.shields.io/badge/Rust-core-DEA584?logo=rust&logoColor=white)](https://www.rust-lang.org)
[![Android](https://img.shields.io/badge/Android-14%2B-3DDC84?logo=android&logoColor=white)](#)
[![Linux](https://img.shields.io/badge/Linux-desktop-FCC624?logo=linux&logoColor=black)](#)
[![CI](https://github.com/xiaquwan1001/netease-mini-player/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/xiaquwan1001/netease-mini-player/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![tests](https://img.shields.io/badge/tests-Dart%20362%20%2B%20Rust%20169-brightgreen)](#build--test)

<img src="docs/images/hero.png" alt="MiniNCM screens" width="100%">

</div>

## What is this

A deliberately small, long-lived NetEase Cloud Music client: a **one-row** player bar, tap it and you land on
lyrics; no recommendation spam. Protocol, crypto, anti-bot and identity live in Rust — the UI only has to look good.

- **One UI, two platforms** — the same Dart code builds an Android APK and a Linux desktop bundle;
  platform differences are confined to `playback.dart` / `platform.dart`.
- **No home-made protocol** — crypto / request shapes come from `core/vendor/ncm-api` (a Rust port of
  *api-enhanced*, pinned commit). We add identity injection, DTO conversion and caching.
- **Identity discipline** — `device_id` is generated once and reused forever; device cookies
  (`_ntes_nuid/_ntes_nnid/NMTID/WNMCID`) are persisted (0600) instead of being randomised per process.

## Screens

<table>
<tr>
<td width="33%"><img src="docs/images/phone-recommend.png" alt="Recommend"></td>
<td width="33%"><img src="docs/images/phone-lyric-i18n.png" alt="Song detail"></td>
<td width="33%"><img src="docs/images/phone-share-sheet.png" alt="Share"></td>
</tr>
<tr>
<td align="center">Daily picks / charts / styles</td>
<td align="center">Song detail: synced lyrics + translation toggle</td>
<td align="center">Select lyrics → share card</td>
</tr>
<tr>
<td width="33%"><img src="docs/images/phone-search.png" alt="Search"></td>
<td width="33%"><img src="docs/images/phone-lyric-select.png" alt="Lyric multi-select"></td>
<td width="33%"><img src="docs/images/phone-audio.png" alt="Audio settings"></td>
</tr>
<tr>
<td align="center">Search: songs / playlists / podcasts</td>
<td align="center">Long-press lyrics → multi-select</td>
<td align="center">Loudness normalisation / AutoEQ</td>
</tr>
</table>

### Share card

Long-press a lyric line, select a few, hit **Share selected lyrics** — you get a card with cover art,
lyrics and a QR code pointing at the official song page (`music.163.com/song?id=...`):

<img src="docs/images/share-card.png" alt="Share card" width="360">

## Features

| Area | What works |
|---|---|
| Discover | Search (history / suggestions / hot queries), daily picks (songs·playlists·podcasts), personal FM, heart mode, charts, new releases, styles, follows feed, private messages, comments |
| Playback | One-row player bar, queue (jump/remove), play modes, song detail page (lyrics / translation / multi-select share / jump to current line), word-by-word lyrics |
| Audio quality | Fine volume (-40..0 dB), loudness normalisation (EBU R128 / BS.1770-4 + ReplayGain 2.0, optional AGC ≤3 dB/s), AutoEQ curve import (PK·LS·HS), fade in/out, hardware/software decode, stream cache with LRU limit |
| Account | Web login on Android (WebView returns the cookie only), multi-account book, liked songs / playlists / podcasts / follows |
| Appearance | Theme (light / dark / OLED pure black), text scale, 1- or 2-row cover grids |

## Architecture

```text
+---------------- Flutter UI (ui/, shared) ----------------+
|  pages / widgets - player bar - song detail - share card  |
+-----------+----------------------------------+------------+
            | flutter_rust_bridge 2.13          | ncm/player (MethodChannel)
+-----------v---------------+      +-----------v------------+
| Rust core (core/)          |      | Android platform layer |
|  ncm-domain    models      |      |  Media3 ExoPlayer      |
|  ncm-provider  abstraction |      |  MediaSessionService   |
|  ncm-service   identity    |      |  login WebView / share |
|  ncm-ffi       FRB bridge  |      +------------------------+
|  ncm-cli       headless    |      +------------------------+
|  vendor/ncm-api protocol   |      | Linux layer (pure Rust)|
+----------------------------+      |  rodio + CPAL + symphonia |
                                    +------------------------+
```

- Only serialisable `ncm-domain` types cross the FFI boundary; provider errors are normalised to
  `ProviderError{kind, retryable, detail}` and the UI branches on `kind`.
- The Linux build has **no system player dependency** (no mpv / MPRIS): unzip and run.

## Build & run

```bash
git clone https://github.com/xiaquwan1001/netease-mini-player.git
cd netease-mini-player
source tools/env.sh          # JDK 21 / Flutter / Android SDK / Rust (edit for your machine)

bash tools/build-linux.sh    # -> ui/build/linux/x64/debug/bundle/minincm
bash tools/build-android.sh  # -> ui/build/app/outputs/flutter-apk/app-debug.apk
bash tools/ci.sh             # tests + bridge smoke + both builds
```

Headless verification (no UI):

```bash
cd core
cargo run -p ncm-cli -- search "shape of you" --limit 5
cargo run -p ncm-cli -- url 186016 --download /tmp/a.mp3
cargo run -p ncm-cli -- lyric 186016
```

## Build & test gates

| Gate | Status |
|---|---|
| `cargo test --workspace` (vendor network smoke excluded) | **169** passing (domain 32 / playback 31 / service 106) |
| `flutter test` | **362 + 1 skip** passing (pure logic / widget tests + a few real-network smoke tests) |
| `dart analyze` | 0 error / 0 warning |
| Builds | Linux bundle + Android debug APK |
| Device run-through | emulator a34 (API 34) — see `docs/testing-dual-platform.md` |

## Roadmap

| Stage | Content | Status |
|---|---|---|
| M0 | Rust workspace layering, provider abstraction, headless CLI | done |
| Protocol | vendored port + prune (382 -> 118 endpoints, 12k -> 4k LOC) | done |
| Shell | Flutter Android/Linux, FRB 2.13 bridge, both builds | done |
| Playback | Media3 (Android) / rodio (Linux), loudness, AutoEQ, cache | done |
| UI | 5-tab IA, recommend/search/follows/mine/settings, one-row player bar, song detail, share card | done |
| TODO | release size numbers, real-device listening checks, pluggable audio sources | planned |

See `docs/PROGRESS.md` (Chinese) for the per-batch evidence.

## Docs (mostly Chinese)

| Doc | Content |
|---|---|
| [`docs/PROGRESS.md`](docs/PROGRESS.md) | progress log with acceptance evidence |
| [`docs/architecture-restart.md`](docs/architecture-restart.md) | architecture decisions, plugin boundaries |
| [`docs/ui-song-detail-share.md`](docs/ui-song-detail-share.md) | player bar merge / song detail / share card & channel contract |
| [`docs/testing-dual-platform.md`](docs/testing-dual-platform.md) | dual-platform testing, semantics-driven automation, gotchas |
| [`docs/api-channel.md`](docs/api-channel.md) | API channel (interface / interface3) measurements |
| [`tools/devui/`](tools/devui/README.md) | headless emulator automation helpers |

## License

MIT — see [LICENSE](LICENSE). Third-party components and their licences (WTFPL / MIT / MPL-2.0 / BSD-3-Clause)
are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Disclaimer

For study and research only — please support the official service. This project ships no audio content:
stream URLs are resolved on demand. Your login state stays on your device (0600 file) and is never uploaded.
