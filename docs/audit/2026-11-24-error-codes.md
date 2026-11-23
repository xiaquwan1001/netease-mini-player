# 审计报告(只读子代理产出, 编排者归档 2026-11-24)

# 错误码与上游 API 返回情况的边界处理审计（2026-11-24，只读）

## Review
- Correct（抽查通过、无需改动的点）：扫码 801/802/803/800/8821/400/402/404 在 `account.rs:266-283` 有完整显式分支且未知码落 `Unknown` 不 panic；`-462` 已由 `request.rs:30-42` 原样保留 + `mod.rs:284` 显式映射 riskControl（有单测 `request.rs:530-549`）；关注/粉丝 `code=400 无数组 → Forbidden` 已按 notes-api 收口（`community.rs:424-438`，有回归测试）；`PodcastRadio.subed` 已是 `Option<bool>` 不再把缺字段当 false（`radio.rs:248`）；云盘 `resourceId` 数字 / `songId` 十六进制已走 `str_or_num_of`（`parse.rs:33-44`、`cloud.rs:238,267`）；`u64_count_of` 对浮点计数不四舍五入；`friendlyLoginError` 覆盖全部 7 个 kind（`login_sheet.dart:34-51`）。

## 一、vendor/ncm-api 归一化层（normalize_status / NcmError::from_api / map_code）
分支现状：`normalize_status`（`request.rs:30-42`）把 `{201,302,400,502,800,801,802,803}` 折成 200、负数码在 `-1000..600` 内原样保留、范围外兜 400；`from_api`（`error.rs:44-56`）只显式处理 301/400/503；`map_code`（`ncm-service/netease/mod.rs:275-287`）只显式处理 200|0 / 301|401 / 8821|-462 / -110|404，其余全部落 `_ => internal` 兜底。

- **P1｜非 JSON / eapi 解密失败的 HTTP 200 响应被静默当成功**：`request.rs:424-430`（`eapi_res_decrypt(...).unwrap_or(Value::Null)`）与 `request.rs:432-434`（`from_str(...).unwrap_or(Value::String(text))`）。body 变 Null/字符串后 `body.get("code")` 为 None → 用 HTTP 状态 200 → `Ok`；下游 `check_body_with` 对 `None` 直接放行（`mod.rs:300-302`）→ 各 parse 层按"无数据"返回空列表，风控页/被劫持 HTML 等都被吞成"没有内容"。与 -462 被吞是同一类残留。建议：status==200 且 body 非 object 时返回 `NcmError::Unknown`/Api 错误而不是 Ok。
- **P2｜`from_api(400) → InvalidParam → map_error 落 internal`**：`error.rs:49` + `mod.rs:265`。HTTP 400（body 无 code）与"body 里 code=400 且不在关注列表形状"都落到 internal「服务端异常」，而 notes-api 已知多类 400 是用户可理解语义（隐私不可见已收口，云盘 `{"code":400,"songId":"0"}` 仍未显式分支）。建议给 map_code 增加注释列举已知 400 形状，或对带可读 message 的 400 提供非 internal 文案。
- **P2｜`code=-2`（他人听歌排行无权限，notes-api:23）无显式分支**：落 `_ => internal`（`mod.rs:285-286`），目前靠 `song.rs:102-111` 把非 Network 错误吞成空列表兜住；语义上是 Forbidden。建议 map_code 增 `-2 => forbidden` 或至少注明由调用方吞。
- **P2｜503 语义三条路不一致**：`from_api(503)→RateLimited→risk_control`（`error.rs:51` + `mod.rs:264`）；`check_body` 路径 503→`map_code`→internal 不可重试（`mod.rs:285-286`）；登录路径 503→internal 可重试（`mod.rs:320-329`）。同一个码三种 kind/retryable。建议统一（503=限流、可重试）。
- **P2｜除 -462/-110 外的负数码全落 internal 兜底**：如 -460（通常=需要登录）、-461 无显式分支（`mod.rs:281-286`），会复现"-462 被吞成 400"的同类误报（用户看到「服务端异常」）。建议至少给 -460 映射 Auth。
- **P2｜`SPECIAL_STATUS_CODES` 把 302/502 也折成 200**（`request.rs:13-15`）：依赖下游每处都调 `check_body` 才能把 body 里的真实错误捞回来；`parse_radio_categories`（`radio.rs:299`，dj_catelist 顶层无 code）这类无 code 端点若遇到 502 body 会被当成功解析。建议在 parse 层对"预期字段全空 + code 缺失"加日志。

