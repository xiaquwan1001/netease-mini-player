// setTimeout 只靠宿主泵循环推进: promise 由定时器 resolve(证明真会触发).
lx.on('musicUrl', function () {
  return new Promise(function (resolve) {
    setTimeout(function () {
      resolve('https://cdn.test/delayed.mp3');
    }, 30);
  });
});
