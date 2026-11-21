// 上游 LX 歌词入口: 只注册 on('request'), action === 'lyric' 时返回 {lyric, tlyric}.
// 把宿主发来的 payload 原样回灌到请求体里, 用来锁 action/type/musicInfo 的口径
// (断言发出的是 action:'lyric' 而不是 musicUrl).
lx.send(lx.EVENT_NAMES.inited, {
  status: true,
  sources: { wy: { name: '网易云', type: 'music', actions: ['musicUrl', 'lyric'] } },
});

lx.on(lx.EVENT_NAMES.request, function (payload) {
  var action = payload.action;
  if (action !== 'lyric') return Promise.reject(new Error('action not supported: ' + action));
  var info = payload.info || {};
  var musicInfo = info.musicInfo || {};
  return lx.request({
    url: 'https://example.test/api/lyric?id=' + musicInfo.id,
    method: 'POST',
    body: JSON.stringify({
      source: payload.source,
      action: action,
      type: info.type,
      musicInfo: musicInfo,
    }),
  }).then(function (res) {
    return JSON.parse(res.body);
  });
});
