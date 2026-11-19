//! 云盘(音乐云盘)大文件分片上传: 分片规划(纯函数) + 传输无关的分片引擎 + 接缝.
//!
//! ## 为什么这里没有「真实分片端点」
//!
//! 2026-11-20 静态核实了本地全部上游参考(`references/api-enhanced`、vendor `ncm-api`、
//! `legacy/plugins/lx-music`):
//!
//! - 音乐云盘桶 `jd-musicrep-privatecloud-audio-public` 的唯一上传路径是**单请求整文件**:
//!   `POST <lbs.upload[0]>/<bucket>/<objectKey>?offset=0&complete=true&version=1.0`
//!   (`plugins/songUpload.js` 与 `module/cloud_upload_token.js` 各自拼了一次, 参数完全一致)。
//! - 全仓唯一带 `?uploads` / `partNumber=` / `uploadId=` 的分片流程在 `module/voice_upload.js`,
//!   但它打的是**另一个桶**(`ymusic`, 主机 `ymusic.nos-hz.163yun.com`, `nos_product: 0`,
//!   `type: "other"`, 还额外走 voice workbench 两支接口), 与音乐云盘不同桶、不同产线、
//!   不同收尾流程 ⇒ 参数不可照搬。
//! - vendor 里没有任何 `offset=` / `partNumber` 相关代码; `cloud_upload_complete` 只做
//!   `/api/upload/cloud/info/v2` + `/api/cloud/pub/v2`(即我们已实现的第 ④⑤ 步)。
//!
//! 所以本模块**只落地有把握的部分**: 分片怎么切、怎么顺序传、单片失败怎么办、断点怎么续、
//! 进度怎么报 —— 这些与 HTTP 形状无关; 真正的 NOS 分片/合并请求留给 [`ChunkUploader`] 的
//! 实现, 生产路径(`netease::cloud::cloud_upload`)暂时仍是单请求。
//!
//! ## TODO(接线前必须补齐的证据)
//!
//! 缺的是「音乐云盘桶的分片 HTTP 形状」, 下面四条缺一条都不许写端点:
//!
//! 1. **初始化**: 大文件上传前是否有独立初始化请求(形如 `<objectKey>?uploads`)? 方法/头/响应里
//!    返回的是 `UploadId`(XML)还是别的句柄?
//! 2. **分片**: 每片的 URL 是 **offset 追加式**(`?offset=<bytes>&complete=false&version=1.0`)
//!    还是 **S3 式**(`?partNumber=<n>&uploadId=<id>`)? 分片大小上限、序号从 0 还是 1 起、
//!    是否需要 `X-Nos-Context` / `session` 之类的上下文头?
//! 3. **合并**: 是否有独立 complete 请求(它要哪种 body: XML `CompleteMultipartUpload` 还是空),
//!    还是「最后一片 `complete=true` 就是合并」? 每片响应里的 `ETag` / `offset` 回执要不要参与合并?
//! 4. **服务端单请求上限**: 单请求路径到底能传多大(上传一个略超阈值的文件看服务端返回码)。
//!    没有这个数字, `netease::cloud::CLOUD_SINGLE_SHOT_CEILING` 只能保持 `None`, 分片分支永远不会被选中。
//!
//! 验证方式(**需真人 + 真机/代理**): 官方客户端上传一个明显超过单请求上限的文件到音乐云盘,
//! 用 mitm(证书装到设备)或 Windows 侧 Fiddler 抓 HTTPS, 记录 ①②③; ④ 用我们自己的
//! `cloud_upload` 逐步加大文件复现。
//!
//! 证据到手后: ① 在本模块实现 `NosAppendUploader` 或 `NosMultipartUploader`(端点/参数只出现在
//! 这一个类型里) ② 在 `netease::cloud` 的 `UploadPlan::Chunked` 分支接线 ③ 把假 HTTP 服务测试从
//! 「单请求序列」扩到「分片→合并→info」 ④ 把 `CLOUD_SINGLE_SHOT_CEILING` 从 `None` 换成实测值。

use ncm_provider::{BoxFuture, ProviderError, ProviderResult};

/// 默认分片大小: **客户端自选的传输粒度**, 不是服务端上限(上限未知, 见模块 TODO 第 4 条)。
///
/// 4 MiB 的取法: 单请求整文件路径在 5-60 MB 的音频上已经跑通, 分片粒度再大就失去
/// 「单次失败只重传一小段」的意义; 再小则请求数暴涨。
pub const DEFAULT_CHUNK_SIZE: u64 = 4 * 1024 * 1024;

