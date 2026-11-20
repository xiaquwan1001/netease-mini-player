# ncm-plugin —— QuickJS 音源插件宿主(切片 1 + 切片 2 第一/二/三/四步)

> **状态: 实验性, 未接入产品(仍不可从 UI 触发)。** 本 crate 没有 FFI 导出、
> `Core::open` 也不构造插件宿主 —— 改动它不会改变 App 默认行为
> (不碰风控、不加包体风险)。**接缝已经落地**: 真实网络 transport 在
> `ncm-service/src/plugins/`(`ReqwestTransport`, 复用 service 的 UA/超时/重试口径),
> 落盘 storage 是本 crate 的 [`FileStorage`](src/storage.rs)(目录由宿主传入),
> 目录扫描/启停是 `PluginManager`, 装配成 `Provider` 是 `PluginRegistry`
> (键 = **插件 id**, 不是 `Provider::id()`, 原因见该文件头注释)。
> **门禁**: `ncm-service` 现在依赖本 crate, 所以 `tools/ci-gates.sh` 的 rust-lint / rust-test
> **按 workspace 全量跑**它(不再 `--exclude`, 独立门 `rust-plugin` 已删除 —— 同一口径只留一份)。
> 接线条件见 docs/remaining-batches.md §11.C。
> 设计边界见 [`docs/archive/architecture-restart.md`](../../../docs/archive/architecture-restart.md)
> 「插件化三层」「插件契约 v1 草案」「M5 插件」; 那里的 `platform/` 目录与 mpv 已作废, 以仓库现状为准。

实现分层:

| 文件 | 职责 |
|---|---|
| `src/sandbox.rs` | QuickJS `Runtime`/`Context`、`lx.*` 注入、单次调用预算(interrupt + 内存上限) |
| `src/prelude.js` | 注入给脚本的 JS 侧兼容层(`lx.on/request/storage/log/utils`, promise -> job queue 泵) |
| `src/transport.rs` | 出站注入面 `Transport` / `TransportError`(带状态码与 `to_provider_error`) + 测试用 `MockTransport`(纯内存); 生产实现在 `ncm-service::plugins` |
| `src/storage.rs` | `Storage` + `MemoryStorage`(进程内) / `FileStorage`(每 namespace 一个 JSON, 0600, tmp+rename 原子替换) |
| `src/convert.rs` | 脚本 JSON -> `ncm-domain` 的 `StreamUrl` / `SearchPage`(纯函数) |
| `src/worker.rs` | `ScriptProvider`: 专属线程 + `oneshot` 桥接,实现既有 `ncm_provider::Provider` |
| `src/error.rs` | `PluginError` -> `ProviderError{kind,retryable,detail}` 映射 |
| `src/manifest.rs` | 插件清单(`manifest.json`)纯数据 + 校验(可读错误, 不 panic); 目录管理在 `ncm-service/src/plugins/manager.rs` |

---

## 1. 契约 v1

### 1.1 脚本形态

ES6+(QuickJS 支持 ES2020 大部分特性), 装载时同步求值; 脚本顶层**注册事件**, 不写返回值。

```js
lx.on('musicUrl', async (source, info, quality) => {
  const res = await lx.request({ url: 'https://example.test/url?id=' + info.id, method: 'POST' });
  const data = JSON.parse(res.body);
  if (!data.url) return null;           // null / 空 url = 取不到直链
  return { url: data.url, type: 'mp3', expireAt: Date.now() + 300000 };
});
```

### 1.2 事件(宿主 -> 脚本)

调用一律是**位置参数**, 返回值经纯 JSON 边界回宿主(不跨沙箱传宿主对象)。

#### `musicUrl` —— 取直链

```js
lx.on('musicUrl', (source, musicInfo, quality) => string | {url,...} | null)
```

| 参数 | 类型 | 说明 |
|---|---|---|
| `source` | string | v1 传 `"script"`(插件没有真实平台代号; 兼容层二期再按 LX 的 `wy/kw/tx…` 传) |
| `musicInfo` | object | `{id, name, singer, albumName, interval, type}` |
| `quality` | string | LX 代号, 见下「音质映射」 |

`musicInfo` 在 v1 **只有 `id` 是真实值**: `ncm_provider::SongUrlRequest` 只带 `TrackId + AudioLevel`,
所以 `name/singer/albumName` 传空串、`interval` 传 0。依赖歌名/歌手中转的脚本(kw/tx 系)现阶段取不到链,
需要上层在后续切片把 `Song` 上下文补进调用参数(见 §4)。

