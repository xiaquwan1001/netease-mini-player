/**
 * provider/remote.js —— 远程 API 服务插件(第二音乐源插件)
 *
 * 直连网易云被风控时的备用通道: 把 API 调用委托给自建的
 * NeteaseCloudMusicApiEnhanced 服务(加密/cookie/风控全在服务端处理)。
 *
 * 启用方式: 原生存储写入 ncm.remote = "http://<host>:3000"
 *   (默认指向本机局域网服务, 便于验证; 正式使用改为自建服务器地址)
 *
 * 接口约定与 provider/netease 完全一致: loginQr/loginCheck/search/songUrl/lyric
 */
(function () {
  'use strict';

  var B = window.AppBridge;
  var BASE_KEY = 'ncm.remote';
  var DEFAULT_BASE = 'http://10.42.0.1:3000'; // 电脑热点网关(局域网验证用)

  function base() {
    var v = B.storeGet(BASE_KEY);
    return (v && v.length > 4) ? v : DEFAULT_BASE;
  }

  async function get(path) {
    var r = await B.post(base() + path, {}, '');
    if (!r || r.status !== 200) throw new Error('HTTP ' + (r && r.status));
    try { return JSON.parse(r.body); } catch (e) { throw new Error('响应非 JSON'); }
  }

  var provider = {
    id: 'provider/remote',
    name: '远程API服务',

    async loginQr() {
      var d = await get('/login/qr/key');
      var unikey = d.data && d.data.unikey;
      return { unikey: unikey, qrurl: 'https://music.163.com/login?codekey=' + unikey };
    },

    async loginCheck(unikey) {
      var d = await get('/login/qr/check?key=' + unikey + '&type=3');
      return { code: d.code, message: d.message || '' };
    },

    isLoggedIn: function () {
      // 远程模式下登录态由服务端维护, App 端不做持久化判断
      return false;
    },

    logout: function () { /* 服务端维护, 无需操作 */ },

    async search(q, limit) {
      var d = await get('/cloudsearch?keywords=' + encodeURIComponent(q) + '&limit=' + (limit || 30));
      return (d.result && d.result.songs) || [];
    },

    async songUrl(id) {
      var d = await get('/song/url/v1?id=' + id + '&level=standard');
      var s = d.data && d.data[0];
      if (s && s.code !== 200) throw new Error('无播放地址(code ' + s.code + ')');
      return (s && s.url) || null;
    },

    async lyric(id) {
      var d = await get('/lyric?id=' + id);
      return (d.lrc && d.lrc.lyric) || '';
    },
  };

  window.App.providers['provider/remote'] = provider;
})();