## 二、ncm-service parse_*/u64_of/str_of 静默兜底
- **P1｜云盘上传 `resourceId` 缺失被静默置空串**：`cloud.rs:267-269` `str_or_num_of(r,"resourceId").unwrap_or_default()`。同函数里 token/objectKey 缺失都 `ok_or_else` 报错，唯独 resourceId 静默放行 → info/v2 缺参 → `{"code":400,"songId":"0"}` → 白白重试 5 次×1s 后报 internal——正是 v0.26.3 修过的坑的残余路径。建议与 token 同款 `ok_or_else(|| ProviderError::internal("nos token: 响应缺 resourceId"))`。`cloud_song_id` 的 `unwrap_or_else(||"0".into())`（`cloud.rs:238`）同型，建议一并显式化。
- **P2｜`privilege_playable` 死分支 + 文档自相矛盾**：`parse.rs:74-85` 的 `match p.get("pl") { Some(_) => true, None => true }` 两臂同值，pl 从未被使用；而函数上方 doc 写"pl=0 表示不可播"。实际只有 st<0 生效。建议删掉 match、把注释改成与实现一致（或真正实现 pl==0 判定，二选一）。
- **P2｜`parse_song_with` 无 privilege 信息时默认可播**（`parse.rs:101-105` `unwrap_or(true)`）：匿名/部分列表通道没有 privileges[] 时不可播曲目也会进列表，点播才报错。展示层可接受，建议保留但注明依据。
- **P2｜云盘条目/歌曲元数据静默 0**：`cloud.rs:102-106`（id/songId 双 0 才丢弃，有注释）、`cloud.rs:143-144`（bitrate/addTime 缺失→0）。仅显示层影响，可接受；`parse_song_like_state`（`parse.rs:131-135`）的缺省已注明"计数是装饰信息"，合理。
- **未发现同类残留**：`Playlist.subscribed`（`parse.rs:159-162`）与 `parse_style_playlist`（`song.rs:1159-1162`）缺字段按"创建侧"处理且已注释，未复现 PodcastRadio.subed 的错误；`parse_stream`（`song.rs:631-650`）对空 data 报 notFound、entry code≠200 显式映射，url=null 保留为 Option 由 UI 处理，符合 notes-api 取链语义。

## 三、ProviderErrorKind 全集 vs UI 分支
kind 全集 7 个（`ncm-provider/src/error.rs:11-19`）；Dart 侧 `friendlyError`（`net_retry.dart:74-100`）只分支 network/auth/forbidden/riskControl；`friendlyLoginError`（`login_sheet.dart:34-51`）覆盖全部 7 个；`retryNetwork`（`net_retry.dart:48-64`）按 retryable 决策（合理）。

- **P1｜`notFound` / `unsupported` / `internal` 三个 kind 没有任何友好文案分支**：`friendlyError` 落到 `describeError` 原样返回 `[internal] code=500: ...` / `[notFound] ...` 给用户（`net_retry.dart:74-100` 末尾）——这正是 2026-11-18「推荐页把 `[auth] Unknown error` 当错误占位」的用户反馈模式。影响面最大的是 internal（map_code 的兜底臂、所有未知码都进这里）。建议补三条分支：internal→「服务开小差了，稍后再试」、notFound→「内容不存在或已下架」、unsupported→「当前版本不支持该功能」。
- **P2｜`errorKind` 的正则 `\[(\w+)\]` 只取第一个方括号**（`net_retry.dart:31`）：detail 里若前置动作文案含 `[xxx]` 会误判 kind（非 FfiError 老路径才会触发）。低风险，可收紧为行首匹配。

## 四、ui/lib catchError/catch 吞错点（catch 后既不提示也不 rethrow）
- **P2｜`messages/sessions_tab.dart:50` `catch (_) {}`**：最近联系人加载失败完全无提示无日志（注释说"不显示"可接受，但零可观测性）。建议加 `debugPrint`。
- **P2｜`home/account_actions.dart:348-352`**：登录态失效检测里 `logout()` 失败被 `catch (_) {}` 吞掉，连本应弹的「登录状态已失效, 请重新登录」toast 也在 try 内被跳过。建议 toast 移出/在 catch 中也提示。
- **P2｜`playback.dart:205` `.catchError((Object _) {})`**：actionHandlersReady 通道失败完全无日志（同文件 :259-262、:307-313 的同类 catch 都有 debugPrint）。
- **P2｜`playback_state.dart:167,174` `catch (_) {}`**：播放现场落盘/清除失败静默——写盘失败意味着下次启动恢复现场丢失且无任何痕迹。建议 debugPrint。
- **P2｜`home/search_controller.dart:158,301,417` 三处 `catch (_) {}`**：搜索历史/默认词/清空历史失败静默。前两处属"降级不提示"可接受但建议留日志；417（clearSearchHistory 失败）用户点清空无任何反馈，建议 toast。
- 判定为合理不列问题：`cloud_page.dart:163`（错误仍经 `_future` 走 AsyncView 呈现）、`discover/history_tab.dart:178`（注释明确"本地读盘失败少几行"）、`home/playback_coordinator.dart:562,608`（注释明确）、`home/account_actions.dart:382`（红心状态未知，注释明确）、`lyric_source.dart:181,203`（行级歌词增强可选项）、`desktop_integration.dart:204`（结果结构化返回 ok:false）。

## 汇总
- 发现总数：**18**（P0=0，P1=3，P2=15）
- 最重要 5 条：
  1. **P1** vendor `request.rs:424-434`：HTTP 200 + 非 JSON/解密失败响应被静默当成功（-462 同类残留，影响所有接口）。
  2. **P1** `ui/lib/src/net_retry.dart:74-100`：`internal/notFound/unsupported` 无友好文案，兜底臂的原始错误直接给用户。
  3. **P1** `ncm-service/netease/cloud.rs:267-269`：上传 resourceId 缺失静默空串，v0.26.3 坑的残余路径（白重试 5 次后报误导性 internal）。
  4. **P2** `mod.rs:275-287` + `error.rs:44-56`：400/-2/-460/503 无显式分支或三条路映射不一致，落 internal/风险不一致。
  5. **P2** `account_actions.dart:348-352`：登录失效时 logout 失败连提示都吞掉，用户完全无感知。

Merge verdict（审计结论）：无 P0；建议先修 3 条 P1（均为小改：一处 unwrap 收紧、三条 UI 文案、一处 body 形状校验），P2 可按批次清理。