返回值(三选一):

- `"https://..."`: 直链字符串;
- `{url, type?, br?, size?, expireAt?, md5?, actualLevel?, durationMs?, isTrial?}`:
  `expireAt` 大于 1e12 视为毫秒(脚本惯例 `Date.now()+n`),宿主折算成秒;
- `null` 或 `{url: null}` / 空串: 视为「拿不到直链」-> `ProviderErrorKind::NotFound`(不重试, 由上层换源)。

音质映射(与 Melodia `mapQualityToLx` 实测口径一致):

| `AudioLevel` | LX 代号 |
|---|---|
| `Hires` | `flac24bit` |
| `Lossless` | `flac` |
| `Exhigh` | `320k` |
| `Higher` / `Standard` | `128k` |

#### `search` —— 搜索(**本宿主自定义形状**, 见 §5)

```js
lx.on('search', (query) => Song[] | {songs, total?, hasMore?})
```

`query = {keywords, limit, offset}`。
单曲字段宽松匹配(社区脚本常见写法):

| 目标字段 | 接受的来源键 |
|---|---|
| 名称 | `name` / `title` / `songname` / `songName` |
| id | `id` / `songId` / `song_id`(数字或数字字符串; 缺省 0) |
| 歌手 | `artists`(字符串数组或 `{name,id,avatarUrl}` 数组) / `singer` / `singerName` / `artist`(按 `/ 、 , &` 拆分) |
| 专辑 | `album`(对象或字符串) / `albumName` / `album_name`; 封面 `picUrl` |
| 时长 | `interval`(秒, LX 惯例) / `durationMs` / `duration`(毫秒) |

`total` 缺省 = 本次条目数; `hasMore` 缺省 = `offset + len < total`。

### 1.3 注入 API(宿主 -> 脚本可用面)

| API | 说明 |
|---|---|
| `lx.on(name, handler)` / `lx.off(name)` | 注册/注销事件, 返回 `lx` |
| `lx.EVENT_NAMES` | `{request, inited, musicUrl, search}`(字符串常量, 与 Melodia 的 `lx.EVENT_NAMES` 对齐) |
| `lx.send(name, data)` | 脚本向宿主上报(当前只在宿主侧留痕, 接 UI 是后续切片) |
| `lx.log(...)` / `console.log/info/warn/error/debug` | 写宿主日志缓冲(`Provider::take_logs`) |
| `lx.request(args)` | **唯一**出站通道, 返回 Promise |
| `lx.storage.get/set/remove/keys` | namespace 隔离的键值存储(值走 JSON) |
| `lx.utils.crypto.md5(str)` | 纯 JS 标准 MD5(测试向量 `abc -> 900150983cd24fb0d6963f7d28e17f72`) |
| `lx.utils.stringify(v)` | `JSON.stringify`, `undefined -> "null"` |

`lx.request(args)`:

```js
const res = await lx.request({
  url: 'https://...',                // 必填, 仅 http/https
  method: 'POST',                    // 可选, 默认 GET(大写)
  headers: { 'User-Agent': 'x' },    // 可选, 对象或 [name, value] 数组, 原样透传
  body: 'level=320k',                // 可选, 字符串; 对象/数组按 JSON 文本递交
});
// res = { status, statusCode, headers: [[k,v],...], body }
```

失败(非 http/https、超出次数/体积预算、transport 报错)在 JS 侧表现为**被 reject 的 Promise**
(`throw new Error(message)`), 脚本可以 try/catch 自行降级。

**沙箱里没有**: `require` / `module` / `process` / `fetch` / `XMLHttpRequest` / `Deno` / 文件系统 /
任意 socket / `setTimeout`(`lx.utils.sleep` 会明确抛错)。这一点有专项用例断言。

### 1.4 预算(默认值, `SandboxConfig`)

| 预算 | 默认 | 实现 |
|---|---|---|
| 单次调用硬超时 | **8 s** | QuickJS interrupt handler + 泵循环截止时间 |
| 内存上限 | **32 MB** | `JS_SetMemoryLimit`(QuickJS 自带分配器; 不开 rust-alloc) |
| JS 栈上限 | 512 KB | `JS_SetMaxStackSize` |
| 单次 `lx.request` 次数 | 8 | 宿主计数, 每次调用重置 |
| 单次响应体 | 4 MB | 与 Melodia `RESPONSE_LIMIT` 对齐 |
| 日志条数 | 200 | 超出丢弃 |
| `lx.storage.set` 单值 | 64 KB | 超出拒绝 |
| 插件装载(初始化) | 8 s | `ScriptProvider::load` 的 `recv_timeout`(对齐 Melodia `INIT_TIMEOUT_MS`) |

