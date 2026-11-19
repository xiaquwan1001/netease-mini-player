# 多端测试指南(Android 模拟器 · Linux · Windows)

> **2026-11-19 合并**: 本文件由 `docs/testing-dual-platform.md`(旧标题写「dual」= 两端, 实为三端)与
> `docs/smoke-desktop.md`(桌面发布前 31 条冒烟清单)合并而来, **原文零删改**: 上篇=日常自测流程,
> 下篇=桌面发布前冒烟清单。旧的两条路径已删除, 代码注释/脚本里的旧路径按本文件解析。
>
> 分工: **日常回归**用上篇(Android 模拟器 + Linux, 语义树驱动, 可 agent 自测); **发版前**再走上篇 §6.5
> 起底 + 下篇 31 条人工清单(每条都写了通过判据, 不写"检查一下")。

---

## 上篇: 日常自测流程(Android 模拟器 / Linux, 语义驱动)

> **2026-11-10 补 Windows**: 第三端 Windows 桌面版已合入, 但**本机是 Linux, 无法本地构建/运行 Windows 版** ——
> Windows 侧的验证口径只有两条: ①`.github/workflows/windows.yml` 在 `windows-latest` 上编出 zip 并成功(实测 ~17 MB);
> ②用户在有 Windows 的机器上解压运行冒烟。本文件其余流程仍以 Android 模拟器 + Linux 为主。

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
```

> **headless 必须显式给 GPU 后端**: `~/bin/avd` 的 `COMMON` 里是 `-gpu host`, 无窗口时 gfxstream 会拿到空 ctx
> 然后**段错误** —— 表现是跑到一半 `device offline` / `device 'emulator-5554' not found`, 很容易误判成测试挂了
> (2026-11-19 实测; 日志判据是 `/tmp/avd-a34-*.log` 里的 `null ctx` + `段错误(核心已转储)`)。稳妥起法:
>
> ```bash
> nohup ~/bin/avd headless a34 -gpu swiftshader_indirect -no-snapshot > /tmp/avd-a34.log 2>&1 &
> ```
>
> 排查顺序: `pgrep -f qemu-system`(进程还在吗) → `/tmp/avd-*.log` 尾部 → 再怀疑用例。

装包:

```bash
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

---

## 下篇: 桌面端(Linux/Windows)发布前冒烟清单(31 条)

> 用法: 先跑 `bash tools/smoke-desktop.sh --env` 做机器侧预检, 再按本清单逐条人工验证,
> 装完跑 `bash tools/smoke-desktop.sh --run BUNDLE=<bundle路径>` 采启动耗时,
> 最后 `--report` 把两段输出拼成 markdown 贴进 issue/PR。
> 目标: 全部走完 ≤ 10 分钟。每条写明**通过判据**(看什么、命令是什么), 不写"检查一下"。

标记约定: ✅ 通过 / ❌ 不通过(写现象) / N/A(该环境不适用) / S(脚本已自动覆盖)。

## 1. 安装

1. **deb 安装**: `sudo apt install ./minincm_<ver>_amd64.deb` → 无报错。
   判据: 终端 exit code 0, 且 `dpkg -l minincm` 显示 installed, `which minincm` 输出 /usr/bin/minincm。
2. **AppImage 直接运行**: `chmod +x MiniNCM-<ver>-x86_64.AppImage && ./MiniNCM-<ver>-x86_64.AppImage` → 主窗口出现。
   判据: 命令 15 秒内出窗口; 终端无 `dlopen(): error loading libfuse.so.2`。
3. **AppImage 首启 FUSE 行为**(无 FUSE 系统): 若报 libfuse 缺失, 应能用 `--appimage-extract` 兜底:
   `./MiniNCM-*.AppImage --appimage-extract` 后运行 `squashfs-root/AppRun`。
   判据: 两条路径至少一条可用, 且报错文案可读。
4. **tar.gz 解压运行**: `tar xf minincm-<ver>-linux-x64.tar.gz -C ~/apps-test && ~/apps-test/minincm/minincm`。
   判据: 解压后目录内有 `minincm` 可执行 + `lib/` + `data/`, 直接运行出窗口、
   无 `error while loading shared libraries`。
5. **S**: bundle 架构与 GLib 符号基线 — 脚本 `--env` 已检查(readelf Machine + 不得引用
   `g_once_init_*_pointer`, 否则 Ubuntu 22.04 起不来, 思路同 packaging/linux/build-deb.sh)。
   判据: --env 输出 `ARCH ... OK` 且 `GLIB-SYMBOL ... OK`。

## 2. 启动与外观

6. **S**: 启动耗时 — `--run BUNDLE=<bundle>` 输出启动毫秒数。
   判据: release 包冷启动 < 3s; **debug 包首帧慢是 debug JIT 成本, 不作数**(见 `.pi/memory/notes-build.md`「启动卡 3s」条, 原记录已归档在 `docs/archive/PROGRESS-2026-11-03-11-12.md`)。
