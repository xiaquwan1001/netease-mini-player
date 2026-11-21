// 取链"慢"脚本: 先在 worker 里忙 `BUSY_MS` 毫秒, 再打一次网络.
// 用途: 队列上界与同曲合并的判据(见 tests/worker_limits.rs); 忙等用 Date.now() 轮询,
// 与 `while(true){}` 不同 —— 它会在预算内自己结束.
lx.on('musicUrl', async (source, info, quality) => {
  const until = Date.now() + 250;
  while (Date.now() < until) {}
  const res = await lx.request({
    url: 'https://example.test/api/song/url?id=' + info.id,
    method: 'POST',
    body: 'level=' + quality,
  });
  return JSON.parse(res.body).url;
});
