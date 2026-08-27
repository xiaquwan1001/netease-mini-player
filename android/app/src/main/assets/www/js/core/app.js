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
    queue: [],      // 当前搜索结果即播放队列
    index: -1,
  };

  function refreshLoginBadge() {
    state.loggedIn = activeProvider.isLoggedIn();
    $('#user-badge').textContent = state.loggedIn ? '✓' : '·';
    $('#user-badge').title = state.loggedIn ? '已登录, 点击退出' : '未登录, 点击登录';
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
      refreshLoginBadge();
      if (state.loggedIn) B.toast('登录成功');
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
      refreshLoginBadge();
      B.toast('已退出登录');
    } else {
      B.loginWeb();   // 原生打开官方网页登录页
    }
  });

  // ================= 启动 =================

  (function init() {
    // 匿名可用: 直接进主视图
    refreshLoginBadge();
  })();
})();
