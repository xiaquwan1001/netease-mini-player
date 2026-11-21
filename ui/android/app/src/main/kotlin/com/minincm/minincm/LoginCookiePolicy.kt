package com.minincm.minincm

/**
 * 打开官方登录页前**该清哪些 cookie**(#5 回归, 2026-11-21) —— 纯逻辑, JVM 单测覆盖。
 *
 * 背景链(P-08 → #5):
 * - v0.8.1(d362411)用户报"已登录时点添加账号, 登录页判定已登录直接跳回来" ⇒ 每次打开
 *   登录页前 `CookieManager.removeAllCookies` 全清(2efe86f 收敛到 LoginActivity 一处)。
 * - 但全清把网易自己的"这台设备登录过谁"的证据也清了: 设备指纹 cookie
 *   (`_ntes_nuid` / `NMTID` / `WNMCID` / `JSESSIONID-WYYY`)和"记住上次账号"类
 *   cookie(`__remember_me` / `_iuqxldmzr_`)。于是官方登录页每次都是一台**全新设备**,
 *   用户反馈"以前有一键手机号 / 输后四位继续, 现在必须完整手机号 + 验证码"(#5)。
 *
 * 现在的取舍: **只删登录凭据键**, 设备指纹与"记住账号"类一律留着。
 * 判据仍然满足 P-08 —— 页面判定已登录看的是 `MUSIC_U`(我们自己的
 * `maybeFinishWithCookie` 也只看这一条), 没有它就不会自动登录进旧账号。
 *
 * 为什么不干脆按 `ncm-service` 的 LOGIN_KEYS 抄: 那边是 **Rust 侧**会话 cookie 的
 * 清理口径(退出登录), 里面含 `__remember_me` —— 那个键正是网页端"记住这台设备/
 * 上次账号"的依据, 在 WebView 里清掉就回到 #5。两处口径不同是有意的。
 */
internal object LoginCookiePolicy {
    /**
     * 要从 WebView 里删掉的键(**只**是登录凭据).
     *
     * - `MUSIC_U`: 主登录凭据, 页面据此判定"已登录"(P-08 的判据);
     * - `MUSIC_A`: 匿名/游客 token, 与 MUSIC_U 同族, 留着会让旧身份继续生效;
     * - `__csrf`: 与登录态配套的 CSRF token, 每次登录都会重发, 删掉无副作用;
     * - `JSESSIONID-WYYY`: 登录会话 id, 同上。
     */
    val CLEAR_KEYS: List<String> = listOf("MUSIC_U", "MUSIC_A", "__csrf", "JSESSIONID-WYYY")

    /** `a=1; MUSIC_U=x; b=2` → 命中的键(`["MUSIC_U"]`); 保持出现顺序并去重. */
    fun keysToClear(rawCookie: String): List<String> {
        val hit = LinkedHashSet<String>()
        for (piece in rawCookie.split(';')) {
            val key = keyOf(piece)
            if (key in CLEAR_KEYS) hit.add(key)
        }
        return hit.toList()
    }

    /** 这条 cookie 串里还有登录凭据吗(删完再问一次, 没删干净就走整体清空兜底). */
    fun hasLoginCookie(rawCookie: String): Boolean = keysToClear(rawCookie).isNotEmpty()

    private fun keyOf(piece: String): String =
        piece.substringBefore('=', "").trim()
}
