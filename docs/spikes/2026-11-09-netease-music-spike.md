# spike: netease-music 0.1.1 替代 vendor ncm-api 验证

## 结论

**倾向「不切 / 需补验证」**：搜索与歌词与现实现完全一致，但 (a) 取链在匿名态两端都拿不到真实 URL（ncm=404、crate=-460/404，均被风控拦），登录态下的 level 降级行为未验证；(b) 身份不等价：crate 每进程随机 device_id/sDeviceId/_ntes_nuid，虽然可用 builder().cookie() 回灌 identity.json，但 appver 形态比仓库现值粗（3.1.17+versioncode vs 3.1.17.204416），需要自建身份注入/持久化层才能避免风控漂移；(c) Android 交叉编译摩擦见 §7。对照表见 §8。

## 1. 依赖与可编译性

- `cargo add netease-music@0.1.1`：成功，Locking 174 packages。
- cargo tree：总行 302，唯一包名 132 个（含 tokio）。头部依赖：aes/cbc/ecb、base64、bytes、flate2 等。
- build：见下方原始输出。

```
   Compiling spike v0.1.0 (/home/xuqianhui/.cache/pi-spike-netease-music)
    Finished `release` profile [optimized] target(s) in 13.01s
	Command being timed: "timeout 300 cargo build --release --target-dir /home/xuqianhui/.cache/pi-spike-netease-music/target"
	User time (seconds): 145.90
	System time (seconds): 13.19
	Percent of CPU this job got: 1221%
	Elapsed (wall clock) time (h:mm:ss or m:ss): 0:13.02
	Average shared text size (kbytes): 0
	Average unshared data size (kbytes): 0
	Average stack size (kbytes): 0
	Average total size (kbytes): 0
	Maximum resident set size (kbytes): 525800
	Average resident set size (kbytes): 0
	Major (requiring I/O) page faults: 1175
	Minor (reclaiming a frame) page faults: 3712412
	Voluntary context switches: 34510
	Involuntary context switches: 34222
	Swaps: 0
	File system inputs: 76112
	File system outputs: 1046072
	Socket messages sent: 0
	Socket messages received: 0
	Signals delivered: 0
	Page size (bytes): 4096
	Exit status: 0

```

## 2. 搜索一致性

一致 ✅。两边对 `晴天` limit 5 返回**完全相同的 id 集合与顺序**：`2668397359, 2653714443, 3391116218, 2730151393, 3452155836`。

crate 侧原始输出：
```
status=200 code=Some(200)
2668397359	晴天 (原唱 周杰伦)
2653714443	晴天 (女声版))
3391116218	晴天
2730151393	晴天(DJ版)
3452155836	絶対晴天！！
```

注：crate 默认 search 走 eapi `/eapi/cloudsearch/pc`；首次请求遇 ConnectionReset(os 104)，重试即成功（本机对网易偶发 reset，ncm 二进制同样出现，非 crate 缺陷）。

## 3. 取链一致性

**匿名态无法验证 level/size**：两端都被拦。
- ncm 二进制（隔离 HOME 数据目录、匿名）：`url 186016` → 两次 ConnectionReset 后稳定 `error: [notFound] code=404`（连续 5 次）。
- crate `song_url_v1(186016, exhigh)`：5 次尝试中 2 次返回 `{"code":-460,"message":"检测到您的网络环境存在风险，请稍后再试"}`，其余 3 次 code=200 但 data 内 `code=404, url=None, size=0, level=None`。
- 结论：匿名无 MUSIC_U 时取链被拒绝，**必须带登录 cookie 重测**（未验证项）。响应结构（data[]/level/size/fee/code）与 vendor 一致。

## 4. 歌词一致性

一致 ✅。id=186016：crate `lrc_len=2486`，首行 `[00:00.000] 作词 : 周杰伦`；ncm 首行相同（作曲/编曲/制作人/吉他… 全同）。

## 5. 身份等价性

**不等价，需要自建身份注入层** ⚠️。

crate `NeteaseMusicClient::new()` 默认只设 1 个 cookie：`sDeviceId = 7F9C..45C3(len=52)`，且每进程 random_device_id()/generate_s_device_id() 重新随机。

仓库 `~/.local/share/ncm/identity.json`（只读、脱敏）：`cookie = JSES..4bit(len=2009)`（完整串含 MUSIC_U）、`device_id = BF44..C41F(len=52)`、profile.user_id/nickname/vip。

源码比对（netease-music-0.1.1/src/client.rs）：
- `apply_request_strategy()` 补 `os=pc, appver=3.1.17, versioncode=204416, osver=Microsoft-Windows-10-Professional-build-19045-64bit, channel=netease, WEVNSM=1.0.0`，并用 `ensure_cookie`（已有值不覆盖）补 `deviceId/WNMCID/_ntes_nuid/_ntes_nnid/NMTID`。
- 五个设备指纹键齐全 ✅；`ensure_cookie` 保证回灌 identity.json 的 cookie 键后不会被随机值覆盖。
- appver 形态差异：crate `"3.1.17"`+versioncode `204416`，仓库 pc profile 为 `"3.1.17.204416"`（identity.rs L45）；osver 相同。
- 判定：**不回灌 → 每进程换设备 → 必然漂移**；回灌 device_id + cookie 键可复用现网身份，风险可控但 os/appver 细微差异未验证。仓库 Android 形态(appver 8.20.20/osver 14) crate 无对应 profile，需走 raw_eapi 自己管指纹。

