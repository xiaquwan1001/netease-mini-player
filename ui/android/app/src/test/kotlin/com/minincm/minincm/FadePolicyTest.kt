package com.minincm.minincm

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 淡入淡出曲线的判据单测(JVM, 不需要设备/声卡)。
 *
 * 锁两件事(2026-11-22 模拟器实测之后的口径):
 * 1) **曲线是感知曲线而不是线性振幅**: 前 1/4 时长就要到目标的 ~58%, 线性只有 25%
 *    (实测旧实现的 500ms 淡入"真正出声时已经 55%", 用户听成"延迟半秒暂停");
 * 2) **起声门控**: 缓冲期不许推进 ramp, 超时必须有兜底。
 *
 * 改回 `ValueAnimator.ofFloat(0, target)` 那条线性 + 立即起 ramp 的老路, 这里会立刻红。
 */
class FadePolicyTest {
    private val duration = 500

    @Test
    fun fadeInIsPerceptualNotLinear() {
        assertEquals(0f, FadePolicy.fadeInFraction(0, duration), 1e-6f)
        assertEquals(1f, FadePolicy.fadeInFraction(duration.toLong(), duration), 1e-6f)
        // 感知曲线: 1/4 时长到 57.8%(线性只有 25%), 1/2 时长到 87.5%(线性 50%)
        assertEquals(0.578f, FadePolicy.fadeInFraction(125, duration), 5e-3f)
        assertEquals(0.875f, FadePolicy.fadeInFraction(250, duration), 5e-3f)
        // 旧实现(线性振幅)在这两个点会给出 0.25 / 0.5 —— 显式钉住"不是线性"
        assertTrue("1/4 时长必须明显高于线性的 25%", FadePolicy.fadeInFraction(125, duration) > 0.5f)
        // 单调不减
        var prev = -1f
        for (ms in 0..duration step 25) {
            val v = FadePolicy.fadeInFraction(ms.toLong(), duration)
            assertTrue("t=$ms 处不单调: $v < $prev", v >= prev)
            prev = v
        }
    }

    @Test
    fun fadeOutMirrorsFadeIn() {
        assertEquals(1f, FadePolicy.fadeOutFraction(0, duration), 1e-6f)
        assertEquals(0f, FadePolicy.fadeOutFraction(duration.toLong(), duration), 1e-6f)
        // 镜像关系: out(t) == 1 - in(t), 淡出与淡入同一条曲线(手感对称)
        for (ms in 0..duration step 50) {
            assertEquals(
                1f - FadePolicy.fadeInFraction(ms.toLong(), duration),
                FadePolicy.fadeOutFraction(ms.toLong(), duration),
                1e-6f,
            )
        }
        // 淡出要"越到后面越慢": 半程已掉到目标的 12.5%, 不是线性的 50%
        assertTrue(FadePolicy.fadeOutFraction(250, duration) < 0.2f)
    }

    @Test
    fun fractionsAreClampedOutsideTheWindow() {
        // 负时间按 0 处理, 超时按终点处理(动画帧偶尔会晚到/早到)
        assertEquals(0f, FadePolicy.fadeInFraction(-50, duration), 1e-6f)
        assertEquals(1f, FadePolicy.fadeInFraction(10_000, duration), 1e-6f)
        assertEquals(1f, FadePolicy.fadeOutFraction(-50, duration), 1e-6f)
        assertEquals(0f, FadePolicy.fadeOutFraction(10_000, duration), 1e-6f)
    }

    @Test
    fun zeroFadeMeansDisabled() {
        // fadeMs = 0 语义不变: 关闭(默认值不动)
        assertFalse(FadePolicy.isEnabled(0))
        assertFalse(FadePolicy.isEnabled(-1))
        assertTrue(FadePolicy.isEnabled(1))
        assertTrue(FadePolicy.isEnabled(500))
        assertEquals(0L, FadePolicy.rampDurationMs(0))
        assertEquals(500L, FadePolicy.rampDurationMs(500))
    }

    @Test
    fun rampWaitsForRealAudioStart() {
        assertFalse(FadePolicy.shouldStartRamp(audioStarted = false))
        assertTrue(FadePolicy.shouldStartRamp(audioStarted = true))
        // 等不到起声时必须有兜底, 否则播放器会一直停在 0 音量
        assertFalse(FadePolicy.shouldAbandonArmed(FadePolicy.ARM_TIMEOUT_MS - 1))
        assertTrue(FadePolicy.shouldAbandonArmed(FadePolicy.ARM_TIMEOUT_MS))
        assertTrue(FadePolicy.shouldAbandonArmed(FadePolicy.ARM_TIMEOUT_MS * 2))
    }

    @Test
    fun fadeOutReportsNotPlayingImmediately() {
        // 用户反馈 F6: 点暂停后按钮在淡出的一秒内又跳回"播放中", 结束后再跳回暂停。
        // 判据: 淡出进行中对外必须报**未播放**(声音本来也要在 fadeMs 内归零),
        // 否则 Dart 侧 500ms 轮询会拿"还在播"把播放按钮顶回暂停图标。
        assertFalse(FadePolicy.reportsPlaying(delegateIsPlaying = true, fadeOutPending = true))
        // 没有淡出时完全按播放器真实状态(不引入新的状态源)
        assertTrue(FadePolicy.reportsPlaying(delegateIsPlaying = true, fadeOutPending = false))
        assertFalse(FadePolicy.reportsPlaying(delegateIsPlaying = false, fadeOutPending = false))
        assertFalse(FadePolicy.reportsPlaying(delegateIsPlaying = false, fadeOutPending = true))
    }
}
