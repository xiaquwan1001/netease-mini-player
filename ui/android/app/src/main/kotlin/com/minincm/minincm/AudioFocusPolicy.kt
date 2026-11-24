package com.minincm.minincm

import android.media.AudioManager

/**
 * 播放器的**音频焦点策略**(用户设置项「被其他媒体抢占时怎么办」): 纯逻辑, JVM 单测覆盖
 * (见 src/test/.../AudioFocusPolicyTest.kt)。
 *
 * 三档(与 Dart 侧 `AudioFocusPolicy` 的 id 一一对应, 改名要两边一起改):
 * - [Mode.FOLLOW_SYSTEM]: 默认。交给 Media3 自己仲裁: 起播申请焦点, 被抢占时暂停,
 *   短暂失去(`LOSS_TRANSIENT`)回来后自动续播。与 2026-11-18 起的行为完全一致。
 * - [Mode.ALWAYS_PLAY]: **不申请也不理会焦点**。别的 App 起播时本应用继续出声
 *   (系统不会自动把两路混音停下来, 代价是可能叠音, 由用户自己选择)。
 * - [Mode.ALWAYS_STOP]: 自己申请焦点; 任何形式的失去(永久/短暂/ducking)都暂停,
 *   且**焦点回来也不自动恢复** —— 必须用户手动按下播放。
 *
 * 为什么 ALWAYS_STOP 不复用 Media3 的仲裁: Media3 在 `AUDIOFOCUS_GAIN` 时会自动把
 * 它因短暂失去焦点而暂停的播放续上, 而"总是停止"的语义恰恰是"别自己动"。
 * 所以这一档把 `handleAudioFocus = false` 传给 ExoPlayer, 由 [PlaybackService]
 * 自己申请焦点并只听 [Action.PAUSE]。
 */
internal enum class AudioFocusMode(val id: String) {
    FOLLOW_SYSTEM("followSystem"),
    ALWAYS_PLAY("alwaysPlay"),
    ALWAYS_STOP("alwaysStop"),
    ;

    companion object {
        /** 未知/缺失一律回落默认: 设置文件被手改坏不该让播放行为变成"叠音"。 */
        fun fromId(raw: String?): AudioFocusMode =
            entries.firstOrNull { it.id == raw } ?: FOLLOW_SYSTEM
    }
}

internal object AudioFocusPolicy {
    /** 焦点变化要做的动作 */
    enum class Action {
        /** 什么都不做(交给 Media3 / 用户自己) */
        NONE,

        /** 暂停, 且不自动恢复 */
        PAUSE,
    }

    /** ExoPlayer 自己的焦点仲裁是否开启(只有「跟随系统」交给它) */
    fun useExoPlayerFocus(mode: AudioFocusMode): Boolean = mode == AudioFocusMode.FOLLOW_SYSTEM

    /** 服务是否要自己申请/管理焦点(只有「总是停止」需要, 其余两个不碰) */
    fun manageFocusInService(mode: AudioFocusMode): Boolean = mode == AudioFocusMode.ALWAYS_STOP

    /** [change] 是 `AudioManager.OnAudioFocusChangeListener` 的回调值。 */
    fun actionFor(mode: AudioFocusMode, change: Int): Action = when (mode) {
        AudioFocusMode.ALWAYS_STOP -> when (change) {
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
            -> Action.PAUSE

            else -> Action.NONE
        }
        // 跟随系统由 Media3 处理; 总是后台播放则刻意什么都不做。
        AudioFocusMode.FOLLOW_SYSTEM, AudioFocusMode.ALWAYS_PLAY -> Action.NONE
    }

    /** MV(独立 Activity)是否申请焦点: 「总是在后台播放」不申请, 免得抢走别的 App 的焦点。 */
    fun mvRequestsFocus(mode: AudioFocusMode): Boolean = mode != AudioFocusMode.ALWAYS_PLAY

    /** MV 拿到 `AUDIOFOCUS_GAIN` 时是否续播: 只有「跟随系统」允许自动恢复。 */
    fun mvResumesOnGain(mode: AudioFocusMode): Boolean = mode == AudioFocusMode.FOLLOW_SYSTEM

    /** 设置项的中文标签(Dart 侧 `AudioFocusPolicy.label` 是同一套口径, 只给日志/诊断用) */
    fun label(mode: AudioFocusMode): String = when (mode) {
        AudioFocusMode.FOLLOW_SYSTEM -> "跟随系统"
        AudioFocusMode.ALWAYS_PLAY -> "总是在后台播放"
        AudioFocusMode.ALWAYS_STOP -> "总是停止播放"
    }
}
