# 双端测试记录(Linux + Android 模拟器)

> 最近验证: **2026-11-08**(播放条合并 / 歌曲详情页 / 分享, 详见 `docs/archive/ui-song-detail-share.md`)。
> 日常功能回归优先 Android 模拟器(**本项目默认 a34; a36 常被另一项目借走**);
> Linux 验证 UI 布局 + 真实网络/播放链路。真机只在打包发布时做冒烟。

## 1. 环境

| 端 | 环境 |
|---|---|
| Android | AVD **两台**: `a34`(API 34) / `a36`(API 36 / Android 16), x86_64 google_apis, 无窗口启动。
先启的那台占 5554, 第二台 5556; 命令一律带 `adb -s emulator-XXXX`。两台可并行跑不同批次(写操作别抢同一账号) |
| Linux | Xvfb `:99`(1280x720)+ `GDK_BACKEND=x11`,`flutter build linux --debug` |

启动/安装(本项目用 **a34**;若 a36 空闲也可用):

```bash
source tools/env.sh
~/bin/avd headless a34                       # 无窗口 + 自动关 netsim wifi
DEV=$(adb devices | awk '/emulator-/{print $1; exit}')   # a34 若排在第二台会是 emulator-5556
echo "DEV=$DEV"

adb -s "$DEV" shell pm grant com.minincm.minincm android.permission.POST_NOTIFICATIONS
# debug APK 现在 ~213MB(双 ABI): 必须 --no-streaming, 否则报
# INSTALL_PARSE_FAILED_NO_CERTIFICATES (SHA-256 digest did not verify)
adb -s "$DEV" install --no-streaming -r -t ui/build/app/outputs/flutter-apk/app-debug.apk
adb -s "$DEV" shell monkey -p com.minincm.minincm -c android.intent.category.LAUNCHER 1
```

### 1.1 无窗口模拟器上怎么"看"和"点"(agent 自测用)

Flutter 的语义树能被 uiautomator 读到,前提是打开无障碍开关:

```bash
export DEV=$(adb devices | awk '/emulator-/{print $1; exit}')   # 所有 devui 脚本都认 $DEV
adb -s "$DEV" shell settings put secure accessibility_enabled 1  # Flutter 才上报语义树

tools/devui/uix                 # 列所有 content-desc + bounds(失败退出码 3)
tools/devui/uix 分享            # 只列含关键词的节点
tools/devui/uitap "分享这首歌"   # 按文案点击
tools/devui/uilong "The club"    # 按文案长按(900ms)
tools/devui/shot /tmp/a.png      # 截图
tools/devui/shotmap /tmp/a.png 44 40        # 灰度 ASCII 缩略图
tools/devui/cropmap /tmp/a.png x y w h 8 8  # 区域 RGB 均值表(查背景色/红黄条)
```

脚本都在 `tools/devui/`(见该目录 README); **`uiautomator dump` 报 `could not get idle state` 的唯一原因是 App 一直在出帧**:
播放中每 500ms 一次 `setState`、输入框光标闪烁都算。对策: 先点播放条的播放/暂停键暂停
(`_pollPlayer` 值不变时已不再 setState),让输入框失焦后立刻能 dump;
**不要**用 `input keyevent 4` 退出 App —— 那样 dump 拿到的是 launcher。

Linux(注意先清代理,见第 5 节):

```bash
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
Xvfb :99 -screen 0 1280x720x24 &
DISPLAY=:99 GDK_BACKEND=x11 NCM_DATA_DIR=/tmp/ncm-a36 \
  ui/build/linux/x64/debug/bundle/minincm
# 截图(按实际屏幕尺寸)
ffmpeg -y -f x11grab -video_size 1280x720 -i :99.0 -frames:v 1 /tmp/linux.png
```

## 2. 用模拟器登录态验证 Linux(不碰真实数据目录)

debug 包的凭据可以直接从模拟器拉出来,放到独立目录给 Linux/CLI 用:

