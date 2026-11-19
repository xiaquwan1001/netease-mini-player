// 形态参考 docs/archive/architecture-restart.md §6 的 lx.on('musicUrl') 示例;
// 位置参数 (source, musicInfo, quality) 沿用 Melodia 里已被实测过的调用形态.
lx.on('musicUrl', async (source, info, quality) => {
  lx.log('resolve', source, info.id, quality);
  const res = await lx.request({
    url: 'https://example.test/api/song/url?id=' + info.id,
    method: 'POST',
    headers: { 'User-Agent': 'minincm-plugin/1' },
    body: 'level=' + quality,
  });
  if (res.status !== 200) throw new Error('upstream ' + res.status);
  const data = JSON.parse(res.body);
  if (!data.url) return null;
  return { url: data.url, type: 'mp3', br: data.br, expireAt: Date.now() + 300000 };
});
