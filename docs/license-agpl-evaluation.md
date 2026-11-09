# 许可证评估：是否把本项目从 MIT 改为 AGPL-3.0（2026-11-10）

> 触发原因：想用 SPlayer-Next / **lyric-dom**（AGPL-3.0）的歌词滚动与逐字渲染实现。
> 评估口径：只看"法律上能否合法做、改了有什么代价"，不做价值判断；结论与可执行清单在最后。

## 0. 结论（先说数字与判断）

1. **不需要改许可证，就能用它们 99% 有价值的东西。** 我们上一轮调研得到的是**行为与参数**
   （seek 判定阈值 −100ms/+2000ms、用户停手 5s 回弹、`scrollInCode` 双标志、`animateScrollBy`
   而非 `animateToItem`、弹簧插值常数、mask 式逐字高亮思路）——**这些属于思想/方法，不受著作权保护**。
   我们目前的实现（`MarqueeText`、`_autoFollowLyric` + `ScrollStartNotification.dragDetails`、
   `WordLyricView` 渐变高亮）是独立编写的，未复制其代码。
2. **只有一种情况必须 AGPL**：逐行/整段**翻译或复制** lyric-dom / SPlayer-Next 的源代码
   （含把 TypeScript 结构 1:1 搬到 Dart）。这种情况 AGPL-3.0 §5 要求整个组合作品以 AGPL 分发。
3. **法律上改得动**：本仓库 147/155 提交为同一作者（Qianhui Xu，多个邮箱），其余为 agent 提交；
   依赖全部是宽松许可（见 §2）。=> 单作者即可重许可，无需外部同意。
4. **但不建议改**（除非你就是想让衍生作品也必须开源）：
   - MIT→AGPL 是**单向门**：已发布的 v0.1.0（MIT）不可撤回，同时存在两套授权，维护成本上升；
   - AGPL §13（网络交互条款）对"侧载 App"影响很小，但对将来任何 Web/联机玩法都会加成义务；
   - 生态代价：一部分贡献者/下游会直接避开 AGPL；而我们要的"参考实现"用不着它。
5. **如果确认要改**：§5 给了 6 步可执行清单（约 30 分钟），风险点只有 2 个（LICENSE 全文替换、更新徽章与 NOTICE）。

## 1. 事实basis

| 项 | 现状 |
|---|---|
| 本项目许可 | MIT（`LICENSE`，Copyright (c) 2026 xiaquwan1001 and MiniNCM contributors） |
| 提交作者分布 | `git log --format='%an' \| sort \| uniq -c`：Qianhui Xu 147 / xiaquwan1001 3 / agent 3 / 其它 2（同一人不同邮箱） |
| 第三方许可清单 | `THIRD_PARTY_NOTICES.md`（vendor ncm-api = WTFPL，上游 api-enhanced = MIT，symphonia = MPL-2.0 未修改，二维码库 BSD-3 …） |
| 分发渠道 | GitHub Release 侧载 APK + Linux tar.gz；无 iOS、无应用商店内购、无 SaaS 服务 |

## 2. 依赖与 AGPL-3.0 的兼容性

AGPL-3.0 与下列许可**兼容**（可作为 AGPL 作品的一部分）：

| 许可 | 我们的组件 | 与 AGPL-3.0 | 备注 |
|---|---|---|---|
| MIT | Rust 依赖绝大多数（tokio/reqwest/serde/rodio…）、ncm-api 上游 api-enhanced | ✅ 兼容（可被 AGPL 吸收） | 保留原版权声明 |
| Apache-2.0 | AndroidX / Media3 / 部分 Rust crate | ✅ 兼容（AGPL-3.0 §3、Apache-2.0 §9） | |
| BSD-2/3 | Flutter、qr_flutter | ✅ 兼容 | |
| MPL-2.0 | symphonia（未修改使用） | ✅ 兼容（MPL §3.3 二级许可） | 若修改 symphonia 源文件，改动文件仍须 MPL |
| WTFPL | vendor `ncm-api`（api-enhanced 的 Rust 移植） | ✅ 兼容（等价公有领域式授权） | |
| **AGPL-3.0** | 拟引入的 lyric-dom | 仅 AGPL 作品可吸收 | 这就是要改许可的唯一理由 |

