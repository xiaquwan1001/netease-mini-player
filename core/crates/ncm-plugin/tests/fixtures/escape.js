lx.on('musicUrl', async () => ({
  require: typeof require,
  process: typeof process,
  fetch: typeof fetch,
  XMLHttpRequest: typeof XMLHttpRequest,
  Deno: typeof Deno,
  module: typeof module,
}));
