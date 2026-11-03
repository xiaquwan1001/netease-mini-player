# 通道实测: interface vs interface3(2026-11-03, Linux, 本仓 ncm-cli)

> 目的: 决定 v2 的默认 API 域名与 UA 形态。结论: **保持库默认 interface + App 形态即可, 无需切网页通道。**

环境: 匿名(无 MUSIC_U), 身份 cookie 注入 os=pc/appver=3.1.17/osver=Win10,
`vendor/ncm-api`(api-enhanced 的 Rust 移植), dev build。

| 通道 | UA | 接口 | 结果 | 耗时 |
|---|---|---|---|---|
| `interface.music.163.com`(库默认) | NeteaseMusicDesktop/3.0.18 | cloudsearch | 200, 336 条 | ~0.20s |
| `interface.music.163.com` | 同上 | song/url/v1(免费曲) | 200, 320k mp3 直链, 5.7MB 下载成功 | ~1.2s(含下载) |
| `interface3.music.163.com` | iPhone Safari(网页形态) | cloudsearch | 200, 336 条 | 0.40s |
| `interface3.music.163.com` | 同上 | song/url/v1(免费曲) | 200, 320k 直链 | 0.15s |

补充事实:

- 匿名 + VIP 曲目: `song/url/v1` 返回 per-entry `code=404`(不是旧版 -110);
  我们的 `ProviderError` 映射为 `notFound`, 且文案带 code。
- 音质: `level=exhigh` → 320k mp3; `standard` → 128k; `lossless` 才拿 flac。
  **`encodeType` 由库写死为 flac, 不需要我们补**(v1 的 400 参数错误坑已被库吸收)。
- 两条通道都通, 但网页形态要求 UA/头序更像浏览器。默认走 App 形态(库自带头序),
  只有风控升级时再用 `NCM_DOMAIN` / `NCM_UA` 环境变量切换(临时旋钮, 正式版改成配置项)。
