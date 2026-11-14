//! 音乐云盘: 列表 / 删除 / 下载直链 / 上传(NOS 单请求 complete=true).

use super::*;
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
    /// 大文件一次读进内存(云盘单曲常见 5-60MB); 分片上传未做 —— 单次 complete=true
    /// 是上游前端同款路径, 超过服务端单请求上限时才需要 offset 分片。
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
            let cloud_song_id = u64_of(&check.body, "songId").unwrap_or(0);

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
            let resource_id = result
                .and_then(|r| str_of(r, "resourceId"))
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
                    .param("songid", &cloud_song_id.to_string())
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

/// 把整份文件 POST 到 NOS 上传节点(秒传判定为 false 时才会调用).
///
/// 与上游前端同款: `http://<lbs-node>/<bucket>/<objectKey>?offset=0&complete=true&version=1.0`,
/// 头 `X-Nos-Token` + `Content-MD5`(hex) + 音频 Content-Type; 响应非 2xx 视为失败。
async fn upload_nos_bytes(
    ua: &str,
    token: &str,
    md5_hex: &str,
    object_key: &str,
    bytes: Vec<u8>,
    ext: &str,
) -> ProviderResult<()> {
    const BUCKET: &str = "jd-musicrep-privatecloud-audio-public";
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(180))
        .build()
        .map_err(|e| ProviderError::internal(format!("创建上传客户端失败: {e}")))?;
    let lbs = http
        .get(format!(
            "https://wanproxy.127.net/lbs?version=1.0&bucketname={BUCKET}"
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
    let host = lbs
        .get("upload")
        .and_then(Value::as_array)
        .and_then(|a| a.first())
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| ProviderError::network("上传节点列表为空"))?;
    let encoded = object_key.replace('/', "%2F");
    let url = format!("{host}/{BUCKET}/{encoded}?offset=0&complete=true&version=1.0");
    let content_type = match ext {
        "flac" => "audio/flac",
        "m4a" | "aac" => "audio/mp4",
        "wav" => "audio/wav",
        "ogg" => "audio/ogg",
        _ => "audio/mpeg",
    };
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
