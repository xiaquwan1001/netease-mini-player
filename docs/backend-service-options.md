# 后端服务形态调研: 是否换"集成度更高、更轻量"的形态

> 2026-11 调研批次(只读, 未改任何代码)。基线 = vendor ncm-api(锁定 commit)全量 + 自写 ncm-service(provider/身份) + ncm-ffi(flutter_rust_bridge)。
> 测量环境: 本仓 core/ workspace, dev profile, 热缓存(之前跑过构建), 网络已 unset 全部 proxy。

## 0. 一句话结论

**不建议换形态(不引入 Node sidecar / 不换第三方后端), 推荐只做两个低成本裁剪: vendor 删未用模块(10.3k→~3.2k LOC) + tokio 去 features=["full"]; 真正的体积大头是 reqwest/tokio/rustls 这套网络栈, 无论选哪种方案都省不掉。**

## 1. 现状量化

| 指标 | 数值 | 说明 |
|---|---|---|
| vendor LOC | **12,035 行** | src/api 10,348 + request.rs 509 + server/ 667 + crypto.rs 200 + util/ 211 |
| vendor 文件数 | **382 个 endpoint 文件**(api/), 平均 ~27 行/个 | 每个文件 = 参数 struct + 请求封装, 很薄 |
| 我们接入的 endpoint | **114/382 (29%)**(api-coverage.sh 口径) | 播放链路已闭环 |
| 我们自写代码 | ncm-service 7,778 + ncm-ffi 12,690 + ncm-domain 1,909 + ncm-provider 1,096 + ncm-cli 1,495 ≈ **25k 行** | 比 vendor 本体大 2 倍 |
| cargo tree (ncm-service) | **213 个唯一包**; ncm_ffi 279 | vendor 边际贡献 ≈ **0 个独有依赖**(comm 对比 vendor 树与服务树无差集) |
| vendor 单独重编译(依赖已缓存) | **1.3 s**; touch mod.rs 增量 2.3 s | vendor **不是**编译时间瓶颈 |
| 端到端延迟(dev, 直连, proxy 已 unset) | search ×5 中位数 **0.39 s**(0.11~0.40 波动, 连接复用影响大); detail ×5 中位数 **0.14 s** | 库本身开销可忽略 |
| 产物体积 | dev: libncm_ffi.so **223 MB**(含 debuginfo, 无参考意义); **无 release 产物可用**(本机未跑过 release/APK) | ⚠️ strip 后体积是本次测量空白, 见附录命令 |
| vendor 许可 | **WTFPL**, 上游 SPlayer-Dev/ncm-api-rs(66★, 最后 push 2026-04-07) | 无传染风险 |

**读法**: vendor 的"拖累"不在编译与依赖(它只比服务层多 0 个独有 crate、增量 1~2s), 而在**维护面**——382 个文件的协议漂移监控面是 114 的 3.4 倍; 真正压体积的是 reqwest+tokio(full)+rustls+rsa 这套, 任何"轻量方案"只要还发 HTTPS 就得带。

## 2. 候选项对比