/// 规划允许的最大分片: 超过它说明调用方传错了参数(而不是想「一片装下整个文件」)。
pub const MAX_CHUNK_SIZE: u64 = 64 * 1024 * 1024;

/// 规划允许的最大分片数: 上万片在移动网络下没有意义, 提前拒绝而不是传一半炸。
pub const MAX_PARTS: u64 = 10_000;

/// 单个分片失败后**额外**尝试的次数(总尝试 = 1 + 1)。
///
/// 与桌面下载加固(`cache.rs` 的 `DOWNLOAD_RETRIES`)同一口径: 只对 `retryable` 的失败多试一次,
/// 不无限重试 —— 直链/签名失效类错误重试只会多打一次上游并放大风控。
pub const DEFAULT_RETRIES: u32 = 1;

// ---------------------------------------------------------------------------
// ① 分片规划(纯函数, 不联网即可单测)
// ---------------------------------------------------------------------------

/// 一个分片在文件里的位置。`index` 从 0 开始(部署到协议序号由实现决定, 差一在这里收口)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PartRange {
    pub index: usize,
    pub offset: u64,
    pub len: u64,
}

impl PartRange {
    /// 该分片的结束字节(不含), 即 `offset + len`。
    pub fn end(&self) -> u64 {
        self.offset + self.len
    }
}

/// 一次上传的分片规划: 总长 / 粒度 / 片数。分片按需算出, 不预先分配 Vec。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChunkPlan {
    total_len: u64,
    chunk_size: u64,
    part_count: usize,
}

impl ChunkPlan {
    pub fn total_len(&self) -> u64 {
        self.total_len
    }

    pub fn chunk_size(&self) -> u64 {
        self.chunk_size
    }

    pub fn part_count(&self) -> usize {
        self.part_count
    }

    /// 第 `index` 片; 越界返回 `None`。
    pub fn part(&self, index: usize) -> Option<PartRange> {
        if index >= self.part_count {
            return None;
        }
        let offset = self.chunk_size * index as u64;
        let len = (self.total_len - offset).min(self.chunk_size);
        Some(PartRange { index, offset, len })
    }

    /// 所有分片(顺序迭代)。
    pub fn parts(&self) -> impl Iterator<Item = PartRange> + '_ {
        (0..self.part_count).filter_map(move |i| self.part(i))
    }

    /// 最后一片的长度: 整片整除时等于 `chunk_size`(此时没有「残缺尾片」)。
    pub fn last_part_len(&self) -> u64 {
        let rem = self.total_len % self.chunk_size;
        if rem == 0 {
            self.chunk_size
        } else {
            rem
        }
    }
}

/// 规划分片。纯函数, 只做参数校验 + 算术。
///
/// 失败语义(沿用 `ProviderError{kind, retryable, detail}`): 都是**调用方参数**问题,
/// 归 `Unsupported` 且不可重试 —— 换网络/重试都不会好, 只有换文件或改粒度才行。
pub fn plan_chunks(total_len: u64, chunk_size: u64) -> ProviderResult<ChunkPlan> {
    if total_len == 0 {
        return Err(ProviderError::unsupported("文件是空的, 没有可分片的字节"));
    }
    if chunk_size == 0 || chunk_size > MAX_CHUNK_SIZE {
        return Err(ProviderError::unsupported(format!(
            "分片大小 {chunk_size} 不在 (0, {MAX_CHUNK_SIZE}] 内"
        )));
    }
    let part_count = total_len.div_ceil(chunk_size);
    if part_count > MAX_PARTS {
        return Err(ProviderError::unsupported(format!(
            "分片数 {part_count} 超过上限 {MAX_PARTS}, 请加大分片粒度"
        )));
    }
    Ok(ChunkPlan {
        total_len,
        chunk_size,
        part_count: part_count as usize,
    })
}

/// 上传策略: 单请求整文件(唯一有协议证据的路径) 或 分片(接缝, 见模块 TODO)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UploadPlan {
    SingleShot,
    Chunked(ChunkPlan),
}

