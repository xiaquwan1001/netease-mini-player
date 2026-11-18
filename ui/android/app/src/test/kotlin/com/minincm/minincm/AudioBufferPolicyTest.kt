package com.minincm.minincm

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T2 音频缓冲水位单测(JVM, 不需要设备)。
 *
 * 这里锁的是**策略数值与合法性**, 不是真实播放行为:
 * "抖动后多久恢复出声"只能在真机上用 logcat 的 ExoPlayer `BUFFERING` 事件核对
 * (报告里已注明「需真机验证」)。真正危险的回退是"有人把 after-rebuffer 改回 5000ms"
 * 或"改成 media3 不接受/需要更多缓冲的值", 这两类都在这里拦住。
 */
class AudioBufferPolicyTest {
    @Test
    fun rebufferRecoveryThresholdIsTwoSecondsNotMedia3DefaultFive() {
        // 5s(media3 默认)是"一次抖动 = 5 秒静音"的直接原因, 不允许回退
        assertEquals(2_000, AudioBufferPolicy.BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS)
        // 起播门槛同理(默认 2.5s → 1s)
        assertEquals(1_000, AudioBufferPolicy.BUFFER_FOR_PLAYBACK_MS)
        // 稳态水位 15s, 上限仍是 50s(不额外占内存)
        assertEquals(15_000, AudioBufferPolicy.MIN_BUFFER_MS)
        assertEquals(50_000, AudioBufferPolicy.MAX_BUFFER_MS)
    }

    @Test
    fun productionValuesSatisfyMedia3BuilderConstraints() {
        assertTrue(AudioBufferPolicy.invariantsHold())
    }

    @Test
    fun validatorRejectsValuesMedia3WouldRejectOrThatRegress() {
        // max < min
        assertFalse(AudioBufferPolicy.invariantsHold(minBufferMs = 15_000, maxBufferMs = 10_000))
        // 起播门槛大于稳态水位
        assertFalse(
            AudioBufferPolicy.invariantsHold(
                minBufferMs = 15_000,
                bufferForPlaybackMs = 20_000,
            ),
        )
        // 低于 media3 的 1000ms 硬下限
        assertFalse(
            AudioBufferPolicy.invariantsHold(
                bufferForPlaybackAfterRebufferMs = 500,
            ),
        )
        // 重缓冲门槛大于稳态水位
        assertFalse(
            AudioBufferPolicy.invariantsHold(
                bufferForPlaybackAfterRebufferMs = 30_000,
            ),
        )
    }
}
