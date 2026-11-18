package com.minincm.minincm

import android.media.AudioManager

/**
 * MV 播放页的音频焦点策略(U-04): **纯逻辑**, 由 JVM 单测覆盖(见 src/test/.../**/MvAudioFocusPolicyTest.kt)。
 *
 * 背景: MV 是独立 Activity 里的 VideoView, 与 Media3 的歌曲 ExoPlayer 是两个音源。
 * 2026-11-18 前的状态是两头都不管焦点 —— 歌曲 ExoPlayer 在 media3 1.9.4 下
 * `ExoPlayer.Builder` 的构造函数只写 audioAttributes=DEFAULT、从不写 handleAudioFocus
 * ⇒ 取 JVM 默认值 false(字节码实测), MV 侧更是一行焦点代码都没有 ⇒ 两路声音叠着放。
 *
 * 现在两头都对齐到系统焦点:
 * - 歌曲: [PlaybackService] 里 `setAudioAttributes(..., handleAudioFocus = true)`;
 * - MV: [MvPlayerActivity] 在 onStart 申请 AUDIOFOCUS_GAIN, onStop/onDestroy 放弃。
 *
 * 各自**只在开始播时**申请 ⇒ 谁最后起播谁拿焦点, 不会出现"来回抢"的抖动;
 * 拿到焦点的那一路不会因为另一路"放弃焦点"而被打断(abandon 不广播)。
 *
 * 语义:
 * - `AUDIOFOCUS_LOSS`(永久失去): 暂停, 且**不自动恢复** —— 用户多半已经在别的 App 里听别的了。
 * - `AUDIOFOCUS_LOSS_TRANSIENT` / `..._CAN_DUCK`: 也暂停。MV 是有对白的视频, ducking
 *   (压低音量继续说)会让人听不清台词, 不如直接停, 拿回焦点再续。
 * - `AUDIOFOCUS_GAIN`: 只有"上次是被焦点抢走才停的"([pausedByFocus])才恢复;
 *   用户自己按的暂停不会被这一回调偷偷播起来。
 */
internal object MvAudioFocusPolicy {
    /** 焦点变化要做的动作 */
    enum class Action {
        /** 什么都不做 */
        NONE,

        /** 暂停 MV */
        PAUSE,

        /** 从"被焦点暂停"恢复播放 */
        RESUME,
    }

    /**
     * [change] 是 `AudioManager.OnAudioFocusChangeListener` 的回调值,
     * [pausedByFocus] 表示当前这个暂停是不是焦点导致的(而不是用户/生命周期导致的)。
     */
    fun actionFor(change: Int, pausedByFocus: Boolean): Action = when (change) {
        AudioManager.AUDIOFOCUS_LOSS,
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
        -> Action.PAUSE

        AudioManager.AUDIOFOCUS_GAIN -> if (pausedByFocus) Action.RESUME else Action.NONE

        else -> Action.NONE
    }
}
