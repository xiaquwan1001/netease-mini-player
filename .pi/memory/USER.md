# User Memory — netease-mini-player

- 目标：功能与实现解耦、一切皆插件、从重要到次要逐步实现；轻量高效（APK 目标 <500KB）。
- 原生层只做三件事：HTTP IO 桥、SharedPreferences 存储、MediaPlayer 前台播放；
  全部业务逻辑在前端 JS。
- Linux 开发：命令行 `adb logcat` 过滤日志排查；有真机就优先真机而非模拟器。
- 真机交互（扫码/操作 App）由**用户在设备上亲自操作**，助手准备资产、给精确步骤并监控日志。
- 环境一律纯用户级安装，不碰系统包。
- 排障先锁定变量（分离"App 逻辑问题"与"安卓直连风控问题"），不盲试。
- 中文交流。
- **对外 PR 的默认目标项目 = Melodia**（rinchao0721/Melodia，KMP/Compose，MIT）。
  以后说「提 PR / 给上游提」一律默认它；源码本地副本已迁出为独立项目 `~/Melodia`（2026-11-02）。
  已发对象：#133 评论、#134 issue、#135/#136/#137/#139/#140/#141/#142/#144 PR、#138 追问评论。 <!-- created=2026-11-02, last=2026-11-03 -->

## 通用工作风格
- 减少反复的同质化思考，每种方案只需一次正反判断。
- 先查社区现成资源与本地已有等效资产。

## 测试分工(2026-11-04 用户明确)
- **功能/逻辑验证一律先在 PC 安卓模拟器(a34 / a36 两台, debug 包)上做**; 单台内串行,
  两台可各跑一个批次(按 `adb -s emulator-5554/5556` 区分, 写操作别抢同一账号)。
  vivo 真机(V2454A)降级为**只在打包发布时做冒烟**(装 release apk、确认能启动/能播/通知栏正常)。
- 原因: 真机会被用户拿去用、自动锁屏(实测 screencap 全黑)、vivo 还关掉了 logcat(`adb logcat` 无输出),
  交互验证成本高; 模拟器可随时点、能拿 logcat/dumpsys。
- vivo 特殊点: `wm density` override = 768(实际逻辑宽仅 300dp)、font_scale=1.25 → 布局要按窄屏+大字号验证
  (AppBar 标题曾截断, 已改 FittedBox)。
- vivo 上 adb root 可用(可 pull /data/data 取 identity.json), 用完记得 `adb unroot`。
<!-- created=2026-11-04, last=2026-11-04 -->
