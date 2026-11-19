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

  var lx = {
    EVENT_NAMES: {
      request: 'request',
      inited: 'inited',
      musicUrl: 'musicUrl',
      search: 'search',
    },
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
    request: function (args) {
      return new Promise(function (resolve, reject) {
        var res;
        try {
          res = unwrap(host.request(stringify(args)));
        } catch (e) {
          reject(e);
          return;
        }
        resolve(res);
      });
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
    var handler = handlers[event];
    if (typeof handler !== 'function') return stringify({ status: 'missing' });
    var args = JSON.parse(argsJson);
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
