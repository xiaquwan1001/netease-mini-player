// ============================================================================
// AutoEQ ParametricEQ.txt 的 Kotlin 侧解析 + biquad 系数(**纯 JVM, 不依赖 Android/Media3**).
//
// 为什么在 Kotlin 侧自己实现解析, 而不是调用 Dart/Rust:
// Media3 的 AudioProcessor 只能运行在 Android 进程里, 且需要在拿到实际采样率后
// 现场生成 RBJ 系数; 走 FFI 会有跨进程/跨语言往返的延迟与生命周期问题。
// 规则与 Rust ncm-domain::EqProfile 保持同一套(见 docs/plan-2026-11-09 任务书 2.2):
//   - 类型只支持 PK/LS/HS(其它明确报不支持);
//   - 最多 20 个 filter(第 21 个报错);
//   - Gain/Preamp 落在 +-24 dB, 超范围报错而不是静默裁剪;
//   - Q 必填且 > 0; Fc 必须 0 < Fc <= 48000 Hz;
//   - 空行与 # / // 注释行忽略; 解析失败带 1 基行号。
//
// 这个文件是 P-11 的落点: 纯逻辑单独成文件(无 Android 依赖)后, 才能用 JVM 单测
// (ui/android/app/src/test/**) 直接跑三端共享夹具 ui/test/fixtures/eq_profile_cases.json,
// 不需要真机。EqAudioProcessor.kt 只留 Media3 AudioProcessor 的胶水。
// ============================================================================

package com.minincm.minincm

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

private const val MAX_FILTERS = 20
private const val MAX_GAIN_DB = 24f
private const val MAX_FREQ_HZ = 48000f

enum class EqFilterKind { PK, LS, HS }

class EqFilter(
    val kind: EqFilterKind,
    val enabled: Boolean,
    val freqHz: Float,
    val gainDb: Float,
    val q: Float,
)

class EqProfile(val preampDb: Float, val filters: List<EqFilter>) {
    fun activeFilters(): List<EqFilter> = filters.filter { it.enabled }

    /** 是否存在实际效果: 前级非 0, 或存在增益非 0 的生效 filter */
    val hasEffect: Boolean
        get() = abs(preampDb) > 1e-6f || activeFilters().any { abs(it.gainDb) > 1e-6f }
}

class EqParseException(val line: Int, val reason: String) :
    Exception("第 $line 行: $reason")

fun parseParametricEq(text: String): EqProfile {
    val filters = ArrayList<EqFilter>()
    var preampDb = 0f
    var seenPreamp = false
    for ((idx, raw) in text.lines().withIndex()) {
        val lineNo = idx + 1
        val line = raw.trim()
        if (line.isEmpty() || line.startsWith("#") || line.startsWith("//")) continue
        val lower = line.lowercase()
        if (lower.startsWith("preamp")) {
            if (seenPreamp) throw EqParseException(lineNo, "Preamp 出现了不止一次")
            seenPreamp = true
            val afterColon = line.substringAfter(':', "").trim()
            if (afterColon.isEmpty()) {
                throw EqParseException(lineNo, "Preamp 缺少数值(形如 Preamp: -6.0 dB)")
            }
            preampDb = parseNumberWithUnit(afterColon, lineNo, "Preamp", "dB")
            checkGain(preampDb, lineNo, "Preamp")
            continue
        }
        if (lower.startsWith("filter")) {
            if (filters.size >= MAX_FILTERS) {
                throw EqParseException(lineNo, "filter 数量超过上限 $MAX_FILTERS 个")
            }
            filters.add(parseFilterLine(line, lineNo))
            continue
        }
        throw EqParseException(lineNo, "无法识别的行(只支持 Preamp 与 Filter N: 两种)")
    }
    return EqProfile(preampDb, filters)
}