7. **主题色 5 色 × 浅/深**: 设置 → 界面 → 主题色, 依次点 红/绿/蓝/橘/粉, 每次各看浅色/深色一眼。
   判据: 每个组合下播放条/选中高亮的主色肉眼可辨互不相同, 深色模式无白底闪烁。
8. **界面字号 4 档**: 设置 → 界面 → 字号, 最小/偏小/标准/最大逐档切换。
   判据: 切档即时生效(无需重启), 最大档下设置页无文字溢出/截断。
9. **OLED 纯黑**: 设置 → 界面 → OLED 纯黑 开启 + 深色模式。
   判据: 列表/设置页背景为纯黑(与非 OLED 的深色灰底对比肉眼可见更黑), 文字仍可读。
10. **窗口缩放**: 最大化→还原→拖窄到最窄。
    判据: 播放条缩到迷你条不溢出, 还原后布局复原。

## 3. 登录

11. **桌面扫码登录**: 未登录点「登录」→ 弹出 QR 窗口 → 手机 App 扫码确认。
    判据: 确认后 QR 窗口自动关闭, 主界面昵称/头像变为登录账号, 无需重启应用。
12. **未登录态不串号**: 退出登录(或用全新 DATA 目录)后冷启动。
    判据: 我的页不显示**上个账号**的昵称/VIP 徽标, 显示「未登录」入口。
13. **登录身份持久化**: 登录后关闭应用再启动。
    判据: 重开即已登录, 无需重扫。

## 4. 播放

14. **搜索→播放**: 搜索任意热门歌 → 点结果播放。
    判据: 播放条出现歌名/封面, 3 秒内有声, 终端无持续报错刷屏。
15. **暂停/上下曲**: 点暂停、播放、上一曲、下一曲。
    判据: 每次点击 1 秒内状态切换, 图标与声音一致。
16. **拖动进度条**: 播放中把进度拖到 50%。
    判据: 拖后从目标位置继续, 时间显示与拖动位置一致(±1s)。
17. **歌词切换**: 打开歌词页, 等两句歌词, 点某句跳转。
    判据: 当前句高亮随播放滚动; 点击后从该句重新播放。
18. **音量与响度均衡**: 拖音量 0↔100; 设置里开关响度均衡后放同一首歌。
    判据: 音量 0 无声、100 明显更大; 响度均衡开/关时响度差异可感知且不爆音。
19. **媒体键**: 终端跑 `playerctl play-pause` 或按键盘媒体键。
    判据: `playerctl status` 反映播放状态; 桌面无 MPRIS 时标 **N/A**
    (Linux 桌面无通知栏媒体卡片)。
20. **重开后播放位置**: 播放中途退出应用再启动, 打开播放页/最近播放。
    判据: 能看到退出前曲目, 点继续能播放该曲(允许从头)。

## 5. 我的 / 设置 / 账号

21. **会员行**: 登录后看「我的」页会员/等级行。
    判据: VIP 账号显示会员标识与到期信息; 非会员账号显示非会员文案, 两者不混淆。
22. **诊断页**: 设置 → 诊断。
    判据: 能看到设备 ID 与数据目录路径, 页面内容可复制。
23. **检查更新**: 设置 → 检查更新。
    判据: 已是最新版时提示「已是最新」; 网络失败时文案可读、不崩溃。

## 6. 退出与重开

24. **S**: DATA 目录存在与权限 — 脚本 `--env` 检查 `~/.local/share/ncm` 存在且当前用户可写。
    判据: --env 输出 `DATA-DIR ... OK`。
25. **身份持久化(device_id 不变)**: 记下诊断页设备 ID → 退出 → 重开 → 再看。
    判据: 两次 ID 完全相同; DATA 目录内身份/cookie 文件重开后未被清空。
26. **设置恢复**: 退出前把主题色改蓝、字号最大、OLED 开 → 退出 → 重开。
    判据: 三项设置与退出前一致, 不回落默认。

## 7. 已知不可用 / 受限项(只确认文案或标注, 不排障)

27. **vivo 锁屏歌词**: N/A — vivo 锁屏歌词是 Android 特性, 桌面端无锁屏歌词通道。
28. **MV 播放**: 桌面走系统播放器打开直链(无内嵌 VideoView)。
    判据: 系统默认播放器弹出并播放; 无默认播放器时有可读提示而非静默失败。
29. **arm64 AppImage**: 未在 aarch64 真机验证过。冒烟只确认 x86_64 产物;
    arm64 产物保留「未验证」标注, 不阻塞发布。
30. **Linux 通知栏**: 桌面无系统通知栏, 播放通知/媒体卡片 N/A(见第 19 条)。
31. **release workflow 接入**: 冒烟脚本本次**不**接入 release 流程(不动 .github/**);
    建议: 后续在发布后用 workflow 手动触发一条人工冒烟 checklist issue(仅建议, 未实现)。

---

## 统计

- 共 **31** 条: **脚本自动 3** 条(#5 #6 #24), **人工 28** 条(其中 N/A/受限标注 5 条: #27 #29 #30 及环境相关 #19 #23)。
