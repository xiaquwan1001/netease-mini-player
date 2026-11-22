package com.minincm.minincm

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * 三端共享夹具(P-05 中期 / P-11)的 **Kotlin 侧** 断言.
 *
 * 同一份 `ui/test/fixtures/eq_profile_cases.json` 也被
 * - Dart: `ui/test/eq_profile_fixture_test.dart`
 * - Rust: `core/crates/ncm-domain/src/eq_profile.rs`(解析) 与
 *   `core/crates/ncm-playback/src/biquad.rs`(系数)
 * 读取. 这里是纯 JVM 单测(不需要设备/不需要 Android 运行时), 因为被测的
 * `EqProfileParser.kt` 只依赖 kotlin.math.
 *
 * 断言口径: `expect` 里出现的字段才断言, `expectKotlin` 会浅覆盖 `expect`
 * (已知口径分叉单列, 见夹具 description). 所有用例跑完后一次性报告差异, 便于定位.
 */
class EqProfileParserFixtureTest {
    private companion object {
        const val FIXTURE_RELATIVE = "test/fixtures/eq_profile_cases.json"

        /**
         * 从当前工作目录向上找夹具: Gradle 单测的 cwd 通常是模块目录
         * (`ui/android/app`), 但也可能是仓库根, 所以逐级向上探测而不是写死相对路径.
         */
        fun fixtureFile(): File {
            var dir: File? = File("").absoluteFile
            while (dir != null) {
                val candidate = File(dir, FIXTURE_RELATIVE)
                if (candidate.isFile) return candidate
                dir = dir.parentFile
            }
            throw AssertionError(
                "找不到三端共享夹具 '$FIXTURE_RELATIVE' (cwd=${File("").absolutePath})"
            )
        }
    }

    /** `expect` 与 `expectKotlin` 的浅合并结果 */
    private fun expected(case: JsonObject): JsonObject {
        val base = case.getAsJsonObject("expect")
        val over = case.getAsJsonObject("expectKotlin") ?: return base
        val merged = JsonObject()
        for ((k, v) in base.entrySet()) merged.add(k, v)
        for ((k, v) in over.entrySet()) merged.add(k, v)
        return merged
    }

    @Test
    fun fixtureIsPresentAndComplete() {
        val doc = JsonParser.parseString(fixtureFile().readText()).asJsonObject
        val cases = doc.getAsJsonArray("cases")
        assertTrue("夹具用例数 ${cases.size()} < 20", cases.size() >= 20)
        assertTrue("夹具缺少 sampleRateHz", doc.has("sampleRateHz"))
        assertTrue("夹具缺少 coefficientTolerance", doc.has("coefficientTolerance"))
    }

