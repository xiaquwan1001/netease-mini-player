lx.on('musicUrl', async (source, info) => {
  if (info.write !== undefined) {
    lx.storage.set('k', info.write);
    return { ok: true };
  }
  return { value: lx.storage.get('k'), keys: lx.storage.keys() };
});
