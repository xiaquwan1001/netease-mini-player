# 轻音 MiniNCM · 匿名诊断上传 Worker

这个目录是「小白点一下就传给你」的**服务端代理**, 部署在 Cloudflare Workers 上。
它不是自建服务器: 真正建单的还是 GitHub, Worker 只是替你保管一个**只能建 Issue** 的
GitHub token, 顺手做字段白名单、PII 兜底、限流和幂等。

一次上传的流程:

```
App(ui/lib/src/diag_upload.dart)
  → POST https://<你的域名>/diag   { ...诊断包, clientId }
    → 白名单/PII/体积/限流校验
      → GitHub API 建 Issue(labels: diagnostics, anonymous)
        → 200 {ok:true, number, url}
```

端上只会收到 `{ok, number, url}` 或 `{error: "<code>"}`, 拿不到 token, 也读不到 Issue 以外的东西。

## 仓库里没有任何 token / 端点(现状)

- **GH_TOKEN 由「你」在部署时手动创建**(第 4 步, GitHub 网页生成 fine-grained PAT),
  只通过 `wrangler secret put` 存到 Cloudflare; 仓库、CI、客户端都不含 token,
  也没有任何 `.env` / 明文密钥(见根 `.gitignore` 的 `tools/diag-worker/.dev.vars*`)。
- 客户端端点常量是 `ui/lib/src/app_meta.dart` 的 `kDiagUploadEndpoint`, **当前为空**
  ⇒ 端上「一键匿名提交」不可点, 只保留「生成匿名诊断包」本地落盘。
  部署完把 `https://<你的域名>/diag` 填进去再发版即可(注意要带 `/diag` 路由)。
- 想彻底停掉上报: Cloudflare 后台删 route 或 `npx wrangler delete`; 端上即使留着旧端点
  也只会拿到网络错误并降级成本地文件。

---

## 8 步部署(不需要写代码, 照抄命令即可)

前提: 装好 Node 18+, 有一个 GitHub 账号, 想接诊断单的那个仓库你有管理员权限。
下面命令都在**本目录**(`tools/diag-worker/`)里执行。

### 1. 登录 Cloudflare

```bash
npx wrangler login
```

浏览器会弹出授权页, 点 Allow。第一次会问是否安装 `wrangler`, 回车同意即可
(它只是下载到 npx 缓存, 不写进本仓库)。

### 2. 建 KV(存幂等结果与限流计数)

```bash
npx wrangler kv namespace create DIAG
```

输出类似(记下这一行 `id = "..."`):

```
[[kv_namespaces]]
binding = "DIAG"
id = "0f2a1c9d8b7e4a6f9c0d1e2f3a4b5c6d"
```

### 3. 把 id 填进 `wrangler.toml`

打开 `wrangler.toml`, 把

```toml
[[kv_namespaces]]
binding = "KV"
id = "REPLACE_ME"
```

里的 `REPLACE_ME` 换成上一步的 id(**只换 id, 不要改 binding = "KV"**)。
顺便把 `[vars]` 里的 `GH_REPO` 改成真实仓库, 例如 `GH_REPO = "xiaquwan1001/netease-mini-player"`。

### 4. 造一个只能建 Issue 的 GitHub token, 并塞进 Worker

1) 打开 https://github.com/settings/personal-access-tokens/new (fine-grained PAT)
2) Name 随便填, Expiration 选最短(90 天, 到期换一个)
3) **Repository access → Only select repositories** 只勾目标仓库
4) **Permissions → Repository permissions → Issues: Read and write**(其它全部保持 No access)
5) Generate token, 复制 `github_pat_...`(只显示一次)

然后执行(会提示粘贴 token, 粘贴时不显示字符, 属正常):

```bash
npx wrangler secret put GH_TOKEN
```

> 这一步之后 token 只存在于 Cloudflare 侧。**别把它写进 `wrangler.toml`**, 也别贴到聊天里。

### 5. 部署

```bash
npx wrangler deploy
```

成功会打印一个 `https://minincm-diag.<你的子域>.workers.dev` 地址。先记住它, 下一步要换掉。

### 6. 绑自定义域名(强烈建议)

原因: `*.workers.dev` 在国内网络下经常连不上(DNS 污染/间歇被阻断), 而用户的诊断包
就是要从国内手机发出来的。用自己的域名成功率明显更高。

1) 在 Cloudflare 里把域名(或一个子域, 如 `diag.example.com`)接管为 zone
2) Workers 后台 → 你的 Worker → Settings → Domains & Routes → Add → Custom domain → 填 `diag.example.com`
   (等价命令: `npx wrangler domains add diag.example.com`, 需要该 zone 在同一个账号下)
