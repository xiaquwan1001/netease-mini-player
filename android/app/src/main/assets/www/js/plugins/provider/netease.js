/**
 * provider/netease.js —— 网易云直连插件(第一个音乐源插件)
 *
 * 协议蓝本: NeteaseCloudMusicApiEnhanced/api-enhanced (util/crypto.js + util/request.js)
 * 第一版全链路使用 eapi 加密(AES-128-ECB, 纯 CryptoJS 实现):
 *   - 请求加密:  params = AES-ECB-hex("{url}-36cd479b6b5-{json}-36cd479b6b5-{md5}")
 *   - 响应明文:  encryptResponse=false, body 直接是 JSON
 *   - Cookie:    JS 全权构造/持久化(原生 SharedPreferences), 登录态不外泄
 *
 * 插件接口约定(所有音乐源插件遵循):
 *   loginQr() -> {unikey, qrurl}
 *   loginCheck(unikey) -> {code, message}   (803=成功)
 *   isLoggedIn() -> bool
 *   logout()
 *   search(q, limit, offset) -> [song]
 *   songUrl(id) -> url | null
 *   lyric(id) -> lrc text
 */
(function () {
  'use strict';

  var B = window.AppBridge;

  var EAPI_KEY = 'e82ckenh8dichen8';
  var EAPI_MARK = '36cd479b6b5';
  // 关键: eapi 读接口打 interface3 域(与 Ncrust 直连成功形态一致, 网页端特征风控宽松)
  var EAPI_DOMAIN = 'https://interface3.music.163.com';
  var DOMAIN = 'https://music.163.com';
  var LINUX_KEY = 'rFgB&h#%2?^eDg:Q';
  // 网页端 UA(Chrome Windows): 模拟网页播放器形态, 而非移动 App 形态
  var UA_CHROME = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  var UA_LINUX = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36';
  var COOKIE_KEY = 'ncm.cookie';

  // ---------- 加密工具(移植自 api-enhanced/util/crypto.js) ----------

  function aesEcbHex(text, key) {
    return CryptoJS.AES.encrypt(
      CryptoJS.enc.Utf8.parse(text),
      CryptoJS.enc.Utf8.parse(key),
      { mode: CryptoJS.mode.ECB, padding: CryptoJS.pad.Pkcs7 }
    ).ciphertext.toString().toUpperCase();
  }

  function eapiEncrypt(uri, object) {
    var text = JSON.stringify(object);
    var digest = CryptoJS.MD5('nobody' + uri + 'use' + text + 'md5forencrypt').toString();
    return aesEcbHex(uri + '-' + EAPI_MARK + '-' + text + '-' + EAPI_MARK + '-' + digest, EAPI_KEY);
  }

  /** linuxapi 加密(播放地址通道): AES-ECB(linuxapiKey), 内容为 {method,url,params} */
  function linuxapiEncrypt(innerUrl, params) {
    var text = JSON.stringify({ method: 'POST', url: innerUrl, params: params });
    return aesEcbHex(text, LINUX_KEY);
  }

  function randomHex(n) {
    var s = '';
    for (var i = 0; i < n; i++) s += '0123456789abcdef'[Math.floor(Math.random() * 16)];
    return s;
  }

  function genDeviceId() { return randomHex(32); }

  // ---------- Cookie 管理(持久化在原生 SharedPreferences) ----------

  function loadCookie() {
    var c = {};
    try { c = JSON.parse(B.storeGet(COOKIE_KEY) || '{}'); } catch (e) { c = {}; }
    // 合并网页登录通道的 MUSIC_U
    var musicU = B.storeGet('ncm.music_u');
    if (musicU && musicU.length > 10) c.MUSIC_U = musicU;
    return {
      os: 'android', osver: '14', appver: '9.5.61', channel: 'xiaomi',
      deviceId: c.deviceId || genDeviceId(),
      NMTID: c.NMTID || ('00O' + randomHex(19)),
      ...c,
    };
  }

  function saveCookie(c) { B.storeSet(COOKIE_KEY, JSON.stringify(c)); }

  // ---------- 请求核心 ----------

  function buildHeader(cookie) {
    var header = {
      osver: cookie.osver,
      deviceId: cookie.deviceId,
      os: cookie.os,
      appver: cookie.appver,
      versioncode: cookie.versioncode || '140',
      mobilename: cookie.mobilename || '',
      buildver: String(Math.floor(Date.now() / 1000)),
      resolution: cookie.resolution || '1920x1080',
      __csrf: cookie.__csrf || '',
      channel: cookie.channel,
      requestId: Date.now() + '_' + String(Math.floor(Math.random() * 1000)).padStart(4, '0'),
    };
    if (cookie.MUSIC_U) header.MUSIC_U = cookie.MUSIC_U;
    if (cookie.MUSIC_A) header.MUSIC_A = cookie.MUSIC_A;
    if (cookie.NMTID) header.NMTID = cookie.NMTID;
    return header;
  }

  function cookieHeaderString(header) {
    return Object.keys(header)
      .map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(header[k]); })
      .join('; ');
  }

  function applySetCookie(res, cookie) {
    var sc = res.headers && res.headers['Set-Cookie'];
    if (!sc) return;
    var parts = sc.split(', ');
    for (var i = 0; i < parts.length; i++) {
      var m = parts[i].match(/^([^=]+)=([^;]*)/);
      if (!m) continue;
      var k = m[1].trim();
      var v = m[2];
      if (k === 'MUSIC_U') cookie.MUSIC_U = v;
      else if (k === 'MUSIC_A') cookie.MUSIC_A = v;
      else if (k === '__csrf') cookie.__csrf = v;
      else if (k.indexOf('NMTID') === 0) cookie.NMTID = v;
    }
  }

  /** fetch 模式下 Set-Cookie 对 JS 不可见, 改为从 WebView CookieManager 主动同步 */
  function syncWebViewCookies(cookie) {
    try {
      var domains = [
        'https://interfacepc.music.163.com',
        'https://music.163.com',
        'https://interface.music.163.com',
        'https://interface3.music.163.com',
      ];
      for (var i = 0; i < domains.length; i++) {
        var cs = B.cookieGet(domains[i]);
        if (!cs) continue;
        var parts = cs.split(';');
        for (var j = 0; j < parts.length; j++) {
          var m = parts[j].trim().match(/^([^=]+)=([^;]*)/);
          if (!m) continue;
          var k = m[1].trim(), v = m[2];
          if (k === 'MUSIC_U') cookie.MUSIC_U = v;
          else if (k === 'MUSIC_A') cookie.MUSIC_A = v;
          else if (k === '__csrf') cookie.__csrf = v;
        }
      }
    } catch (e) { /* ignore */ }
  }

  /**
   * eapi 请求核心 —— 网页端形态(对齐 Ncrust 直连成功形态):
   *   - 域名 interface3.music.163.com
   *   - Chrome Windows UA, 不注入设备 header cookie(裸登录 cookie 或空)
   *   - 响应明文 JSON
   * @param uri  如 /api/cloudsearch/pc
   * @param data 业务参数(不再注入 header)
   * @param opts {raw: true} 时不做 code!=200 抛错(用于二维码轮询等)
   */
  async function requestEapi(uri, data, opts) {
    opts = opts || {};
    var cookie = loadCookie();
    var params = eapiEncrypt(uri, data);
    var url = EAPI_DOMAIN + '/eapi/' + uri.replace(/^\/api\//, '');

    var cookieStr = '';
    if (cookie.MUSIC_U) cookieStr += 'MUSIC_U=' + cookie.MUSIC_U + '; ';
    if (cookie.MUSIC_A) cookieStr += 'MUSIC_A=' + cookie.MUSIC_A + '; ';
    var headers = {
      'User-Agent': UA_CHROME,
      'Referer': 'https://music.163.com/',
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': '*/*',
    };
    if (cookieStr) headers['Cookie'] = cookieStr;

    var res = await B.post(url, headers, 'params=' + params);

    if (!res || !res.status) throw new Error('网络不可用');
    if (res.status !== 200) throw new Error('HTTP ' + res.status);

    applySetCookie(res, cookie);
    syncWebViewCookies(cookie);
    saveCookie(cookie);

    var body;
    try { body = JSON.parse(res.body); } catch (e) { throw new Error('响应非 JSON'); }
    if (!opts.raw && body.code && body.code !== 200) {
      var err = new Error(body.message || ('code ' + body.code));
      err.code = body.code;
      throw err;
    }
    return body;
  }

  // ---------- 插件实现 ----------

  var provider = {
    id: 'provider/netease',
    name: '网易云直连',

    async loginQr() {
      // 返回 {code, unikey} —— unikey 在顶层(经真实接口验证)
      var keyRes = await requestEapi('/api/login/qrcode/unikey', { type: 3 });
      var unikey = keyRes.unikey;
      return { unikey: unikey, qrurl: 'https://music.163.com/login?codekey=' + unikey };
    },

    async loginCheck(unikey) {
      // 真实 URI: /api/login/qrcode/client/login (经 api-enhanced 源码确认)
      // code: 800=过期 801=待扫码 802=已扫码待确认 803=成功
      var res = await requestEapi('/api/login/qrcode/client/login', { key: unikey, type: 3 }, { raw: true });
      return { code: res.code, message: res.message || '' };
    },

    isLoggedIn: function () {
      // 登录态来自网页登录通道(ncm.music_u, 原生 LoginActivity 写入)
      try {
        var u = B.storeGet('ncm.music_u');
        return !!(u && u.length > 10);
      } catch (e) { return false; }
    },

    logout: function () {
      try {
        B.storeRemove('ncm.music_u');
        var c = JSON.parse(B.storeGet(COOKIE_KEY) || '{}');
        delete c.MUSIC_U;
        B.storeSet(COOKIE_KEY, JSON.stringify(c));
      } catch (e) { /* ignore */ }
    },

    async search(q, limit, offset) {
      var res = await requestEapi('/api/cloudsearch/pc', {
        s: q, type: 1, limit: limit || 30, offset: offset || 0, total: true,
      });
      return (res.result && res.result.songs) || [];
    },

    async songUrl(id, br) {
      // 网页端形态: eapi 打 /eapi/song/enhance/player/url/v1 (interface3 域, 明文响应)
      // 与 Ncrust 直连成功形态一致; linuxapi 通道保留为备用
      var res = await requestEapi('/api/song/enhance/player/url/v1', {
        ids: '[' + id + ']',
        level: 'standard',
      });
      var d = (res.data && res.data[0]) || {};
      if (d.code !== 200) throw new Error('无播放地址(code ' + d.code + ')');
      return d.url || null;
    },

    async lyric(id) {
      var res = await requestEapi('/api/song/lyric', { id: id });
      // lrc 可能为 null(无歌词/纯音乐)
      return (res.lrc && res.lrc.lyric) || '';
    },
  };

  // 注册进全局插件注册表(核心只提供接口, 内容靠插件)
  window.App = window.App || {};
  window.App.providers = window.App.providers || {};
  window.App.providers[provider.id] = provider;
})();
