// 只挂定时器不 settle: 必须被调用预算(而不是 idle 判定)截断.
lx.on('musicUrl', function () {
  return new Promise(function () {
    setTimeout(function () {
      lx.log('late');
    }, 60000);
  });
});