    @Test
    fun sharedFixtureParsesLikeDartAndRust() {
        val doc = JsonParser.parseString(fixtureFile().readText()).asJsonObject
        val floatTol = doc.get("floatTolerance").asDouble
        val coefTol = doc.get("coefficientTolerance").asDouble
        val sampleRate = doc.get("sampleRateHz").asFloat
        val issues = StringBuilder()
        var asserted = 0

        for (element in doc.getAsJsonArray("cases")) {
            val case = element.asJsonObject
            val name = case.get("name").asString
            val input = case.get("input").asString
            val want = expected(case)
            val wantOk = want.get("ok").asBoolean

            var profile: EqProfile? = null
            var error: EqParseException? = null
            try {
                profile = parseParametricEq(input)
            } catch (e: EqParseException) {
                error = e
            }

            if (profile != null != wantOk) {
                issues.append(
                    "$name: 期望 ${if (wantOk) "解析成功" else "解析失败"}, 实际 ${error ?: profile}\n"
                )
                continue
            }
            if (!wantOk) {
                val wantLine = want.get("errorLine").asInt
                if (error!!.line != wantLine) {
                    issues.append("$name: 报错行号期望 $wantLine, 实际 ${error.line}\n")
                }
                asserted++
                continue
            }

            val parsed = profile!!
            if (want.has("preampDb")) {
                val v = want.get("preampDb").asDouble
                if (abs(parsed.preampDb - v) > floatTol) {
                    issues.append("$name: preampDb 期望 $v, 实际 ${parsed.preampDb}\n")
                }
            }
            if (want.has("filterCount") && parsed.filters.size != want.get("filterCount").asInt) {
                issues.append(
                    "$name: filter 数期望 ${want.get("filterCount").asInt}, 实际 ${parsed.filters.size}\n"
                )
            }
            if (want.has("applied") && parsed.hasEffect != want.get("applied").asBoolean) {
                issues.append(
                    "$name: applied 期望 ${want.get("applied").asBoolean}, 实际 ${parsed.hasEffect}\n"
                )
            }
            for (which in listOf("first", "last")) {
                if (!want.has(which)) continue
                val slot = want.get(which)
                if (slot.isJsonNull) {
                    if (parsed.filters.isNotEmpty()) {
                        issues.append("$name: $which 期望没有 filter, 实际 ${parsed.filters.size} 条\n")
                    }
                    continue
                }
                val expectFilter = slot.asJsonObject
                val actual = if (which == "first") parsed.filters.firstOrNull()
                else parsed.filters.lastOrNull()
                if (actual == null) {
                    issues.append("$name: $which 期望有 filter, 实际为空\n")
                    continue
                }
                val ctx = "$name/$which"
                if (actual.kind.name != expectFilter.get("kind").asString) {
                    issues.append(
                        "$ctx: 类型期望 ${expectFilter.get("kind").asString}, 实际 ${actual.kind.name}\n"
                    )
                }
                if (actual.enabled != expectFilter.get("enabled").asBoolean) {
                    issues.append(
                        "$ctx: enabled 期望 ${expectFilter.get("enabled").asBoolean}, 实际 ${actual.enabled}\n"
                    )
                }
                for ((field, value) in listOf(
                    "freqHz" to actual.freqHz,
                    "gainDb" to actual.gainDb,
                    "q" to actual.q,
                )) {
                    val v = expectFilter.get(field).asDouble
                    if (abs(value - v) > floatTol) {
                        issues.append("$ctx: $field 期望 $v, 实际 $value\n")
                    }
                }
                // 夹具缺 biquad 时**不要静默 continue**(2026-11-22 审计 D2: 单条漏断言会被
                // 整夹具级的 `asserted > 0` 兜住) —— 记进 issues, 让这条真的红。
                val biquad = expectFilter.getAsJsonArray("biquad")
                if (biquad == null) {
                    issues.append("$ctx: 夹具缺 biquad 系数, 无法比对传递函数\n")
                    asserted++
                    continue
                }
                val coeffs = Biquad.fromFilter(actual, sampleRate)
                    .let { listOf(it.b0, it.b1, it.b2, it.a1, it.a2) }
                assertEquals("$ctx: biquad 应有 5 个系数", 5, biquad.size())
                for (i in coeffs.indices) {
                    val v = biquad[i].asDouble
                    if (abs(coeffs[i] - v) > coefTol) {
                        issues.append("$ctx: biquad[$i] 期望 $v, 实际 ${coeffs[i]}\n")
                    }
                }
            }
            asserted++
        }

        assertTrue("夹具里一个用例都没断言到", asserted > 0)
        if (issues.isNotEmpty()) {
            fail("三端共享夹具在 Kotlin 侧不一致:\n$issues")
        }
    }

    @Test
    fun emptyInputIsBypass() {
        val profile = parseParametricEq("")
        assertNull("空串不应有 filter", profile.filters.firstOrNull())
        assertNotNull(profile)
        assertTrue("空串不应生效", !profile.hasEffect)
        assertEquals(0.0, profile.preampDb.toDouble(), 0.0)
    }
}
