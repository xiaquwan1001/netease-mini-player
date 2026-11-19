//! QuickJS 沙箱: 装载脚本 + 注入 lx 兼容层 + 单次调用的时间/内存/请求预算.
//!
//! 线程模型: 一个 [`ScriptEngine`] 只在自己的 worker 线程上被调用(sync API),
//! 因为 rquickjs 的 `Runtime`/`Context` 在没有 `parallel` feature 时是 `!Send`.
//! 跨线程调用由 `ScriptProvider` 负责(见 `worker` 模块), 本模块保持纯同步、可直接单测.
//!
//! 沙箱边界(契约 v1):
//! - 脚本只能经 `lx.request` 出站(宿主注入的 transport), 没有 fetch/require/文件系统;
//! - `lx.storage` 按 namespace 隔离;
//! - 单次调用硬超时由 QuickJS interrupt handler 实现, 内存上限由 `JS_SetMemoryLimit` 实现;
//! - 每次调用都重置请求计数, 日志留在宿主侧。

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use rquickjs::{Context, Ctx, Exception, Function, Object, Runtime};
use serde::Deserialize;

use crate::error::{PluginError, PluginErrorKind};
use crate::storage::Storage;
use crate::transport::{Transport, TransportRequest, TransportResponse};

const PRELUDE: &str = include_str!("prelude.js");

/// 宿主预算(契约 v1 的默认值, 见 README「预算」).
#[derive(Debug, Clone)]
pub struct SandboxConfig {
    /// 单次调用(含脚本加载)的硬超时.
    pub call_timeout: Duration,
    /// QuickJS 堆上限.
    pub memory_limit_bytes: usize,
    /// JS 栈上限.
    pub max_stack_bytes: usize,
    /// 单次调用允许的 `lx.request` 次数.
    pub max_requests_per_call: usize,
    /// 单次响应体上限(与 Melodia 的 4 MB 对齐).
    pub max_response_bytes: usize,
    /// 单次调用保留的日志条数上限.
    pub max_log_entries: usize,
    /// 单次 `lx.storage.set` 的 value 字节上限.
    pub max_storage_value_bytes: usize,
}

impl Default for SandboxConfig {
    fn default() -> Self {
        Self {
            call_timeout: Duration::from_secs(8),
            memory_limit_bytes: 32 * 1024 * 1024,
            max_stack_bytes: 512 * 1024,
            max_requests_per_call: 8,
            max_response_bytes: 4 * 1024 * 1024,
            max_log_entries: 200,
            max_storage_value_bytes: 64 * 1024,
        }
    }
}

/// 脚本通过 `lx.request` 递交的请求(宽松解析: 只要 url 必填, 其余可选).
#[derive(Debug, Deserialize)]
struct RawRequest {
    url: String,
    #[serde(default)]
    method: Option<String>,
    #[serde(default)]
    headers: Option<serde_json::Value>,
    #[serde(default)]
    body: Option<serde_json::Value>,
}

struct HostState {
    transport: Arc<dyn Transport>,
    storage: Arc<dyn Storage>,
    namespace: String,
    config: SandboxConfig,
    requests: usize,
    logs: Vec<String>,
}

impl HostState {
    fn begin_call(&mut self) {
        self.requests = 0;
    }

    fn push_log(&mut self, level: &str, message: &str) {
        if self.logs.len() >= self.config.max_log_entries {
            return;
        }
        self.logs.push(format!("[{level}] {message}"));
    }

