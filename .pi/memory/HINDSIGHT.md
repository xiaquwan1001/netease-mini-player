# Hindsight — netease-mini-player

API/protocol details and anti-bot technique live in the
`netease-cloud-music-api-reverse` skill. Durable lessons:

- 网易云 2024+ 反爬：`xeapi` + TLS/JA3 指纹 + 反作弊 token；标准安卓 TLS 栈全被拦。
  可行解法 = 模拟网页端形态读接口；登录走官方网页（WebView + `MUSIC_U` cookie）零风控。
- 分离调试变量：先用远程 API 服务（本地起 api-enhanced）验证 App 逻辑，再压直连风控，
  否则会把"App bug"误当"风控"排查。
- 内部 URI ≠ 路由路径：路由路径可能 404，按文档用内部 URI。
- 响应默认明文（`encryptResponse=false`）；`login_qr_key` 的 unikey 在顶层 `res.unikey`。
- 播放 URL 走 `linuxapi`（`/api/song/enhance/player/url/v1`）。
- 架构验证：原生壳 + JS SPA + provider 注册表可把 APK 压到几十 KB 并保持可热更新。

## Environment
- 构建：`gradle assembleDebug`；安卓环境纯用户级安装。
- 真机优先；`adb logcat` + grep 是最顺的排查方式。