private fun parseFilterLine(line: String, lineNo: Int): EqFilter {
    val parts = line.split(":", limit = 2)
    if (parts.size < 2) {
        throw EqParseException(lineNo, "Filter 行缺少冒号, 形如 Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71")
    }
    val head = parts[0].trim()
    val rest = parts[1].trim()

    val headParts = head.split(Regex("\\s+"))
    val keyword = headParts.getOrNull(0) ?: ""
    if (!keyword.equals("filter", ignoreCase = true)) {
        throw EqParseException(lineNo, "Filter 行必须以 Filter 开头")
    }
    val indexStr = headParts.getOrNull(1)
        ?: throw EqParseException(lineNo, "Filter 后面缺少序号(如 Filter 1:)")
    if (indexStr.toIntOrNull() == null) {
        throw EqParseException(lineNo, "Filter 序号 '$indexStr' 不是数字")
    }

    val tokens = rest.split(Regex("\\s+"))
    var i = 0
    val state = tokens.getOrNull(i++) ?: throw EqParseException(lineNo, "缺少 ON/OFF")
    val enabled = when (state.uppercase()) {
        "ON" -> true
        "OFF" -> false
        else -> throw EqParseException(lineNo, "过滤开关应为 ON/OFF, 实际是 '$state'")
    }
    val kindToken = tokens.getOrNull(i++) ?: throw EqParseException(lineNo, "缺少滤波器类型(PK/LS/HS)")
    val kind = when (kindToken.uppercase()) {
        "PK" -> EqFilterKind.PK
        "LS" -> EqFilterKind.LS
        "HS" -> EqFilterKind.HS
        else -> throw EqParseException(lineNo, "不支持的滤波器类型 '$kindToken'(只支持 PK / LS / HS)")
    }

    var freq: Float? = null
    var gain: Float? = null
    var q: Float? = null
    while (i < tokens.size) {
        val key = tokens[i++]
        val value = tokens.getOrNull(i++) ?: throw EqParseException(lineNo, "$key 后面缺少数值")
        val parsed = value.toFloatOrNull()
            ?: throw EqParseException(lineNo, "$key 的数值 '$value' 不是数字")
        when (key.lowercase()) {
            "fc" -> {
                if (i < tokens.size && tokens[i].equals("hz", ignoreCase = true)) i++
                freq = parsed
            }
            "gain" -> {
                if (i < tokens.size && tokens[i].equals("db", ignoreCase = true)) i++
                gain = parsed
            }
            "q" -> q = parsed
            else -> throw EqParseException(lineNo, "无法识别的参数 '$key'(只支持 Fc / Gain / Q)")
        }
    }

    val f = freq ?: throw EqParseException(lineNo, "缺少 Fc(中心/转折频率)")
    if (!(f.isFinite() && f > 0f && f <= MAX_FREQ_HZ)) {
        throw EqParseException(lineNo, "Fc 必须在 0 < Fc <= $MAX_FREQ_HZ Hz")
    }
    val g = gain ?: throw EqParseException(lineNo, "缺少 Gain")
    checkGain(g, lineNo, "Gain")
    val qv = q ?: throw EqParseException(lineNo, "缺少 Q(Q 必填且 > 0)")
    if (!(qv.isFinite() && qv > 0f)) {
        throw EqParseException(lineNo, "Q 必须 > 0")
    }
    return EqFilter(kind, enabled, f, g, qv)
}

private fun checkGain(v: Float, line: Int, what: String) {
    if (!v.isFinite()) throw EqParseException(line, "$what 不是有效数字")
    if (abs(v) > MAX_GAIN_DB) throw EqParseException(line, "$what 超出 ±$MAX_GAIN_DB dB 范围")
}

private fun parseNumberWithUnit(token: String, line: Int, what: String, expectedUnit: String): Float {
    val parts = token.split(Regex("\\s+"))
    val num = parts.getOrNull(0) ?: throw EqParseException(line, "$what 缺少数值")
    val v = num.toFloatOrNull() ?: throw EqParseException(line, "$what 的数值 '$num' 不是数字")
    if (parts.size > 1 && !parts[1].equals(expectedUnit, ignoreCase = true)) {
        throw EqParseException(line, "$what 的单位应为 $expectedUnit, 实际是 '${parts[1]}'")
    }
    return v
}

