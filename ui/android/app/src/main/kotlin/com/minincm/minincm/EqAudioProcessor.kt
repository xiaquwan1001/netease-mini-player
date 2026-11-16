package com.minincm.minincm

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt

private fun dbToLinear(db: Float): Float = 10f.pow(db / 20f)

// ============================================================================
// Media3 AudioProcessor: 解析出的 EQ 链, 逐样本处理交错 PCM。
//
// 为什么只处理交错 PCM: Media3 给 AudioProcessor 的输入永远是一块交错的
// ByteBuffer(16bit 小端或 float), 不存在非交错(planar)的输入路径;
// 因此这里实现交错路径, 每声道独立 biquad 状态(等价于非交错的分声道处理)。
// 输出限幅到 [-1,1]: 正增益可能把样本推出量程, 宁可削波也不要把噪声灌给设备。
// ============================================================================

class EqAudioProcessor(private val profile: EqProfile) : BaseAudioProcessor() {
    private var sampleRate = 48000
    private var channelCount = 2
    private var encoding = C.ENCODING_PCM_16BIT
    private var passthrough = true
    private var stages: Array<Biquad> = emptyArray()
    private var preampGain = 1f
    private var z1 = FloatArray(0)
    private var z2 = FloatArray(0)

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        sampleRate = inputAudioFormat.sampleRate
        channelCount = max(1, inputAudioFormat.channelCount)
        encoding = inputAudioFormat.encoding
        val supported = encoding == C.ENCODING_PCM_16BIT || encoding == C.ENCODING_PCM_FLOAT
        if (!supported) {
            // 不支持的编码(如 24/32bit 整型)直接旁路: 返回 NOT_SET 让 Media3 把本 processor 置为 inactive
            passthrough = true
            return AudioProcessor.AudioFormat.NOT_SET
        }
        buildChain()
        return inputAudioFormat
    }

    private fun buildChain() {
        val active = profile.activeFilters().filter { abs(it.gainDb) > 1e-6f }
        stages = active.map { Biquad.fromFilter(it, sampleRate.toFloat()) }.toTypedArray()
        preampGain = dbToLinear(profile.preampDb)
        passthrough = stages.isEmpty() && abs(preampGain - 1f) < 1e-6f
        val stateSize = channelCount * stages.size
        z1 = if (stateSize > 0) FloatArray(stateSize) else FloatArray(0)
        z2 = if (stateSize > 0) FloatArray(stateSize) else FloatArray(0)
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        inputBuffer.order(ByteOrder.nativeOrder())
        val out = replaceOutputBuffer(inputBuffer.remaining())
        if (passthrough) {
            // 无任何滤波效果: 逐字节直通, 不改变格式
            out.put(inputBuffer)
            out.flip()
            return
        }
        val bytesPerSample = if (encoding == C.ENCODING_PCM_16BIT) 2 else 4
        val frames = inputBuffer.remaining() / (bytesPerSample * channelCount)
        if (encoding == C.ENCODING_PCM_16BIT) {
            for (frame in 0 until frames) {
                for (ch in 0 until channelCount) {
                    val x = inputBuffer.short.toFloat() / 32768f
                    out.putShort((processSample(ch, x) * 32767f).roundToInt().toShort())
                }
            }
        } else { // ENCODING_PCM_FLOAT
            for (frame in 0 until frames) {
                for (ch in 0 until channelCount) {
                    val x = inputBuffer.float
                    out.putFloat(processSample(ch, x))
                }
            }
        }
        out.flip()
    }

    private fun processSample(channel: Int, x: Float): Float {
        var v = x * preampGain
        val base = channel * stages.size
        for (i in stages.indices) {
            val s = stages[i]
            val idx = base + i
            val y = s.b0 * v + z1[idx]
            z1[idx] = s.b1 * v - s.a1 * y + z2[idx]
            z2[idx] = s.b2 * v - s.a2 * y
            v = y
        }
        return clamp(v)
    }

    private fun clamp(v: Float): Float = if (v.isNaN()) 0f else v.coerceIn(-1f, 1f)

    override fun onFlush() = resetState()

    override fun onReset() = resetState()

    private fun resetState() {
        if (z1.isNotEmpty()) {
            z1.fill(0f)
            z2.fill(0f)
        }
    }
}
