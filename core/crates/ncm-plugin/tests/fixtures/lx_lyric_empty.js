// 空 payload(对象里没有 lyric/tlyric)与空串: 都必须落 unsupported, 不能当成功.
lx.on(lx.EVENT_NAMES.request, function (payload) {
  if (payload.action !== 'lyric') return null;
  return { lyric: '', tlyric: '' };
});