// ============================================================================
// RBJ Audio EQ Cookbook 的二阶节(转置直接 II 型), 公式与 Rust ncm-playback::biquad 一致。
// ============================================================================

class Biquad(val b0: Float, val b1: Float, val b2: Float, val a1: Float, val a2: Float) {
    companion object {
        fun fromFilter(filter: EqFilter, sampleRate: Float): Biquad = when (filter.kind) {
            EqFilterKind.PK -> peaking(sampleRate, filter.freqHz, filter.gainDb, filter.q)
            EqFilterKind.LS -> lowShelf(sampleRate, filter.freqHz, filter.gainDb, filter.q)
            EqFilterKind.HS -> highShelf(sampleRate, filter.freqHz, filter.gainDb, filter.q)
        }

        fun peaking(sampleRate: Float, freqHz: Float, gainDb: Float, q: Float): Biquad {
            val a = 10f.pow(gainDb / 40f)
            val w0 = omega(sampleRate, freqHz)
            val sinW0 = sin(w0)
            val cosW0 = cos(w0)
            val alpha = sinW0 / (2f * q)
            val a0 = 1f + alpha / a
            return Biquad(
                (1f + alpha * a) / a0,
                (-2f * cosW0) / a0,
                (1f - alpha * a) / a0,
                (-2f * cosW0) / a0,
                (1f - alpha / a) / a0,
            )
        }

        fun lowShelf(sampleRate: Float, freqHz: Float, gainDb: Float, q: Float): Biquad =
            shelf(sampleRate, freqHz, gainDb, q, low = true)

        fun highShelf(sampleRate: Float, freqHz: Float, gainDb: Float, q: Float): Biquad =
            shelf(sampleRate, freqHz, gainDb, q, low = false)

        private fun shelf(
            sampleRate: Float,
            freqHz: Float,
            gainDb: Float,
            q: Float,
            low: Boolean,
        ): Biquad {
            val a = 10f.pow(gainDb / 40f)
            val w0 = omega(sampleRate, freqHz)
            val sinW0 = sin(w0)
            val cosW0 = cos(w0)
            val alpha = sinW0 / (2f * q)
            val twoSqrtAAlpha = 2f * sqrt(a) * alpha
            val b0: Float
            val b1: Float
            val b2: Float
            val a0: Float
            val a1: Float
            val a2: Float
            if (low) {
                b0 = a * ((a + 1f) - (a - 1f) * cosW0 + twoSqrtAAlpha)
                b1 = a * 2f * ((a - 1f) - (a + 1f) * cosW0)
                b2 = a * ((a + 1f) - (a - 1f) * cosW0 - twoSqrtAAlpha)
                a0 = (a + 1f) + (a - 1f) * cosW0 + twoSqrtAAlpha
                a1 = -2f * ((a - 1f) + (a + 1f) * cosW0)
                a2 = (a + 1f) + (a - 1f) * cosW0 - twoSqrtAAlpha
            } else {
                b0 = a * ((a + 1f) + (a - 1f) * cosW0 + twoSqrtAAlpha)
                b1 = -a * 2f * ((a - 1f) + (a + 1f) * cosW0)
                b2 = a * ((a + 1f) + (a - 1f) * cosW0 - twoSqrtAAlpha)
                a0 = (a + 1f) - (a - 1f) * cosW0 + twoSqrtAAlpha
                a1 = 2f * ((a - 1f) - (a + 1f) * cosW0)
                a2 = (a + 1f) - (a - 1f) * cosW0 - twoSqrtAAlpha
            }
            return Biquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
        }

        private fun omega(sampleRate: Float, freqHz: Float): Float {
            // 频率高于 Nyquist 时钳到 0.49*fs, 避免 tan 溢出导致系数爆掉(与 Rust 一致)
            val fs = max(sampleRate, 8000f)
            val f = freqHz.coerceIn(1f, fs * 0.49f)
            return (2f * PI.toFloat()) * f / fs
        }
    }
}