    /// 返回 Err(String) => 变成 `{"__error": ...}` 信封, 由 prelude 抛成 JS 异常.
    fn request(&mut self, json: &str) -> Result<String, String> {
        if self.requests >= self.config.max_requests_per_call {
            return Err(format!(
                "lx.request: 单次调用请求数超过上限({})",
                self.config.max_requests_per_call
            ));
        }
        let raw: RawRequest = serde_json::from_str(json)
            .map_err(|e| format!("lx.request: 参数不是合法 JSON: {e}"))?;
        let url = raw.url.trim();
        if !(url.starts_with("https://") || url.starts_with("http://")) {
            return Err(format!("lx.request: 只允许 http/https, 拒绝 {url}"));
        }
        let method = raw
            .method
            .map(|m| m.trim().to_ascii_uppercase())
            .filter(|m| !m.is_empty())
            .unwrap_or_else(|| "GET".to_string());
        let headers = parse_headers(raw.headers.as_ref())?;
        let body = match raw.body {
            None | Some(serde_json::Value::Null) => None,
            Some(serde_json::Value::String(s)) => Some(s),
            // 对象/数组按 JSON 文本递交(契约: 出站 body 始终是字符串).
            Some(other) => Some(other.to_string()),
        };

        self.requests += 1;
        let request = TransportRequest {
            url: url.to_string(),
            method,
            headers,
            body,
        };
        let response = self.transport.send(&request).map_err(|e| e.message)?;
        if response.body.len() > self.config.max_response_bytes {
            return Err(format!(
                "lx.request: 响应体 {} 字节超过上限 {}",
                response.body.len(),
                self.config.max_response_bytes
            ));
        }
        serde_json::to_string(&transport_response_json(&response))
            .map_err(|e| format!("lx.request: 响应序列化失败: {e}"))
    }

    fn storage(&mut self, json: &str) -> Result<String, String> {
        #[derive(Deserialize)]
        struct Op {
            op: String,
            #[serde(default)]
            key: Option<String>,
            #[serde(default)]
            value: Option<String>,
        }
        let op: Op = serde_json::from_str(json)
            .map_err(|e| format!("lx.storage: 参数不是合法 JSON: {e}"))?;
        let key = op.key.unwrap_or_default();
        match op.op.as_str() {
            "get" => {
                let value: Option<serde_json::Value> = self
                    .storage
                    .get(&self.namespace, &key)
                    .and_then(|s| serde_json::from_str(&s).ok());
                Ok(serde_json::json!({ "value": value }).to_string())
            }
            "set" => {
                let value = op.value.unwrap_or_else(|| "null".to_string());
                if value.len() > self.config.max_storage_value_bytes {
                    return Err(format!(
                        "lx.storage: value {} 字节超过上限 {}",
                        value.len(),
                        self.config.max_storage_value_bytes
                    ));
                }
                self.storage.set(&self.namespace, &key, value);
                Ok("{\"ok\":true}".to_string())
            }
            "remove" => {
                self.storage.remove(&self.namespace, &key);
                Ok("{\"ok\":true}".to_string())
            }
            "keys" => {
                Ok(serde_json::json!({ "keys": self.storage.keys(&self.namespace) }).to_string())
            }
            other => Err(format!("lx.storage: 未知操作 {other}")),
        }
    }
}

fn parse_headers(raw: Option<&serde_json::Value>) -> Result<Vec<(String, String)>, String> {
    let Some(value) = raw else {
        return Ok(Vec::new());
    };
    match value {
        serde_json::Value::Null => Ok(Vec::new()),
        serde_json::Value::Object(map) => Ok(map
            .iter()
            .map(|(k, v)| {
                let text = match v {
                    serde_json::Value::String(s) => s.clone(),
                    other => other.to_string(),
                };
                (k.clone(), text)
            })
            .collect()),
        serde_json::Value::Array(items) => {
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                let pair = item
                    .as_array()
                    .filter(|p| p.len() == 2)
                    .ok_or_else(|| "lx.request: headers 数组项必须是 [name, value]".to_string())?;
                let name = pair[0]
                    .as_str()
                    .ok_or_else(|| "lx.request: header 名必须是字符串".to_string())?;
                let value = match &pair[1] {
                    serde_json::Value::String(s) => s.clone(),
                    other => other.to_string(),
                };
                out.push((name.to_string(), value));
            }
            Ok(out)
        }
        _ => Err("lx.request: headers 必须是对象或 [name, value] 数组".to_string()),
    }
}

fn transport_response_json(response: &TransportResponse) -> serde_json::Value {
    serde_json::json!({
        "status": response.status,
        "statusCode": response.status,
        "headers": response
            .headers
            .iter()
            .map(|(k, v)| serde_json::json!([k, v]))
            .collect::<Vec<_>>(),
        "body": response.body,
    })
}