## 6. 扫码登录形态

形态可用 ✅（未做真实扫码）：
```
key_status=200 unikey_prefix=https://music.16…
qr_url=https://music.163.com/login?codekey=https://music.163.com/login?codekey=674ef64f-…
check_status=200 code=Some(800)  {"code":800,"message":"二维码不存在或已过期"}
```
未扫码 `login_qr_check` 返回 **800**（符合预期）。坑：`login_qr_key` 返回的 unikey 本身已是完整 URL（`https://music.163.com/login?codekey=<uuid>`），`login_qr_url()` 又再拼一遍前缀产生畸形 URL——集成时自己截 codekey。

## 7. Android 交叉编译

**需配 NDK 环境变量，配好后一次通过** ✅（编译产物 OK，未上机）。

第一跑（仅 `source tools/env.sh`，`ANDROID_NDK_HOME` 为空）失败：
```
error occurred in cc-rs: failed to find tool "aarch64-linux-android-clang": No such file or directory
```
命中者是 cc-rs 系 crate（依赖树含 **ring v0.17.14**、**zstd-sys v2.1.2**）。

修法（配好即成，7.9s 编完 174 个包）：
```
export ANDROID_NDK_HOME=~/android-dev/sdk/ndk/28.2.13676358
export CC_aarch64_linux_android=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android23-clang
export CXX_aarch64_linux_android=…clang++   AR=…llvm-ar
# .cargo/config.toml:
[target.aarch64-linux-android]
linker = "…/aarch64-linux-android23-clang"
```
不设 linker 时中间产物能编出来，最后一步用宿主 ld.bfd 报 `Relocations in generic ELF (EM: 183) / file in wrong format`。
另注意：env.sh 只配 PATH/镜像，**不导出 ANDROID_NDK_HOME**，交叉 Rust 必须自己给。

## 8. 收益/代价对照

| 维度 | vendor ncm-api（现状） | netease-music 0.1.1 |
|---|---|---|
| 依赖量 | 213 包 | 132 包（-81） |
| tokio | 全套 tokio | 仍含 tokio（reqwest 链路），并非「同步 API 去 tokio」 |
| 自持加解密 | ~2.4k 行自维护 | crate 内置（weapi/eapi/linuxapi + ncbl） |
| 搜索/歌词 | — | 与现实现完全一致 ✅ |
| 取链 | 匿名 404 | 匿名 -460/404（登录态 level 未验证 ⚠️） |
| 身份 | identity.rs 完整（4 形态 + 持久化指纹） | 每进程随机，需自建回灌层；appver 形态更粗 ⚠️ |
| QR 登录 | — | 可用，code 800 正常；unikey 是完整 URL 的坑 |
| Android 交叉编译 | 现有 cargokit 链路 | 需手配 NDK CC/linker，配好即过 ✅ |
| API 覆盖 | 全功能 | 118 请求中约 43 个无同步方法（有 raw_eapi/weapi 逃生口） |

**建议：暂不切，需补验证**。理由：决定性的两项（登录态取链 level 降级、身份注入后风控表现）没验证；且切换必须新写一层「identity.json → ClientBuilder.cookie() 回灌 + device_id 持久化 + appver 形态对齐」封装，工作量 ≈ 保留现有 identity.rs，净收益缩到「少 2.4k 行加解密维护」。

补验证清单（全过再切）：
1. 回灌 MUSIC_U 后重测 `song_url_v1` level/size 与 vendor 对比（exhigh/lossless/hires）。
2. 回灌身份后多进程跑，确认 device_id/sDeviceId/_ntes_nuid 稳定、无 -460。
3. Android 形态（appver 8.20.20/osver 14）经 raw_eapi 注入是否被风控接受。
4. 本项目用到的 43 个缺失接口能否全走 raw_*。

## 附：可复现命令清单

```bash
# 工作区: /home/xuqianhui/.cache/pi-spike-netease-music (独立 target/)
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
cd /home/xuqianhui/.cache/pi-spike-netease-music
cargo add netease-music@0.1.1 && cargo add serde_json
cargo tree                              # §1
timeout 300 cargo build --release --target-dir $PWD/target   # §1
target/release/spike cookies            # §5
target/release/spike search 晴天        # §2
target/release/spike url 186016 exhigh  # §3
target/release/spike lyric 186016       # §4
target/release/spike qr                 # §6
HOME=$PWD/ncmdata timeout 60 /home/xuqianhui/netease-mini-player/core/target/release/ncm search 晴天 --limit 5
HOME=$PWD/ncmdata timeout 60 /home/xuqianhui/netease-mini-player/core/target/release/ncm url 186016
HOME=$PWD/ncmdata timeout 60 /home/xuqianhui/netease-mini-player/core/target/release/ncm lyric 186016
# §7 Android:
export ANDROID_NDK_HOME=~/android-dev/sdk/ndk/28.2.13676358
export CC_aarch64_linux_android=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android23-clang
export CXX_aarch64_linux_android=${CC_aarch64_linux_android}++
export AR_aarch64_linux_android=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar
timeout 600 cargo build --release --target aarch64-linux-android --target-dir $PWD/target
```
测试程序: `src/main.rs`（子命令 cookies/search/url/lyric/qr）。
