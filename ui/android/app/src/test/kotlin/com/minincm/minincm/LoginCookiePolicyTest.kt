package com.minincm.minincm

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #5 的单测: 打开登录页前**只**清登录凭据, 保留设备指纹 / "记住上次账号"。
 *
 * 真机行为(网易登录页是否因此重新露出"一键手机号 / 输后四位继续")只能实测,
 * 这里锁的是策略本身: 一旦谁把 CLEAR_KEYS 改回"全清"或把 __remember_me 加进来,
 * 这两组断言会先红。
 */
class LoginCookiePolicyTest {
    @Test
    fun clearsLoginCredentials() {
        val raw = "MUSIC_U=secret; MUSIC_A=anon; __csrf=abc; JSESSIONID-WYYY=w; os=android"
        assertEquals(
            listOf("MUSIC_U", "MUSIC_A", "__csrf", "JSESSIONID-WYYY"),
            LoginCookiePolicy.keysToClear(raw),
        )
    }

    @Test
    fun keepsDeviceFingerprintAndRememberMe() {
        val raw = "_ntes_nuid=aa; _ntes_nnid=aa,1; NMTID=n; WNMCID=w; deviceId=D; " +
            "__remember_me=1; _iuqxldmzr_=x; os=android; appver=9.1.0"
        assertTrue(LoginCookiePolicy.keysToClear(raw).isEmpty())
        assertFalse(LoginCookiePolicy.hasLoginCookie(raw))
    }

    @Test
    fun emptyOrPartialStringsAreSafe() {
        assertTrue(LoginCookiePolicy.keysToClear("").isEmpty())
        // 前缀不算命中: MUSIC_U2 是别的键
        assertTrue(LoginCookiePolicy.keysToClear("MUSIC_U2=x; NOT_MUSIC_U=y").isEmpty())
        // 只有值(没有键)也认不出来 —— 与 Rust 侧 cookie_has_music_u 同口径
        assertTrue(LoginCookiePolicy.keysToClear("abc123").isEmpty())
    }

    @Test
    fun hasLoginCookieMatchesOnlyCredentialKeys() {
        assertTrue(LoginCookiePolicy.hasLoginCookie("a=1; MUSIC_U=abc"))
        assertTrue(LoginCookiePolicy.hasLoginCookie("MUSIC_U=; __csrf=1"))
        assertFalse(LoginCookiePolicy.hasLoginCookie("a=1; b=2"))
    }

    @Test
    fun keysAreDedupedInOrder() {
        assertEquals(
            listOf("MUSIC_U"),
            LoginCookiePolicy.keysToClear("MUSIC_U=a; os=android; MUSIC_U=b"),
        )
    }
}
