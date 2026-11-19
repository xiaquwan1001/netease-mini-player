lx.on('search', async (query) => {
  const res = await lx.request({
    url: 'https://example.test/api/search?q=' + encodeURIComponent(query.keywords),
  });
  const data = JSON.parse(res.body);
  return { songs: data.songs, total: data.total, hasMore: false };
});
