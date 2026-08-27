/**
 * bridge.js —— 原生桥封装
 *
 * 原生层只做三件事: HTTP IO / 存储 / 播放。
 * 这里把它们包装成 Promise 风格的 JS API, 业务代码无需关心回调机制。
 */
(function () {
  'use strict';
  var Native = window.Native;
  if (!Native) {
    // 浏览器调试兜底: 纯前端跑不起来(无原生桥), 只提示
    console.warn('Native bridge not available (must run inside WebView)');
  }

  var seq = 0;
  var pending = {};

  // 原生线程池完成 httpPost 后回调: window.__nativeCb(id, resultObj)
  window.__nativeCb = function (id, resultObj) {
    var p = pending[id];
    delete pending[id];
    if (!p) return;
    if (resultObj && resultObj.error) {
      p.reject(new Error(resultObj.error));
    } else {
      p.resolve(resultObj || {});
    }
  };

  // 原生桥 POST 封装(回调 id 机制)
  function nativePost(url, headers, body) {
    return new Promise(function (resolve, reject) {
      var id = ++seq;
      pending[id] = { resolve: resolve, reject: reject };
      Native.httpPost(url, JSON.stringify(headers || {}), body || '', id);
    });
  }

  var bridge = {
    /**
     * 无 CORS 限制的 HTTP POST, 返回 {status, headers, body}
     *
     * 优先用 WebView 的 Chromium 网络栈(fetch) —— 它的 TLS 指纹是主流浏览器指纹,
     * 网易云风控不拦; 安卓系统 HttpURLConnection(Conscrypt 默认配置)会被 TLS 指纹风控
     * 拦截返回空响应(实测 status=200 bytes=0)。
     * fetch 不可用时回退原生桥。
     */
    post: async function (url, headers, body) {
      // 传输层开关: ncm.transport = 'bridge' 强制原生桥(用于 TLS 指纹实验/调试)
      if (Native.storeGet('ncm.transport') === 'bridge') {
        return nativePost(url, headers, body);
      }
      try {
        var resp = await fetch(url, {
          method: 'POST',
          headers: headers,
          body: body,
          credentials: 'include',   // 允许接收/存储 Set-Cookie(浏览器自动管理)
          cache: 'no-store',
        });
        var text = await resp.text();
        // 跨域时 Set-Cookie 头对 JS 不可见 —— 登录态靠 cookieGet() 主动同步
        var respHeaders = {};
        resp.headers.forEach(function (v, k) { respHeaders[k] = v; });
        try {
          Native.log('[fetch] ' + url.slice(0, 60) + ' -> ' + resp.status + ' bytes=' + text.length + ' body=' + text.slice(0, 120));
        } catch (e2) { /* ignore */ }
        return { status: resp.status, headers: respHeaders, body: text };
      } catch (e) {
        // fetch 失败回退原生桥
        return nativePost(url, headers, body);
      }
    },

    /** 原生桥 POST(Java HttpURLConnection, 带 OkHttp 风格 TLS 指纹) */
    nativePost: nativePost,

    storeGet: function (k) { return Native.storeGet(k); },
    storeSet: function (k, v) { Native.storeSet(k, v); },
    storeRemove: function (k) { Native.storeRemove(k); },
    cookieGet: function (d) { return Native.cookieGet(d); },

    play: function (url, meta) { Native.play(url, JSON.stringify(meta || {})); },
    pause: function () { Native.pause(); },
    resume: function () { Native.resume(); },
    seekTo: function (ms) { Native.seekTo(ms); },
    stop: function () { Native.stop(); },
    getState: function () {
      try { return JSON.parse(Native.getState()); } catch (e) { return { state: 'idle' }; }
    },

    toast: function (msg) { Native.toast(msg); },
  };

  window.AppBridge = bridge;
})();
