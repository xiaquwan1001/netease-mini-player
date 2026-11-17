# PC 网页登录为什么被风控(短信 4 位 / 微信扫不了)

日期: 2026-11-17 ｜ 性质: **静态分析**(未做真实登录、未发短信、未扫码)
现象: 手机验证码登录收到的短信是 **4 位**(网页通道正常是 6 位); 二维码**微信扫不了**
(官方 PC 网页版可以)。

## 结论先行

两条症状都指向同一件事: **我们的请求不是"浏览器在网页上登录", 而是"用 weapi 加密封装的
脚本请求假装成浏览器"** —— 参数面几乎全对, 差异集中在**会话/请求形态/传输栈**这三层。

已排除的"背锅项"(别再去改它们, 都是对的):
- 参数面与 api-enhanced 一致: unikey `{type:1}`、poll `{key,type:1}`、发码
  `{cellphone,ctcode}`、校验 `{phone,countrycode,captcha,rememberLogin:"true"}`
  (`core/crates/ncm-service/src/netease/account.rs:105-208`);
- 状态码语义对: 800/801/802/803, 803 凭据只在 Set-Cookie, 只落 `LOGIN_KEYS`
  (`account.rs:247-295`, `.pi/memory/notes-api.md:5`);
- 设备指纹**已持久化**: identity.json 里 `_ntes_nuid/_ntes_nnid/WNMCID/NMTID/deviceId`
  首启生成后复用, 登录请求也确实带上了(客户端 cookie 兜底在
  `core/vendor/ncm-api/src/request.rs:186-190`, 注入逻辑 `:194-230`),
  所以"每次请求换一台设备"这条**不成立**。

## 差异点(按最可能触发风控排序)

### 1. 缺 `__csrf`: weapi body 里提交的是空 csrf_token(最明确的 bot 指纹)

- 证据: `request.rs:262-274` —— `csrf_token = cookie["__csrf"].unwrap_or_default()`,
  然后 `data["csrf_token"] = ""`。首次登录前 identity.json 里没有 `__csrf`
  (`core/crates/ncm-service/src/identity.rs:455-463` 的 `LOGIN_KEYS` 只在**登录成功后**
  才把它落盘), 所以第一次登录必然带空值。
- 影响: 真实浏览器一定先加载 `music.163.com` 页面拿到 `__csrf` 才会 POST; 空
  `csrf_token` + 无 `__csrf` cookie 是"没有页面上下文"的直接标志。风控可以据此把
  这条会话降级处理 —— 短信分流到 4 位短码通道、二维码 key 交给微信端判"非官方渠道/已失效"。
- 判定: 抓一次 unikey/sms 的请求体(mitmproxy 或临时在 `request.rs` 打 header),
  看到 `encSecKey/params` 解不出内容时看 `Cookie` 头有没有 `__csrf=`; 同时对照
  Chrome DevTools 里官方页的同一请求(必然有 `__csrf` cookie + 非空 `csrf_token`)。

### 2. 请求形态自相矛盾: UA 说 Mac Chrome, cookie 说 Windows 官方桌面客户端

- 证据: weapi 分支强制浏览器 UA
  `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ... Edg/124`
  (`core/vendor/ncm-api/src/util/config.rs:75`, 使用点 `request.rs:269-272`),
  但 cookie 里同时注入 `os=pc, appver=3.1.17.204416(NeteaseMusicDesktop),
  osver=Microsoft-Windows-10..., channel=netease, deviceId=<52 位 hex>`
  (`request.rs:194-230`; 值来自 `identity.rs:36-46` 的 `DESKTOP_PROFILE`)。
  真实浏览器**不会**带 `deviceId/appver/osver` 这些客户端字段。
- 影响: "同一台设备既是 Mac 上的 Chrome/Edge, 又是 Windows 官方客户端 3.1.17" 是
  硬矛盾; `.pi/memory/FAILURES.md:20` 记的正是这类不一致会"假通过"(静默降权),
  最坏结果就是通道被换成短码/二维码被判失效。
- 判定: 抓包看 `User-Agent` 与 `Cookie` 里的 `os/appver/osver/deviceId` 是否同时出现;
  对照官方页(纯浏览器 cookie, 无 `deviceId/appver`)。

### 3. 缺浏览器必备请求头(Origin / Accept-Language / Accept / Sec-Fetch-*), Referer 少尾斜杠

- 证据: `request.rs:9-12, 414-424` 只设 `Cookie / User-Agent / Referer / Content-Type`;
  没有任何 `Accept*`、`Origin`、`Sec-Fetch-*`; `Referer` 写的是 `https://music.163.com`
  (`DOMAIN`, `util/config.rs:7`) 而浏览器发的是 `https://music.163.com/`。
