/*!
 * @name NCM-WY 直连音源
 * @description 网易云官方接口直连(MiniNCM 协议实验台):注入 os=pc/appver 客户端身份,按 level+encodeType 取直链;填 cookie 可解锁高音质
 * @version 0.1.0
 * @author xuqianhui
 * @repository https://github.com/xuqianhui/netease-mini-player
 */

/*
 * LX Music 自定义音源脚本(Melodia 沙盒契约):
 *   - 沙盒只提供 lx.request(url, {method, headers, body}, cb) / lx.on('request') /
 *     lx.send(EVENT_NAMES.inited, {status, sources}) / lx.utils.crypto.md5
 *   - 没有 CryptoJS、没有 AES、没有 fetch,因此本脚本只用明文 /api 通道,不做 eapi/weapi 加密
 *   - 响应只有 statusCode + body,拿不到 Set-Cookie:登录态必须由用户自己填进 USER_COOKIE
 *
 * 与 Melodia 自带的网易云通道的差别(本脚本存在的意义):
 *   1. 身份用 os=pc / appver=3.0.6(官方 PC 客户端形态),不是 os=android / 9.0.90;
 *      缺 os/appver 会被静默封顶音质。
 *   2. 显式带 encodeType,避免 flac 请求被静默降级成 mp3 时客户端毫不知情。
 *   3. 可独立回归:同一份协议逻辑在 tools/lx-plugin-harness.mjs 里跑,不依赖 App。
 */

'use strict'

// ===== 用户可改 =====
// 登录后的 cookie,MUSIC_U + __csrf 即可;留空 = 匿名(只能拿到无版权限制曲目的 128k/免费音质)
const USER_COOKIE = ''
// 固定的伪设备指纹:同一台机器永远用同一个,换掉等于换会话(登录态与风控评级都会变)
const DEVICE_ID = '5a1b2c3d4e5f60718293a4b5c6d7e8f9'
// ===================

const SOURCE = 'wy'
const API = 'https://interface3.music.163.com/api/song/enhance/player/url/v1'
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

// LX 音质代号 -> 网易云 level;encodeType 与 level 必须一致,否则服务端可能静默降级
const QUALITY = {
  '128k': { level: 'standard', encodeType: 'mp3' },
  '320k': { level: 'exhigh', encodeType: 'mp3' },
  flac: { level: 'lossless', encodeType: 'flac' },
  flac24bit: { level: 'hires', encodeType: 'flac' },
}

// 直链有效期约 20 分钟,缓存 5 分钟足够避免同曲重复请求
const CACHE_TTL = 5 * 60 * 1000
const cache = new Map()

function identityCookie() {
  const parts = [
    'os=pc',
    'appver=3.0.6',
    'osver=10.0.19045',
    'deviceId=' + DEVICE_ID,
    'channel=netease',
  ]
  if (USER_COOKIE) parts.push(USER_COOKIE.replace(/;?\s*$/, ''))
  return parts.join('; ')
}

// lx.request 的回调版封装 -> Promise
function request(url, opts) {
  return new Promise((resolve, reject) => {
    lx.request(
      url,
      opts,
      (err, resp, body) => {
        if (err) return reject(err)
        resolve({ status: resp && resp.statusCode ? resp.statusCode : 0, body: body })
      }
    )
  })
}

async function fetchUrl(id, quality) {
  const q = QUALITY[quality] || QUALITY['128k']
  const payload = 'ids=%5B' + encodeURIComponent(String(id)) + '%5D'
    + '&level=' + q.level
    + '&encodeType=' + q.encodeType

  const res = await request(API, {
    method: 'POST',
    headers: {
      'User-Agent': UA,
      Referer: 'https://music.163.com/',
      'Content-Type': 'application/x-www-form-urlencoded',
      Cookie: identityCookie(),
    },
    body: payload,
  })

  if (res.status !== 200) throw new Error('HTTP ' + res.status)
  let json
  try {
    json = typeof res.body === 'string' ? JSON.parse(res.body) : res.body
  } catch (e) {
    throw new Error('响应非 JSON')
  }
  if (!json || json.code !== 200) throw new Error('code=' + (json && json.code))

  const item = json.data && json.data[0]
  if (!item) throw new Error('无 data')
  if (item.code && item.code !== 200) throw new Error('url code=' + item.code)
  // freeTrialInfo 非空 = 只拿到试听片段,不能当成正常直链返回,否则播放会在 30s 处截断
  if (item.freeTrialInfo) throw new Error('仅试听片段,需登录或换源')
  if (!item.url) throw new Error('url 为空(code=' + item.code + ')')

  return {
    url: item.url.replace(/^http:\/\//, 'https://'),
    type: item.type,
    br: item.br,
    size: item.size,
    level: item.level,
    requestedLevel: q.level,
  }
}

async function musicUrl(musicInfo, quality) {
  const id = musicInfo && (musicInfo.id || musicInfo.songmid)
  if (!id) throw new Error('缺少歌曲 id')
  const key = id + '@' + (quality || '128k')
  const hit = cache.get(key)
  if (hit && Date.now() - hit.at < CACHE_TTL) return hit.url

  const got = await fetchUrl(id, quality)
  // 服务端静默降级是很常见的坑:请求了 lossless 却回 exhigh,code 仍是 200。
  // 这里保留降级后的可播直链(比无声失败有用),但必须把差异打到日志里,不能装作没发生。
  if (got.level && got.level !== got.requestedLevel) {
    console.warn('[ncm-wy] 音质被降级: 请求 ' + got.requestedLevel + ' -> 实得 ' + got.level + ' (' + got.type + '/' + got.br + ')')
  }
  console.log('[ncm-wy] id=' + id + ' quality=' + quality + ' -> ' + got.type + '/' + got.br)
  cache.set(key, { at: Date.now(), url: got.url })
  return got.url
}

lx.on(lx.EVENT_NAMES.request, (event) => {
  if (!event || event.source !== SOURCE) {
    return Promise.reject(new Error('不支持的音源: ' + (event && event.source)))
  }
  if (event.action !== 'musicUrl') {
    return Promise.reject(new Error('不支持的动作: ' + event.action))
  }
  const info = event.info || {}
  return musicUrl(info.musicInfo, info.type)
})

lx.send(lx.EVENT_NAMES.inited, {
  status: true,
  openDevTools: false,
  sources: {
    wy: {
      name: '网易云音乐(直连)',
      type: 'music',
      actions: ['musicUrl'],
      qualitys: ['128k', '320k', 'flac', 'flac24bit'],
    },
  },
})