/// 选出上传策略: 文件超过 `single_shot_ceiling` 才分片。
///
/// `single_shot_ceiling == None` 表示**服务端单请求上限未实测**, 一律走单请求
/// (不猜阈值: 猜低了会把本来能传的文件拆进没验证过的分片路径)。
pub fn plan_cloud_upload(
    total_len: u64,
    single_shot_ceiling: Option<u64>,
    chunk_size: u64,
) -> ProviderResult<UploadPlan> {
    if total_len == 0 {
        return Err(ProviderError::unsupported("文件是空的"));
    }
    match single_shot_ceiling {
        Some(ceiling) if total_len > ceiling => {
            Ok(UploadPlan::Chunked(plan_chunks(total_len, chunk_size)?))
        }
        _ => Ok(UploadPlan::SingleShot),
    }
}

// ---------------------------------------------------------------------------
// ② 进度与可恢复点
// ---------------------------------------------------------------------------

/// 上传进度(字节口径)。UI 只需要 `fraction()`, 但也保留两端字节数便于日志/断言。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UploadProgress {
    pub uploaded: u64,
    pub total: u64,
}

impl UploadProgress {
    pub fn new(uploaded: u64, total: u64) -> Self {
        Self { uploaded, total }
    }

    /// 0.0..=1.0; `total == 0` 时返回 0.0(空文件在上游已被拒, 这里只是不 panic)。
    pub fn fraction(&self) -> f64 {
        if self.total == 0 {
            return 0.0;
        }
        (self.uploaded as f64 / self.total as f64).clamp(0.0, 1.0)
    }
}

/// 分片回执: `finish`(合并)要用它, 断点续传也要把它带过进程边界。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PartReceipt {
    pub index: usize,
    /// 服务端回执(offset 式可能是新 offset, S3 式是 ETag); 形状由实现决定, 这里只存不解释。
    pub marker: Option<String>,
}

/// 可恢复点: 已完成的分片回执 + 已上传字节数。
///
/// 失败时随 [`ChunkUploadError::checkpoint`] 一起交回; 下次把它当 `resume` 传进来即可跳过
/// 已完成的分片(**不重传**已完成部分)。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UploadCheckpoint {
    pub receipts: Vec<PartReceipt>,
    pub uploaded_bytes: u64,
}

impl UploadCheckpoint {
    pub const START: UploadCheckpoint = UploadCheckpoint {
        receipts: Vec::new(),
        uploaded_bytes: 0,
    };

    pub fn completed_parts(&self) -> usize {
        self.receipts.len()
    }
}

/// 分片上传失败: 错误本体 + 失败时刻的可恢复点。
#[derive(Debug, Clone)]
pub struct ChunkUploadError {
    pub error: ProviderError,
    pub checkpoint: UploadCheckpoint,
}

impl ChunkUploadError {
    fn new(error: ProviderError, checkpoint: UploadCheckpoint) -> Self {
        Self { error, checkpoint }
    }
}

impl std::fmt::Display for ChunkUploadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{} (已完成 {} 片)",
            self.error,
            self.checkpoint.completed_parts()
        )
    }
}

impl std::error::Error for ChunkUploadError {}

// ---------------------------------------------------------------------------
// ③ 引擎: 顺序传 + 每片重试恰一次 + 进度回调
// ---------------------------------------------------------------------------

/// 分片字节的来源(生产是本地文件, 测试是内存假实现)。
pub trait ChunkSource: Send {
    /// 读出 `part` 指定的字节; 长度必须等于 `part.len`(引擎会再校验一次)。
    fn read_part(&mut self, part: PartRange) -> ProviderResult<Vec<u8>>;
}

/// 分片上传的**协议侧**接缝: 端点、参数、合并请求都只能出现在它的实现里。
///
/// 为什么先做顺序而不是并发: 云盘仅有「offset 追加式」这半截线索(URL 里带着
/// `offset=0&complete=true`), 追加式必然要求分片**按序到达**; S3 式虽可并发, 但形状没抓到之前
/// 并发只是猜测。顺序版落地后, 加 `concurrency` 参数是纯优化。
pub trait ChunkUploader: Send {
    /// 开始一次上传(offset 式可能是空操作; S3 式要拿 UploadId)。
    fn begin(&mut self, plan: &ChunkPlan) -> BoxFuture<'_, ProviderResult<()>>;

    /// 传一片。
    fn put_part(
        &mut self,
        part: PartRange,
        bytes: Vec<u8>,
    ) -> BoxFuture<'_, ProviderResult<PartReceipt>>;