/// 宿主装载好的脚本实例(单线程可用).
pub struct ScriptEngine {
    // 字段顺序 = 析构顺序: Context 必须先于 Runtime 释放, 否则 QuickJS 在
    // JS_FreeRuntime 里断言 gc_obj_list 非空(实测 SIGABRT).
    context: Context,
    runtime: Runtime,
    config: SandboxConfig,
    host: Rc<RefCell<HostState>>,
    handlers: Vec<String>,
    /// interrupt handler 用: 这次调用是否已被判成超时(区分超时与脚本自己抛错).
    timed_out: Arc<AtomicBool>,
    /// 相对 `epoch` 的绝对截止毫秒(u64::MAX = 未布防).
    deadline_ms: Arc<AtomicU64>,
    /// 与 interrupt handler 共享的时间原点(`Instant` 是 Copy, 可直接搬进闭包).
    epoch: Instant,
}

#[derive(Debug, Deserialize)]
struct CallOutcome {
    status: String,
    #[serde(default)]
    value: serde_json::Value,
    #[serde(default)]
    error: String,
}

impl ScriptEngine {
    /// 装载脚本(先跑 prelude, 再跑脚本).
    pub fn new(
        source: &str,
        config: SandboxConfig,
        transport: Arc<dyn Transport>,
        storage: Arc<dyn Storage>,
        namespace: impl Into<String>,
    ) -> Result<Self, PluginError> {
        let runtime =
            Runtime::new().map_err(|e| PluginError::load(format!("Runtime::new: {e}")))?;
        // 内存/栈上限必须在建 Context 之前设好: 装载期就要受约束(脚本顶层也能放炸弹).
        // 注意 rquickjs 的 set_memory_limit 只有**不用** rust-alloc/allocator 特性时才生效,
        // 我们正是这么选的(见 Cargo.toml 注释).
        runtime.set_memory_limit(config.memory_limit_bytes);
        runtime.set_max_stack_size(config.max_stack_bytes);
        let context = Context::full(&runtime)
            .map_err(|e| PluginError::load(format!("Context::full: {e}")))?;
        let host = Rc::new(RefCell::new(HostState {
            transport,
            storage,
            namespace: namespace.into(),
            config: config.clone(),
            requests: 0,
            logs: Vec::new(),
        }));
        let mut engine = Self {
            context,
            runtime,
            config,
            host,
            handlers: Vec::new(),
            timed_out: Arc::new(AtomicBool::new(false)),
            deadline_ms: Arc::new(AtomicU64::new(u64::MAX)),
            epoch: Instant::now(),
        };
        engine.install_interrupt();
        engine.install()?;
        engine.arm_deadline(engine.config.call_timeout);
        let loaded = engine.load_script(source);
        engine.disarm_deadline();
        loaded?;
        engine.handlers = engine.eval_handlers()?;
        Ok(engine)
    }

    /// 本实例注册的事件名(顺序 = 脚本注册顺序).
    pub fn handlers(&self) -> &[String] {
        &self.handlers
    }

    /// 取走累计日志(交付给上层日志通道).
    pub fn take_logs(&self) -> Vec<String> {
        std::mem::take(&mut self.host.borrow_mut().logs)
    }

    /// 触发一次事件. 入参/出参都是纯 JSON(契约: 不跨沙箱传宿主对象).
    pub fn invoke(
        &mut self,
        event: &str,
        args: serde_json::Value,
    ) -> Result<serde_json::Value, PluginError> {
        self.host.borrow_mut().begin_call();
        self.timed_out.store(false, Ordering::SeqCst);
        self.arm_deadline(self.config.call_timeout);
        let result = self.invoke_armed(event, args);
        self.disarm_deadline();
        result
    }

    /// QuickJS 每跑若干条字节码就回调一次; 超过截止时间返回 true, 引擎随即抛
    /// InternalError 中断执行。这是死循环必须有界的唯一实现点。
    fn install_interrupt(&mut self) {
        let timed_out = self.timed_out.clone();
        let deadline_ms = self.deadline_ms.clone();
        let epoch = self.epoch;
        self.runtime.set_interrupt_handler(Some(Box::new(move || {
            let now = epoch.elapsed().as_millis() as u64;
            if now >= deadline_ms.load(Ordering::Relaxed) {
                timed_out.store(true, Ordering::SeqCst);
                true
            } else {
                false
            }
        })));
    }

