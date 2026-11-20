// 落盘 storage 与请求预算共存: 先写一次 storage, 再连打 9 次请求(预算 8).
lx.on('musicUrl', async () => {
  lx.storage.set('hits', 1);
  for (let i = 0; i < 9; i++) {
    await lx.request({ url: 'https://example.test/' + i });
  }
  return 'never';
});