    /// 合并/收尾, 入参是**全部分片**的回执(续传时也包含上次已完成的部分)。
    fn finish(&mut self, receipts: &[PartReceipt]) -> BoxFuture<'_, ProviderResult<()>>;
}

/// 顺序上传全部分片(从 `resume` 的可恢复点开始)。
///
/// 语义:
/// - 每片失败时, 只有 `retryable` 的错误才**多试一次**(见 [`DEFAULT_RETRIES`]);
/// - 任何一片最终失败 ⇒ 返回 [`ChunkUploadError`], 里面带着「到这片为止」的可恢复点;
/// - 全部传完才调 `finish`(合并); 合并失败同样回带完整可恢复点 —— 重试合并不必重传字节;
/// - 每完成一片回调一次进度, 开始与结束各再回调一次。
pub async fn upload_chunked(
    plan: &ChunkPlan,
    source: &mut dyn ChunkSource,
    uploader: &mut dyn ChunkUploader,
    resume: UploadCheckpoint,
    on_progress: &mut (dyn FnMut(UploadProgress) + Send),
) -> Result<UploadCheckpoint, ChunkUploadError> {
    let mut checkpoint = resume;
    if checkpoint.completed_parts() > plan.part_count() {
        return Err(ChunkUploadError::new(
            ProviderError::internal(format!(
                "可恢复点里有 {} 片, 超过本次计划的 {} 片",
                checkpoint.completed_parts(),
                plan.part_count()
            )),
            checkpoint,
        ));
    }
    if let Err(e) = uploader.begin(plan).await {
        return Err(ChunkUploadError::new(e, checkpoint));
    }
    on_progress(UploadProgress::new(
        checkpoint.uploaded_bytes,
        plan.total_len(),
    ));

    while checkpoint.completed_parts() < plan.part_count() {
        let index = checkpoint.completed_parts();
        // 片数已在 plan_chunks 里校验过, 这里取不到只可能是内部算错
        let part = match plan.part(index) {
            Some(part) => part,
            None => {
                return Err(ChunkUploadError::new(
                    ProviderError::internal(format!("分片 {index} 越界")),
                    checkpoint,
                ))
            }
        };
        let bytes = match source.read_part(part) {
            Ok(bytes) => bytes,
            // 读本地文件失败: 不可重试(重试读同一个坏文件没意义), 但要带回可恢复点
            Err(e) => return Err(ChunkUploadError::new(e, checkpoint)),
        };
        if bytes.len() as u64 != part.len {
            return Err(ChunkUploadError::new(
                ProviderError::internal(format!(
                    "分片 {index} 字节数不符: 读到 {}, 应为 {}",
                    bytes.len(),
                    part.len
                )),
                checkpoint,
            ));
        }
        match put_part_with_retry(uploader, part, bytes).await {
            Ok(receipt) => {
                checkpoint.receipts.push(receipt);
                checkpoint.uploaded_bytes += part.len;
                on_progress(UploadProgress::new(
                    checkpoint.uploaded_bytes,
                    plan.total_len(),
                ));
            }
            Err(e) => return Err(ChunkUploadError::new(e, checkpoint)),
        }
    }

    if let Err(e) = uploader.finish(&checkpoint.receipts).await {
        return Err(ChunkUploadError::new(e, checkpoint));
    }
    Ok(checkpoint)
}

