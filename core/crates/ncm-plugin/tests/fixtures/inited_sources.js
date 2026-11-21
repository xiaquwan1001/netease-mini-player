// 上游 LX 的握手: 脚本自己声明支持哪些平台(sources 的 key)。
// 宿主只把它当"展示/诊断"信息读出来, 不据此改路由判定。
lx.send(lx.EVENT_NAMES.inited, {
  status: true,
  openDevTools: false,
  sources: {
    wy: { name: '网易云', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k', 'flac'] },
    kw: { name: '酷我', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] },
    tx: { name: 'QQ', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k', 'flac'] },
  },
});

lx.on('musicUrl', async function () {
  return 'https://cdn.test/inited.mp3';
});
