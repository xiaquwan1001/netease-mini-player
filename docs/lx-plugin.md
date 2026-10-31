# LX 音源脚本工坊(plugins/lx-music)

把我们的网易云协议知识做成**能在 Melodia 里直接跑的 LX 自定义音源脚本**,不 fork、不重写 App。
本轮落地:`plugins/lx-music/ncm-wy.js` + 回归台 `tools/lx-plugin-harness.mjs`。

## 1. 沙盒契约(从 Melodia 源码读出来的,不是猜的)

| 位置 | 事实 |
|---|---|
| `shared/.../core/source/LxShim.kt` | 沙盒只有 `lx.request` / `lx.on` / `lx.send` / `lx.utils.crypto.md5` / `lx.EVENT_NAMES` / `lx.env`;提供 `setTimeout` 垫片 |
| 同上 | **没有 CryptoJS、没有 AES、没有 fetch** → eapi/weapi 需要自己内置 AES 实现;本脚本改用明文 `/api` 通道 |
| `app/.../plugin/LxPluginEngine.kt` `SandboxBridge.onEvent` | 只认 `inited`,且从 `data.sources` 的 **key** 取支持平台列表 |
| `LxPluginEngine.resolveMusicUrl` | 调用形态 `(source, musicInfo{id,songmid,name,singer,albumName,interval}, type)` → 脚本返回 url 字符串 |
| `LxScriptSupport.INIT_TIMEOUT_MS / RESOLVE_TIMEOUT_MS` | 初始化 8 s、单次解析 12 s |
| `LxPluginEngine.handleHttpRequest` | 请求经宿主 OkHttp 代理,**headers 原样透传**(可自带 UA/Cookie),但**拿不到 Set-Cookie**,响应体上限 4 MB |
| `LxScriptSupport.mapQualityToLx` | 宿主音质 → LX 代号:`lossless→flac`、`hires→flac24bit`、`exhigh→320k`、其余 `128k` |
| `AudioSourceRouter` | 插件只在「官方直链失败或仅试听」时被调用;开「社区源优先」则先问插件 |

## 2. 脚本设计(`ncm-wy.js`)

- 通道:`POST https://interface3.music.163.com/api/song/enhance/player/url/v1`,明文表单,无加密依赖。
- 身份:`os=pc / appver=3.0.6 / osver=10.0.19045 / deviceId=<固定伪指纹>/ channel=netease`
  —— 缺 `os`/`appver` 会被服务端**静默封顶音质**。
- 音质:`level` 与 `encodeType` 成对给出(`standard/mp3`、`exhigh/mp3`、`lossless/flac`、`hires/flac`)。
- 两个必须显式处理的真实坑:
  1. **`freeTrialInfo` 非空 = 试听片段**,直接抛错让宿主换源;否则播放会在 30 s 处断。
  2. **静默降级**:请求 lossless 收到 `level=exhigh`、code 仍 200 —— 降级链仍返回可用直链,但必须打 `console.warn`。
- `USER_COOKIE` 用户自填(沙盒拿不到宿主登录态),留空=匿名。
- 直链缓存 5 分钟(真实有效期约 20 分钟)。

## 3. 回归台(不需要设备)

```bash
node tools/lx-plugin-harness.mjs                      # 默认 33894312 / flac
node tools/lx-plugin-harness.mjs plugins/lx-music/ncm-wy.js 347230 flac
NCM_COOKIE='MUSIC_U=...; __csrf=...' node tools/lx-plugin-harness.mjs   # 带登录态测高音质
```

检查项:inited 握手与 `sources.wy`、`lx.on('request')` 注册、直链可取且 `Range` 请求 206、
非法 source/action 必须拒绝、匿名 VIP 歌必须识别为试听并拒绝。

> cookie 只在运行期以环境变量注入并打补丁进内存副本,仓库里的脚本永远保持 `USER_COOKIE = ''`。

## 4. 真机导入(Melodia 2.1.0-beta.1)

```bash
cd plugins/lx-music && python3 -m http.server 8765 --bind 127.0.0.1 &
adb reverse tcp:8765 tcp:8765        # 手机侧用 127.0.0.1:8765 即访问本机
adb logcat -v time | grep -i 'LxPlugin\|ncm-wy'
```

App 内:**设置 → 音源 → 粘贴脚本导入**(它同时支持粘贴远程脚本 URL)——填
`http://127.0.0.1:8765/ncm-wy.js` → 解析并导入 → 打开「启用社区源插件」,视需要打开「社区源优先」。

