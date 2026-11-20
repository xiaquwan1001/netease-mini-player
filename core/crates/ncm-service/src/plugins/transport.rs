//! 插件 `lx.request` 的生产 Transport: 复用 ncm-service 既有的 HTTP 口径.
//!
//! 复用清单(改这里等于改产品网络口径, 动之前先看 `cache.rs` 头注释):
//!
//! | 口径 | 来源 |
//! |---|---|
//! | UA | `crate::identity::platform_profile().ua`(与取链/下载同一套身份口径, 不自己编字符串) |
//! | 连接超时 | `cache::CONNECT_TIMEOUT` |
//! | 总超时 | `cache::READ_TIMEOUT`(**blocking API 没有独立的 `read_timeout`**: 它只有 `timeout`;
//! 插件请求都是小 JSON, 用"读停顿上限"当整请求上限是更严的同一口径; 沙箱的 8s 调用预算是另一道闸) |
//! | 重试档位 | `cache::DOWNLOAD_RETRIES`(只对 `retryable` 失败多试一次) |
//! | 错误展开 | `netease::error_chain`(reqwest 的 Display 只有一句话, 真因在 source 链) + `netease::proxy_hint` |
//!
//! 为什么用 reqwest 的 **blocking** 客户端: 插件 `Transport` 是同步 trait(沙箱在专属线程上
//! 同步泵 job queue), 而 `cache.rs` 那份 async client 在没有 tokio runtime 的线程上
//! `block_on` 会 panic; blocking 客户端内部自带 runtime, 配置项(UA/连接/读超时)与 async 那份
//! 一一对应 —— 这不是"另起一套 reqwest 配置", 是同一套口径的同步入口.
//!
//! 失败语义(交回 `ncm-plugin` 的 `TransportError`):
//! - 非 2xx ⇒ `TransportError::http_status`: 401/403/404 不可重试, 其余可重试;
//! - 超时 / 连接失败 ⇒ 可重试; 其余(证书、URL 形状、header 非法)不可重试;
//! - `TransportError::to_provider_error()` 决定最终 `ProviderError{kind,retryable,detail}`
//!   (403 -> forbidden, 404 -> notFound, 其余 -> network).

use ncm_plugin::{Transport, TransportError, TransportRequest, TransportResponse};
use ncm_provider::{ProviderError, ProviderResult};

use crate::cache::{CONNECT_TIMEOUT, DOWNLOAD_RETRIES, READ_TIMEOUT};

/// 与 `cache::DOWNLOAD_RETRIES` 同档: 只对可重试失败多试一次.
const TRANSPORT_RETRIES: u32 = DOWNLOAD_RETRIES;

/// 生产 Transport: 一个进程内复用的 blocking 客户端(连接池由 reqwest 管).
pub struct ReqwestTransport {
    client: reqwest::blocking::Client,
    retries: u32,
}

impl ReqwestTransport {
    /// 生产构造: UA + 连接/读超时全部走 service 既有口径.
    pub fn new() -> ProviderResult<Self> {
        let client = reqwest::blocking::Client::builder()
            .user_agent(crate::identity::platform_profile().ua)
            .connect_timeout(CONNECT_TIMEOUT)
            // blocking ClientBuilder 只暴露整体 timeout(没有 async 那边的 read_timeout);
            // 用读停顿上限当整请求上限(更严), 见模块头注释的复用表.
            .timeout(READ_TIMEOUT)
            .build()
            .map_err(|e| ProviderError::internal(format!("创建插件出站客户端失败: {e}")))?;
        Ok(Self {
            client,
            retries: TRANSPORT_RETRIES,
        })
    }

    /// 注入现成客户端(测试用: 换超时/换 UA 不需要碰生产口径).
    pub fn with_client(client: reqwest::blocking::Client) -> Self {
        Self {
            client,
            retries: TRANSPORT_RETRIES,
        }
    }

    /// 覆盖重试次数(0 = 不重试, 测试用).
    pub fn with_retries(mut self, retries: u32) -> Self {
        self.retries = retries;
        self
    }

    /// 单次尝试(不含重试).
    fn attempt(&self, request: &TransportRequest) -> Result<TransportResponse, TransportError> {
        let method = reqwest::Method::from_bytes(request.method.as_bytes()).map_err(|e| {
            TransportError::new(format!("非法 HTTP 方法 {}: {e}", request.method), false)
        })?;
        let mut builder = self.client.request(method, &request.url);
        for (name, value) in &request.headers {
            builder = builder.header(name.as_str(), value.as_str());
        }
        if let Some(body) = &request.body {
            builder = builder.body(body.clone());
        }
        let response = builder.send().map_err(|e| classify(&e))?;
        let status = response.status().as_u16();
        if !(200..300).contains(&status) {
            // 非 2xx 一律当传输失败(axios/LX 的脚本惯例也是 throw): 脚本侧看到的是 rejection,
            // 上层的 kind/retryable 由 `TransportError::http_status` 决定.
            return Err(TransportError::http_status(
                status,
                format!("上游返回 http {status}({} {})", request.method, request.url),
            ));
        }
        let headers = response
            .headers()
            .iter()
            .map(|(name, value)| {
                (
                    name.as_str().to_string(),
                    String::from_utf8_lossy(value.as_bytes()).to_string(),
                )
            })
            .collect();
        let body = response.text().map_err(|e| {
            let detail = format!(
                "读响应体失败: {}{}",
                crate::netease::error_chain(&e),
                crate::netease::proxy_hint()
            );
            TransportError::new(detail, e.is_timeout())
        })?;
        // 注: reqwest 会自动解压(gzip/br 视 feature), 4 MB 的沙箱响应体预算在 plugin 侧判.
        Ok(TransportResponse {
            status,
            headers,
            body,
        })
    }
}

impl Transport for ReqwestTransport {
    fn send(&self, request: &TransportRequest) -> Result<TransportResponse, TransportError> {
        let attempts = 1 + self.retries;
        let mut attempt = 1;
        loop {
            match self.attempt(request) {
                Ok(response) => return Ok(response),
                Err(err) => {
                    if attempt < attempts && err.retryable {
                        eprintln!(
                            "[plugin-transport] 第 {attempt} 次请求失败, 重试一次: {}",
                            err.message
                        );
                        attempt += 1;
                        continue;
                    }
                    return Err(err);
                }
            }
        }
    }
}

/// reqwest 错误 -> TransportError(可重试性只由错误种类决定, 不看字符串).
fn classify(err: &reqwest::Error) -> TransportError {
    let detail = format!(
        "{}{}",
        crate::netease::error_chain(err),
        crate::netease::proxy_hint()
    );
    if err.is_timeout() {
        TransportError::timeout(format!("插件请求超时: {detail}"))
    } else if err.is_connect() {
        // 连接失败(DNS/TCP/TLS 握手)在移动网络上是瞬时的, 值得重试一次
        TransportError::new(format!("插件请求连不上: {detail}"), true)
    } else {
        TransportError::new(detail, false)
    }
}

#[cfg(test)]
#[path = "transport_tests.rs"]
mod tests;