```bash
adb -s emulator-5554 shell run-as com.minincm.minincm cat files/ncm/identity.json > /tmp/identity.json
mkdir -p /tmp/ncm-a36 && cp /tmp/identity.json /tmp/ncm-a36/identity.json
NCM_DATA_DIR=/tmp/ncm-a36 ./core/target/debug/ncm whoami
```

- `identity.json` 含 `MUSIC_U`,**只放临时目录,不要提交/外传**。
- Linux 的 `Playback.dataDir()` 返回 null,Rust 会回落到 `NCM_DATA_DIR`,所以这样能
  在桌面端用同一账号测试,而不覆盖 `~/.local/share/ncm`。

## 3. 验证项与结果

| 功能 | Android(a34/a36 模拟器) | Linux Xvfb |
|---|---|---|
| 底部四栏(搜索/推荐/我的/设置) | ✅ | ✅ |
| 搜索历史 + 猜你想搜 + 热词榜 | ✅ 真实数据 | ✅ 真实数据 |
| 热词点击 → 搜索结果 | ✅ | ✅ |
| 每日推荐歌曲/歌单 | ✅ | ✅(含真实封面) |
| 推荐播客 | ✅ | ✅ |
| 每日私人 FM 播放 | ✅ MediaSession `PLAYING` | 未单独点 FM;普通歌曲播放通过 |
| 心动模式入口 | ✅ | ✅ |
| 我的: 我喜欢/歌单/播客/关注艺人/关注动态 | ✅ | ✅(我喜欢/歌单已验) |
| 关注动态内容(艺人分享单曲/配文/时间) | ✅ | — |
| 设置: 账号昵称/VIP/账号管理 | ✅ | ✅(无账号簿时显示"已登录") |
| 设置: 主题即时切换/字号/音质 | ✅ | ✅ |
| 播放条 + 队列 | ✅ | ✅ 00:10/02:40, 1/34 |

## 4. 本轮发现并修复的问题

1. **私人 FM 报 `no provider supports personalFm`**
   `Capability::PersonalFm` 枚举存在,但 `NeteaseProvider::CAPABILITIES` 漏声明。
   修复: 补能力声明 + `capabilities_include_personal_fm` 单测。
2. **关注动态一直为空**
   - 线上 `/api/v1/event/get` 顶层字段是 `event`(单数),不是 `events`。
   - 事件类型字段是 `type`,不是 `eventType`;`type=35` 是文字动态,`18` 是分享单曲。
   - 修复: 两种字段名都兼容;用真实响应验证并通过单测。

## 5. 踩坑速查

- **HTTPS_PROXY 会毒化 Rust 请求**:宿主代理进程没起时,reqwest 报
  `error sending request for url (...)`,GUI 上表现为热词/推荐一直转圈。
  跑 Linux 前后都要 `unset` 大小写全部代理变量;CLI 可加
  `curl --noproxy '*' ` 对照。
- **Xvfb 尺寸**:`ffmpeg -video_size` 必须和 Xvfb 启动尺寸一致,否则报
  `Capture area ... outside the screen size`。
- **模拟器截图坐标换算**:截图显示 900x2000、实际 1080x2400 时,点击坐标 ×1.2。
- **封面在模拟器上显示音符占位**是模拟器 TLS 问题,不是代码:
  同一 guest 里 Rust 接口正常,Flutter `Image.network` 拉封面域名被重置;真机/Linux 正常。
- **Xvfb + Impeller 下 modal bottom sheet 可能停在屏幕外**(无 DRI3),弹层类交互要上模拟器验证。
- **杀进程不要用 `pkill -f bundle/minincm`**(会匹配到发起命令的 shell);用具体 PID 或
  `pkill -x minincm`。

## 6. 收尾

测试结束后:

```bash
~/bin/avd stop a34          # 或 stopall(a36 若是别人的项目在用, 别 stopall)
kill <linux-app-pid>
```

并确认工作区没有把 `/tmp/ncm-a36`、截图、日志等测试产物写进仓库。
