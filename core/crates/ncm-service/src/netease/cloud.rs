//! 音乐云盘: 列表 / 删除 / 下载直链 / 上传(NOS 单请求 complete=true).
//!
//! 大文件分片: **分片规划与引擎已在 `crate::cloud_chunk`**(规划/进度/重试/可恢复点 + 单测),
//! 但音乐云盘桶的分片端点**没有可信证据**(只有 voice 桶的 S3 式流程, 参数不可照搬) ⇒
//! 这里仍只走单请求整文件; 接缝与「缺什么证据、怎么验」写在 `cloud_chunk` 的模块注释里.

use super::*;
use crate::cloud_chunk::{self, UploadPlan};
use md5::Digest as _;

impl NeteaseProvider {
    /// 云盘歌曲列表(分页). 需要登录.
    pub(super) fn user_cloud(
        &self,
        limit: u32,
        offset: u32,
    ) -> BoxFuture<'_, ProviderResult<CloudPage>> {
        Box::pin(async move {
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("音乐云盘需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua)
                .param("limit", &limit.max(1).to_string())
                .param("offset", &offset.to_string());
            let resp = client.user_cloud(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_cloud_page(&resp.body))
        })
    }

    /// 删除云盘歌曲. 入参是**云盘条目 id**(CloudSong::id), 不是 songId.
    pub(super) fn cloud_delete(&self, ids: &[u64]) -> BoxFuture<'_, ProviderResult<bool>> {
        let ids = ids.to_vec();
        Box::pin(async move {
            if ids.is_empty() {
                return Err(ProviderError::internal("cloud_delete: 没有要删除的条目"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("删除云盘歌曲需要登录"));
            }
            let joined = ids
                .iter()
                .map(|id| id.to_string())
                .collect::<Vec<_>>()
                .join(",");
            let q = make_query(&cookie, &domain, &ua).param("songIds", &joined);
            let resp = client.user_cloud_del(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(true)
        })
    }

    /// 云盘歌曲的下载直链(eapi /api/cloud/dowonload). 需要登录.
    pub(super) fn cloud_song_url(
        &self,
        song_id: u64,
    ) -> BoxFuture<'_, ProviderResult<Option<String>>> {
        Box::pin(async move {
            if song_id == 0 {
                return Err(ProviderError::not_found("歌曲 id 为空"));
            }
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("云盘下载需要登录"));
            }
            let q = make_query(&cookie, &domain, &ua).param("songId", &song_id.to_string());
            let resp = client.song_cloud_download(&q).await.map_err(map_error)?;
            check_body(&resp.body)?;
            Ok(parse_cloud_song_url(&resp.body))
        })
    }
}

/// user_cloud 响应: {code, count, size, maxSize, hasMore?, more?, data:[...]}.
///
/// data[] 里既有云盘文件字段(id/fileSize/bitrate/addTime), 也有内嵌的
/// simpleSong(歌曲元信息: 名字/歌手/专辑封面). 老数据可能没有 simpleSong,
/// 这时退回 fileName 当歌名.
pub fn parse_cloud_page(body: &Value) -> CloudPage {
    let songs = body
        .get("data")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_cloud_song).collect::<Vec<_>>())
        .unwrap_or_default();
    CloudPage {
        songs,
        count: u64_of(body, "count").unwrap_or(0),
        size: u64_of(body, "size").unwrap_or(0),
        max_size: u64_of(body, "maxSize").unwrap_or(0),
        more: body
            .get("more")
            .or_else(|| body.get("hasMore"))
            .and_then(Value::as_bool)
            .unwrap_or(false),
    }
}

pub fn parse_cloud_song(v: &Value) -> Option<CloudSong> {
    let simple = v.get("simpleSong");
    let song_id = u64_of(v, "songId")
        .or_else(|| simple.and_then(|s| u64_of(s, "id")))
        .unwrap_or(0);
    // 云盘条目 id 缺失时退回 songId: 至少还能删(同一首歌只上传一份是常态)
    let id = u64_of(v, "id").or_else(|| u64_of(v, "songId")).unwrap_or(0);
    let name = simple
        .and_then(|s| str_of(s, "name"))
        .or_else(|| str_of(v, "fileName"))
        .unwrap_or_default();
    if id == 0 && song_id == 0 {
        return None;
    }
    let artist = simple
        .and_then(|s| s.get("ar").or_else(|| s.get("artists")))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|a| str_of(a, "name"))
                .filter(|n| !n.is_empty())
                .collect::<Vec<_>>()
                .join(" / ")
        })
        .unwrap_or_default();
    let album_obj = simple.and_then(|s| s.get("al").or_else(|| s.get("album")));
    let album = album_obj
        .and_then(|a| str_of(a, "name"))
        .unwrap_or_default();
    let cover_url = album_obj
        .and_then(|a| str_of(a, "picUrl").or_else(|| str_of(a, "blurPicUrl")))
        .or_else(|| str_of(v, "coverUrl"))
        .filter(|s| !s.is_empty());
    Some(CloudSong {
        id,
        song_id: if song_id != 0 { song_id } else { id },
        name,
        artist,
        album,
        cover_url,
        size: u64_of(v, "fileSize")
            .or_else(|| u64_of(v, "size"))
            .unwrap_or(0),
        bitrate: u64_of(v, "bitrate").unwrap_or(0),
        add_time: u64_of(v, "addTime").unwrap_or(0),
    })
}