3) 等证书变成 Active(通常 1~2 分钟)

### 7. 冒烟: 确认真的能建单

```bash
curl -sS -X POST 'https://diag.example.com/diag' \
  -H 'content-type: application/json' \
  -d '{"schema":1,"app":"0.9.0-smoke","env":{"platform":"curl"},"credential":{"backend":"none"},"clientId":"3f2504e0-4f89-41d3-9a0c-0305e82c3301"}'
```

期望输出:

```json
{"ok":true,"number":123,"url":"https://github.com/<owner>/<repo>/issues/123"}
```

再发一次**同样的命令**(clientId 不变): 应该返回**同一个 number**, 仓库里不会多一张单。
顺手验一下防线:

```bash
# 期望 {"error":"unexpected_field"} (400)
curl -sS -X POST 'https://diag.example.com/diag' -H 'content-type: application/json' \
  -d '{"schema":1,"evil":1,"clientId":"3f2504e0-4f89-41d3-9a0c-0305e82c3302"}'

# 期望 {"error":"pii_detected"} (400)
curl -sS -X POST 'https://diag.example.com/diag' -H 'content-type: application/json' \
  -d '{"schema":1,"note":"MUSIC_U=abc","clientId":"3f2504e0-4f89-41d3-9a0c-0305e82c3303"}'
```

冒烟单记得手动关掉(`[diag] 0.9.0-smoke / curl / none`), 别污染诊断列表。

### 8. 把地址给 App, 以及日后怎么换/怎么撤

- 端上端点来自构建注入(编排者接线时填到设置里), 形如 `https://diag.example.com/diag`。
  **端点是空字符串时就等于功能未开启**: 上传器抛 `not_configured`, 直接降级成本地文件。
- **换 token**: 重新走第 4 步(`wrangler secret put GH_TOKEN` 覆盖), 不需要重新 deploy, 也无需发版。
- **暂停上报**: 在 Cloudflare 后台把 Worker 的 route/域名删掉, 或用 `npx wrangler delete`;
  端上会在 15s 后拿 `network` 错误并降级本地文件, 用户不会卡住。
- **彻底撤销**: Cloudflare 里删 Worker + KV, 再去 GitHub 把那个 PAT 删掉(改权限也行)。
- **看日志/排障**: `npx wrangler tail`(实时输出 `github issue create failed` 这类错误)。

---

## 已知不稳定点与兜底

| 不稳定点 | 表现 | 我们怎么兜 |
|---|---|---|
| `*.workers.dev` 在国内连通性差 | 上传超时 / 连接被重置 | 必须绑自定义域名(第 6 步); 客户端 3 次退避重试, 仍失败就降级成落盘文件让用户自己贴 |
| GitHub API 5xx / 连接抖动 | Worker 侧偶发失败 | Worker 对 GitHub 做 3 次(8s 超时 + 0.5/1.5s 退避)重试, 失败回 `github_failed`(502); 客户端把 5xx 当 `retryable=true` 再试一轮 |
| GitHub 限流(次级速率限制) | 403/429, 表现同 5xx | Worker 会重试 3 次; 真失败则 `github_failed`, 客户端降级本地文件 |
| 同一用户连点 / 客户端重发 | 仓库里出现重复 Issue | `clientId`(UUID)幂等: Worker 记 `done:<clientId>` 30 天, 命中直接返回上次 `{number,url}` |
| 有人把 Worker 当开放代理刷单 | Issue 被灌水 | 每 IP 每小时 10 次(429 `rate_limited`); KV 最终一致, 并发突发可能少量超发, 只做粗挡 |
| KV 尚未写入就重发(极小概率) | 极短窗口内重复建单 | 端上重试间隔 ≥0.5s, 实际很难撞上; 真撞上就关掉多余那张 |
| token 过期 / 权限不足 | 全部 `github_failed` | 401/404/422 一律不重试(重试无意义), `wrangler tail` 里能看到 `github_401` 之类; 重新走第 4 步 |
| 诊断包越界(带昵称/cookie/device id 原文) | 400 `pii_detected` / `unexpected_field` | 这是**故意的**: 宁可上传失败也不收身份数据。看到这类错误应该去修采集端, 别放宽白名单 |

## 文件

- `worker.js` — 全部逻辑(无依赖, 单文件)
- `wrangler.toml` — name/main/compatibility_date/KV binding/vars
- `README.md` — 本文

客户端: `ui/lib/src/diag_upload.dart`; 用例: `ui/test/diag_upload_test.dart`。
