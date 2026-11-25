package com.minincm.minincm

import android.media.AudioManager
import com.minincm.minincm.AudioFocusPolicy.Action
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「被其他媒体抢占时怎么办」的三档策略单测(JVM, 不需要设备)。
 *
 * 锁住的是**策略 → 行为**的映射:
 * - 跟随系统: 只有 Media3 管焦点(默认档, 升级用户不该感到变化);
 * - 总是在后台播放: 谁都不申请、谁都不理(代价是可能叠音, 用户自己选的);
 * - 总是停止播放: 服务自己申请焦点, 任何失去都暂停且**不自动恢复**。
 */
class AudioFocusPolicyTest {
    @Test
    fun unknownOrMissingIdFallsBackToFollowSystem() {
        assertEquals(AudioFocusMode.FOLLOW_SYSTEM, AudioFocusMode.fromId(null))
        assertEquals(AudioFocusMode.FOLLOW_SYSTEM, AudioFocusMode.fromId(""))
        assertEquals(AudioFocusMode.FOLLOW_SYSTEM, AudioFocusMode.fromId("whatever"))
        assertEquals(AudioFocusMode.ALWAYS_PLAY, AudioFocusMode.fromId("alwaysPlay"))
        assertEquals(AudioFocusMode.ALWAYS_STOP, AudioFocusMode.fromId("alwaysStop"))
        assertEquals(AudioFocusMode.FOLLOW_SYSTEM, AudioFocusMode.fromId("followSystem"))
    }

    @Test
    fun onlyFollowSystemDelegatesToExoPlayer() {
        assertTrue(AudioFocusPolicy.useExoPlayerFocus(AudioFocusMode.FOLLOW_SYSTEM))
        assertFalse(AudioFocusPolicy.useExoPlayerFocus(AudioFocusMode.ALWAYS_PLAY))
        // 总是停止: media3 会在 GAIN 时自动续播, 与"总是停止"语义相反 ⇒ 必须自己管
        assertFalse(AudioFocusPolicy.useExoPlayerFocus(AudioFocusMode.ALWAYS_STOP))
    }

    @Test
    fun onlyAlwaysStopManagesFocusInService() {
        assertFalse(AudioFocusPolicy.manageFocusInService(AudioFocusMode.FOLLOW_SYSTEM))
        assertFalse(AudioFocusPolicy.manageFocusInService(AudioFocusMode.ALWAYS_PLAY))
        assertTrue(AudioFocusPolicy.manageFocusInService(AudioFocusMode.ALWAYS_STOP))
    }

    @Test
    fun alwaysStopPausesOnEveryKindOfLoss() {
        listOf(
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
        ).forEach { change ->
            assertEquals(
                "change=$change 必须暂停",
                Action.PAUSE,
                AudioFocusPolicy.actionFor(AudioFocusMode.ALWAYS_STOP, change),
            )
        }
    }

    @Test
    fun alwaysStopNeverAutoResumes() {
        // 焦点回来(GAIN / GAIN_TRANSIENT / DUCK) 一律不动作: 等用户自己按播放
        listOf(
            AudioManager.AUDIOFOCUS_GAIN,
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
        ).forEach { change ->
            assertEquals(
                "change=$change 不许自动续播",
                Action.NONE,
                AudioFocusPolicy.actionFor(AudioFocusMode.ALWAYS_STOP, change),
            )
        }
    }

    @Test
    fun otherModesNeverTouchFocusThemselves() {
        val changes = listOf(
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
            AudioManager.AUDIOFOCUS_GAIN,
        )
        for (mode in listOf(AudioFocusMode.FOLLOW_SYSTEM, AudioFocusMode.ALWAYS_PLAY)) {
            for (change in changes) {
                assertEquals(
                    "mode=$mode change=$change",
                    Action.NONE,
                    AudioFocusPolicy.actionFor(mode, change),
                )
            }
        }
    }

    @Test
    fun mvAlignment() {
        // 跟随系统: MV 照旧申请焦点、焦点回来照旧续播
        assertTrue(AudioFocusPolicy.mvRequestsFocus(AudioFocusMode.FOLLOW_SYSTEM))
        assertTrue(AudioFocusPolicy.mvResumesOnGain(AudioFocusMode.FOLLOW_SYSTEM))
        // 总是在后台播放: MV 也不抢焦点, 更不自动续播
        assertFalse(AudioFocusPolicy.mvRequestsFocus(AudioFocusMode.ALWAYS_PLAY))
        assertFalse(AudioFocusPolicy.mvResumesOnGain(AudioFocusMode.ALWAYS_PLAY))
        // 总是停止: MV 仍申请焦点(要能被抢占), 但不自动续播
        assertTrue(AudioFocusPolicy.mvRequestsFocus(AudioFocusMode.ALWAYS_STOP))
        assertFalse(AudioFocusPolicy.mvResumesOnGain(AudioFocusMode.ALWAYS_STOP))
    }

