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

## 客户端形态必须自洽(2026-11-04 修正)

原则: **安卓端一切按安卓形态, 桌面端一切按桌面形态**; API 的 os/appver/osver/channel、
UA、以及网页入口的版式必须成套, 混着用会得到"假通过"(静默降权/只给试听), 比报错更难查。

| 平台 | os / appver / osver / channel | API UA | 网页入口 |
|---|---|---|---|
| Android | `android / 8.20.20.231215173437 / 14 / xiaomi` | `NeteaseMusic/9.1.65...(9001065);Dalvik/2.1.0 (Linux; U; Android 14; ...)` | 移动版: 设备默认移动 UA + `music.163.com/login`(302 → `y.music.163.com/m/login`) |
| Linux/PC | `pc / 3.1.17.204416 / Microsoft-Windows-10-...-64bit / netease` | `... N GM/3.0.18.203152`(官方 PC 客户端 UA) | Android 走 Kotlin `LoginActivity`(WebView);桌面/统一弹层走**官方网页登录的扫码 + 手机号验证码通道**(weapi, 见 `docs/PROGRESS.md` 2026-11-11),不需要内嵌 WebView;导入 cookie 仍作为兜底 |

实现位置:

- `ncm-service::identity` 里的 `ANDROID_PROFILE` / `DESKTOP_PROFILE`, 由 `platform_profile()`
  按编译目标选择; 形态四键**覆盖式**写入 identity.json(老版本写死 `os=pc` 的会被就地纠正,
  deviceId/_ntes_nuid/_ntes_nnid/WNMCID/NMTID/MUSIC_U 全部保留)。
- `NeteaseProvider::new` 默认 UA 取 `platform_profile().ua`。**必须显式给**: vendor 库对
  `eapi` 的默认 UA 是 iPhone(`NeteaseMusic 9.0.90/5038 (iPhone; ...)`), 与我们的 os 声明冲突。
- `PlaybackService`(安卓)的 CDN UA 用官方安卓客户端 UA —— 直链 CDN 对 UA 敏感, 但同样要
  与形态一致; ExoPlayer 默认 UA 会被拒。

验证(2026-11-04, 模拟器 a36):

- 设备端 `run-as com.minincm.minincm cat files/ncm/identity.json` →
  `os=android; appver=8.20.20.231215173437; channel=xiaomi; deviceId=BF448268...`(旧值已迁移, id 未变)。
- 该形态下搜索/取链/播放全部正常(`state=PLAYING`, 通知栏曲目正确), CDN 未拒绝安卓 UA。
- Linux 侧 `ncm search` 仍走 `os=pc` + 官方 PC UA, 336 条正常。