结论：改 AGPL 不会踩任何依赖的雷；反过来也意味着**我们没有"必须改"的依赖压力**。

## 3. 改与不改的代价对比

| 维度 | 保持 MIT | 改为 AGPL-3.0 |
|---|---|---|
| 能否**借鉴** lyric-dom 思路 | ✅ 可以（思想不受保护） | ✅ |
| 能否**复制/翻译** lyric-dom 代码 | ❌ 不行 | ✅ 可以（仍需保留其版权声明与 §5 的修改说明） |
| 已发布 v0.1.0 | 保持 MIT（不可撤回） | 两套授权并存，README 需说明"v0.1.0 及之前为 MIT" |
| 下游/贡献者 | 最宽松 | 部分企业环境禁 AGPL；Fork 必须 AGPL |
| 我们的实际用途（侧载 App，无 SaaS） | 无义务 | §13 义务很轻：源码本来就公开；只要保持"用户可获取对应源码"即可 |
| 操作成本 | 0 | 约 30 分钟（§5），此后每次引入新依赖都要审一次兼容性 |

## 4. 我建议

**保持 MIT，继续"只借鉴思路不抄代码"**。理由：我们要的三件事（seek 后恢复跟随、程序滚动与用户滚动双标志、逐字渐变高亮）都已经**独立实现完毕并在真机/模拟器验证**，
再回头抄 AGPL 代码没有增量收益，却要永久承担 AGPL 的传播义务。

**如果你出于立场（希望衍生作品也必须开源）想改**，那就当独立决定来做——法律上完全可行，清单见 §5；此时可以顺手把 lyric-dom 的 mask 式逐字高亮、弹簧插值常数直接移植，省一轮重写。

## 5. 若决定切换：可执行清单（30 分钟）

1. 下载官方全文（**不要自写摘要版**）：
   `curl -fsSL https://www.gnu.org/licenses/agpl-3.0.txt -o LICENSE`（或 `AGPL-3.0-only` 更严格；建议 **AGPL-3.0-only** 并在文首保留项目版权行）。
2. `THIRD_PARTY_NOTICES.md` 增加一节「本项目的许可」：明确 AGPL-3.0-only + 之前的版本为 MIT（v0.1.0 及更早）。
3. `README.md` / `README.en.md`：徽章 `license-MIT` → `license-AGPL--3.0`，并把「许可」小节改成 AGPL + 一句"网络使用也须提供源码"。
4. `CONTRIBUTING.md`：加一句「提交即同意以 AGPL-3.0-only 授权」（DCO 式声明，避免将来权属争议）。
5. `ui/lib/src/app_meta.dart`（设置页「版本与许可」）里展示的许可名同步为 AGPL-3.0。
6. 若要引入 lyric-dom 代码：在其源文件顶部保留原始版权与 AGPL 头，并在仓库内新增 `docs/agpl-third-party.md` 记录"文件名 ← 上游路径 @ commit sha"，满足 §5 的修改声明义务。

**风险点**：① 忘记替换 LICENSE 全文（GNU 官方要求全文，缺段会导致许可无效）；② 忘记标注旧版本仍是 MIT（会让已有用户困惑）；
③ 之后新增的每个依赖都要重新核一遍 AGPL 兼容性（目前全部兼容，但要形成习惯）。

## 6. 不变的那条底线

无论选哪个许可：**网易云接口/加解密仍只走 vendor 库（WTFPL/MIT），不复制网易官方代码**；歌词文本与封面版权不属于我们，
TTML 数据源（amll-ttml-db 是 CC0）可缓存但**不要打包进发行物**——这条与许可选择无关，已在 `docs/research-2026-11-10-lyric-and-color.md` §5 记过。
