// 内存炸弹: 逐块分配约 2 MB, 总量远超 8 MB 预算.
lx.on('musicUrl', () => {
  const chunks = [];
  for (let i = 0; i < 64; i++) chunks.push(new Array(262144).fill(i));
  return { url: 'https://cdn.test/bomb.mp3' };
});
