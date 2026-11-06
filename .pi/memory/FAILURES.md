# Failures — netease-mini-player

- 把 App 逻辑错误误判为安卓直连风控（或反之）：先隔离变量再归因。
- 用路由路径当内部 URI 调接口 → 404，误以为接口变更。
- 在标准安卓 TLS 栈上硬碰反爬：JA3 指纹会被拦，应改用网页形态。
- 追求大而全的依赖栈：与 <500KB、零第三方 Gradle 依赖的目标冲突。
- 把"中间设备拦截明文 http(502 空 body)"误判成音频解码问题: 报错文案是 ExoPlayer 的 extractor
  列表, 但真正的证据是 status/内容类型 —— 先看服务端给了什么, 再怀疑解码器。
- 没检查代理环境变量就断言"接口挂了/设备风控": reqwest 的 `error sending request` 对
  "代理端口没人监听"和"真断网"长得一模一样。
- 看到"模拟器里 https 打不开"就先骂站点/风控: 先分栈验证——同一 guest 里 rustls 通、
  chromium 不通, 且宿主 curl 通 ⇒ 先怀疑模拟器的会话语义(本次是 wlan0/netsim, 关 wifi 即好)。
- 身份指纹"成套"才有效: cookie 说 `os=pc` 而 UA 是 iPhone / 网页是移动版, 属于自相矛盾的客户端,
  风控会"假通过"(静默降权)而不是报错 —— 曾长期带着这个不一致在跑。

§
## 2026-11-05 手工跑 cargo test 挂 vendor 联网集成测试
- `tools/env.sh` 会 export 指向 127.0.0.1:7890 的代理变量(本机 7890 常没起): 手工跑 `cargo test --manifest-path core/Cargo.toml` 时 vendor/ncm-api 的 8 个真实联网集成测试 reqwest 走死代理必挂 `assert!(result.is_ok())`。手工跑测试前必须 `unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY`(ci.sh 自己会 unset, 所以 CI 没暴露)。
- vendor/ncm-api/tests/integration.rs(8 个)打真实网易云接口, 全量连跑偶发 1~3 个风控失败, 且每轮失败集合不同; 单独复跑即过, 是网络抖动不是代码问题。判据: 只盯新增/离线单测, vendor 联网测试复跑确认。
- fabric/pi 会话里别裸 `git stash`: 会把运行时一直改写的 `.pi/fabric/mesh/state.json` 一起 stash, pop 必被卡"本地修改将被合并操作覆盖"。解法: pop 前 `git checkout -- .pi/fabric/mesh/state.json` 再 pop。

§
## 2026-11-06 封面图全 403 / 切 tab 占位符高频闪烁
- 现象: 所有封面/头像只显示占位音符, logcat 里逐个 `HTTP request failed, statusCode: 403`; 切 tab 时占位符和图片交替闪。
- 根因 1(403): 网易 CDN 对默认 `Dart/3.x (dart:io)` UA 回 403。用 `Image.network(headers: {'User-Agent': browser})` **修不好** —— NetworkImage 内部是 `HttpHeaders.add`, 会**追加**到 HttpClient 预置的默认 UA 后面, 实际发出 "Dart/3.9 (dart:io), Mozilla/..." 拼接值, 照样 403。必须自定义 ImageProvider, 用 `HttpClient()..userAgent = ...` 整体替换(见 `ui/lib/src/cover_art.dart::_UaNetworkImage`)。
- 根因 2(闪烁): tab 用 switch 直接返回新 Widget ⇒ 每次切 tab 都销毁重建子树, 图片 State 重来 + 占位符重绘。改为 IndexedStack + 访问过才构建(`_tabVisited`), 并让 provider 实现 `==`/`hashCode` 以命中 ImageCache, 再加 `gaplessPlayback: true`。
- 判据: `adb logcat | grep IMGFAIL` 为 0; 连续截图 md5 相同即无闪烁。
