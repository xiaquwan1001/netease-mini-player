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
| **f. wasm / 单文件服务** | ncm-api-rs 本身已带 server feature(axum, optional, 默认不编) — 现状已是"集成式内嵌", 独立服务进程是倒退 | — | 382 | 同现状 | 双端各起一进程 | — | — | 负收益, 排除 |

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