/// /api/cloud/dowonload 的响应: 直链可能在 data.url, 也可能在 data[0].url.
pub fn parse_cloud_song_url(body: &Value) -> Option<String> {
    let data = body.get("data");
    let url = data
        .and_then(|d| str_of(d, "url"))
        .or_else(|| {
            data.and_then(Value::as_array)
                .and_then(|arr| arr.first())
                .and_then(|first| str_of(first, "url"))
        })
        .or_else(|| str_of(body, "url"))
        .filter(|s| !s.is_empty());
    url
}

impl NeteaseProvider {
    /// 上传一个本地音频文件到音乐云盘. 需要登录.
    ///
    /// 协议按上游 `module/cloud_upload_token.js` + 前端 `cloudLocalUpload.js` 的五步流程:
    /// ① `/api/cloud/upload/check` 按 md5 查重(needUpload=false ⇒ 秒传)
    /// ② `/api/nos/token/alloc` 拿 token/objectKey/resourceId
    /// ③ 单次 POST 整文件到 LBS 节点(`?offset=0&complete=true&version=1.0`)
    /// ④ `/api/upload/cloud/info/v2` 提交元信息(转码中会重试几次)
    /// ⑤ `/api/v1/cloud/music/status` 轮询转码(status=9 就绪) → `/api/cloud/pub/v2` 发布
    ///
    /// 大文件一次读进内存(云盘单曲常见 5-60MB); 单次 complete=true 是上游前端同款路径
    /// (`plugins/songUpload.js`), 超过服务端单请求上限时才需要分片 —— 服务端上限尚未实测,
    /// 见 `CLOUD_SINGLE_SHOT_CEILING` 与 `crate::cloud_chunk` 的模块 TODO.
    pub(super) fn cloud_upload(
        &self,
        file_path: String,
    ) -> BoxFuture<'_, ProviderResult<CloudUploadResult>> {
        Box::pin(async move {
            let path = std::path::PathBuf::from(&file_path);
            let (client, domain, ua, cookie) = self.snapshot();
            if !cookie.contains("MUSIC_U=") {
                return Err(ProviderError::auth("上传云盘需要登录"));
            }
            // 先按文件大小选策略: 分片分支今天一定选不中(上限未实测 ⇒ 恒为 None),
            // 接缝留在这里是为了「证据到手后只改常量 + 加一个 ChunkUploader 实现」.
            let file_size = tokio::fs::metadata(&path)
                .await
                .map(|m| m.len())
                .unwrap_or(0);
            if let UploadPlan::Chunked(_) = cloud_upload_plan(file_size)? {
                return Err(ProviderError::unsupported(
                    "大文件分片上传尚未接线: 音乐云盘分片端点缺少可信证据(见 ncm_service::cloud_chunk 模块 TODO)",
                ));
            }
            let bytes = tokio::fs::read(&path)
                .await
                .map_err(|e| ProviderError::unsupported(format!("读取文件失败: {e}")))?;
            if bytes.is_empty() {
                return Err(ProviderError::unsupported("文件是空的"));
            }
            let file_name = path
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("unknown.mp3")
                .to_string();
            let ext = path
                .extension()
                .and_then(|s| s.to_str())
                .unwrap_or("mp3")
                .to_ascii_lowercase();
            let stem = file_name
                .rsplit_once('.')
                .map(|(a, _)| a)
                .unwrap_or(&file_name)
                .to_string();
            let md5_hex = {
                let mut hasher = md5::Md5::new();
                hasher.update(&bytes);
                format!("{:x}", hasher.finalize())
            };
            let size = bytes.len().to_string();

            // ① 查重
            let q = make_query(&cookie, &domain, &ua)
                .param("md5", &md5_hex)
                .param("length", &size);
            let check = client.cloud_upload_check(&q).await.map_err(map_error)?;
            check_body(&check.body)?;
            let need_upload = check
                .body
                .get("needUpload")
                .and_then(Value::as_bool)
                .unwrap_or(true);
            // check 的 songId 是 **128 位十六进制串**(不是数字); 上游把它原样回填给 info/v2。
            // 2026-11-19 前这里用 u64_of 解析 ⇒ 永远变 0, 见 upload_ids_from 的注释。
            let cloud_song_id = str_or_num_of(&check.body, "songId").unwrap_or_else(|| "0".into());

            // ② 申请 NOS token
            let safe_stem: String = stem
                .chars()
                .filter(|c| !c.is_whitespace() && *c != '.')
                .collect();
            let safe_stem = if safe_stem.is_empty() {
                "unknown".to_string()
            } else {
                safe_stem
            };
            let q = make_query(&cookie, &domain, &ua)
                .param("filename", &safe_stem)
                .param("ext", &ext)
                .param("md5", &md5_hex);
            let tok = client.cloud_nos_token(&q).await.map_err(map_error)?;
            check_body(&tok.body)?;
            let result = tok.body.get("result");
            let token = result
                .and_then(|r| str_of(r, "token"))
                .filter(|s| !s.is_empty())
                .ok_or_else(|| ProviderError::internal("nos token: 响应缺 token"))?;
            let object_key = result
                .and_then(|r| str_of(r, "objectKey"))
                .filter(|s| !s.is_empty())
                .ok_or_else(|| ProviderError::internal("nos token: 响应缺 objectKey"))?;
            // resourceId 是**数字**(如 84382086772), 只按字符串解析会拿到空串 ⇒
            // info/v2 缺 resourceId ⇒ `{"code":400,"songId":"0"}`(2026-11-19 实测复现)。
            let resource_id = result
                .and_then(|r| str_or_num_of(r, "resourceId"))
                .unwrap_or_default();

            // ③ 上传文件字节(秒传跳过)
            if need_upload {
                let ua_str = ua.as_deref().unwrap_or("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36");
                upload_nos_bytes(ua_str, &token, &md5_hex, &object_key, bytes, &ext).await?;
            }

            // ④ 提交元信息(刚上传完可能还在转码, 按上游做法重试)
            let mut new_song_id = 0u64;
            for attempt in 0..5 {
                let q = make_query(&cookie, &domain, &ua)
                    .param("md5", &md5_hex)
                    .param("songid", &cloud_song_id)
                    .param("filename", &file_name)
                    .param("song", &stem)
                    .param("resourceId", &resource_id);
                let info = client.cloud_upload_info(&q).await.map_err(map_error)?;
                let code = info.body.get("code").and_then(Value::as_i64).unwrap_or(0);
                if code == 200 {
                    new_song_id = u64_of(&info.body, "songId").unwrap_or(0);
                    break;
                }
                if attempt == 4 {
                    return Err(ProviderError::internal(format!(
                        "提交云盘信息失败: {}",
                        compact_body(&info.body)
                    )));
                }
                tokio::time::sleep(std::time::Duration::from_millis(1000)).await;
            }
            if new_song_id == 0 {
                return Err(ProviderError::internal("提交云盘信息后没有拿到 songId"));
            }

            // ⑤ 轮询转码 + 发布
            for _ in 0..30 {
                let q =
                    make_query(&cookie, &domain, &ua).param("song_ids", &new_song_id.to_string());
                let st = client.cloud_music_status(&q).await.map_err(map_error)?;
                let status = st
                    .body
                    .get("statuses")
                    .and_then(|s| s.get(new_song_id.to_string()))
                    .and_then(|v| v.get("status"))
                    .and_then(Value::as_i64)
                    .unwrap_or(0);
                if status == 9 {
                    break;
                }
                if status != 1 && status != 0 {
                    // 未知状态: 仍然尝试发布, 失败由 pub 的 code 兜底
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            }
            let q = make_query(&cookie, &domain, &ua).param("songid", &new_song_id.to_string());
            let published = client.cloud_pub(&q).await.map_err(map_error)?;
            let code = published
                .body
                .get("code")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            if code != 200 && code != 201 {
                return Err(ProviderError::internal(format!(
                    "发布云盘歌曲失败: {}",
                    compact_body(&published.body)
                )));
            }
            Ok(CloudUploadResult {
                song_id: new_song_id,
                name: stem,
                instant: !need_upload,
            })
        })
    }
}

