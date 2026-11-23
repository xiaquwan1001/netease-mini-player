package com.minincm.minincm

/**
 * 淡入/淡出的曲线、开关与起声门控: **纯函数 + 不碰 Android 框架**,
 * 便于 JVM 单测(见 src/test/.../FadePolicyTest.kt)。真正落地在 [PlaybackService] 的
 * fadeIn/fadeOutThen 与 [SkipAwarePlayer] 的 pause/stop 拦截。
 *
 * 为什么不是"线性振幅 + play 后立即起 ramp"(2026-11-22 模拟器 a34 实测, fadeMs=500):
 * - `ValueAnimator` 默认插值器是 accelerate-decelerate(慢起慢收), 不是线性;
 * - `fadeIn()` 在 `c.play()` 的同一轮就启动, 而首曲要 ~300ms 缓冲才出声:
 *   实测 243–404ms 后才 `onIsPlayingChanged(true)`, 那一刻振幅已经爬到目标的 55%;
 * - 剩下 45% 在 ~220ms 内冲完 ⇒ 听感是「先静音半秒, 然后一下响起来」, 即用户说的
 *   「更像延迟半秒暂停」。
 *
 * 曲线取等响感知曲线 `1-(1-t)^3`: t=0.25 时已是目标的 57.8%(-4.8dB), 线性只有
 * 25%(-12dB)。同样的 fadeMs 下人耳听到的是平滑升起, 而不是"半天没声 → 突然响"。
 */
internal object FadePolicy {
    /** `fadeMs <= 0` = 关闭淡入淡出(既有口径, 默认值 0 不变) */
    fun isEnabled(fadeMs: Int): Boolean = fadeMs > 0

    /**
     * `play()` 这一下该不该淡入(2026-11-23 用户口径)。
     *
     * - 换曲/首次起播([trackStart] = true) ⇒ **不淡入**: 新曲目开头本来就从静默开始,
     *   再叠用户的 fadeMs 会把歌曲前 1s 盖成近乎静音(用户原话: "直接错过 1s 播放");
     * - 从暂停恢复 ⇒ 淡入(这才是"切换不突兀"真正需要斜坡的地方);
     * - fadeMs = 0 ⇒ 关闭淡入淡出, 两个场景都不淡入(既有语义不变)。
     */
    fun shouldFadeOnResume(trackStart: Boolean, fadeMs: Int): Boolean =
        !trackStart && isEnabled(fadeMs)

    /** 动画时长(fadeMs 已由 configure 钳到 0..5000); <=0 时返回 0, 调用方按关闭处理 */
    fun rampDurationMs(fadeMs: Int): Long = fadeMs.coerceAtLeast(0).toLong()

    /**
     * 淡入: 第 [elapsedMs] 毫秒时的**振幅比例**(0..1), 感知曲线 `1-(1-t)^3`。
     *
     * 传振幅比例而不是 dB: 落地处只有 `player.volume`(线性振幅), 在这里把曲线算完,
     * 服务侧只做一次乘法, 便于单测盯住曲线形状("改回线性就红")。
     */
    fun fadeInFraction(elapsedMs: Long, durationMs: Int): Float {
        val t = progress(elapsedMs, durationMs)
        val remain = 1f - t
        return 1f - remain * remain * remain
    }

    /** 淡出: 淡入的时间镜像 `(1-t)^3`(同一套曲线的逆), 保证暂停/切歌的收尾与淡入同手感 */
    fun fadeOutFraction(elapsedMs: Long, durationMs: Int): Float {
        val remain = 1f - progress(elapsedMs, durationMs)
        return remain * remain * remain
    }

    /**
     * 起声门控: ramp 只在真正出声后推进(缓冲期不空转)。
     *
     * [audioStarted] = `Player.Listener.onIsPlayingChanged(true)` 已经发生。
     * 为什么不用 `playWhenReady`/`STATE_READY`: 实测首曲从 play 到真正出声 243–404ms,
     * 这段静默期里推 ramp 等于把淡入的慢起段白白烧掉(见类 KDoc)。
     */
    fun shouldStartRamp(audioStarted: Boolean): Boolean = audioStarted

    /** 等起声的上限: 超过就放弃淡入, 直接把音量落到目标(绝不把播放器留在 0 音量) */
    const val ARM_TIMEOUT_MS = 5_000L

    /** 是否该放弃"已挂起、等起声"的淡入(超时保护, 见 [ARM_TIMEOUT_MS]) */
    fun shouldAbandonArmed(elapsedSinceArmedMs: Long): Boolean =
        elapsedSinceArmedMs >= ARM_TIMEOUT_MS

    /**
     * 对外报告"在播"还是"已暂停": 淡出进行中必须报**未播放**(用户反馈 F6)。
     *
     * 为什么: 暂停/停止是先淡出 [fadeMs] 再真正执行, 这段时间里 ExoPlayer 的
     * `isPlaying` 仍为 true —— Dart 侧每 500ms 轮询一次状态, 拿到的"还在播"会把
     * 播放按钮又翻回暂停图标, 手听到的就是"按下暂停 → 一秒内又变回播放中 → 再变回来"。
     * 用户已经按了暂停, 从意图上就该立即报未播放(声音本来也要在 [fadeMs] 内归零)。
     */
    fun reportsPlaying(delegateIsPlaying: Boolean, fadeOutPending: Boolean): Boolean =
        delegateIsPlaying && !fadeOutPending

    /** 时间进度 0..1(duration<=0 视为"瞬时结束", 与 fadeMs=0 的关闭语义一致) */
    private fun progress(elapsedMs: Long, durationMs: Int): Float {
        if (durationMs <= 0) return 1f
        return (elapsedMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)
    }
}