/// 传一片 + 失败重试恰一次(只重试 `retryable` 的失败)。
async fn put_part_with_retry(
    uploader: &mut dyn ChunkUploader,
    part: PartRange,
    bytes: Vec<u8>,
) -> ProviderResult<PartReceipt> {
    let attempts = 1 + DEFAULT_RETRIES;
    let mut attempt = 1;
    loop {
        match uploader.put_part(part, bytes.clone()).await {
            Ok(receipt) => return Ok(receipt),
            Err(err) => {
                if attempt < attempts && err.retryable {
                    eprintln!(
                        "[cloud-chunk] 分片 {} 第 {} 次失败, 重试一次: {err}",
                        part.index, attempt
                    );
                    attempt += 1;
                    continue;
                }
                return Err(err);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// ④ 本地文件分片源(生产用; 顺序 IO, 不额外起线程)
// ---------------------------------------------------------------------------

/// 从本地文件按偏移读分片。
///
/// 用同步 `std::fs` 而不是 `tokio::fs`: 每次只 seek + 读一片(默认 4 MiB, 本地盘几 ms),
/// spawn_blocking 的调度开销比读本身还大; 整条上传链路本来就是 IO 等待为主。
pub struct FileChunkSource {
    file: std::fs::File,
}

impl FileChunkSource {
    pub fn open(path: &std::path::Path) -> ProviderResult<Self> {
        let file = std::fs::File::open(path)
            .map_err(|e| ProviderError::unsupported(format!("读取文件失败: {e}")))?;
        Ok(Self { file })
    }
}

impl ChunkSource for FileChunkSource {
    fn read_part(&mut self, part: PartRange) -> ProviderResult<Vec<u8>> {
        use std::io::{Read, Seek, SeekFrom};
        self.file
            .seek(SeekFrom::Start(part.offset))
            .map_err(|e| ProviderError::unsupported(format!("定位分片失败: {e}")))?;
        let mut buf = vec![0u8; part.len as usize];
        self.file
            .read_exact(&mut buf)
            .map_err(|e| ProviderError::unsupported(format!("读取分片失败: {e}")))?;
        Ok(buf)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // -----------------------------------------------------------------------
    // 规划(纯函数)
    // -----------------------------------------------------------------------

    fn ranges(plan: &ChunkPlan) -> Vec<(u64, u64)> {
        plan.parts().map(|p| (p.offset, p.len)).collect()
    }

    #[test]
    fn plan_splits_with_remainder_last() {
        let plan = plan_chunks(10, 4).expect("10/4 应当可规划");
        assert_eq!(plan.total_len(), 10);
        assert_eq!(plan.chunk_size(), 4);
        assert_eq!(plan.part_count(), 3);
        assert_eq!(plan.last_part_len(), 2);
        assert_eq!(ranges(&plan), vec![(0, 4), (4, 4), (8, 2)]);
        assert_eq!(plan.part(2).map(|p| p.end()), Some(10));
        assert_eq!(plan.part(3), None, "越界分片必须返回 None");
    }

    #[test]
    fn plan_exact_division_has_no_partial_tail() {
        let plan = plan_chunks(8, 4).expect("8/4 应当可规划");
        assert_eq!(plan.part_count(), 2);
        assert_eq!(plan.last_part_len(), 4, "整除时最后一片是整片");
        assert_eq!(ranges(&plan), vec![(0, 4), (4, 4)]);
    }

    #[test]
    fn plan_single_part_when_file_smaller_than_chunk() {
        let plan = plan_chunks(3, DEFAULT_CHUNK_SIZE).expect("小文件也能规划");
        assert_eq!(plan.part_count(), 1);
        assert_eq!(plan.last_part_len(), 3);
        assert_eq!(ranges(&plan), vec![(0, 3)]);
    }

    #[test]
    fn plan_rejects_bad_input() {
        let empty = plan_chunks(0, 4).expect_err("空文件必须拒绝");
        assert_eq!(empty.kind, ncm_provider::ProviderErrorKind::Unsupported);
        assert!(!empty.retryable, "参数问题重试无用");

        assert!(plan_chunks(10, 0).is_err(), "分片大小为 0 必须拒绝");
        assert!(
            plan_chunks(10, MAX_CHUNK_SIZE + 1).is_err(),
            "分片超过规划上限必须拒绝"
        );

        // 分片数超限: 总长 = (MAX_PARTS + 1) 片 * 1 字节
        let too_many = plan_chunks(MAX_PARTS + 1, 1).expect_err("片数超限必须拒绝");
        assert!(too_many.detail.contains("分片数"), "{}", too_many.detail);
    }

    #[test]
    fn plan_cloud_upload_without_ceiling_is_always_single_shot() {
        // 服务端上限未实测 ⇒ 不猜阈值, 一律单请求(生产常量就是 None)
        for size in [1u64, 5 * 1024 * 1024, 200 * 1024 * 1024] {
            assert_eq!(
                plan_cloud_upload(size, None, DEFAULT_CHUNK_SIZE).expect("非空文件应当可规划"),
                UploadPlan::SingleShot
            );
        }
        assert!(plan_cloud_upload(0, None, DEFAULT_CHUNK_SIZE).is_err());
    }

    #[test]
    fn plan_cloud_upload_switches_to_chunked_past_ceiling() {
        let ceiling = Some(10u64);
        assert_eq!(
            plan_cloud_upload(10, ceiling, 4).expect("刚好等于上限仍走单请求"),
            UploadPlan::SingleShot
        );
        match plan_cloud_upload(11, ceiling, 4).expect("超过上限应当分片") {
            UploadPlan::Chunked(plan) => {
                assert_eq!(plan.part_count(), 3);
                assert_eq!(ranges(&plan), vec![(0, 4), (4, 4), (8, 3)]);
            }
            other => panic!("超过上限应当分片, 实际 {other:?}"),
        }
    }

    #[test]
    fn progress_fraction_is_bounded() {
        assert_eq!(UploadProgress::new(0, 0).fraction(), 0.0);
        assert_eq!(UploadProgress::new(0, 10).fraction(), 0.0);
        assert!((UploadProgress::new(5, 10).fraction() - 0.5).abs() < f64::EPSILON);
        assert_eq!(UploadProgress::new(10, 10).fraction(), 1.0);
        assert_eq!(
            UploadProgress::new(99, 10).fraction(),
            1.0,
            "不允许超过 1.0"
        );
    }

    // -----------------------------------------------------------------------
    // 引擎(假 source + 假 uploader, 不联网)
    // -----------------------------------------------------------------------

    /// 内存分片源; `short_at` 让它少给几个字节, 用来验证引擎的长度校验。
    struct MemSource {
        data: Vec<u8>,
        short_at: Option<usize>,
    }

    impl MemSource {
        fn new(data: Vec<u8>) -> Self {
            Self {
                data,
                short_at: None,
            }
        }
    }

    impl ChunkSource for MemSource {
        fn read_part(&mut self, part: PartRange) -> ProviderResult<Vec<u8>> {
            let start = part.offset as usize;
            let end = part.end() as usize;
            let mut bytes = self.data[start..end].to_vec();
            if self.short_at == Some(part.index) {
                bytes.pop();
            }
            Ok(bytes)
        }
    }

    /// 假 uploader: 可安排「某片第一次失败」「某片每次都失败」「合并失败」。
    #[derive(Default)]
    struct FakeUploader {
        began: usize,
        attempts: Vec<usize>,
        uploaded_lens: Vec<u64>,
        finished: Option<Vec<PartReceipt>>,
        fail_first: Option<usize>,
        fail_always: Option<(usize, ProviderError)>,
        fail_finish: Option<ProviderError>,
    }

    impl FakeUploader {
        fn attempts_of(&self, index: usize) -> usize {
            self.attempts.iter().filter(|i| **i == index).count()
        }
    }

    impl ChunkUploader for FakeUploader {
        fn begin(&mut self, plan: &ChunkPlan) -> BoxFuture<'_, ProviderResult<()>> {
            self.began += 1;
            let parts = plan.part_count();
            Box::pin(async move {
                assert!(parts > 0);
                Ok(())
            })
        }

        fn put_part(
            &mut self,
            part: PartRange,
            bytes: Vec<u8>,
        ) -> BoxFuture<'_, ProviderResult<PartReceipt>> {
            self.attempts.push(part.index);
            self.uploaded_lens.push(bytes.len() as u64);
            let seen = self.attempts_of(part.index);
            let fail_first = self.fail_first == Some(part.index);
            let always = self
                .fail_always
                .as_ref()
                .filter(|(index, _)| *index == part.index)
                .map(|(_, err)| err.clone());
            let index = part.index;
            Box::pin(async move {
                if let Some(err) = always {
                    return Err(err);
                }
                if fail_first && seen == 1 {
                    return Err(ProviderError::network("连接被重置(假)"));
                }
                Ok(PartReceipt {
                    index,
                    marker: Some(format!("etag-{index}")),
                })
            })
        }

        fn finish(&mut self, receipts: &[PartReceipt]) -> BoxFuture<'_, ProviderResult<()>> {
            self.finished = Some(receipts.to_vec());
            let fail = self.fail_finish.clone();
            Box::pin(async move {
                match fail {
                    Some(err) => Err(err),
                    None => Ok(()),
                }
            })
        }
    }

    #[tokio::test]
    async fn engine_uploads_all_parts_then_finishes() {
        let plan = plan_chunks(10, 4).expect("可规划");
        let mut source = MemSource::new((0u8..10).collect());
        let mut uploader = FakeUploader::default();
        let mut progress: Vec<UploadProgress> = Vec::new();
        let mut cb = |p: UploadProgress| progress.push(p);

        let done = upload_chunked(
            &plan,
            &mut source,
            &mut uploader,
            UploadCheckpoint::START,
            &mut cb,
        )
        .await
        .expect("顺序上传应当成功");

        assert_eq!(done.completed_parts(), 3);
        assert_eq!(done.uploaded_bytes, 10);
        assert_eq!(uploader.began, 1, "begin 只调一次");
        assert_eq!(uploader.attempts, vec![0, 1, 2], "顺序上传, 每片一次成功");
        assert_eq!(uploader.uploaded_lens, vec![4, 4, 2], "最后一片是尾片");
        let finished = uploader.finished.as_ref().expect("必须调 finish");
        assert_eq!(finished.len(), 3);
        assert_eq!(finished[2].marker.as_deref(), Some("etag-2"));

        // 进度: 开始 0 + 每片一次 = 4 次, 单调递增到 1.0
        assert_eq!(progress.len(), 4);
        assert_eq!(progress[0], UploadProgress::new(0, 10));
        assert_eq!(progress[3], UploadProgress::new(10, 10));
        assert_eq!(progress[3].fraction(), 1.0);
        assert!(progress.windows(2).all(|w| w[0].uploaded <= w[1].uploaded));
    }

    #[tokio::test]
    async fn engine_retries_retryable_failure_exactly_once() {
        let plan = plan_chunks(10, 4).expect("可规划");
        let mut source = MemSource::new((0u8..10).collect());
        let mut uploader = FakeUploader {
            fail_first: Some(1),
            ..Default::default()
        };
        let mut cb = |_p: UploadProgress| {};

        let done = upload_chunked(
            &plan,
            &mut source,
            &mut uploader,
            UploadCheckpoint::START,
            &mut cb,
        )
        .await
        .expect("可重试失败重试一次后应当成功");

        assert_eq!(done.completed_parts(), 3);
        assert_eq!(uploader.attempts_of(1), 2, "分片 1 恰好多试一次");
        assert_eq!(uploader.attempts_of(0), 1);
        assert_eq!(uploader.attempts_of(2), 1);
    }

    #[tokio::test]
    async fn engine_does_not_retry_non_retryable_failure() {
        let plan = plan_chunks(10, 4).expect("可规划");
        let mut source = MemSource::new((0u8..10).collect());
        let mut uploader = FakeUploader {
            fail_always: Some((1, ProviderError::forbidden("被服务端拒绝(假)"))),
            ..Default::default()
        };
        let mut cb = |_p: UploadProgress| {};

        let err = upload_chunked(
            &plan,
            &mut source,
            &mut uploader,
            UploadCheckpoint::START,
            &mut cb,
        )
        .await
        .expect_err("不可重试失败必须直接返回");

        assert_eq!(err.error.kind, ncm_provider::ProviderErrorKind::Forbidden);
        assert!(!err.error.retryable);
        assert_eq!(uploader.attempts_of(1), 1, "不可重试不许重试");
        // 可恢复点 = 已成功的第 0 片
        assert_eq!(err.checkpoint.completed_parts(), 1);
        assert_eq!(err.checkpoint.uploaded_bytes, 4);
    }

    #[tokio::test]
    async fn engine_reports_checkpoint_after_retry_exhausted() {
        let plan = plan_chunks(10, 4).expect("可规划");
        let mut source = MemSource::new((0u8..10).collect());
        let mut uploader = FakeUploader {
            fail_always: Some((1, ProviderError::network("一直连不上(假)"))),
            ..Default::default()
        };
        let mut cb = |_p: UploadProgress| {};

        let err = upload_chunked(
            &plan,
            &mut source,
            &mut uploader,
            UploadCheckpoint::START,
            &mut cb,
        )
        .await
        .expect_err("重试耗尽必须失败");

        assert!(err.error.retryable, "网络类失败保持可重试语义");
        assert_eq!(uploader.attempts_of(1), 2, "可重试最多多试一次(共 2 次)");
        assert_eq!(err.checkpoint.completed_parts(), 1);
        assert_eq!(uploader.finished, None, "失败时不调合并");
    }

    #[tokio::test]
    async fn engine_resumes_without_reuploading_finished_parts() {
        let plan = plan_chunks(10, 4).expect("可规划");
        let mut source = MemSource::new((0u8..10).collect());
        let mut uploader = FakeUploader::default();
        let mut cb = |_p: UploadProgress| {};
        let resume = UploadCheckpoint {
            receipts: vec![
                PartReceipt {
                    index: 0,
                    marker: Some("etag-0".into()),
                },
                PartReceipt {
                    index: 1,
                    marker: Some("etag-1".into()),
                },
            ],
            uploaded_bytes: 8,
        };

        let done = upload_chunked(&plan, &mut source, &mut uploader, resume, &mut cb)
            .await
            .expect("从可恢复点续传应当成功");

        assert_eq!(uploader.attempts, vec![2], "只补传缺失的第 2 片");
        assert_eq!(done.completed_parts(), 3);
        assert_eq!(done.uploaded_bytes, 10);
        let finished = uploader.finished.as_ref().expect("必须调 finish");
        assert_eq!(finished.len(), 3, "合并要拿到全部分片回执");
        assert_eq!(finished[0].marker.as_deref(), Some("etag-0"));
    }

    #[tokio::test]
    async fn engine_rejects_checkpoint_longer_than_plan() {
        let plan = plan_chunks(4, 4).expect("可规划");
        let mut source = MemSource::new(vec![1, 2, 3, 4]);
        let mut uploader = FakeUploader::default();
        let mut cb = |_p: UploadProgress| {};
        let bogus = UploadCheckpoint {
            receipts: vec![
                PartReceipt {
                    index: 0,
                    marker: None,
                },
                PartReceipt {
                    index: 1,
                    marker: None,
                },
            ],
            uploaded_bytes: 8,
        };

        let err = upload_chunked(&plan, &mut source, &mut uploader, bogus, &mut cb)
            .await
            .expect_err("可恢复点比计划还长必须拒绝");
        assert_eq!(err.error.kind, ncm_provider::ProviderErrorKind::Internal);
        assert_eq!(uploader.began, 0, "参数错就别开始上传");
    }

    #[tokio::test]
    async fn engine_fails_on_short_read() {
        let plan = plan_chunks(10, 4).expect("可规划");
        let mut source = MemSource {
            data: (0u8..10).collect(),
            short_at: Some(1),
        };
        let mut uploader = FakeUploader::default();
        let mut cb = |_p: UploadProgress| {};

        let err = upload_chunked(
            &plan,
            &mut source,
            &mut uploader,
            UploadCheckpoint::START,
            &mut cb,
        )
        .await
        .expect_err("分片字节数不符必须失败");
        assert_eq!(err.error.kind, ncm_provider::ProviderErrorKind::Internal);
        assert!(
            err.error.detail.contains("字节数不符"),
            "{}",
            err.error.detail
        );
        assert_eq!(err.checkpoint.completed_parts(), 1);
    }

    #[tokio::test]
    async fn engine_returns_full_checkpoint_when_finish_fails() {
        let plan = plan_chunks(10, 4).expect("可规划");
        let mut source = MemSource::new((0u8..10).collect());
        let mut uploader = FakeUploader {
            fail_finish: Some(ProviderError::network("合并请求超时(假)")),
            ..Default::default()
        };
        let mut cb = |_p: UploadProgress| {};

        let err = upload_chunked(
            &plan,
            &mut source,
            &mut uploader,
            UploadCheckpoint::START,
            &mut cb,
        )
        .await
        .expect_err("合并失败必须失败");

        assert_eq!(err.error.kind, ncm_provider::ProviderErrorKind::Network);
        assert_eq!(
            err.checkpoint.completed_parts(),
            3,
            "合并失败时字节都传完了, 重试只该重发合并"
        );
        assert_eq!(err.checkpoint.uploaded_bytes, 10);
    }

    #[test]
    fn file_source_reads_by_offset() {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "ncm-cloud-chunk-{}-{:?}.bin",
            std::process::id(),
            std::thread::current().id()
        ));
        let data: Vec<u8> = (0u8..=255).collect();
        std::fs::write(&path, &data).expect("写临时文件");
        let mut source = FileChunkSource::open(&path).expect("打开临时文件");
        let plan = plan_chunks(data.len() as u64, 10).expect("可规划");
        let part = plan.part(3).expect("第 4 片存在");
        let bytes = source.read_part(part).expect("读分片");
        assert_eq!(bytes.len() as u64, part.len);
        assert_eq!(bytes[0], data[part.offset as usize]);
        let tail = plan.part(plan.part_count() - 1).expect("尾片存在");
        assert_eq!(
            source.read_part(tail).expect("读尾片").len() as u64,
            plan.last_part_len()
        );
        let _ = std::fs::remove_file(&path);
    }
}