/// 音乐云盘桶名(上游 `module/cloud_upload_token.js` 写死的那一个).
pub(super) const CLOUD_BUCKET: &str = "jd-musicrep-privatecloud-audio-public";

/// 单请求 `complete=true` 路径能承载的文件上限.
///
/// **实测值未知**(见 `crate::cloud_chunk` 模块 TODO 第 4 条) ⇒ `None`: 不设门槛, 一律走单请求.
/// 拿到实测数字后只改这一行, `UploadPlan::Chunked` 分支才开始可能被选中 —— 那之前
/// `cloud_upload` 遇到 `Chunked` 会返回明确的 `Unsupported`, 不会静默走错路径.
pub(super) const CLOUD_SINGLE_SHOT_CEILING: Option<u64> = None;

/// 选上传策略(薄包装: 让「今天恒为单请求」这件事在单测里可断言).
pub(super) fn cloud_upload_plan(file_size: u64) -> ProviderResult<UploadPlan> {
    cloud_chunk::plan_cloud_upload(
        file_size,
        CLOUD_SINGLE_SHOT_CEILING,
        cloud_chunk::DEFAULT_CHUNK_SIZE,
    )
}

/// 创建 NOS 上传用的客户端(整文件请求可能跑几分钟).
pub(super) fn build_upload_client() -> ProviderResult<reqwest::Client> {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(180))
        .build()
        .map_err(|e| ProviderError::internal(format!("创建上传客户端失败: {e}")))
}

