lx.on('musicUrl', async () => ({
  abc: lx.utils.crypto.md5('abc'),
  empty: lx.utils.crypto.md5(''),
}));