日志期望:`脚本校验成功: NCM-WY 直连音源 v0.1.0, 支持平台: [wy]`、
`插件 [NCM-WY 直连音源] 沙盒激活成功 ... sources=[wy]`、`JS Console: [ncm-wy] id=... `。

## 5. 真机实测结论(2026-10-31,vivo X200 Ultra + VIP 账号)

### 5.1 插件槽位对 VIP 账号是**不可达**的

`AudioSourceRouter.kt:32-40` 的顺序写死:`官方直链完整且非试听 → 直接 return`。VIP 账号官方永远成功,
**插件一次都不会被调用**(真机播了多首含 VIP 歌,logcat 无 `LxPluginEngine` 行,探针无 `call`)。
想让插件层成为"主音源",必须改上游路由顺序 —— 这是可提 PR 的点,不是脚本能绕过的。

### 5.2 身份 cookie 的真实语义(更正了此前的结论)

同一首歌(`/api/song/enhance/player/url/v1`,明文通道):

| Cookie | 347230(VIP 曲) | 1330348068(可 hires 曲) |
|---|---|---|
| 无 | `code=200` 但 **`url=null`** | 320k(exhigh) |
| 仅 `deviceId` | 同上 | 320k |
| `os=pc; appver=3.0.6` | 128k **试听** | 320k |
| 再加 `deviceId`/`channel` | 同(无变化) | 同 |
| 再加 `MUSIC_U` | **flac 797 kbps** | **hires flac 2.83 Mbps** |

`os=android; appver=9.0.90; osver=14` 与 `os=pc; appver=3.0.6` **结果完全一致**。
结论:`os`/`appver` 是"能不能拿到直链"的闸门,**不是音质旋钮**;音质只跟登录态有关。

### 5.3 脚本在本机(带 VIP cookie)已验证

```
[ncm-wy] id=1330348068 quality=flac24bit -> flac/2832352     PASS
[ncm-wy] id=347230 quality=flac24bit -> flac/797831(降级告警)  PASS
匿名: VIP 曲 -> "仅试听片段,需登录或换源"                      PASS
```


## 6. 社区源脚本兼容性实测(2026-10-31,为 #133 排查)

对象:最常用的社区源脚本 HelloWorld `260925`(只用 `lx.request` / `resp.statusCode` / `resp.body`,
与 `LxShim` 契约兼容)。在 Node 里复刻 Melodia 沙盒语义跑 `musicUrl`(320k,同一首歌):

| 平台 | 结果 | 耗时 |
|---|---|---|
| `wy` | 成功(匿名拿不到 VIP 曲) | 0.25 s |
| `kw` | 成功 | 0.14–0.22 s |
| `mg` | 成功 | 1.0–6.3 s |
| `tx` | 成功 | 3.8 / 5.5 / **12.5** s |
| `kg` | **稳定失败**(脚本内部抛错,非超时) | 1.4–23 s |

对宿主实现的三个含义:

1. `LxScriptSupport.RESOLVE_TIMEOUT_MS = 12000` 偏紧:`tx` 实测出现过 12.5 s;
   一首 VIP 歌常常要先试 `wy`(失败)再串行试 `kw`/`kg`/`tx`,很容易「全部超时」。
2. 只声明 `kg` 的脚本当前注定失败(脚本自身在 kg 路径报错),用户看到的就是「加了社区源还是听不了」。
3. 沙盒契约与官方 spec 的差异(不是本脚本触发,但会影响别的脚本):
   - `utils.buffer.from/bufToString` 在 Melodia 里是**恒等实现**(不做 utf-8/base64/hex 编解码);
   - `utils.crypto` 只有 `md5`,缺 spec 里的 `aesEncrypt / rsaEncrypt / randomBytes`;
   - `utils.zlib`(`inflate/deflate`)完全缺失;
   - 代理请求把 `statusCode` **恒定为 200** 且非 2xx 直接抛异常,脚本看不到真实状态码/响应头。

含 `weapi/eapi` 加密的网易云/QQ 音源脚本必然用到 `aesEncrypt` → 在 Melodia 沙盒里直接 TypeError。
是否补齐这几项,取决于上游对插件层的定位(见 issue #134 的讨论)。

## 7. 已知边界

- 匿名只能到 **320k mp3**(`exhigh`),flac/hires 必须登录;登录态要手动填 `USER_COOKIE`。
- 沙盒无 `Set-Cookie` → 无法在脚本内完成登录流程(扫码/手机号登录仍留在宿主侧,这也是 PR 讨论点)。
- 只有 `musicUrl` 动作;搜索/歌词走宿主自己的实现(Melodia 的 `PlatformSearchProvider` 是 Kotlin 编译期)。
