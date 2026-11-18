package com.minincm.minincm

/**
 * 音频缓冲水位策略(T2, 2026-11-18): **纯数值 + 不变量**, 不碰 Android 框架, 便于 JVM 单测
 * (见 src/test/.../**/AudioBufferPolicyTest.kt); 真正生效由 [PlaybackService.buildExoPlayer]
 * 交给 media3 的 `DefaultLoadControl`。
 *
 * 背景(「香港用户卡顿」归因矩阵 #4): ExoPlayer 之前**没有自定义 LoadControl** ⇒ media3
 * 默认值是 minBuffer=50s / bufferForPlayback=2.5s / **bufferForPlaybackAfterRebuffer=5s**。
 * 后两项的语义是"起播/重缓冲前必须先攒够多少缓冲":
 * 一次 200-400ms 的网络抖动把缓冲吃空后, 播放器要等**攒回 5 秒**才恢复出声 ——
 * 用户听到的是「卡了 5 秒」, 而不是抖动本身的 0.3 秒。跨境链路的 TTFB 本来就有
 * 0.1-0.4s 的方差(见调研 §3.3), 5 秒的恢复线把方差放大了十几倍。
 *
 * 取值与理由:
 * - [BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS] = 2s: 抖动后 **2 秒**即可恢复出声。2s 足够
 *   盖住一次 TCP 重传/RTT 尖峰(2×0.4s TTFB), 又远小于 5s 的"用户会骂卡"阈值。
 * - [BUFFER_FOR_PLAYBACK_MS] = 1s: 起播更快(切歌几乎立刻出声)。media3 的硬下限是 1000ms。
 * - [MIN_BUFFER_MS] = 15s: 稳态维持的**抗抖动水位**。按 128kbps(16 KB/s)算约 240 KB,
 *   只占内存/SimpleCache 的零头; 15s 能扛住一次"半分钟都不来字节"之前的抖动。
 * - [MAX_BUFFER_MS] = 50s: 与 media3 默认一致, 不额外放大内存/磁盘占用。
 *
 * 副作用(明确写下, 便于以后回滚判断):
 * - 起播门槛从 2.5s 降到 1s ⇒ 极慢网(吞吐 < 需求的 1/5)上可能"刚出声就再缓冲",
 *   即 rebuffer 次数变多但每次都短; 对音乐(码率低)这比"等 5 秒"体感好得多。
 * - 15s 水位 ⇒ 播放中更频繁地做小幅网络请求(每次分段拉取更短), 对 CDN 的并发/请求数
 *   请求量略有上升; 我们本来就是单条连接顺序拉流, 没有并发探针, 不放大风控面。
 * - 不覆盖"边听边存"(CacheDataSource)的语义: 缓存命中/回源开关完全没动。
 */
internal object AudioBufferPolicy {
    /** 稳态要维持的缓冲下限(抗抖动水位) */
    const val MIN_BUFFER_MS = 15_000

    /** 缓冲上限: 与 media3 默认一致, 不额外占内存 */
    const val MAX_BUFFER_MS = 50_000

    /** 起播前必须攒够的缓冲(media3 硬下限 1000ms) */
    const val BUFFER_FOR_PLAYBACK_MS = 1_000

    /** 重缓冲后恢复出声前必须攒够的缓冲 —— 这条是"卡顿时长"的直接决定因素 */
    const val BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = 2_000

    /**
     * media3 `DefaultLoadControl.Builder.setBufferDurationsMs` 的合法性条件, 抽成纯函数
     * 让单测能在 JVM 上锁住(真实构建器要 Android 框架, 单测里跑不了)。
     */
    fun invariantsHold(
        minBufferMs: Int = MIN_BUFFER_MS,
        maxBufferMs: Int = MAX_BUFFER_MS,
        bufferForPlaybackMs: Int = BUFFER_FOR_PLAYBACK_MS,
        bufferForPlaybackAfterRebufferMs: Int = BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS,
    ): Boolean =
        minBufferMs >= 0 &&
            maxBufferMs >= minBufferMs &&
            bufferForPlaybackMs in 1_000..minBufferMs &&
            bufferForPlaybackAfterRebufferMs in 1_000..minBufferMs
}
