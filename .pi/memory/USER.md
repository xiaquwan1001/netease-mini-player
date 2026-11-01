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
  以后说「提 PR / 给上游提」一律默认它；源码本地副本 `references/Melodia/`（gitignored，浅克隆）。
  已发对象：#133 评论、#134 issue、#135/#136/#137 PR。 <!-- created=2026-11-02, last=2026-11-02 -->

## 通用工作风格
- 减少反复的同质化思考，每种方案只需一次正反判断。
- 先查社区现成资源与本地已有等效资产。