超时/内存超限都会**中断**执行, 不会把宿主卡死; 每次调用的计时/计数都是独立的。

### 1.5 错误映射(`PluginError` -> `ProviderError`)

| `PluginErrorKind` | `ProviderErrorKind` | retryable | 触发场景 |
|---|---|---|---|
| `Timeout` | `network` | ✅ | 死循环 / 超时 |
| `Memory` | `internal` | ❌ | 内存炸弹 / OOM |
| `Script` | `internal` | ❌ | 脚本抛错、promise reject、transport 报错/策略拒绝被脚本透传 |
| `Protocol` | `internal` | ❌ | 返回值形状不对 / promise 永不 settle |
| `MissingHandler` | `unsupported` | ❌ | 脚本没注册该事件 |
| `NoUrl` | `notFound` | ❌ | 脚本返回 null / 空 url |
| `Load` | `internal` | ❌ | 语法错误 / 初始化超时 / 线程起不来 |
| `Shutdown` | `internal` | ❌ | worker 线程已退出 |

`Display` 形状是 `[<kind>] <detail>`, 与 `ncm-provider` 既有约定一致(跨桥文本协议, 不要改格式)。

> **没有 `RequestDenied` / `Transport` 两个变体**(分类收敛口径): 策略拒绝(白名单/预算超出)与
transport 层失败在沙箱链路里都只把文案交给脚本, 脚本不捕获就成 `Script` -> `internal` + 不重试;
需要按状态码分档(`401/403 -> Forbidden`、`404 -> NotFound`)时由
`TransportError::to_provider_error()` 直接给 `ProviderError`, 不经过 `PluginError`。
> 理由与判据用例见 `src/error.rs` 模块头。

---

### 1.6 插件清单(`manifest.json`)与目录管理(切片 2 第二步)

清单由本 crate 的 [`manifest`](src/manifest.rs) 定义并校验(**纯数据, 无 I/O**):

```json
{
  "id": "demo",
  "name": "Demo 插件",
  "version": "1.0.0",
  "entry": "index.js",
  "permissions": { "lxEvents": ["musicUrl", "search"], "requestDomains": ["api.example.com"] }
}
```

| 字段 | 规则(违反 -> `ManifestError{field,reason}`, 绝不 panic) |
|---|---|
| `id` | `[a-z0-9][a-z0-9_-]{0,63}`, **必须等于目录名**(不收点号/斜杠/大写: 路径安全 + 大小写不敏感文件系统) |
| `name` | 非空、≤64 字符、无首尾空白/控制字符 |
| `version` | `主.次.修订`(可带 `-预发布`) |
| `entry` | **单层文件名**, 以 `.js` 结尾, 不以点开头, 无分隔符/冒号 |
| `permissions.lxEvents` | 只能取 `KNOWN_EVENTS`(`request/inited/musicUrl/search`), 不重复, ≤8 个 |
| `permissions.requestDomains` | `host` 或 `*.host`, 不带 scheme/端口/路径, ≤16 个 |

目录管理在 `ncm-service::plugins::PluginManager`(`<root>/<plugin-id>/{manifest.json, <entry>}` 扫描;
启停落盘 `<root>/plugins-state.json` 0600 原子写; 每插件自己的 `<root>/<id>/data/` storage 目录 +
自己那份 `SandboxConfig` clone)。判据表见 `manager.rs` 头注释, 逐条用例见 `manager_tests.rs`。
**权限已强制**(不再是"声明性数据"): 插件装载时把宿主 transport 包进 `GuardedTransport`
(每插件一份 `DomainPolicy`), 未声明主机/白名单外的请求在发出去之前就被拒;
拒绝形态与两条消费路径见 `src/policy.rs` 的 `GuardedTransport` 文档。

---

## 2. 线程与生命周期

- `ScriptEngine` 是 **`!Send`**(rquickjs 未开 `parallel` feature), 只在一个线程里用;
- `ScriptProvider::load` 起一条专属线程持有 `ScriptEngine`, 外层只留 `mpsc::Sender`;
- 异步 `Provider` 方法经 `futures::channel::oneshot` 回传结果, 不阻塞调用方 executor(不引入 tokio);
- `Drop` 只发 `Shutdown`、**不 join**: 若有一次调用正在跑, join 会把析构阻塞到超时预算结束;
- 字段声明顺序是 `Context` 在 `Runtime` 之前 —— 反过来会在 `JS_FreeRuntime` 断言 `gc_obj_list` 非空并 SIGABRT。