| 方案 | 依赖/体积 | LOC | 接口覆盖 | 风控形态 | 双端 | 许可 | 活跃度 | 迁移成本 |
|---|---|---|---|---|---|---|---|---|
| **a. 现状(基线)** | 213 crates(服务树), vendor 边际 0 独有依赖 | vendor 12.0k + 自写 25k | 382(用 114) | App 形态 eapi + 身份注入, 已实测通过 | 已通 | WTFPL | 上游 2026-04 后停更 | 0 |
| **b. 裁剪 vendor: 删 268 个未用模块** | 依赖不变(1 个 crate) | vendor 12.0k→**~3.2k**(api 按行数比例 114/382) | 114 + 按需加回 | 不变 | 不变 | WTFPL | 自持 | **低**: 删 268 文件 + api/mod.rs 清单; vendor 是锁定 commit 的死代码, 删了不产生合并冲突; 风险是上游修协议时 diff 变脏——但上游已 7 个月没动, 实际风险低 |
| **c. 自写最小客户端(~15 核心接口)** | 可删 rsa/cbc/regex-lite/chrono(若只走 eapi); tokio 可 rt-only; 估 213→~190 crates | 加解密+请求层参考 Netease-Music-VScode(MIT, TS: crypto 92 + http 249 行)→Rust 约 **1.5–2.5k 行**含 serde struct | 15, 每加一个接口自己写 | 自己维护头序/身份(已有 ncm-service 经验可搬) | 不变 | 自持 | 自持 | **中高**: request.rs 509 行(签名/头序/错误语义)是要重新踩的坑; eapi 加密本体只有 ~60 行, 大头是 endpoint 文件里的隐式参数约定 |
| **d. Node sidecar(NeteaseCloudMusicApi / api-enhanced)** | api-enhanced 仓库 147 MB, Node 18+ runtime; APK 需打包 Node(≈20-40MB/ABI)或依赖 Termux | 服务端 456 模块 | 456 | 服务端形态, 与 App 形态(身份四键/CDN UA)**不一致**, 头序自洽原则被打破(api-channel.md) | Android 不能天然跑 Node(Termux 或自带 runtime); Linux 可 | MIT | api-enhanced 2.2k★, 2026-11 活跃 | **高**: 每请求多一跳 IPC, 离线/后台保活双端差异大, 违背"双端一份二进制"架构 |
| **e. 其它 Rust 现成客户端** | etnt/ncrust(Rust, 0★, 借鉴价值低); Ncrust(GuitaristRin) 是 **Kotlin 不是 Rust**(239★, MIT, 2026-11 活跃) — 其 ClientIdentity 语义我们已吸收进 ncm-service | — | — | 同 App 形态 | Android only | MIT | 见左 | Rust 侧无现成"加解密+请求层"成品; **Netease-Music-VScode(MIT, TS)是最接近的可移植样板** |
| **f. wasm / 单文件服务** | ncm-api-rs 曾带 server feature(axum, optional, 默认不编), **已于 2026-11-09 随 P1 裁剪直接删除**(本项目从未启用, 且启用后因 endpoint 被删会 E0599) — 现状是"集成式内嵌", 独立服务进程是倒退 | — | 382 | 同现状 | 双端各起一进程 | — | — | 负收益, 排除 |

## 3. 推荐路线

**结论: 什么都不换, 只做裁剪。** 理由: vendor 的量化代价(0 个独有依赖、1.3s 增量编译、12k 薄代码)远小于任何迁移成本; "更轻量"的收益上限被网络栈封死。

分三步:

1. **P1 删模块(1 天内)**: 先跑 api-coverage.sh --list 复算, 删除 268 个未接入 endpoint 文件 + api/mod.rs 对应清单行; crypto/request/error/util/server 不动。**验收**: cargo build --offline -p ncm-api-rs 通过、清单仍覆盖 114/114、ncm-cli search/detail 延迟中位数不劣化(search ≤0.4s / detail ≤0.15s)。
2. **P2 依赖瘦身(半天)**: tokio 去 features=["full"] 改按需(rt/macros/time/sync...), 验收同上; 用 cargo tree -e features 复核 vendor 依赖里未用 feature(如 reqwest socks)。
3. **P3 补测量(填本文档空白)**: 跑一次 release build, 记录 strip 前后 libncm_ffi.so 四个 ABI 体积与 APK/Linux bundle 占比; 只有当 strip 后 vendor 相关代码 >5MB 才值得进入"方案 c"。

## 4. 风险与验收指标

**风险**
- **协议漂移**: 上游 7 个月未更新, 风控一变我们仍是唯一维护者, 删模块不减这个风险(本来就在)。缓解: git 历史 + vendor/UPSTREAM.txt 锁定 commit 可按文件随时找回。
- **方案 c 的隐式参数坑**: endpoint 文件里散落的默认值(如 encodeType=flac)是文档外隐式契约, 自写要重踩; 这是"不推荐 c"的主要原因。
- **Node sidecar 形态不一致**(d): 服务端 UA/身份与 App 形态自洽原则冲突, 引入"假通过"类静默降级。
- **双端差异**: 直连方案(a/b/c)双端一致; sidecar(d) 在 Android 的进程保活是独立风险源。

**验收指标(P1+P2 后)**
- vendor LOC ≤ 3.5k; 唯一包数不增(≤213);
- ncm-cli search/detail 延迟中位数不劣化;
- FFI 123 个导出函数编译通过, api-coverage.sh 清单零回退。

