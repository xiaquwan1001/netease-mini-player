#!/usr/bin/env node
// LX 自定义音源脚本回归台:在 Node 里复刻 Melodia 的 LxShim + SandboxBridge,
// 用来在没有设备的情况下验证脚本能否通过 inited 校验、能否取到可访问的直链。
//
// 用法: node tools/lx-plugin-harness.mjs [脚本路径] [歌曲id] [音质]
//   默认: plugins/lx-music/ncm-wy.js  33894312  flac
// 环境变量: NCM_COOKIE='MUSIC_U=...; __csrf=...' —— 注入登录态后再测一次高音质

import fs from 'node:fs'
import vm from 'node:vm'
import crypto from 'node:crypto'
import path from 'node:path'

const scriptPath = process.argv[2] || 'plugins/lx-music/ncm-wy.js'
const songId = process.argv[3] || '33894312'
const quality = process.argv[4] || 'flac'

let src = fs.readFileSync(path.resolve(scriptPath), 'utf8')
if (process.env.NCM_COOKIE) {
  // 只在测试时注入 cookie,仓库里的脚本永远保持 USER_COOKIE = ''
  src = src.replace(/const USER_COOKIE = ''/, 'const USER_COOKIE = ' + JSON.stringify(process.env.NCM_COOKIE))
}

const events = []
let requestHandler = null
let pendingId = 0
const pending = new Map()

const sandbox = {
  console,
  setTimeout,
  clearTimeout,
  URL,
  JSON,
  Math,
  Date,
  Promise,
  encodeURIComponent,
  decodeURIComponent,
  String,
  Number,
  Object,
  Array,
  Error,
  Buffer,
}
sandbox.window = sandbox

sandbox.lx = {
  version: '2.0.0',
  env: 'mobile',
  currentScriptInfo: { name: '', description: '', version: '', author: '', rawScript: '' },
  EVENT_NAMES: { request: 'request', inited: 'inited', updateAlert: 'updateAlert' },
  request(url, opts, cb) {
    const id = ++pendingId
    pending.set(id, cb)
    const options = opts || {}
    const method = (options.method || 'GET').toUpperCase()
    const headers = options.headers || {}
    const body = typeof options.body === 'string' ? options.body : options.body ? JSON.stringify(options.body) : undefined
    ;(async () => {
      try {
        const res = await fetch(url, { method, headers, body: method === 'GET' ? undefined : body })
        const text = await res.text()
        pending.delete(id)
        // 对齐 Melodia:resp.body 已是解析后的对象,statusCode 来自宿主(宿主固定回 200)
        cb(null, { statusCode: 200, body: tryJson(text) }, tryJson(text))
      } catch (e) {
        pending.delete(id)
        cb(new Error(e.message || 'Network error'), null, null)
      }
    })()
    return () => pending.delete(id)
  },
  on(event, handler) {
    if (event === 'request') requestHandler = handler
    return Promise.resolve()
  },
  send(event, data) {
    events.push({ event, data })
    return Promise.resolve()
  },
  utils: {
    crypto: { md5: (s) => crypto.createHash('md5').update(String(s)).digest('hex') },
    buffer: { from: (d) => d, bufToString: (b) => String(b) },
  },
}

function tryJson(text) {
  const t = String(text).trim()
  if ((t.startsWith('{') && t.endsWith('}')) || (t.startsWith('[') && t.endsWith(']'))) {
    try { return JSON.parse(t) } catch (e) { /* 落到原文 */ }
  }
  return text
}

const ctx = vm.createContext(sandbox, { name: 'lx-sandbox' })
vm.runInContext(src, ctx, { filename: scriptPath })

const fails = []
const check = (ok, msg, extra) => {
  if (ok) console.log('  PASS ' + msg)
  else { fails.push(msg); console.log('  FAIL ' + msg + (extra ? ' -> ' + extra : '')) }
}

console.log('== 1. inited 握手(Melodia 用 sources 的 key 作为支持平台列表)')
const inited = events.find((e) => e.event === 'inited')
check(!!inited, 'inited 已发送')
check(!!(inited && inited.data && inited.data.status === true), 'status === true')
const sources = Object.keys((inited && inited.data && inited.data.sources) || {})
check(sources.includes('wy'), 'sources 含 wy', sources.join(','))

console.log('== 2. request 处理器注册')
check(typeof requestHandler === 'function', 'lx.on("request") 已注册')

console.log('== 3. 解析直链 id=' + songId + ' quality=' + quality)
const url = await new Promise((resolve, reject) => {
  const p = Promise.resolve(
    requestHandler({
      source: 'wy',
      action: 'musicUrl',
      info: { type: quality, musicInfo: { id: songId, songmid: songId, name: 'test', singer: '', albumName: '', interval: '00:00' } },
    })
  )
  p.then(resolve, reject)
}).catch((e) => { console.log('  解析异常: ' + e.message); return null })
check(typeof url === 'string' && /^https?:\/\//.test(url || ''), '返回 http(s) 直链', String(url).slice(0, 80))

console.log('== 4. 直链可访问(取前 1 字节)')
if (url) {
  const head = await fetch(url, { headers: { Range: 'bytes=0-1' }, redirect: 'follow' })
  const buf = Buffer.from(await head.arrayBuffer())
  check(head.status === 206 || head.status === 200, 'HTTP ' + head.status)
  check(buf.length > 0, '有音频字节返回(' + buf.length + 'B)')
}

console.log('== 5. 非法来源/动作必须拒绝')
let rejected = 0
for (const ev of [{ source: 'kg', action: 'musicUrl', info: {} }, { source: 'wy', action: 'lyric', info: {} }]) {
  try { await requestHandler(ev) } catch (e) { rejected++ }
}
check(rejected === 2, '两个非法请求都被拒绝')

console.log('== 6. 匿名 VIP 歌(347230/flac)只给试听片段,必须拒绝而不是返回 30s 片段')
let trialRejected = false
try {
  await requestHandler({ source: 'wy', action: 'musicUrl', info: { type: 'flac', musicInfo: { id: '347230' } } })
} catch (e) {
  trialRejected = /试听/.test(e.message)
}
check(trialRejected, '试听片段被识别并拒绝')

console.log('')
if (fails.length) {
  console.log('结果: FAIL (' + fails.length + ')')
  process.exit(1)
}
console.log('结果: PASS')