- 影响: 头部集合本身就是可分类的特征(TLS/HTTP 层同样能看出), 与第 2 条叠加。
- 判定: 同上抓包; 或本地起一个请求记录代理跑一次官方页对照头部清单。

### 4. 通道选择: `/weapi/` 加密封装 vs 官方页的明文 `/api/` 路由

- 证据: `account.rs:412-418` 的 `qr_option` 用 `CryptoType::Weapi`
  → 实际打到 `POST https://music.163.com/weapi/login/qrcode/unikey`,
  `.../weapi/sms/captcha/sent`(`request.rs:266-276`)。
  官方网页调用的是 `POST /api/login/qrcode/unikey`、`/api/sms/captcha/sent`(明文)。
  api-enhanced 也用 weapi, 但那是"服务器端 RPC" 形态 —— 服务端完全可以把
  `/weapi/*` 归到"第三方脚本"桶里。
- 影响: 同一套业务参数被归到不同风控桶; 这和 `.pi/memory/notes-api.md:3`
  "原生登录族(eapi/weapi)必返 8821、官方网页登录是唯一低风险路径"是同一类现象。
- 判定: 不改代码, 用 curl 以**完全相同的 cookie/UA** 打明文
  `https://music.163.com/api/login/qrcode/unikey` (`type=1`) 与
  `https://music.163.com/weapi/login/qrcode/unikey`, 看返回 `code` 是否不同;
  若明文成功而 weapi 被 8821/400, 即证通道差异。

### 5. 传输栈指纹 + 无页面预检 + 轮询节奏

- 证据: 全程 reqwest(系统 TLS, 非 Chrome 的 BoringSSL/JA3 指纹; 技能文件
  `.pi/skills/netease-cloud-music-api-reverse/SKILL.md` 的 anti-bot 段明确写了
  2024+ 风控含 **TLS/JA3 指纹**); 登录前没有任何页面预检(官方页会先 GET 首页种
  `__csrf/NMTID/_ntes_nuid`, 还有 `cellphone_existence_check`/`captcha_verify`);
  二维码轮询间隔 2s(`ui/lib/src/login_sheet.dart:64`), 比网页版(约 3s)更密。
- 影响: 单独不致命, 但会把前 4 条的综合分再抬高。
- 判定: 用 curl(OpenSSL, 另一套 JA3)发完全相同的 cookie/body: curl 也失败而浏览器
  成功 ⇒ 传输栈/会话层; curl 与浏览器都成功而 reqwest 失败 ⇒ 必须看证书/HTTP 版本。

## 报告级建议(本次不改代码, 仅结论)

1. 先补"页面上下文": 登录前 GET `https://music.163.com/` 收 `Set-Cookie`
   (`__csrf`, `NMTID`, `_ntes_nuid` 若缺), 再发 unikey/发码; 并让 `csrf_token`
   取真值而非空串。这是**唯一一条纯应用层就能改、且证据最硬**的差异。
2. 形态二选一: 要么彻底"浏览器"(去掉 `deviceId/appver/osver/channel` cookie, 补齐
   Origin/Accept-Language, 明文 `/api/` 路由), 要么彻底"桌面客户端"(eapi + 客户端 UA)。
   现在是两者的混搭。
3. 安卓端不受影响(走官方登录页 WebView, 见 `.pi/memory/notes-api.md:3,17`); 受影响的
   是桌面端与内置 API 直连的"网页通道"。真要不被风控, 长期解是桌面也复用官方页
   (WebView/系统浏览器 + 读 cookie), 代价是拿不到 HttpOnly 的 `MUSIC_U`
   —— 也就是 `.pi/memory/notes-api.md:5` 里记的约束。

## 必须真机/联网验证的点

- **短信 4 位**: 4 位码不是网页登录通道的正常形态, 但"4 位 = 风控分流"目前只是推断。
  判定必须实测: ① 同一号码当天先用**官方 PC 网页**(Chrome 无痕)发一次码, 记录位数;
  ② 再用本项目发码, 记录位数; ③ 记录两次 `sent` 响应的 `code/message/expiresIn`。
  只有 ①6 位 ②4 位 才算坐实"被分流"。
- **微信扫不了**: 需要手机微信分别扫官方页二维码与本项目二维码。若本项目的一扫即
  "二维码已失效/非官方渠道", 立刻在同进程再 poll 一次看是否 800(过期) —— 若 unikey
  后第一次 poll 就是 800, 说明 key 在服务端就被判无效(与第 1/4 条同源)。
- **对照实验(不改代码)**: mitmproxy 抓"官方页登录"与"本项目登录"两组请求, 逐字段
  diff `Cookie / UA / Referer / Origin / Accept-Language / 路由前缀 / body`。
  这是把上面 5 条从"差异"变成"因果"的最快路径。