## 附录: 测量命令

```bash
cd core
# LOC
find vendor/ncm-api/src -name '*.rs' | xargs wc -l | tail -1
# 依赖树(唯一包数)
cargo tree -p ncm-service --prefix none --offline | sort -u | wc -l
cargo tree -p ncm_ffi    --prefix none --offline | sort -u | wc -l
# vendor 边际独有依赖(应为 0 行)
cargo tree -p ncm-api-rs --prefix none --offline | sort -u > /tmp/a
cargo tree -p ncm-service --prefix none --offline | sort -u > /tmp/b
comm -13 /tmp/b /tmp/a | grep -v '(*)'
# 编译耗时(热缓存增量)
touch vendor/ncm-api/src/api/mod.rs && cargo build --offline --timings -p ncm-api-rs
# 端到端延迟(先 unset proxy)
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
for i in 1 2 3 4 5; do /usr/bin/time -f '%es' target/debug/ncm search 周杰伦 --limit 3 >/dev/null; done
# [待补 P3] release 产物: bash tools/build-android.sh 后看
#   ui/build/rust_lib_minincm/**/arm64-v8a/libncm_ffi.so + llvm-strip 前后
```

*本次测量缺口: release/strip 体积与 APK 占比(本机无 release 产物, 且调研约束禁止全量 build), 已列入 P3。*

---

## 5. 补充实测(2026-11-09 编排者复测, 填 §3 P3 的空缺)

全部数字来自本仓实测, 环境: 本机 dev 热缓存, 网络已 unset 全部 proxy。

### 5.1 产物体积(release/strip 空白已填)

| 产物 | 体积 | 说明 |
|---|---|---|
| `target/release/libncm_ffi.so` | **14,246,736 B (13.6 MiB)** | `cargo build --release -p ncm_ffi --offline` |
| 同上 strip 后 | **8,971,728 B (8.6 MiB)** | 含 std + reqwest + tokio + rustls + vendor 12k + 自写 4k **全部** |
| `target/debug/libncm_ffi.so` | 225,687,640 B (215 MiB) | debuginfo 无参考意义 |
| **Android arm64 release**(P1 裁剪后) | 12,197,912 B (11.6 MiB) → `llvm-strip` 后 **6,564,056 B (6.3 MiB)** | 交叉编译需自配 `ANDROID_NDK_HOME`+`CC_*`+`CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER`(`tools/env.sh` 不带), 否则报 `Relocations in generic ELF (EM: 183)` |
| Linux debug bundle 整树 | 304 MB | = 上者 225 MB + `libflutter_linux_gtk.so` 43 MB |
| `app-debug.apk` | **231.8 MB** | 见下表构成 |

APK(debug, 4 ABI 全打)构成 top:

| 条目 | 体积 |
|---|---|
| `lib/*/libflutter.so` × 3 ABI | 118 MB (x86_64 40.1 / arm64 38.8 / v7a 33.2) |
| `assets/flutter_assets/kernel_blob.bin`(debug JIT) | 46.6 MB |
| `lib/arm64-v8a/libVkLayer_khronos_validation.so` | 15.2 MB |
| `lib/*/libncm_ffi.so` × 4 ABI | 62.6 MB (arm64 16.4 / x86_64 18.1 / x86 19.3 / v7a 8.6) |
| `classes*.dex` | ≈15 MB |
| `isolate_snapshot_data` | 11.6 MB |

**读法**: Rust 侧(arm64 strip 后 16.4 MB)只占 APK **7%**, 而 `libflutter.so` 单 ABI 就 38 MB —— **包体大头是 Flutter 运行时 + debug 配置, 不是协议库**。所以「精简后端」在包体维度的收益上限很低; 正确的第一步是 release + `--split-per-abi`(预估可把 231 MB 打到 ~30–40 MB/ABI), 与选哪个协议库无关。

### 5.2 运行时占用(实测)

| 场景 | RSS / 线程 / CPU |
|---|---|
| Linux debug bundle(`Xvfb :99`, Impeller OpenGL)首帧后 | **555 MB / 84 线程 / ≈47% CPU** |
| Rust core release CLI 单次 `search`(含网络) | **峰值 8.7 MB**, wall 0.52 s |