    /**
     * 模拟 [PlaybackService.applyFocusMode] 的落地: 账本 + 系统调用计数。
     *
     * 账本那几行是 [AudioFocusPolicy.focusRequestStep] 的入参来源
     * (appliedMode / hasRequest), 真实实现里它们是服务的两个字段。
     */
    private class FakeFocusSystem {
        var appliedMode: AudioFocusMode? = null
        var hasRequest = false
        var requests = 0
        var abandons = 0

        fun apply(mode: AudioFocusMode): AudioFocusPolicy.FocusRequestStep {
            val step = AudioFocusPolicy.focusRequestStep(appliedMode, mode, hasRequest)
            when (step) {
                AudioFocusPolicy.FocusRequestStep.KEEP -> Unit

                AudioFocusPolicy.FocusRequestStep.ABANDON -> {
                    abandons++
                    hasRequest = false
                }

                AudioFocusPolicy.FocusRequestStep.REQUEST -> {
                    requests++
                    hasRequest = true
                }

                AudioFocusPolicy.FocusRequestStep.ABANDON_AND_REQUEST -> {
                    abandons++
                    requests++
                    hasRequest = true
                }
            }
            appliedMode = mode
            return step
        }
    }

    @Test
    fun configuringTwiceWithSameModeRequestsFocusOnce() {
        // 审计 U7(2026-11-25): configure 在每次换曲、每次响度补测(20s)都会来一次。
        // 以前每趟都「放弃 → 重申请」⇒ 反复的无焦点窗口 + 给别的 App 补发假 LOSS。
        val system = FakeFocusSystem()

        assertEquals(AudioFocusPolicy.FocusRequestStep.REQUEST, system.apply(AudioFocusMode.ALWAYS_STOP))
        assertEquals(1, system.requests)
        assertEquals(0, system.abandons)

        // 第二、三次 configure(换曲 / 未测到响度的补测): 档位没变 ⇒ 一个字都不动
        assertEquals(AudioFocusPolicy.FocusRequestStep.KEEP, system.apply(AudioFocusMode.ALWAYS_STOP))
        assertEquals(AudioFocusPolicy.FocusRequestStep.KEEP, system.apply(AudioFocusMode.ALWAYS_STOP))
        assertEquals("同一档位反复 configure 只该申请一次", 1, system.requests)
        assertEquals("同一档位反复 configure 不该放弃焦点", 0, system.abandons)
    }

    @Test
    fun focusFollowsRealModeChangesOnly() {
        val system = FakeFocusSystem()

        // 首次 configure 是默认档(跟随系统): 服务不碰焦点
        assertEquals(AudioFocusPolicy.FocusRequestStep.KEEP, system.apply(AudioFocusMode.FOLLOW_SYSTEM))
        assertEquals(0, system.requests)
        assertEquals(0, system.abandons)

        // 切到「总是在后台播放」: 两档都不需要服务管焦点 ⇒ 仍然不动
        assertEquals(AudioFocusPolicy.FocusRequestStep.KEEP, system.apply(AudioFocusMode.ALWAYS_PLAY))
        assertEquals(0, system.abandons)

        // 切到「总是停止」: 现在真的要抢焦点了
        assertEquals(
            AudioFocusPolicy.FocusRequestStep.REQUEST,
            system.apply(AudioFocusMode.ALWAYS_STOP),
        )
        assertEquals(1, system.requests)

        // 切回其它档: 必须放弃(否则别的 App 起播时会收到一次假的中断)
        assertEquals(
            AudioFocusPolicy.FocusRequestStep.ABANDON,
            system.apply(AudioFocusMode.FOLLOW_SYSTEM),
        )
        assertEquals(1, system.abandons)
        assertFalse(system.hasRequest)

        // 再从其它档切回「总是停止」: 放弃旧的(没有) + 重新申请 —— 档位真的变了
        assertEquals(
            AudioFocusPolicy.FocusRequestStep.REQUEST,
            system.apply(AudioFocusMode.ALWAYS_STOP),
        )
        assertEquals(2, system.requests)
        assertEquals(1, system.abandons)
    }

    @Test
    fun missingRequestIsReRequestedEvenIfModeMatches() {
        // 账本与目标不一致(例如 pre-O 申请失败/被系统回收): 仍然要去申请, 不能因为
        // "档位没变"就永远不出声地停在不持焦点的状态。
        assertEquals(
            AudioFocusPolicy.FocusRequestStep.REQUEST,
            AudioFocusPolicy.focusRequestStep(
                appliedMode = AudioFocusMode.ALWAYS_STOP,
                nextMode = AudioFocusMode.ALWAYS_STOP,
                hasRequest = false,
            ),
        )
    }
}
