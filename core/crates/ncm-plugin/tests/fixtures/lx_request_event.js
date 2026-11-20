// 上游 LX 形态的最小脚本切片(S1 HelloWorld 的三处致命差异都在这里):
//   ① 只注册 on('request') ② setTimeout/clearTimeout 包超时 ③ 回调式 lx.request(url, opts, cb)
// 顺带覆盖 lx.env / lx.utils.buffer / btoa+atob / send('inited', {sources}).
lx.send(lx.EVENT_NAMES.inited, {
  status: true,
  openDevTools: false,
  sources: { wy: { name: '网易云', type: 'music', actions: ['musicUrl'] } },
});

lx.on(lx.EVENT_NAMES.request, function (payload) {
  var source = payload.source;
  var action = payload.action;
  var info = payload.info || {};
  if (action !== 'musicUrl') return Promise.reject(new Error('action not supported: ' + action));
  var musicInfo = info.musicInfo || {};
  var b64 = lx.utils.buffer.bufToString(
    lx.utils.buffer.from(String(musicInfo.id), 'utf-8'),
    'base64'
  );
  return new Promise(function (resolve, reject) {
    var timer = setTimeout(function () {
      reject(new Error('upstream timeout'));
    }, 2000);
    lx.request(
      'https://example.test/api/song/url?id=' + musicInfo.id,
      {
        method: 'POST',
        headers: { 'X-Source': source },
        body:
          'quality=' +
          info.type +
          '&b64=' +
          b64 +
          '&env=' +
          lx.env.platform +
          '&roundtrip=' +
          atob(btoa('ok')),
      },
      function (err, resp) {
        clearTimeout(timer);
        if (err) return reject(err);
        if (resp.statusCode !== 200) return reject(new Error('upstream ' + resp.statusCode));
        var data = JSON.parse(resp.body);
        if (!data.url) return reject(new Error('no url'));
        resolve(data.url);
      }
    );
  });
});
