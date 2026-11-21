<div align="center">

# MiniNCM · 轻音

**An unofficial NetEase Cloud Music client — Android · Linux · Windows**

[中文](README.md) · **English**

Rust core (protocol / identity / cache / playback) + Flutter UI (one codebase, three platforms)
+ platform layer (Android Media3 / Linux·Windows rodio+CPAL)

[![Flutter](https://img.shields.io/badge/Flutter-3.47-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Rust](https://img.shields.io/badge/Rust-core-DEA584?logo=rust&logoColor=white)](https://www.rust-lang.org)
[![Android](https://img.shields.io/badge/Android-14%2B-3DDC84?logo=android&logoColor=white)](#)
[![Linux](https://img.shields.io/badge/Linux-desktop-FCC624?logo=linux&logoColor=black)](#)
[![Windows](https://img.shields.io/badge/Windows-x64-0078D4?logo=windows&logoColor=white)](https://github.com/xiaquwan1001/netease-mini-player/actions/workflows/windows.yml)
[![CI](https://github.com/xiaquwan1001/netease-mini-player/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/xiaquwan1001/netease-mini-player/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![tests](https://img.shields.io/badge/tests-Dart%201528%20%2B%20Rust%20545-brightgreen)](#build--test)

<img src="docs/images/hero.png" alt="MiniNCM screens" width="100%">

</div>

## What is this

A deliberately small, long-lived NetEase Cloud Music client: a **one-row** player bar, tap it and you land on
lyrics; no recommendation spam. Protocol, crypto, anti-bot and identity live in Rust — the UI only has to look good.

- **One UI, three platforms** — the same Dart code builds an Android APK, a Linux desktop bundle and a
  Windows x64 app; platform differences are confined to `playback.dart` / `platform.dart` and two `cfg` playback backends.
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
<tr>
<td width="33%"><img src="docs/images/phone-row-menu.png" alt="Song actions from a long press"></td>
<td width="33%"><img src="docs/images/phone-playlist-search.png" alt="Search-in-page in a playlist"></td>
<td width="33%"><img src="docs/images/phone-podcast-search.png" alt="Search-in-page in a podcast"></td>
</tr>
<tr>
<td align="center">Long-press / right-click a song row → shared “Song actions” sheet</td>
<td align="center">Playlist detail: persistent “search in page” icon in the AppBar</td>
<td align="center">Podcast detail: episode list + “search in page”</td>
</tr>
</table>

### Share card

Long-press a lyric line, select a few, hit **Share selected lyrics** — you get a card with cover art,
lyrics and a QR code pointing at the official song page (`music.163.com/song?id=...`):

<img src="docs/images/share-card.png" alt="Share card" width="360">

## Features

| Area | What works |
|---|---|
| Playback | One-row player bar, queue (jump / drag-reorder / clear / save as playlist), 4 play orders (repeat-all / repeat-one / in-order / shuffle), heart mode and personal FM as **separate guided states** (FM auto-continues, own notification icon), auto update check (off / daily / weekly / monthly), MV playback (embedded VideoView on Android / system player on desktop), stream cache with LRU limit |
| Long text | One shared `AdaptiveText`: song / playlist / album / artist names marquee one-way only when they do not fit (static otherwise), subtitles truncate with ellipsis, cover-card titles use two lines |
| Recommend | Top row fixed to three cells (playlist square / heart mode / personal FM); daily-pick tabs size to content, podcast cards use two-line subtitles; daily-pick history merges online dates with the local per-day cache (playlists and songs in one v2 file, v1 still readable) and collapses repeated playlist days |
| Lyrics | Synced highlight, word-by-word lyrics (**AMLL TTML by default** — community-reviewed word timing; switch to auto-scoring or NetEase yrc in settings), translation toggle, lyric multi-select → share card, cover-colour backdrop |
| Playlists | Playlist square browsed by the **official two-level categories** (language / style / scene / mood / theme, names come from `/api/playlist/catlist`), hot and premium modes are mutually exclusive with a persistent filter bar; charts; subscribe / create / edit / delete, batch add, in-playlist search play action (whole list / append to queue), liked-songs ordering, recent-play four tabs |
| Community | Comments (hot / all / replies / like / delete / IP location), private messages & mentions (read-only), follows feed, follow/fan lists, sign-in |
| Desktop | Linux (deb/AppImage/tar.gz) and Windows (setup.exe/zip) share one rodio backend (ALSA/WASAPI), OLED pure-black theme, fine volume -40..0 dB, sleep timer (now / end of track), close-to-tray option (tray capability is probed natively, degrades honestly when absent) |
| Profile pages | Artist and user pages share one skeleton: hi-res banner (size × DPR × quality preset, tap for full-screen and save original), identity card (bio under the nickname, stats spanning the card: follows / fans / level / works), declarative tabs (artist = top songs / all songs / albums / MVs / feed · user = feed / liked songs / playlists); your own bio and feed are editable from Mine |
| Cloud drive | Music cloud list (quota / sizes), playback, delete, upload local audio (md5 dedupe → NOS upload → cloud transcode → publish) with progress; chunked upload ships only the planning/resume engine — the production path is still a single request (the music-bucket chunk HTTP shape needs a capture from a real client) |
| VIP (read-only) | VIP card / growth / weekly sign-in / tasks, purchased digital albums (no payments) |
| Search & discover | Search (history / **guess-you-want-to-search** grid / toggleable hot queries / suggestions / typed sections incl. MV; the landing page also carries charts), daily picks, personal FM, heart mode, new songs & albums by region, style picks, podcast square (radio folded into podcasts) |
| Layout | **Three responsive tiers** (narrow <600 / medium 600–899 / wide ≥900): content capped at 840, two-column and playlist master-detail on wide, NavigationRail on wide; 300dp narrow and 1.25 text scale are golden-locked |
| Extensibility | Source-plugin host slice 1 (`ncm-plugin`: rquickjs host + lx compatibility layer + sandbox budget) — crate-only, no route registered, not linked into `ncm_ffi`/the APK |
| Audio quality | Loudness normalisation (EBU R128 + ReplayGain 2.0), AutoEQ curve import (PK·LS·HS), fade in/out, hardware/software decode, cover quality presets |

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
- Linux and Windows builds have **no system player dependency** (no mpv / MPRIS) — same rodio backend,
  ALSA on Linux and WASAPI on Windows: unzip and run (`bundle/minincm`, `minincm.exe`).

## Build & run

```bash
git clone https://github.com/xiaquwan1001/netease-mini-player.git
cd netease-mini-player
source tools/env.sh          # JDK 21 / Flutter / Android SDK / Rust (edit for your machine)

bash tools/build-linux.sh    # -> ui/build/linux/x64/debug/bundle/minincm
bash tools/build-android.sh  # -> .../app-x86_64-debug.apk (emulator) + app-arm64-v8a-debug.apk (device)
bash tools/ci.sh             # tests + bridge smoke + Linux/Android builds
```

Desktop packages (local scripts in [`packaging/`](packaging/)):

```bash
bash packaging/linux/build-deb.sh        # -> dist/minincm_<ver>_amd64.deb
bash packaging/linux/build-appimage.sh   # -> dist/MiniNCM-<ver>-linux-x86_64.AppImage
# Windows installer (Inno Setup), on Windows: iscc /DAppVersion=<ver> /Odist packaging\windows\installer.iss
```

Every tagged release ships via [**GitHub Releases**](https://github.com/xiaquwan1001/netease-mini-player/releases/latest):
APK (arm64) · Linux tar.gz · `.deb` · AppImage · Windows `setup.exe` · Windows portable zip · `SHA256SUMS.txt`
exact asset names come from [`release.yml`](.github/workflows/release.yml); sizes are listed on each release page.

Windows desktop **must be built on Windows** (Flutter desktop does not cross-compile), so there is no local
script: [`.github/workflows/windows.yml`](.github/workflows/windows.yml) produces
`MiniNCM-<version>-windows-x64.zip` (~17 MB, verified) on `windows-latest`. Locally on Windows:
`flutter config --enable-windows-desktop` then `flutter build windows --release` (cargokit builds the Rust `ncm_ffi`).

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
| `cargo test --offline --workspace --exclude ncm-api-rs` | **545** passing / 0 failed (the vendor crate's 4 network smoke tests skip themselves offline; the authoritative numbers live in `docs/PROGRESS.md`) |
| `cargo clippy --workspace --all-targets` | **0 warnings** |
| `flutter test --exclude-tags network` | **1528** passing / 0 failing (includes **21** golden pages, also run in CI; real-network smoke tests are tagged `@Tags(['network'])`) |
| `dart analyze` | **0 issues** (errors / warnings / infos) |
| `tools/check-write-guard.sh` | OK (tests never touch comment / like / share / playlist write endpoints) |
| Builds | Linux bundle + Android APK locally; Windows x64 zip via `windows.yml` CI |
| `tools/check-tokens.sh --strict` | OK (spacing / radii / font sizes limited to `layout.dart`'s token set) |
| API coverage | **135/136** (**158** FFI exports, 6 without a UI entry point: 4 intentionally kept, 2 awaiting a product decision; the one unused endpoint `vip_sign_info` is intentionally dropped); recompute with `bash tools/api-coverage.sh` |
| Android unit / lint | `testDebugUnitTest` **10** passing / 0 failing · `lintDebug` **0 error / 9 warning** (all dependency-version hints); both run inside `ci-gates.sh verify` |
| Device run-through | emulator **a34** (API 34) + real-device (vivo X200 Ultra) release smoke & listening checks — see `docs/testing.md` |

## Roadmap (the only source of truth for the version is `ui/pubspec.yaml`; the published line is on [Releases](https://github.com/xiaquwan1001/netease-mini-player/releases/latest))

| Stage | Content | Status |
|---|---|---|
| M0 | Rust workspace layering, provider abstraction, headless CLI | done |
| Protocol | vendored port + prune (382 -> 136 endpoints, 135/136 now covered, 12k -> 4k LOC) | done |
| Shell | Flutter Android/Linux/Windows, FRB 2.13 bridge, all builds (Windows via CI) | done |
| Playback | Media3 (Android) / rodio (Linux ALSA · Windows WASAPI), loudness, AutoEQ, cache | done |
| UI | 5-tab IA, recommend/search/follows/mine/settings, one-row player bar, song detail, share card | done |
| Real-device checks | listening items (EQ clipping / fade feel / loudness A/B / hardware decoding) and MV playback passed on a real device on 2026-11-10 | done |
| TODO | visual review pass, post-install smoke (deb / keyring), L-sized features (listen together / audio recognition; the cloud drive itself is done, chunked upload needs a real-client capture) — see [`docs/remaining-batches.md`](docs/remaining-batches.md) §11 | planned |

See `docs/PROGRESS.md` (Chinese) for the per-batch evidence.

## Docs (mostly Chinese)

| Doc | Content |
|---|---|
| [`docs/README.md`](docs/README.md) | **documentation index** (one line per file, with status) |
| [`docs/PROGRESS.md`](docs/PROGRESS.md) | progress log: version timeline + per-batch evidence (Chinese) |
| [`docs/archive/architecture-restart.md`](docs/archive/architecture-restart.md) | architecture decisions, plugin boundaries (archived) |
| [`docs/archive/ui-song-detail-share.md`](docs/archive/ui-song-detail-share.md) | player bar merge / song detail / share card & channel contract |
| [`docs/testing.md`](docs/testing.md) | multi-platform testing: daily self-test flow (semantics-driven) + gotchas; desktop pre-release 31-item smoke checklist |
| [`docs/archive/api-channel.md`](docs/archive/api-channel.md) | API channel (interface / interface3) measurements (archived) |
| [`docs/remaining-batches.md`](docs/remaining-batches.md) | backlog & batching plan (latest in §11) |
| [`packaging/`](packaging/) | deb / AppImage / Windows installer scripts |
| [`tools/devui/`](tools/devui/README.md) | headless emulator automation helpers |

## License

MIT — see [LICENSE](LICENSE). Third-party components and their licences (WTFPL / MIT / MPL-2.0 / BSD-3-Clause)
are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Disclaimer

For study and research only — please support the official service. This project ships no audio content:
stream URLs are resolved on demand. Your login state stays on your device (0600 file) and is never uploaded.
