/**
 * app.js —— 轻音入口
 *
 * 职责: 视图切换 / 登录(官方网页通道) / 搜索 / 播放队列 / 播放器状态同步。
 * 所有业务走 provider 插件接口, 核心不绑定任何具体音乐源。
 *
 * 登录: 点击右上角徽标 → 原生打开官方网页登录页(零风控通道),
 *       登录后 MUSIC_U 存原生存储, __nativeEvent('loginStateChanged') 通知刷新。
 * 未登录也能搜索/播放(网页端形态匿名可用)。
 */
(function () {
  'use strict';

  var B = window.AppBridge;
  var providers = window.App.providers || {};
  var netease = providers['provider/netease'];
  var remote = providers['provider/remote'];
  // 插件路由: 配置了 ncm.remote 地址时走远程 API 插件, 否则网易云直连插件
  var activeProvider = (remote && B.storeGet('ncm.remote')) ? remote : netease;

  var $ = function (sel) { return document.querySelector(sel); };

  var state = {
    loggedIn: false,
    guest: false,   // 选了「先逛逛」: 免登录使用(匿名可用)
    queue: [],      // 当前搜索结果即播放队列
    index: -1,
  };

  /** 视图切换: 'login' | 'main' */
  function showView(name) {
    $('#view-login').classList.toggle('hidden', name !== 'login');
    $('#view-main').classList.toggle('hidden', name !== 'main');
  }

  function refreshLoginBadge() {
    state.loggedIn = activeProvider.isLoggedIn();
    $('#user-badge').textContent = state.loggedIn ? '✓' : '·';
    $('#user-badge').title = state.loggedIn ? '已登录, 点击退出' : '未登录, 点击登录';
    $('#view-login').classList.toggle('hidden', state.loggedIn || state.guest);
    $('#view-main').classList.toggle('hidden', !(state.loggedIn || state.guest));
  }

  // ================= 搜索 =================

  var searchTimer = null;
  $('#search-input').addEventListener('input', function (e) {
    clearTimeout(searchTimer);
    var q = e.target.value.trim();
    if (!q) return;
    searchTimer = setTimeout(function () { doSearch(q); }, 400);
  });

  async function doSearch(q) {
    var list = $('#search-result');
    list.innerHTML = '<div class="tip">搜索中...</div>';
    try {
      var songs = await activeProvider.search(q, 30, 0);
      if (!songs || !songs.length) {
        list.innerHTML = '<div class="tip">无结果</div>';
        return;
      }
      state.queue = songs;
      state.index = -1;
      list.innerHTML = '';
      songs.forEach(function (song, i) {
        var item = document.createElement('div');
        item.className = 'song-item';
        var artists = (song.ar || []).map(function (a) { return a.name; }).join('/');
        var album = (song.album && song.album.name) || '';
        item.innerHTML =
          '<div class="song-name"></div><div class="song-artist"></div>';
        item.children[0].textContent = song.name;
        item.children[1].textContent = artists + (album ? ' · ' + album : '');
        item.addEventListener('click', function () { playAt(i); });
        list.appendChild(item);
      });
    } catch (e) {
      list.innerHTML = '<div class="tip err">搜索失败: ' + e.message + '</div>';
    }
  }

  // ================= 播放 =================

  async function playAt(i) {
    var song = state.queue[i];
    if (!song) return;
    state.index = i;
    var meta = {
      title: song.name,
      artist: (song.ar || []).map(function (a) { return a.name; }).join('/'),
    };
    $('#mini-title').textContent = meta.title;
    $('#mini-artist').textContent = meta.artist;
    $('#mini-player').classList.remove('hidden');
    try {
      var url = await activeProvider.songUrl(song.id);
      if (!url) {
        B.toast('无播放地址(可能需VIP/版权受限)');
        return;
      }
      B.play(url, meta);
      $('#btn-toggle').textContent = '⏸';
    } catch (e) {
      B.toast('播放失败: ' + e.message);
    }
  }

  $('#btn-toggle').addEventListener('click', function () {
    var st = B.getState();
    if (st.state === 'playing') { B.pause(); $('#btn-toggle').textContent = '▶'; }
    else if (st.state === 'paused') { B.resume(); $('#btn-toggle').textContent = '⏸'; }
  });

  $('#btn-next').addEventListener('click', function () {
    if (state.index < state.queue.length - 1) playAt(state.index + 1);
    else B.toast('已是最后一首');
  });

  $('#btn-prev').addEventListener('click', function () {
    if (state.index > 0) playAt(state.index - 1);
  });

  // 原生事件
  window.__nativeEvent = function (type) {
    if (type === 'loginStateChanged') {
      // 网页登录页返回: 刷新登录态
      var was = state.loggedIn;
      refreshLoginBadge();
      if (state.loggedIn) {
        stopQrPolling();
        showView('main');
        if (!was) B.toast('登录成功');
      }
    } else if (type === 'ended') {
      if (state.index < state.queue.length - 1) {
        playAt(state.index + 1);
      } else {
        $('#btn-toggle').textContent = '▶';
      }
    }
  };

  // 播放器状态同步(按钮图标)
  setInterval(function () {
    var st = B.getState();
    if (st.state === 'playing') $('#btn-toggle').textContent = '⏸';
    else if (st.state === 'paused') $('#btn-toggle').textContent = '▶';
  }, 1000);

  // 用户徽标: 登录/退出
  $('#user-badge').addEventListener('click', function () {
    if (state.loggedIn) {
      activeProvider.logout();
      state.guest = false;
      refreshLoginBadge();
      B.toast('已退出登录');
      startQrLogin();   // 回到登录页并重新取二维码
    } else {
      B.loginWeb();   // 原生打开官方网页登录页
    }
  });

  // ================= 启动 =================

  // ================= 登录(自绘二维码, eapi 扫码接口) =================

  var qrTimer = null;
  var qrStarting = false;

  function qrStatus(text, cls) {
    var el = $('#qr-status');
    el.textContent = text;
    el.className = 'qr-status' + (cls ? ' ' + cls : '');
  }

  function stopQrPolling() {
    if (qrTimer) { clearInterval(qrTimer); qrTimer = null; }
  }

  function renderQr(text) {
    var box = $('#qr');
    box.innerHTML = '';
    if (typeof QRCode === 'undefined') {
      box.innerHTML = '<div class="tip err">二维码库未加载</div>';
      return;
    }
    var size = Math.floor(box.clientWidth) - 20;
    if (size < 120) size = 240;
    new QRCode(box, {
      text: text, width: size, height: size,
      colorDark: '#000000', colorLight: '#ffffff',
      correctLevel: QRCode.CorrectLevel.M,
    });
  }

  async function startQrLogin() {
    if (qrStarting) return;
    qrStarting = true;
    stopQrPolling();
    $('#qr').innerHTML = '<div class="tip">获取二维码…</div>';
    qrStatus('准备中…');
    try {
      var r = await activeProvider.loginQr();
      if (!r || !r.unikey) throw new Error('拿不到 unikey');
      renderQr(r.qrurl);
      qrStatus('用网易云音乐 App 扫码');
      pollQr(r.unikey);
    } catch (e) {
      B.log('[login] 取二维码失败: ' + e.message);
      $('#qr').innerHTML = '<div class="tip err">二维码获取失败</div>';
      qrStatus('获取失败: ' + e.message + '（可试官方网页登录）');
    } finally {
      qrStarting = false;
    }
  }

  function pollQr(unikey) {
    var started = Date.now();
    stopQrPolling();
    qrTimer = setInterval(async function () {
      // 二维码有效期约 5 分钟, 超时或视图已切走就停
      if (Date.now() - started > 5 * 60 * 1000 || $('#view-login').classList.contains('hidden')) {
        stopQrPolling();
        return;
      }
      try {
        var st = await activeProvider.loginCheck(unikey);
        if (st.code === 800) {
          stopQrPolling();
          qrStatus('二维码已过期, 正在刷新…');
          startQrLogin();
        } else if (st.code === 802) {
          qrStatus('已扫码, 请在手机上确认', 'confirm');
        } else if (st.code === 8821) {
          stopQrPolling();
          qrStatus('环境风险拦截(8821), 请改用官方网页登录', 'err');
          $('#qr').innerHTML = '<div class="tip err">此通道被风控拦截</div>';
          B.toast('扫码登录被风控拦截, 请点「官方网页登录」');
        } else if (st.code === 803) {
          stopQrPolling();
          qrStatus('登录成功', 'ok');
          state.loggedIn = true;
          refreshLoginBadge();
          showView('main');
          B.toast('登录成功');
        } else {
          qrStatus('用网易云音乐 App 扫码');
        }
      } catch (e) {
        B.log('[login] 轮询失败: ' + e.message);
      }
    }, 2000);
  }

  $('#btn-qr-refresh').addEventListener('click', function () { startQrLogin(); });

  $('#btn-web-login').addEventListener('click', function () {
    stopQrPolling();
    try { B.loginWeb(); } catch (e) { B.toast('打开登录页失败: ' + e.message); }
  });

  $('#btn-guest').addEventListener('click', function () {
    stopQrPolling();
    state.guest = true;   // 匿名可用: 直接进主视图
    refreshLoginBadge();
  });

  (function init() {
    refreshLoginBadge();
    // 未登录时自动开始扫码流程
    if (!state.loggedIn) startQrLogin();
  })();
})();
