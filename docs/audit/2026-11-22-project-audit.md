# 项目审计 · 2026-11-22

> **报告人**: 只读审计子代理(reviewer); **落盘**: 编排者。
> **处置注记(2026-11-22 当晚)**: A 节 7 条漂移已就地修正 —— 文件头/§11/§13 三处的「P-11 ③ 通知点击」
> 已改为「用户 2026-11-21 已验证通过(§11.A0 H5)」;§12.6「未做」段改为「已由第二步 `ade2b97` 收口」;
> §12.8 第 2 波改为「只剩 12.6 跨域分块订阅小尾 + 12.7(暂不做)」;§12.1b 补 `api.rs` 2026-11-22 实测 435 行;
> §12.7 改「15 域 + 1 测试文件」;§15 标题去「待开工」。**C 节 5 处 `#[frb(ignore)]` 观察期到期项与
> D 节 4 处弱断言未处理**, 留作下个清理批。

口径: 静态核实, 未跑构建; 基线 main@45e5540
范围: docs/remaining-batches.md §11–§15 · PROGRESS.md 数字 vs /tmp/verify-v0380.log · 代码遗留 · 测试有效性抽查

## A. 文档事实漂移(remaining-batches.md)

| 严重度 | 位置 | 事实 | 建议措辞/处置 |
|---|---|---|---|
| P1 | remaining-batches.md:162(§11 顶部)与 :14(文件头)、:383(§13 顶部) | 三处仍写「只剩两条尾巴: P-11 ③ 通知点击(需真机) / P-10 真机听感」;但 §11.A0 H5 已标「通知点击真机验证 ✅ 通过(2026-11-21 用户), 不再作为待办」 | 三处改为「只剩 P-10 真机听感一条; P-11 ③ 已于 2026-11-21 用户通过(H5), 仅剩 BAL 拦截 1 例 assume-skip」 |
| P1 | remaining-batches.md:357(§12.6 末) | 「**未做(仍开着)**: 字段还是可变单例…要做就做不可变快照」——同节上方已写「第二步已完成(2026-11-19, lane/settings-snapshot, `ade2b97`): @immutable AppSettingsSnapshot + diffTo 通知」,自相矛盾 | 删该段或改「~~未做~~ ✅ 已由第二步(快照)收口; 残余仅 12.6『仍开着(小尾)』一段」 |
| P1 | remaining-batches.md:375(§12.8 第 2 波行) | 「§12 只剩 12.6 第二步(不可变快照)与 12.7」——12.6 第二步已落(见上条) | 改「§12 只剩 12.6 小尾(设置页跨域订阅)与 12.7(暂不做)」 |
| P2 | remaining-batches.md:270(§12.1b ②) | 「api.rs 3 325 行」标 2026-11-18 复核, 现实测 `core/crates/ncm-ffi/src/api.rs` = **435 行**(T2 拆分后), 与 :366 的「380 行」也不一致(T2 后插件批又加) | 补一句「2026-11-22 实测 435 行(插件域后续追加), 结论(暂不拆)不变」 |
| P2 | remaining-batches.md:366(§12.7) | 「拆到 api/*.rs 14 个文件」;实测 `api/` 目录 **16 个文件**(15 域 + plugin_tests.rs) | 改「15 域 + 1 测试文件」 |
| P2 | remaining-batches.md:427(§15 标题) | 「待开工」——S0–S4 表内全落(已核实 v0.24.0/v0.25.0/v0.27.0 条目与 golden `master_detail_1280x720` 存在)。**编排者工作树已有未提交修正**(watchdog_diff: 「2026-11-22 核实: S0–S4 全部已落」),待随下次提交入库 | 已修, 确认提交即可 |
| P2 | remaining-batches.md §11.C 插件段 | 「无 crate 依赖它(不进 ncm_ffi/APK)」正文已过期(切片 2/3 + Android 接线已落), 但节内已有 2026-11-21 更新注记自我订正 | 保留现状, 属已自我勘误的历史段 |
| 核实一致 | §11.A0 表 | H1(取消)/H2(已落 v0.37.0, `api/me.rs:45` `user_play_ranking` 无 `#[frb(ignore)]`、`api/account.rs:411` `logged_in()` 均在)/H4(降级可选, `cloud_chunk.rs` TODO 仍在)/H5(通过) 与代码一致 | — |

## B. PROGRESS.md 数字核对

| 严重度 | 位置 | 事实 | 处置 |
|---|---|---|---|
| 核实一致 | PROGRESS.md:1(头部) vs /tmp/verify-v0380.log | Rust **545** ✔(log 各 suite 求和 0+49+50+28+4+16+20+7+4+1+353+12+doctest 1 = 545);Dart **1528** ✔(log:2396 `+1528: All tests passed!`);golden **21** ✔(log:2395 `master_detail` 后 tearDown);`ALL GATES OK`/`EXIT=0`(log:2668-2669)。**无分叉** | — |
| P2 | PROGRESS.md:22-23 | 「当前门禁」小节首行复核口径仍是「2026-11-17 晚」, 而 2026-11-22 核实块(:17-19)在其上方, 时序读感颠倒 | 把 2026-11-22 块挪到「当前门禁」段首, 或删 11-17 的「复核口径」引导句 |

## C. 代码遗留扫描(TODO / unimplemented / frb(ignore))

| 严重度 | 位置 | 事实 | 处置 |
|---|---|---|---|
| 真未接线 | core/crates/ncm-service/src/cloud_chunk.rs:22(模块 TODO) + netease/cloud.rs:194 | 分片 HTTP 端点无可信证据, `Chunked` 分支运行时返回「尚未接线」错误;属**有意保留**的真人抓包前置项(§11.C/H4 口径一致) | 保留; 接线时按模块 TODO 第 4 条补实测 ceiling |
| P2 | api/playback.rs:231,267,292 · api/cloud.rs:63 · api/account.rs:309 | 5 处「候选删除; 先 #[frb(ignore)] 观察一个版本」(2026-11-20 审计 7.2 标注)。最早标注至今 ≥1 个版本(已发多版), 观察期已过 | 下一个清理批删 Rust 侧死函数, 或改为明确「保留」 |
| 正常 | frb_generated.rs:14433 `unimplemented!("")` | FRB 生成物 | 忽略 |
| P2 | .pi/memory/notes-wip.md:25 | 「待办: 插件设备侧验收(模拟器跑 fixture 插件链路)」仍未完成且未进 §11.A0 表 | 并入 A0 表(需模拟器, 非真人项)或注明为何不入表 |

## D. 测试有效性抽查

| 严重度 | 位置 | 事实 | 建议 |
|---|---|---|---|
| P2 | ui/android/.../NotificationClickTest.kt:275(`startMainActivitySync`)**全文件零调用**;:158-159「案例 3」注释重复两行 | 死代码;案例 2 本体靠 `Assume.assumeTrue` 环境跳过(BAL, 有注释说明, 可接受) | 删未用 helper 与重复注释 |
| P2 | ui/android/.../EqProfileParserFixtureTest.kt:160 | `getAsJsonArray("biquad") ?: continue` —— 夹具某 filter 缺 biquad 时静默跳过系数比对, 仅靠 :174 `asserted>0` 兜底(整夹具级, 不防单条漏断) | 夹具缺 biquad 时记入 `issues` 而非静默 continue |
| P2 | ui/test/marquee_long_title_test.dart:92-93 | `expect(p2, isNotNull)` 后 `lessThan(p1 ?? 0)` —— p1 为 null(首帧无 transform)时退化为 `p2 < 0`, 动画没动也可能绿 | `p1` 为 null 时 fail 而非 `?? 0` |
| P2 | ui/test/song_tile_test.dart:49 | `expect(title.style?.color, isNotNull)` 恒真倾向(默认样式即非空), 未断言具体值/继承链 | 断言期望色值或删除 |

## 结论
- 最严重 3 条: ① :14/:162/:388 三处仍把已通过的 H5(P-11 ③)列为「剩两条尾巴」;② §12.6「未做(仍开着)」段与同节「第二步已完成」自相矛盾;③ §12.8「只剩 12.6 第二步」同因过期。
- 过期文档条目: 7 处(上表 A 节), 其中 1 处(§15 标题)编排者已在未提交工作树修正。
- PROGRESS 头部 545/1528/21 与实测日志**完全一致, 无分叉**;仅「复核口径」引导句时序略乱(P2)。
- 未能核实: git 历史提交号(89f523b/fe604e2/ade2b97 等未逐一查 git log, 只验证了代码现状);Kotlin instrumented 与模拟器行为(禁止跑构建/测试);`docs/health` 报告内容(任务范围外)。

## 处置回执(2026-11-22 深夜, 自动化会话)

| 节 | 项 | 处置 |
|---|---|---|
| A | 7 条文档漂移 | ✅ 已就地修正(e3eacf6) |
| B | PROGRESS 数字/时序 | ✅ 数字无分叉; 时序随 v0.38.1 条目落位 |
| C | 5 处 `#[frb(ignore)]` 观察期到期 | ✅ 决策收口(不删代码, 按 `docs/api-coverage.md` 分类写进注释): `cache_stats`/`eq_profile_normalize`/`player_tuning`/`cloud_song_url` = **有意保留**; `consent_plaintext_storage` = **待产品决策**(UI 同意门未落地, 落地时去掉 ignore 复用) |
| D1 | `NotificationClickTest.startMainActivitySync` 死代码 + 重复注释 | ✅ 删除未用 helper 与重复的「案例 3」注释行 |
| D2 | `EqProfileParserFixtureTest` 缺 biquad 时静默 continue | ✅ 改为记进 `issues` 并计入 `asserted`(单条漏断言会真的红) |
| D3 | `marquee_long_title_test` 的 `p1 ?? 0` | ✅ 两个采样点都断言非 null(`p1` 拿不到就 fail) |
| D4 | `song_tile_test` 的颜色 `isNotNull` 恒真 | ✅ 改为断言等于 `colorScheme.outline`(具体色值) |

口径: C 节判据是「观察期过必须有明确结论」, 而**删 Rust 侧函数会连带 provider/CLI 面**, 收益只是少 5 个 `#[frb(ignore)]`;
`docs/api-coverage.md` 已按用途分类(给未来设置项留的宿主口 / 凭据回退门), 所以结论取「保留 + 注释如实」。D 节全部是测试有效性加固。
