// 宿主注入给脚本的 lx 兼容层(契约 v1, 见 crates/ncm-plugin/README.md).
//
// 这个文件在脚本之前求值; 它**只**通过 __lxHost 暴露的三个原生函数回到宿主:
//   __lxHost.request(json)  -> json   (受控出站, 只能走宿主注入的 transport)
//   __lxHost.log(level, msg) -> undefined
//   __lxHost.storage(json)  -> json   (命名空间隔离的键值)
// 沙箱里没有 require / process / fetch / XMLHttpRequest / Deno(专项用例断言).
(function () {
  'use strict';

  var host = globalThis.__lxHost;
  delete globalThis.__lxHost;

  var handlers = Object.create(null);
  var sends = [];

  function stringify(value) {
    if (value === undefined) return 'null';
    return JSON.stringify(value);
  }

  // 宿主失败统一走 {"__error": "..."} 信封(宿主 native 不抛异常, 见 sandbox.rs 注释).
  function unwrap(raw) {
    var res = JSON.parse(raw);
    if (res && typeof res.__error === 'string') throw new Error(res.__error);
    return res;
  }

  function errorText(e) {
    if (e && typeof e.message !== 'undefined') return String(e.message);
    return String(e);
  }

  function log(level, args) {
    var parts = [];
    for (var i = 0; i < args.length; i++) {
      var a = args[i];
      parts.push(typeof a === 'string' ? a : stringify(a));
    }
    host.log(level, parts.join(' '));
  }

  // ---- lx.utils.crypto.md5: 纯 JS 实现(标准 MD5, 有测试向量), 只给脚本做签名/去重用 ----
  function utf8Bytes(s) {
    var out = [];
    for (var i = 0; i < s.length; i++) {
      var cp = s.codePointAt(i);
      if (cp > 0xffff) i++;
      if (cp < 0x80) out.push(cp);
      else if (cp < 0x800) out.push(0xc0 | (cp >> 6), 0x80 | (cp & 63));
      else if (cp < 0x10000)
        out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      else
        out.push(
          0xf0 | (cp >> 18),
          0x80 | ((cp >> 12) & 63),
          0x80 | ((cp >> 6) & 63),
          0x80 | (cp & 63)
        );
    }
    return out;
  }

  function md5(input) {
    var bytes = utf8Bytes(String(input));
    var bitLen = bytes.length * 8;
    bytes.push(0x80);
    while (bytes.length % 64 !== 56) bytes.push(0);
    var lo = bitLen >>> 0;
    var hi = Math.floor(bitLen / 4294967296);
    bytes.push(lo & 255, (lo >>> 8) & 255, (lo >>> 16) & 255, (lo >>> 24) & 255);
    bytes.push(hi & 255, (hi >>> 8) & 255, (hi >>> 16) & 255, (hi >>> 24) & 255);

    var K = [];
    for (var k = 0; k < 64; k++) {
      K.push(Math.floor(Math.abs(Math.sin(k + 1)) * 4294967296) | 0);
    }
    var S = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
    var a0 = 0x67452301;
    var b0 = 0xefcdab89 | 0;
    var c0 = 0x98badcfe | 0;
    var d0 = 0x10325476;

    for (var off = 0; off < bytes.length; off += 64) {
      var M = [];
      for (var m = 0; m < 16; m++) {
        M.push(
          bytes[off + m * 4] |
            (bytes[off + m * 4 + 1] << 8) |
            (bytes[off + m * 4 + 2] << 16) |
            (bytes[off + m * 4 + 3] << 24)
        );
      }
      var A = a0;
      var B = b0;
      var C = c0;
      var D = d0;
      for (var i = 0; i < 64; i++) {
        var F;
        var g;
        if (i < 16) {
          F = (B & C) | (~B & D);
          g = i;
        } else if (i < 32) {
          F = (D & B) | (~D & C);
          g = (5 * i + 1) % 16;
        } else if (i < 48) {
          F = B ^ C ^ D;
          g = (3 * i + 5) % 16;
        } else {
          F = C ^ (B | ~D);
          g = (7 * i) % 16;
        }
        F = (F + A + K[i] + M[g]) | 0;
        A = D;
        D = C;
        C = B;
        var shift = S[(i >> 4) * 4 + (i % 4)];
        B = (B + ((F << shift) | (F >>> (32 - shift)))) | 0;
      }
      a0 = (a0 + A) | 0;
      b0 = (b0 + B) | 0;
      c0 = (c0 + C) | 0;
      d0 = (d0 + D) | 0;
    }

    function hex(x) {
      var s = '';
      for (var b = 0; b < 4; b++) {
        var v = (x >>> (b * 8)) & 255;
        s += (v < 16 ? '0' : '') + v.toString(16);
      }
      return s;
    }

    return hex(a0) + hex(b0) + hex(c0) + hex(d0);
  }

  // ---- 运行端信息(上游 LX 的 lx.env) ----
  // 宿主在建 Context 时注入字符串; 读到即删, 不给脚本留额外全局.
  var platform =
    typeof globalThis.__lxPlatform === 'string' ? globalThis.__lxPlatform : 'desktop';
  try {
    delete globalThis.__lxPlatform;
  } catch (e) {
    /* 删不掉也无害 */
  }

  // ---- 定时器: 只有 setTimeout/clearTimeout(无 setInterval), 由宿主泵循环推进 ----
  // 语义: 精度 = 泵周期; 不建定时线程; 一次调用结束即丢弃未到期任务.
  var timers = Object.create(null);
  var nextTimerId = 1;

  function addTimer(fn, delay, args) {
    var id = nextTimerId++;
    var ms = typeof delay === 'number' && isFinite(delay) && delay > 0 ? delay : 0;
    timers[id] = { due: Date.now() + ms, fn: fn, args: args };
    return id;
  }

  globalThis.setTimeout = function (fn, delay) {
    if (typeof fn !== 'function') return 0;
    return addTimer(fn, delay, Array.prototype.slice.call(arguments, 2));
  };

  globalThis.clearTimeout = function (id) {
    delete timers[id];
  };

  // 宿主泵循环调用: 触发所有到期任务, 返回 {fired, nextDelay}.
  // nextDelay = null 表示没有未到期任务; 有值 = 还要等这么多毫秒.
  globalThis.__lxPumpTimers = function () {
    var now = Date.now();
    var ids = Object.keys(timers);
    var fired = 0;
    var nextDelay = null;
    for (var i = 0; i < ids.length; i++) {
      var task = timers[ids[i]];
      if (!task) continue;
      if (task.due <= now) {
        delete timers[ids[i]];
        fired++;
        try {
          task.fn.apply(null, task.args);
        } catch (e) {
          log('error', 'setTimeout: ' + errorText(e));
        }
      } else {
        var delay = task.due - now;
        if (nextDelay === null || delay < nextDelay) nextDelay = delay;
      }
    }
    return stringify({ fired: fired, nextDelay: nextDelay });
  };

  // ---- 二进制编解码: lx.utils.buffer + 全局 btoa/atob(QuickJS 没有 Web 全局) ----
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function bytesToBase64(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
      var b0 = bytes[i] & 255;
      var has1 = i + 1 < bytes.length;
      var has2 = i + 2 < bytes.length;
      var b1 = has1 ? bytes[i + 1] & 255 : 0;
      var b2 = has2 ? bytes[i + 2] & 255 : 0;
      out += B64.charAt(b0 >> 2);
      out += B64.charAt(((b0 & 3) << 4) | (b1 >> 4));
      out += has1 ? B64.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '=';
      out += has2 ? B64.charAt(b2 & 63) : '=';
    }
    return out;
  }

  function base64ToBytes(text) {
    var clean = String(text).replace(/[^A-Za-z0-9+/=]/g, '');
    var out = [];
    for (var i = 0; i < clean.length; i += 4) {
      var c0 = B64.indexOf(clean.charAt(i));
      var c1 = B64.indexOf(clean.charAt(i + 1));
      var c2 = B64.indexOf(clean.charAt(i + 2));
      var c3 = B64.indexOf(clean.charAt(i + 3));
      if (c0 < 0) continue;
      out.push(((c0 << 2) | (c1 < 0 ? 0 : c1 >> 4)) & 255);
      if (c2 >= 0) out.push((((c1 & 15) << 4) | (c2 >> 2)) & 255);
      if (c3 >= 0) out.push((((c2 & 3) << 6) | c3) & 255);
    }
    return out;
  }

  function bytesToUtf8(bytes) {
    var out = '';
    var i = 0;
    while (i < bytes.length) {
      var b = bytes[i++] & 255;
      var cp;
      if (b < 0x80) cp = b;
      else if (b < 0xe0) cp = ((b & 31) << 6) | (bytes[i++] & 63);
      else if (b < 0xf0) cp = ((b & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
      else
        cp =
          ((b & 7) << 18) |
          ((bytes[i++] & 63) << 12) |
          ((bytes[i++] & 63) << 6) |
          (bytes[i++] & 63);
      out += String.fromCodePoint(cp);
    }
    return out;
  }

  function bytesToHex(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i++) {
      var v = bytes[i] & 255;
      s += (v < 16 ? '0' : '') + v.toString(16);
    }
    return s;
  }

  function hexToBytes(text) {
    var clean = String(text).replace(/[^0-9a-fA-F]/g, '');
    var out = [];
    for (var i = 0; i + 1 < clean.length; i += 2) {
      out.push(parseInt(clean.substr(i, 2), 16) & 255);
    }
    return out;
  }

  function latin1ToBytes(text) {
    var out = [];
    var s = String(text);
    for (var i = 0; i < s.length; i++) out.push(s.charCodeAt(i) & 255);
    return out;
  }

  function bytesToLatin1(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i] & 255);
    return out;
  }

  function normalizeEncoding(encoding) {
    var enc = String(encoding || 'utf-8').toLowerCase();
    if (enc === 'utf8' || enc === 'utf-8') return 'utf-8';
    if (enc === 'hex') return 'hex';
    if (enc === 'base64') return 'base64';
    if (enc === 'latin1' || enc === 'binary' || enc === 'ascii') return 'latin1';
    return 'utf-8';
  }

  // 接受 string / 字节数组 / Uint8Array / array-like, 统一成普通数字数组.
  function asBytes(value, encoding) {
    if (value === null || value === undefined) return [];
    if (typeof value === 'string') {
      var enc = normalizeEncoding(encoding);
      if (enc === 'base64') return base64ToBytes(value);
      if (enc === 'hex') return hexToBytes(value);
      if (enc === 'latin1') return latin1ToBytes(value);
      return utf8Bytes(value);
    }
    if (typeof value === 'number') return [value & 255];
    if (typeof value.length === 'number') {
      var out = [];
      for (var i = 0; i < value.length; i++) out.push(Number(value[i]) & 255);
      return out;
    }
    return utf8Bytes(String(value));
  }

  function makeBytes(list) {
    var arr = new Uint8Array(list.length);
    for (var i = 0; i < list.length; i++) arr[i] = list[i] & 255;
    return arr;
  }

  function encodeBytes(bytes, encoding) {
    var enc = normalizeEncoding(encoding);
    if (enc === 'base64') return bytesToBase64(bytes);
    if (enc === 'hex') return bytesToHex(bytes);
    if (enc === 'latin1') return bytesToLatin1(bytes);
    return bytesToUtf8(bytes);
  }

  globalThis.btoa = function (input) {
    return bytesToBase64(latin1ToBytes(String(input)));
  };

  globalThis.atob = function (input) {
    return bytesToLatin1(base64ToBytes(String(input)));
  };

  // ---- 上游 LX 的 request 事件 shaping ----
  // 回调式 lx.request 的响应形状对齐 axios/LX: headers 是普通对象(小写键), 带最终 URL.
  function lxResponse(res, fallbackUrl) {
    var headers = {};
    var list = res && res.headers ? res.headers : [];
    for (var i = 0; i < list.length; i++) {
      var pair = list[i];
      if (pair && pair.length === 2) headers[String(pair[0]).toLowerCase()] = pair[1];
    }
    var status = res && typeof res.status === 'number' ? res.status : 0;
    if (res && typeof res.statusCode === 'number') status = res.statusCode;
    return {
      statusCode: status,
      status: status,
      headers: headers,
      headersArray: list,
      body: res && res.body !== undefined ? res.body : '',
      url: (res && res.url) || fallbackUrl || '',
    };
  }

  // 脚本通过 send('inited', {sources}) 声明的平台能力(决定 request 事件的 source 代号).
  function initedSources() {
    for (var i = 0; i < sends.length; i++) {
      var entry = sends[i];
      if (entry && entry.name === 'inited' && entry.data && entry.data.sources) {
        return entry.data.sources;
      }
    }
    return null;
  }

  function pickSource(preferred) {
    var sources = initedSources();
    if (sources && typeof sources === 'object') {
      if (Object.prototype.hasOwnProperty.call(sources, 'wy')) return 'wy';
      var keys = Object.keys(sources);
      if (keys.length > 0) return keys[0];
    }
    if (preferred && preferred !== 'script') return String(preferred);
    return 'wy';
  }

  // 宿主调 musicUrl 而脚本只注册了 request 时, 翻译成上游形状:
  //   {source, action: 'musicUrl', info: {type, musicInfo}}
  function requestEventArg(sourceArg, info, quality) {
    var musicInfo = {};
    if (info && typeof info === 'object') {
      for (var key in info) {
        if (Object.prototype.hasOwnProperty.call(info, key)) musicInfo[key] = info[key];
      }
    }
    var source = pickSource(sourceArg);
    musicInfo.source = source;
    return { source: source, action: 'musicUrl', info: { type: quality, musicInfo: musicInfo } };
  }

  var lx = {
    EVENT_NAMES: {
      request: 'request',
      inited: 'inited',
      musicUrl: 'musicUrl',
      search: 'search',
      updateAlert: 'updateAlert',
    },
    // 运行端: 桌面(Linux/Windows) 与 Android 各报自己的形态.
    env: { platform: platform, env: platform },
    on: function (name, handler) {
      if (typeof name !== 'string') throw new TypeError('lx.on: event name must be a string');
      if (typeof handler !== 'function') throw new TypeError('lx.on: handler must be a function');
      handlers[name] = handler;
      return lx;
    },
    off: function (name) {
      delete handlers[name];
      return lx;
    },
    log: function () {
      log('log', Array.prototype.slice.call(arguments));
    },
    // 脚本向宿主上报(当前只在宿主侧留痕; 接 UI 是后续切片).
    send: function (name, data) {
      sends.push({ name: String(name), data: data === undefined ? null : data });
    },
    // 两种调用形态(同一实现):
    //   ① 宿主契约 v1: lx.request({url, method?, headers?, body?}) -> Promise<resp>
    //   ② 上游 LX: lx.request(url, options, callback) / lx.request({url,...}, callback)
    request: function (urlOrArgs, options, callback) {
      var cb = null;
      var opts = null;
      if (typeof options === 'function') cb = options;
      else if (options && typeof options === 'object') opts = options;
      if (typeof callback === 'function') cb = callback;

      var args;
      if (typeof urlOrArgs === 'string') {
        args = {};
        if (opts) {
          for (var key in opts) {
            if (Object.prototype.hasOwnProperty.call(opts, key)) args[key] = opts[key];
          }
        }
        args.url = urlOrArgs;
      } else {
        args = urlOrArgs;
      }

      var promise = new Promise(function (resolve, reject) {
        var res;
        try {
          res = unwrap(host.request(stringify(args)));
        } catch (e) {
          reject(e);
          return;
        }
        resolve(res);
      });
      if (typeof cb !== 'function') return promise;
      promise.then(
        function (res) {
          try {
            cb(null, lxResponse(res, args && args.url));
          } catch (e) {
            log('error', 'lx.request 回调抛错: ' + errorText(e));
          }
        },
        function (e) {
          try {
            cb(e, null);
          } catch (err) {
            log('error', 'lx.request 回调抛错: ' + errorText(err));
          }
        }
      );
      return undefined;
    },
    storage: {
      get: function (key) {
        return unwrap(host.storage(stringify({ op: 'get', key: String(key) }))).value;
      },
      set: function (key, value) {
        host.storage(stringify({ op: 'set', key: String(key), value: stringify(value) }));
      },
      remove: function (key) {
        host.storage(stringify({ op: 'remove', key: String(key) }));
      },
      keys: function () {
        return unwrap(host.storage(stringify({ op: 'keys' }))).keys;
      },
    },
    utils: {
      crypto: {
        md5: md5,
      },
      // Buffer 子集的纯 JS 实现(from/bufToString/toString/concat, utf-8/hex/base64/latin1).
      buffer: {
        from: function (value, encoding) {
          return makeBytes(asBytes(value, encoding));
        },
        bufToString: function (buf, encoding) {
          return encodeBytes(asBytes(buf), encoding);
        },
        toString: function (buf, encoding) {
          return encodeBytes(asBytes(buf), encoding);
        },
        concat: function (list) {
          var out = [];
          if (list && typeof list.length === 'number') {
            for (var i = 0; i < list.length; i++) {
              var part = asBytes(list[i]);
              for (var j = 0; j < part.length; j++) out.push(part[j]);
            }
          }
          return makeBytes(out);
        },
      },
      // 纯函数, 不碰宿主: 脚本常用的 JSON 往返.
      stringify: stringify,
      sleep: function () {
        throw new Error('lx.utils.sleep: 沙箱不支持挂起(同步宿主, 无事件循环定时器)');
      },
    },
  };

  globalThis.lx = lx;
  globalThis.console = {
    log: function () {
      log('log', Array.prototype.slice.call(arguments));
    },
    info: function () {
      log('info', Array.prototype.slice.call(arguments));
    },
    warn: function () {
      log('warn', Array.prototype.slice.call(arguments));
    },
    error: function () {
      log('error', Array.prototype.slice.call(arguments));
    },
    debug: function () {
      log('debug', Array.prototype.slice.call(arguments));
    },
  };

  // 宿主调用入口: 事件名 + 位置参数(JSON 数组).
  globalThis.__lxCall = function (event, argsJson) {
    var args = JSON.parse(argsJson);
    var handler = handlers[event];
    // 上游 LX 唯一入口是 on('request'); 宿主仍按契约 v1 发 musicUrl, 这里做一次翻译.
    if (typeof handler !== 'function' && event === 'musicUrl') {
      if (typeof handlers.request === 'function') {
        event = 'request';
        handler = handlers.request;
        args = [requestEventArg(args[0], args[1], args[2])];
      }
    }
    if (typeof handler !== 'function') return stringify({ status: 'missing' });
    var out;
    try {
      out = handler.apply(null, args);
    } catch (e) {
      return stringify({ status: 'error', error: errorText(e) });
    }
    if (out && typeof out.then === 'function') {
      globalThis.__lxSettled = { status: 'pending' };
      out.then(
        function (value) {
          globalThis.__lxSettled = { status: 'ok', value: value === undefined ? null : value };
        },
        function (e) {
          globalThis.__lxSettled = { status: 'error', error: errorText(e) };
        }
      );
      return stringify({ status: 'pending' });
    }
    return stringify({ status: 'ok', value: out === undefined ? null : out });
  };

  globalThis.__lxSettledJson = function () {
    return stringify(globalThis.__lxSettled || { status: 'pending' });
  };

  globalThis.__lxHandlerNames = function () {
    return stringify(Object.keys(handlers));
  };

  globalThis.__lxSends = function () {
    return stringify(sends);
  };
})();