即 core 侧稳态内存是 MB 级, UI 侧 555 MB 主要是 debug(未 AOT、带 VM service); release 未测, 仍是空白。

### 5.3 构建产物占地

仓库 27 GB 中 **26.9 GB(99.6%)是构建产物**: `ui/build` 18 GB(其中 `rust_lib_minincm` 单目录 **12 GB**, 4 ABI × 多份中间产物) + `core/target/debug` 8.9 GB。源码+文档+参考仓合计 ≈55 MB。

### 5.4 候选库实测: `netease-music` 0.1.1(§2 表外的新发现)

§2 调研时未发现的 crates.io 现成库, 已下载源码并实测依赖树:

| 指标 | 实测值 |
|---|---|
| crate 包体 / 源码 | 40,663 B / `src` **2,448 行**(client 709 + ncbl 704 + services 771 + crypto 149 + request 49 + types/error/lib 66), 另有 tests 145 / example 629 |
| 依赖树 | **132 个唯一包**(同法 `cargo tree` 于临时 crate), 对照 `ncm-service` 213 / `ncm_ffi` 279 ⇒ **↓81 包** |
| tokio | **无直接依赖**, 但**并非「去 tokio」**: 仅经 `reqwest(blocking)` 带入, tokio 仍在链接内(树中 9 处引用)。实务收益只是 FFI 层可去掉自持的 `rt-multi-thread` 直接依赖 + 代码从 async 改同步(见 §6 spike 更正) |
| 其他依赖画像 | reqwest 0.12 blocking+rustls、aes/cbc/ecb/cipher、flate2、**zstd(C)**, ring(asm), num-bigint, md5, rand, serde_json |
| 冷构建 | release **11.07 s**(临时 crate) |
| 许可 | LICENSE.md 是 **MIT 文本**, 但首行 copyright 写着 "GitHub Inc."(沿袭上游 fork); crates.io 元数据因此标 `non-standard`(license-file) ⇒ 实质 MIT 可用, 归档需保留原文 |
| 活跃度 | 单版本 0.1.1(2026-07-01), 仓库 0★ / 519 下载 / 单作者(ddy314, fork 自 anhoder 系) |
| 能力 | weapi/eapi/linuxapi/raw 四种请求; cookie 持久化(捕获 Set-Cookie); **自动补 `appver/osver/_ntes_nuid/NMTID` 身份 cookie**; `interface.music.163.com` eapi 带 encoded client header; **43 个 `pub fn` 类型化封装**(登录/扫码登录/验证码/搜索/联想/热搜/账号/banner/推荐歌单/每日推荐/签到/歌曲 URL v1/歌词/播放上报/歌单详情+全量曲目/歌曲详情/用户详情+歌单/喜欢列表/最近/听歌数据)+ raw 兜底 |
| 缺口 | 我们用的 118 个 endpoint 里只有 **43 个有类型封装**, 其余 ~75 个要走 raw 手写参数; 登录上下文按 **PC 形态**(NetEaseCloudMusicApi 4.32.0)建模, 与我们的 App 形态头序需实测比对 |

**§3 P3 门判定**: 门槛是「strip 后 vendor 相关代码 >5 MB 才值得进入方案 c」。实测 strip 后**整个动态库**(std+网络栈+vendor 12k+自写)仅 8.6 MiB, vendor 部分必然远低于 5 MB ⇒ **门未通过, 方案 c 仍不推荐**。

**新增候选 g(`netease-music`)的定位**: 它不改变「网络栈省不掉」的结论(仍带 reqwest+rustls+tokio 内部运行时), 但在**依赖数(213→132)、自持代码(不写加解密与请求层)、同步 API(FFI 去 tokio)**三点上优于现状; 代价是 118→43 的封装落差与身份形态需重验。是否切换取决于 spike 结论, 见 §6。

### 5.5 收益排序(修正 §3 的优先级)

1. **打包配置**(release + `--split-per-abi` + 去 Vk validation): 收益最大(231 MB → 约 30–40 MB/ABI), 零协议风险;
2. **Rust 依赖瘦身**(P1 vendor 裁剪 + P2 tokio 按需; 或换 `netease-music`): 中等收益, 决定 FFI .so 与编译/维护面;
3. 方案 c(自写最小客户端): 仍不推荐。

