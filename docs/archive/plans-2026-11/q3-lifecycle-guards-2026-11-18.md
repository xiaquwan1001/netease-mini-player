# Q3 — 生命周期守卫 U-05 / U-06 / U-07(2026-11-18)

来源: `docs/archive/plans-2026-11/arch-audit-ui-overlay-2026-11-18.md` 的 P2/P3 缺陷。
基线: HEAD `c794767`(v0.24.0), Dart **1243** / analyze 0 / golden 18。
本车道只做这三条; 不 commit, 不改 `docs/PROGRESS.md` 与 `docs/remaining-batches.md`。

## 1. 改了什么

| 缺陷 | 落点 | 实现 |
|---|---|---|
| **U-05** 帧后回调缺 mounted 守卫 | 新增 `ui/lib/src/lifecycle_guard.dart`(27 行); `app_shell.dart` `publishBottomBar`; `home/home_page.dart` `_publishPlayerBar` | 一个工具函数 `runPostFrameIfAlive(BuildContext, VoidCallback)`(`BuildContext.mounted` 判据), 两个调用点都改成过它; `publishBottomBar` / `_publishPlayerBar` 因此各多收一个 `context` |
| **U-06** `HomeWiring._latest` 漏组合 | `ui/lib/src/home/home_wiring.dart` | 单指针 → **实例栈** `_alive`(attach 顺序, 栈顶是槽位主人); 主人 detach 时把全局槽位**交还**给仍然活着的上一个(`_installSlots()`); 栈空才 `_clearSlots()`。attach 时缓存动作宿主(`_host`), 交还时复用同一份, 不重复构造 |
| **U-07** `didReplace` 未处理 | `app_shell.dart` `NcmRouteObserver` | 补 `didReplace({newRoute, oldRoute})`: 先摘旧的、再挂新的 —— 全屏↔全屏 层数不变, 全屏→弹层 层数 -1 且入登记表, 弹层→全屏 反之 |

### U-06 为什么不会在「真实多页面」下退化

生产里同一时刻只有一个 `HomePage` 实例在树上(根 tab 容器就是它), 栈深恒为 1;
栈 >1 只出现在「新实例已 attach、旧实例还没 dispose」的交接帧(测试反复建/销毁 HomePage,
或热重启), 那时的正确语义正是「新的拥有槽位、新的走掉就还给旧的」。也**不需要引用计数**:
每个实例的 attach/detach 严格配对(`_attached`), 栈里不会出现重复项(有用例覆盖重复 attach)。

### 顺带的口径变化(有意)

`playerBarActions` 的帧后投递从 `value = value ?? barActions` 改成「主人无条件写自己那份」。
旧写法在 A→B 交接时永远保留 A 的集合, 与「栈顶 = 主人」不一致; 现在由「只有栈顶写」保证不打架。

## 2. 新增测试(全部先在旧代码上跑红, 再跑绿)

| 文件 | 用例 | 旧代码表现 |
|---|---|---|
| `ui/test/post_frame_alive_test.dart` | 存活→写入 / 同帧销毁→不写(带"对照组"证明帧后队列真的跑过) / `publishBottomBar` 已销毁不投递 | 前两条在旧代码上是"编译即红"(`publishBottomBar` 旧签名无 context); 工具函数本身是新 API |
| `ui/test/home_wiring_stack_test.dart` | A→B→**B detach** ⇒ 槽位还给 A; A→B→**A detach** ⇒ 槽位仍为 B; 重复 attach 幂等 | 前两条 **实测失败**(单指针语义下 `_latest` 变 null) |
| `ui/test/route_observer_replace_test.dart` | 全屏→(pushReplacement)弹层; 弹层→全屏; 全屏↔全屏 三层连替 | 前两条 **实测失败**(`pageDepth` 停在 2 / `modalRouteOpen` 永久 true) |

红/绿验证方式: 把三个 lib 文件临时还原成 `git show HEAD:<path>`, 跑这三个测试文件记录失败项,
再 `git apply` 回我的补丁(补丁留在 `/tmp/q3_lib.patch`, 备份 `/tmp/q3bak/`)。

### 测试口径坑(记一笔)

`AutomatedTestWidgetsFlutterBinding.pump()` 只在 **有帧被调度** (`hasScheduledFrame`) 时才真的
推进一帧 —— 没有脏 widget 时, `addPostFrameCallback` 注册的回调**一次都不会跑**, 用例会假绿。
所以两个测试文件里都有 `flushFrame(tester)`(`binding.scheduleFrame(); await tester.pump();`),
U-05 的销毁用例还加了一条**无守卫的对照回调**, 证明那一帧的帧后队列确实执行过。

## 3. 边界遵守

- 只动这三个缺陷: 没改 `dismissAllPopups` 语义(它仍然按登记表逐条 `dismissPopupRoute`),
  没碰播放/网络逻辑, 没动 `feed/`、`detail/`、`player_bar.dart`、`settings_*`。
- 只格式化自己改的 7 个文件(其中 2 个测试文件 `dart format` 后有一次重排; 3 个 lib 文件本来就合规,
  没有触发 tall style 的全仓重排)。

## 4. 自验结果(本机实测)

| 项 | 结果 |
|---|---|
| `cd ui && dart analyze` | **No issues found!(0)** |
| 三个新增测试文件 | **+9 全绿**(post_frame_alive 3 / home_wiring_stack 3 / route_observer_replace 3) |
| 全量 `flutter test --exclude-tags network` | **+1265, All tests passed!(0 失败)**, `EXIT=0`(耗时≈1m22s) |
| `tools/check-tokens.sh --strict` | OK(没有集合外的间距/圆角/字号) |
| `tools/check-row-padding.sh --strict` | OK(所有行留白都在 layout.dart 的具名口径里) |
| `tools/check-write-guard.sh` | OK(write-guard OK) |
| golden | 18 张全绿, **没有 golden 文件变化**(`git status` 里 ui/test/goldens 无改动) |

> 1265 > 1243 基线的差额 = 本车道 9 条 + 同工作树里其它在飞车道新增的用例(工作树不是纯净基线)。
> 本车道的 9 条都在这 1265 里面, 没有 `-n` 跳过。

## 5. 变更文件清单

改: `ui/lib/src/app_shell.dart`(+38/-2)、`ui/lib/src/home/home_page.dart`(+16/-3)、
`ui/lib/src/home/home_wiring.dart`(+79/-28)。
新增: `ui/lib/src/lifecycle_guard.dart`、`ui/test/post_frame_alive_test.dart`、
`ui/test/home_wiring_stack_test.dart`、`ui/test/route_observer_replace_test.dart`、本文件。
**未 commit**, 未动 `docs/PROGRESS.md` / `docs/remaining-batches.md`。