/// 取 NOS 上传节点(上游 `plugins/songUpload.js` 同款 `wanproxy.127.net/lbs`).
async fn resolve_lbs_upload_host(http: &reqwest::Client, ua: &str) -> ProviderResult<String> {
    let lbs = http
        .get(format!(
            "https://wanproxy.127.net/lbs?version=1.0&bucketname={CLOUD_BUCKET}"
        ))
        .header("Referer", "https://music.163.com")
        .header("User-Agent", ua)
        .send()
        .await
        .map_err(|e| ProviderError::network(format!("获取上传节点失败: {e}")))?;
    let lbs: Value = lbs
        .json()
        .await
        .map_err(|e| ProviderError::internal(format!("上传节点响应无法解析: {e}")))?;
    lbs.get("upload")
        .and_then(Value::as_array)
        .and_then(|a| a.first())
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .ok_or_else(|| ProviderError::network("上传节点列表为空"))
}

/// 把整份文件 POST 到一个已知的 NOS 上传节点(秒传判定为 false 时才会调用).
///
/// 与上游前端同款: `<lbs-node>/<bucket>/<objectKey>?offset=0&complete=true&version=1.0`,
/// 头 `X-Nos-Token` + `Content-MD5`(hex) + 音频 Content-Type; 响应非 2xx 视为失败。
///
/// 与 [`resolve_lbs_upload_host`] 拆开是**为了可测**: 本地假 HTTP 服务能直接吃这条请求
/// (不经 LBS 域名), 从而在不触网的前提下断言 URL 参数/请求头/body 与失败映射.
pub(super) async fn upload_nos_whole_file(
    http: &reqwest::Client,
    lbs_host: &str,
    token: &str,
    md5_hex: &str,
    object_key: &str,
    bytes: Vec<u8>,
    ext: &str,
) -> ProviderResult<()> {
    let encoded = object_key.replace('/', "%2F");
    let url = format!("{lbs_host}/{CLOUD_BUCKET}/{encoded}?offset=0&complete=true&version=1.0");
    let content_type = nos_content_type(ext);
    let resp = http
        .post(&url)
        .header("X-Nos-Token", token)
        .header("Content-MD5", md5_hex)
        .header("Content-Type", content_type)
        .body(bytes)
        .send()
        .await
        .map_err(|e| ProviderError::network(format!("上传文件失败: {e}")))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(ProviderError::internal(format!(
            "上传文件失败(HTTP {status}): {}",
            compact_body_str(&body)
        )));
    }
    Ok(())
}

/// 上传后整条链路: 取 LBS 节点 → 整文件 POST.
async fn upload_nos_bytes(
    ua: &str,
    token: &str,
    md5_hex: &str,
    object_key: &str,
    bytes: Vec<u8>,
    ext: &str,
) -> ProviderResult<()> {
    let http = build_upload_client()?;
    let host = resolve_lbs_upload_host(&http, ua).await?;
    upload_nos_whole_file(&http, &host, token, md5_hex, object_key, bytes, ext).await
}

/// 音频扩展名 → 上传 Content-Type(上游不少文件是 mp3/flac, 其余按容器近似).
pub(super) fn nos_content_type(ext: &str) -> &'static str {
    match ext {
        "flac" => "audio/flac",
        "m4a" | "aac" => "audio/mp4",
        "wav" => "audio/wav",
        "ogg" => "audio/ogg",
        _ => "audio/mpeg",
    }
}

/// 错误详情里别塞整段响应体: 只保留前 200 字符, 便于日志/提示。
fn compact_body(body: &Value) -> String {
    compact_body_str(&body.to_string())
}

fn compact_body_str(raw: &str) -> String {
    let text: String = raw.chars().take(200).collect();
    if raw.chars().count() > 200 {
        format!("{text}…")
    } else {
        text
    }
}