## 6. Spike: `netease-music` 可行性验证(2026-11-09 完成)

工作区 `/home/xuqianhui/.cache/pi-spike-netease-music`(独立 target); 完整报告已归档入库: **`docs/spikes/2026-11-09-netease-music-spike.md`**(8 节 + 可复现命令清单)。

### 6.1 结论

**暂不切换。** 搜索/歌词与现实现逐字节一致、Android 交叉编译配好 NDK 后一次通过; 但两项决定性验证都没过:
①**取链**匿名态两端都被风控拦(ncm `code=404`、crate `-460`/`404`), 登录态 level/size 降级行为未测;
②**身份不等价**: crate 每进程 `random_device_id()` + 随机 `sDeviceId`(源码 `client.rs:61,63,598`), 必须新写「identity.json → `ClientBuilder.cookie()` 回灌 + device_id 持久化 + appver 形态对齐」层。
切换的净收益因此缩到「少 ~2.4k 行自维护加解密代码」, 不足以抵消新增身份层与 43/118 封装落差。

### 6.2 实测结果

| 验证项 | 结果 | 证据 |
|---|---|---|
| 依赖/编译 | ✅ 132 唯一包, release 13.0 s, 0 error | `cargo tree` 302 行/132 包 |
| 搜索一致性 | ✅ **完全相同**(id 集合与顺序) | `2668397359, 2653714443, 3391116218, 2730151393, 3452155836` |
| 歌词一致性 | ✅ `lrc_len=2486`, 首行/署名行全同 | id=186016 对照 |
| 取链 | ⚠️ 匿名不可用: 5 次中 2 次 `-460`(网络环境风险), 3 次 200 但 `data.code=404,url=None,size=0`; ncm 侧稳定 404 | **须带 MUSIC_U 重测** |
| 身份等价 | ⚠️ 不等价: 默认只有 `sDeviceId` 且每进程随机; `ensure_cookie`(= `or_insert`, `client.rs:298`) 保证回灌不被覆盖 ⇒ 回灌可行但要我们写; appver `"3.1.17"`+versioncode `204416` vs 仓库 `"3.1.17.204416"`(`identity.rs:45`) | 五键 `deviceId/WNMCID/_ntes_nuid/_ntes_nnid/NMTID` 齐全 ✅ |
| 扫码登录 | ✅ 形态可用, 未扫码回 `code=800`; **坑**: `login_qr_key` 返回的 unikey 本身已是完整 URL(`https://music.163.com/login?codekey=<uuid>`), `login_qr_url()` 又拼一次前缀 ⇒ 畸形 URL(`services/mod.rs:238`), 集成需自己截 codekey | 未做真实扫码(按约束只到 800) |
| Android 交叉编译 | ✅ 配好即过(7.9 s 编 174 包); 不配则 `cc-rs: failed to find tool "aarch64-linux-android-clang"`, 命中 `ring 0.17.14` + `zstd-sys 2.1.2` | 需 `ANDROID_NDK_HOME` + `CC_/CXX_/AR_aarch64_linux_android` + `.cargo/config.toml` linker(否则末尾 `EM: 183/in wrong format`) |
| `env.sh` 缺陷 | ⚠️ `tools/env.sh` 只配 PATH/镜像, **不导出 `ANDROID_NDK_HOME`** ⇒ 任何带 C 依赖的 crate 做 Android 交叉都要自己补 | 现有 cargokit 链路不受影响 |

### 6.3 「全过再切」的门槛(若将来重启此事)

1. 回灌 MUSIC_U 后重测 `song_url_v1` 的 exhigh/lossless/hires level 与 size, 与 vendor 逐字段对比;
2. 回灌身份后多进程跑, 确认 `device_id/sDeviceId/_ntes_nuid` 稳定且无 `-460`;
3. Android 形态(appver 8.20.20 / osver 14)经 `raw_eapi` 注入是否被风控接受;
4. 本项目用到的 75 个无同步封装的接口能否全部走 `raw_*`(参数形状逐个验证)。

任一条不过 → 维持现状 + 只做 §3 的 P1/P2 裁剪。
