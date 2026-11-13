// 匿名诊断上传代理: 客户端只知道本 Worker 的地址, GitHub token 只存在 Worker 侧。
//
// 为什么需要这一层: 客户端里放 GitHub token 等于把仓库写权限公开(APK 可反编译),
// 而 GitHub API 的 CORS/风控也不适合端上直连。
//
// 契约(客户端 ui/lib/src/diag_upload.dart 按此解析):
//   成功: 200 {ok:true, number, url}
//   失败: 非 200 {error:"<code>"}, code ∈ too_large/bad_json/unexpected_field/
//         pii_detected/rate_limited/github_failed/method_not_allowed/not_found

const MAX_BODY_BYTES = 64 * 1024;
const MAX_PER_HOUR = 10;
const ISSUE_LABELS = ['diagnostics', 'anonymous'];
const GITHUB_TIMEOUT_MS = 8000;
const GITHUB_ATTEMPTS = 3;
const GITHUB_BACKOFF_MS = [0, 500, 1500]; // 立即 → 0.5s → 1.5s

// 白名单比黑名单稳: 只认诊断包现有字段 + 客户端补上的 clientId。
// 白名单的代价是采集口径一变就要改这里, 但那正是一次"该停下来想清楚"的改动。
const ALLOWED_TOP = new Set([
  'schema',
  'app',
  'generatedAt',
  'env',
  'settings',
  'account',
  'providers',
  'credential',
  'note',
  'clientId',
]);
const ALLOWED_ACCOUNT = new Set(['loggedIn', 'vip', 'deviceTag']);

// 兜底: 就算有人在白名单字段的值里塞了身份证, 也拦住。
// 之所以还要 "nickname"/"uid"/"cookie" 这类键名: 它们只可能出现在嵌套对象里。
const PII_PATTERNS = [
  /MUSIC_U/, // 网易云登录 cookie 的关键字段
  /[0-9a-fA-F]{12,}/, // 网易云 deviceId / NMTID / WNMCID 一类的长十六进制串
  /"(?:nickname|uid|cookie)"\s*:/, // 账号身份的字段名
];

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'POST, OPTIONS',
  'access-control-allow-headers': 'content-type',
  'access-control-max-age': '86400',
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', ...CORS_HEADERS },
  });
}

const fail = (status, code) => json(status, { error: code });

/** 422/401/404 这类是配置或权限问题, 重试只会浪费配额。 */
class NonRetryable extends Error {}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== '/' && url.pathname !== '/diag') return fail(404, 'not_found');

    // CORS 预检要在任何方法/内容校验之前回答, 否则浏览器端连错误都读不到
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }
    if (request.method !== 'POST') return fail(405, 'method_not_allowed');

    // 1) 体积上限。先看声明值(省一次读取), 再按真实字节数复核 —— header 可以造假
    const declared = Number(request.headers.get('content-length') || '0');
    if (declared > MAX_BODY_BYTES) return fail(413, 'too_large');
    let text;
    try {
      text = await request.text();
    } catch {
      return fail(400, 'bad_json');
    }
    if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) return fail(413, 'too_large');

    // 2) 结构: JSON → 顶层白名单 → account 子白名单(account 是唯一有嵌套身份的字段)
    let pkg;
    try {
      pkg = JSON.parse(text);
    } catch {
      return fail(400, 'bad_json');
    }
    if (pkg === null || typeof pkg !== 'object' || Array.isArray(pkg)) return fail(400, 'bad_json');
    for (const key of Object.keys(pkg)) {
      if (!ALLOWED_TOP.has(key)) return fail(400, 'unexpected_field');
    }
    const account = pkg.account;
    if (account !== undefined && account !== null) {
      if (typeof account !== 'object' || Array.isArray(account)) return fail(400, 'bad_json');
      for (const key of Object.keys(account)) {
        if (!ALLOWED_ACCOUNT.has(key)) return fail(400, 'unexpected_field');
      }
    }

    // clientId 是幂等键: 没有它就挡不住"点了两次/超时重发"造成的重复建单
    const clientId = typeof pkg.clientId === 'string' ? pkg.clientId.toLowerCase() : '';
    if (!UUID_RE.test(clientId)) return fail(400, 'bad_json');

    // 3) PII 兜底。扫描前必须把 clientId 抹掉: UUID 末段就是 12 位十六进制,
    //    会和"长十六进制串 = device id"的规则撞车。
    const scanned = text.split(pkg.clientId).join('');
    for (const pattern of PII_PATTERNS) {
      if (pattern.test(scanned)) return fail(400, 'pii_detected');
    }

    // 4) 幂等: 同一个 clientId 只建一张单, 重发直接给上次的结果
    const doneKey = `done:${clientId}`;
    const cached = await env.KV.get(doneKey);
    if (cached) {
      try {
        const hit = JSON.parse(cached);
        return json(200, { ok: true, number: hit.number, url: hit.url });
      } catch {
        // 缓存坏了不是客户端的问题, 当没命中继续走
      }
    }

    // 5) 限流: 每 IP 每小时 10 次。放在幂等之后 —— 重试打到已完成的单不该吃配额。
    //    注意 KV 最终一致, 并发突发能少量超发; 目的只是挡掉刷单/被当成开放代理,
    //    不是精确计费。
    const ip = request.headers.get('cf-connecting-ip') || 'unknown';
    const hourBucket = Math.floor(Date.now() / 3600000);
    const rlKey = `rl:${ip}:${hourBucket}`;
    const used = Number((await env.KV.get(rlKey)) || '0');
    if (used >= MAX_PER_HOUR) return fail(429, 'rate_limited');
    await env.KV.put(rlKey, String(used + 1), { expirationTtl: 3700 });

    // 6) 建单
    let created;
    try {
      created = await createIssue(env, pkg);
    } catch (e) {
      // 不把 GitHub 的错误细节回给客户端: 里面可能带仓库名/token 提示
      console.error('github issue create failed', String(e && e.message ? e.message : e));
      return fail(502, 'github_failed');
    }
    await env.KV.put(doneKey, JSON.stringify(created), { expirationTtl: 60 * 60 * 24 * 30 });
    return json(200, { ok: true, number: created.number, url: created.url });
  },
};