    /// 布防一次调用的截止时间(装载脚本也走这条路).
    fn arm_deadline(&self, timeout: Duration) {
        let now = self.epoch.elapsed().as_millis() as u64;
        self.deadline_ms.store(
            now.saturating_add(timeout.as_millis() as u64),
            Ordering::SeqCst,
        );
    }

    fn disarm_deadline(&self) {
        self.deadline_ms.store(u64::MAX, Ordering::SeqCst);
    }

    fn install(&mut self) -> Result<(), PluginError> {
        let host = self.host.clone();
        self.context.with(|ctx| {
            let result = (|| -> rquickjs::Result<()> {
                let host_obj = Object::new(ctx.clone())?;

                // 注意: native 闭包里不许捕获 `Ctx`(实测会在 JS_FreeRuntime 断言
                // gc_obj_list 非空 -> SIGABRT). 失败以 {"__error": msg} 信封回给 prelude,
                // 由 JS 侧 throw new Error(...), 语义不变且异常栈落在脚本侧.
                let request_host = host.clone();
                let request = Function::new(ctx.clone(), move |args: String| {
                    let mut state = request_host.borrow_mut();
                    Ok::<String, rquickjs::Error>(match state.request(&args) {
                        Ok(payload) => payload,
                        Err(message) => serde_json::json!({ "__error": message }).to_string(),
                    })
                })?;
                host_obj.set("request", request)?;

                let log_host = host.clone();
                let log = Function::new(ctx.clone(), move |level: String, message: String| {
                    log_host.borrow_mut().push_log(&level, &message);
                })?;
                host_obj.set("log", log)?;

                let storage_host = host.clone();
                let storage = Function::new(ctx.clone(), move |args: String| {
                    let mut state = storage_host.borrow_mut();
                    Ok::<String, rquickjs::Error>(match state.storage(&args) {
                        Ok(payload) => payload,
                        Err(message) => serde_json::json!({ "__error": message }).to_string(),
                    })
                })?;
                host_obj.set("storage", storage)?;

                ctx.globals().set("__lxHost", host_obj)?;
                ctx.eval::<(), _>(PRELUDE)?;
                Ok(())
            })();
            result.map_err(|e| js_error(&ctx, e, &self.timed_out, PluginErrorKind::Load, "prelude"))
        })
    }

    fn eval_handlers(&self) -> Result<Vec<String>, PluginError> {
        let raw: String = self.context.with(|ctx| {
            ctx.eval::<std::string::String, _>("__lxHandlerNames()")
                .map_err(|e| js_error(&ctx, e, &self.timed_out, PluginErrorKind::Load, "handlers"))
        })?;
        serde_json::from_str(&raw)
            .map_err(|e| PluginError::load(format!("事件名列表解析失败: {e}")))
    }

    fn load_script(&mut self, source: &str) -> Result<(), PluginError> {
        self.context.with(|ctx| {
            ctx.eval::<(), _>(source)
                .map_err(|e| js_error(&ctx, e, &self.timed_out, PluginErrorKind::Load, "script"))
        })
    }

    fn call(&mut self, event: &str, args_json: &str) -> Result<CallOutcome, PluginError> {
        let event_json = serde_json::to_string(event)
            .map_err(|e| PluginError::protocol(format!("事件名序列化失败: {e}")))?;
        // args 必须以 **JSON 字符串字面量** 传入(prelude 会 JSON.parse), 不能
        // 直接内联成 JS 表达式 —— 否则 JSON.parse([]) 拿到的就是空串.
        let args_literal = serde_json::to_string(args_json)
            .map_err(|e| PluginError::protocol(format!("入参序列化失败: {e}")))?;
        let raw: String = self.context.with(|ctx| {
            let expr = format!("__lxCall({event_json}, {args_literal})");
            ctx.eval::<std::string::String, _>(expr)
                .map_err(|e| js_error(&ctx, e, &self.timed_out, PluginErrorKind::Script, event))
        })?;
        parse_outcome(&raw)
    }

    fn invoke_armed(
        &mut self,
        event: &str,
        args: serde_json::Value,
    ) -> Result<serde_json::Value, PluginError> {
        let args_json = serde_json::to_string(&args)
            .map_err(|e| PluginError::protocol(format!("入参无法序列化: {e}")))?;

        let first = self.call(event, &args_json)?;
        match first.status.as_str() {
            "missing" => Err(PluginError::missing_handler(format!(
                "脚本未注册事件 {event}"
            ))),
            "error" => Err(script_failure(first.error)),
            "ok" => Ok(first.value),
            "pending" => self.drive_promises(),
            other => Err(PluginError::protocol(format!("未知的调用状态 {other}"))),
        }
    }

