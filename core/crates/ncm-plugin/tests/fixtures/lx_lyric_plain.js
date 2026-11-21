// 有的源只给一段原文(纯字符串): 宿主应把它当作 lrc, translated 为空.
lx.on(lx.EVENT_NAMES.request, function (payload) {
  if (payload.action !== 'lyric') return null;
  return '[00:01.00]一句原文\n[00:05.00]另一句\n';
});