---

## 3. 测试与实证

```bash
cargo test -p ncm-plugin --manifest-path core/Cargo.toml --offline
# 落盘 storage 的专项用例(tests/storage_file.rs): 命名空间隔离 / 原子替换 / 0600 /
# 坏 JSON 当空 / 沙箱 8 请求预算在落盘后端下仍生效
```

- `tests/sandbox.rs`(14 例): 事件分发、request 注入(method/headers/body 原样)、transport 报错、
  **超时中断**、**内存上限**、storage 命名空间隔离与跨调用保持、请求次数/响应体/协议白名单预算、
  逃逸面(`require/process/fetch/XMLHttpRequest/Deno/module` 全 undefined)、MD5 向量、缺处理器、脚本抛错映射;
- `tests/provider.rs`(6 例): `songUrl`/`search` 走既有 `Provider`、能力声明由注册事件决定、
  不支持能力 -> `unsupported`、语法错误 -> `Load`、`null` 直链 -> `notFound`;
- JS fixture 在 `tests/fixtures/`(music_url / search / storage / budget / escape / md5 / loop / memory_bomb)。

**红 -> 绿实证**(必看):

1. 提交 `f5915b8`(红相): 沙箱未接 interrupt/内存上限, `cargo test -p ncm-plugin` 实测
   `12 passed; 2 failed` —— `timeout_interrupts_infinite_loop` 以「守护时限 10s 内未返回」失败,
   `memory_limit_stops_memory_bomb` 以 `expect_err` 拿到 `Ok` 失败;
2. 下一提交(绿相): 接 `set_interrupt_handler` + `set_memory_limit` + `set_max_stack_size`,
   同一批用例 `14 passed; 0 failed`(含超时/内存两类)。

超时/内存用例都在子线程里建引擎 + 外层 `recv_timeout` 守护, 即使预算失效也不会把 test 进程挂死。

---

## 4. 未做项与后续切片

| # | 事项 | 说明 |
|---|---|---|
| 1 | **插件管理层** | ✅ 切片 2 第二步已落目录扫描/启停/元信息(`PluginManager`, 清单 JSON 取代 `@name` 头注释); 仍缺版本协商与「连续失败 3 次自动禁用」, 且**未接 FFI/UI** |
| 2 | **导入/启停** | 粘贴/文件/URL 导入、启用禁用、卸载; 目前只接受调用方给的内存脚本文本 |
| 3 | **插件管理页** | UI 车道; 本切片按要求不碰 UI |
| 4 | ~~**真实网络 transport**~~ | ✅ 切片 2 第一步已落: `ncm-service::plugins::ReqwestTransport`(UA/连接超时/读超时/重试档位全部复用 `cache.rs` 口径); 仍**未接线**(产路径不构造) |
| 5 | ~~**持久化 storage**~~ | ✅ 切片 2 第一步已落: `FileStorage`(0600 / 原子替换 / 坏文件当空); 目录由宿主传入, 接线路由仍待做 |
| 6 | **`songUrl` 上下文补齐** | `SongUrlRequest` 只有 `track+level`, 需要上层把 `name/singer/albumName/interval` 带进来(§1.2) |
| 7 | **FFI / 注册路由** | ✅ 切片 2 第四步已落 `ncm-service::plugins::PluginRegistry`(按插件 id 索引, 扫描/刷新/启停/失败隔离); **仍缺**: FFI 导出、`Core::open` 构造, 以及路由层直接认这张"插件 id -> provider"表(`ScriptProvider::id()` 恒为 `"script"`, 直接塞 `ncm_provider::ProviderRegistry` 会静默丢第二个插件); 接入要单独评审风控与体积 |
| 8 | **双端一致性** | Android(NDK)与桌面(PC)交叉编译 rquickjs-sys 未在本切片验证, 只在 Linux x86_64 全绿 |
| 9 | **日志通道到 UI** | 日志暂由 `ScriptProvider::take_logs()` 拉取, 没有订阅/回放 |
| 10 | **歌词能力** | `LyricProvider::lyric` 明确返回 `unsupported` |
| 11 | **运行期进程外隔离** | 二期: 进程/沙箱子进程; 本切片只有线程内 QuickJS 沙箱 |
| 12 | **`lx.crypto` / `lx.utils.zlib` / `buffer` codec** | 未实现(见 §5 的差异表) |

