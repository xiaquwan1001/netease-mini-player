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