    fn drive_promises(&mut self) -> Result<serde_json::Value, PluginError> {
        // 同步泵 QuickJS job queue: 脚本的 await 只等宿主注入的同步实现,
        // 所以微任务队列是有限且必然收敛的; 不收敛 = 脚本把 promise 挂死了.
        let mut idle_rounds = 0usize;
        loop {
            // interrupt 只在 JS 执行时被回调; 纯 Rust 侧的泵循环自己再看一眼截止时间.
            if self.epoch.elapsed().as_millis() as u64 >= self.deadline_ms.load(Ordering::Relaxed) {
                self.timed_out.store(true, Ordering::SeqCst);
                return Err(PluginError::timeout(format!(
                    "沙箱调用超时(泵 job queue, 预算 {:?})",
                    self.config.call_timeout
                )));
            }
            match self.runtime.execute_pending_job() {
                Ok(true) => idle_rounds = 0,
                Ok(false) => {
                    let settled = self.settled()?;
                    if settled.status == "pending" {
                        idle_rounds += 1;
                        if idle_rounds > 3 {
                            return Err(PluginError::protocol(
                                "promise 永不 settle(宿主没有异步源, 脚本不要创建挂起的 promise)",
                            ));
                        }
                    }
                }
                Err(err) => {
                    let message = err.0.with(|ctx| exception_message(&ctx));
                    return Err(PluginError::script(message));
                }
            }
            let settled = self.settled()?;
            match settled.status.as_str() {
                "pending" => continue,
                "ok" => return Ok(settled.value),
                "error" => return Err(script_failure(settled.error)),
                other => {
                    return Err(PluginError::protocol(format!(
                        "未知的 promise 状态 {other}"
                    )))
                }
            }
        }
    }

    fn settled(&self) -> Result<CallOutcome, PluginError> {
        let raw: String = self.context.with(|ctx| {
            ctx.eval::<std::string::String, _>("__lxSettledJson()")
                .map_err(|e| js_error(&ctx, e, &self.timed_out, PluginErrorKind::Script, "settled"))
        })?;
        parse_outcome(&raw)
    }
}

fn parse_outcome(raw: &str) -> Result<CallOutcome, PluginError> {
    serde_json::from_str(raw).map_err(|e| PluginError::protocol(format!("调用结果无法解析: {e}")))
}

fn exception_message(ctx: &Ctx<'_>) -> String {
    let value = ctx.catch();
    if let Some(s) = value.as_string() {
        if let Ok(text) = s.to_string() {
            return text;
        }
    }
    if let Some(obj) = value.as_object().cloned() {
        if let Some(exc) = Exception::from_object(obj) {
            if let Some(message) = exc.message() {
                return message;
            }
        }
    }
    "script error".to_string()
}

/// 脚本侧冒泡上来的失败: OOM 要单独归类(内存上限 ≠ 脚本 bug).
fn script_failure(message: String) -> PluginError {
    if is_oom_message(&message) {
        PluginError::memory(message)
    } else {
        PluginError::script(message)
    }
}

fn is_oom_message(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("out of memory") || lower.contains("allocation")
}

/// JS 层错误 -> PluginError. 超时优先级最高(interrupt 也以异常形式冒泡).
fn js_error(
    ctx: &Ctx<'_>,
    err: rquickjs::Error,
    timed_out: &AtomicBool,
    default_kind: PluginErrorKind,
    phase: &str,
) -> PluginError {
    if timed_out.load(Ordering::SeqCst) {
        return PluginError::timeout(format!("沙箱调用超时({phase})"));
    }
    let message = match err {
        rquickjs::Error::Allocation => "out of memory".to_string(),
        rquickjs::Error::Exception => exception_message(ctx),
        other => other.to_string(),
    };
    if is_oom_message(&message) {
        return PluginError::memory(message);
    }
    match default_kind {
        PluginErrorKind::Load => PluginError::load(message),
        _ => PluginError::script(message),
    }
}