/**
 * 建 GitHub Issue, 最多 3 次(8s 超时 + 退避)。
 * 之所以要重试: GitHub 5xx / 连接被切断是常态抖动, 而客户端只重试 3 次、
 * 且用户正在等结果; Worker 侧多扛一轮能显著减少"上传失败"。
 */
async function createIssue(env, pkg) {
  const repo = env.GH_REPO;
  // 部署漏配 secret 时不能静默, 否则线上表现是永远 github_failed
  if (!env.GH_TOKEN || !repo || repo === 'REPLACE_ME/netease-mini-player') {
    throw new Error('worker misconfigured: GH_TOKEN / GH_REPO 未配置');
  }
  const title = `[diag] ${pkg.app ?? 'unknown'} / ${pkg.env?.platform ?? 'unknown'} / ${
    pkg.credential?.backend ?? 'unknown'
  }`;
  const body = [
    '自动上报的匿名诊断包(不含账号身份)。',
    '',
    '```json',
    JSON.stringify(pkg, null, 2),
    '```',
  ].join('\n');
  const payload = JSON.stringify({ title, body, labels: ISSUE_LABELS });

  let lastStatus = 0;
  let lastError = '';
  for (let attempt = 0; attempt < GITHUB_ATTEMPTS; attempt++) {
    if (GITHUB_BACKOFF_MS[attempt]) await sleep(GITHUB_BACKOFF_MS[attempt]);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), GITHUB_TIMEOUT_MS);
    try {
      const resp = await fetch(`https://api.github.com/repos/${repo}/issues`, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${env.GH_TOKEN}`,
          accept: 'application/vnd.github+json',
          'x-github-api-version': '2022-11-28',
          'content-type': 'application/json',
          'user-agent': 'minincm-diag-worker',
        },
        body: payload,
        signal: controller.signal,
      });
      const text = await resp.text();
      if (resp.ok) {
        const data = JSON.parse(text);
        return { number: data.number, url: data.html_url };
      }
      lastStatus = resp.status;
      // 422=标签/仓库/token 权限不对, 401/404=token 或仓库错: 都不该重试
      if (resp.status === 422 || resp.status === 401 || resp.status === 404) {
        throw new NonRetryable(`github_${resp.status}`);
      }
    } catch (e) {
      if (e instanceof NonRetryable) throw e;
      lastStatus = 0; // 网络/超时: 当次算失败, 允许再来
      lastError = String(e && e.name ? e.name : e);
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error(`github_failed status=${lastStatus} err=${lastError}`);
}
