package com.minincm.app;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.webkit.CookieManager;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/**
 * 网页登录 Activity: 加载网易云官方网页登录页(零风控的官方登录通道),
 * 用户扫码后从 CookieManager 抓取 MUSIC_U 保存, 完成后自动关闭。
 *
 * 背景: API 扫码登录接口(/eapi/login/qrcode/client/login)在网页端形态下
 * 会被 8821"安全环境风险"风控拦截, 官方网页登录页无此问题(与 Ncrust 同方案)。
 */
public class LoginActivity extends Activity {

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        WebView wv = new WebView(this);
        WebSettings s = wv.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setUseWideViewPort(true);
        s.setLoadWithOverviewMode(true);
        s.setUserAgentString("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
        CookieManager.getInstance().setAcceptThirdPartyCookies(wv, true);

        // 重新登录前清掉旧登录态(避免误判)
        CookieManager.getInstance().removeAllCookies(null);

        wv.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                String cookie = CookieManager.getInstance().getCookie("https://music.163.com");
                if (cookie != null && cookie.contains("MUSIC_U=")) {
                    String mus = extractCookie(cookie, "MUSIC_U");
                    if (mus != null && !mus.isEmpty()) {
                        SharedPreferences sp = getSharedPreferences("mini_ncm", MODE_PRIVATE);
                        sp.edit().putString("ncm.music_u", mus).commit();
                        android.util.Log.i("MiniNCM", "登录成功, MUSIC_U 已保存");
                        finish();
                    }
                }
            }
        });

        wv.loadUrl("https://music.163.com/#/login");
        setContentView(wv);
    }

    private String extractCookie(String cookie, String name) {
        for (String part : cookie.split(";")) {
            String p = part.trim();
            if (p.startsWith(name + "=")) {
                return p.substring(name.length() + 1);
            }
        }
        return null;
    }
}
