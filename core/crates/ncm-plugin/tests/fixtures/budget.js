lx.on('musicUrl', async () => {
  for (let i = 0; i < 4; i++) {
    await lx.request({ url: 'https://example.test/' + i });
  }
  return 'all-ok';
});
