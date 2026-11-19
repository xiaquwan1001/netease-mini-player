// 死循环: 预算生效前会一直占着 worker 线程(红相证据).
lx.on('musicUrl', () => {
  while (true) {}
});