---

## 5. 待验证项(不编造 LX 生态行为)

以下是**我们没在本仓验证过**、因此只能按「已知信息 + 明确标注」处理的地方:

1. **`search` 事件在 LX 上游的调用形状**: `docs/archive/lx-plugin.md` §7 记录 Melodia 沙箱
   「只有 `musicUrl` 动作; 搜索/歌词走宿主自己的实现」——即上游 LX 的 `search` 契约未在本仓核实。
   本 crate 的 `{keywords, limit, offset}` -> `Song[] | {songs,...}` 是**本主机 v1 自定义形状**,
   与社区脚本的 `lx.on('search', (keyword, page, limit) => ...)` 之类写法可能不一致, 接入前要拿真实脚本对表。
2. **`musicUrl` 的位置参数**沿用 Melodia 源码读出的 `(source, musicInfo, quality)`
   (`resolveMusicUrl`), 但 `source` 的真实平台代号(`wy/kw/tx…`)本切片不传, 统一给 `"script"`;
   依赖 `source` 分流的多平台脚本会受影响。
3. **`lx.utils.crypto`**: 上游只有 `md5`(Melodia 实测), 本 crate 也只实现 md5;
   `aesEncrypt / rsaEncrypt / randomBytes / zlib / buffer codec` 的上游语义未验证, 暂不提供。
4. **`lx.send('inited', {sources})` 握手**: Melodia 从 `data.sources` 的 key 取支持平台列表;
   本 crate 只把 `lx.send` 的载荷留在沙箱内(尚未回传宿主), 握手语义等接插件管理层时再定。
5. **LX 脚本元信息头**(`@name/@description/@version/@capabilities/@apiVersion`)解析与
   `apiVersion` 不兼容时的拒绝文案, 本切片未做。
6. **`expireAt` 单位**: 按社区惯例当毫秒处理并折算成秒; 是否有脚本给秒级时间戳未统计。
7. **静默降级 / 试听片段**: 上游 `freeTrialInfo` 非空 = 试听, 这属于网易云协议层(vendor)而不是
   插件契约; 本切片只透传脚本给的 `isTrial`, 不做猜测。

---

## 6. 用法

```rust
use std::sync::Arc;
use ncm_plugin::{MemoryStorage, MockTransport, PluginSpec, SandboxConfig, ScriptProvider};
use ncm_provider::{AudioLevel, Provider, ReadProvider, SongUrlRequest};
use ncm_domain::TrackId;

let transport = Arc::new(MockTransport::new()
    .on("example.test", Ok(ncm_plugin::TransportResponse {
        status: 200,
        headers: vec![],
        body: r#"{"url":"https://cdn.test/a.mp3"}"#.to_string(),
    })));
let storage = Arc::new(MemoryStorage::new());
let provider = ScriptProvider::load(
    PluginSpec::new("demo", include_str!("demo.js"), transport, storage)
        .with_config(SandboxConfig::default()),
)
.expect("load");

assert!(provider.supports(ncm_provider::Capability::SongUrl));
let stream = futures::executor::block_on(provider.song_url(&SongUrlRequest {
    track: TrackId(42),
    level: AudioLevel::Exhigh,
}))
.expect("url");
println!("{:?}", stream.url);
```

---

## 7. 实现坑(给后来者)

- **native 闭包不许捕获 `Ctx`**: 实测会在 `JS_FreeRuntime` 断言 `gc_obj_list` 非空 -> SIGABRT。
  宿主失败改用 `{"__error": "..."}` 信封 + JS 侧 `throw`, 语义相同且异常栈落在脚本侧。
- **eval 传参必须是 JSON 字符串字面量**: `__lxCall(event, <args>)` 里的 `<args>` 要
  `serde_json::to_string(&args_json)` 再拼, 否则 `JSON.parse([])` 拿到的就是空串。
- **`Context` 必须先于 `Runtime` 释放**(字段顺序)。
- **`set_memory_limit` 只在不开 `rust-alloc`/`allocator` 特性时生效**: 所以 `Cargo.toml` 里
  rquickjs 用 `default-features = false, features = ["std"]`。
- **`await` 需要手动泵 job queue**: 本宿主不引 async 运行时, `lx.request` 是同步实现 +
  `Promise` 包装, 由 `Runtime::execute_pending_job()` 循环推进; 永不 settle 的 promise 会被判 `Protocol`。
