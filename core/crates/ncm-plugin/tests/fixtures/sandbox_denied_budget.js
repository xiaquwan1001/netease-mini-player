// 沙箱自己能提前判死的请求(非 http(s) scheme)**不消耗** `lx.request` 预算。
//
// 与 `denied_budget.js` 成对: 白名单拒 = 计费(已经走到 transport),
// 沙箱前置拒 = 不计费(在计数自增之前就 return 了)。
// 预算设成 1 时, 若 file:// 那次也计费, 第二次合法请求就会撞上限而不是拿到 200。
lx.on('musicUrl', async () => {
  const out = [];
  try {
    await lx.request({ url: 'file:///etc/passwd' });
    out.push('LEAK');
  } catch (e) {
    out.push(String(e.message));
  }
  try {
    const res = await lx.request({ url: 'https://api.example.com/ok' });
    out.push('OK ' + res.status);
  } catch (e) {
    out.push(String(e.message));
  }
  return out;
});
