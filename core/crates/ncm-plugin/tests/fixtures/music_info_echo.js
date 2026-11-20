// 把宿主传进来的位置参数原样回灌到请求体里, 用来锁 musicInfo 的字段口径
// (SongUrlMeta -> LX 脚本期望的 name/singer/albumName/albumId/interval/songmid).
lx.on('musicUrl', async function (source, info, quality) {
  const res = await lx.request({
    url: 'https://example.test/api/echo',
    method: 'POST',
    body: JSON.stringify({ source: source, quality: quality, info: info }),
  });
  const data = JSON.parse(res.body);
  return data.url;
});
