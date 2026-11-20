// 白名单拒绝 vs `lx.request` 次数预算的交互(口径见 src/policy.rs 顶部「预算语义」).
//
// 三次请求, 全部把错误吞进数组里返回(宿主只需看返回的文案):
//   1) denied.test  —— 越界, 白名单拒
//   2) denied.test  —— 越界, 白名单拒
//   3) api.example.com —— 在白名单内, 但沙箱预算(测试里设成 2)已被前两次花掉, 必须先撞预算
// 若"被拒不计费", 第 3 次会真的出站, 用例随即失败。
lx.on('musicUrl', async () => {
  const urls = [
    'https://denied.test/1',
    'https://denied.test/2',
    'https://api.example.com/ok',
  ];
  const errors = [];
  for (const url of urls) {
    try {
      const res = await lx.request({ url: url });
      errors.push('OK ' + res.status);
    } catch (e) {
      errors.push(String(e.message));
    }
  }
  return errors;
});
