# 第三方组件与许可(Third-Party Notices)

本项目自身代码以 [MIT](LICENSE) 发布。下面是随源码分发、或被打进构建产物的第三方组件的许可说明。

## 1. 网易云接口实现(Rust,vendored 源码)

| 组件 | 版本 / 来源 | 许可 | 说明 |
|---|---|---|---|
| `ncm-api-rs` | 0.1.0 · [SPlayer-Dev/ncm-api-rs](https://github.com/SPlayer-Dev/ncm-api-rs) · commit `133b65b` | **WTFPL** | 位于 `core/vendor/ncm-api`,本项目**有修改**(删除未接入的 endpoint、去 tokio、裁剪 `server` 特性),改动同样以 WTFPL 公开 |
| `api-enhanced` | [NeteaseCloudMusicApiEnhanced/api-enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced) | **MIT**(Copyright (c) 2013-2022 Binaryify) | 上述 Rust 实现的移植来源 |
| `NeteaseCloudMusicApi` | [Binaryify/NeteaseCloudMusicApi](https://github.com/Binaryify/NeteaseCloudMusicApi) | MIT 血统 | api-enhanced 的上游 JS 项目 |

WTFPL 与 MIT 均为宽松许可且互相兼容:允许使用、修改、再许可与商业分发,义务仅为保留版权与许可声明。

## 2. 运行期依赖

### Rust(`cargo metadata` 全量盘点,~310 个 crate)

| 许可 | 数量 | 代表 |
|---|---|---|
| MIT OR Apache-2.0(含等价写法) | ~200 | `reqwest` `serde` `tokio` `rustls` 等 |
| MIT(单一) | ~50 | `flutter_rust_bridge` 生态等 |
| **MPL-2.0** | 16 | `symphonia` 全家(Linux 解码链) |
| Unicode-3.0 | 18 | `icu_*`(经 `url`/`idna` 引入) |
| BSD-3-Clause | 1 | `subtle` |
| CDLA-Permissive-2.0 | 1 | `webpki-roots`(根证书数据) |
| Zlib / ISC / 0BSD / Unlicense | 若干 | 均为宽松许可 |
| WTFPL | 1 | 见上表 `ncm-api-rs` |

- **MPL-2.0(symphonia)**:文件级弱 copyleft,仅在**修改了它自己的源文件**时才需要公开对应文件;
  本项目未修改 symphonia 源码,只做链接与打包。
- `r-efi` 标称 `MIT OR Apache-2.0 OR LGPL-2.1-or-later`,本项目使用 MIT/Apache 分支。
- `allo-isolate` 的 `Cargo.toml` 把 `license` 字段误写成占位串 `L,I,C,E,N,S,E`;
  其仓库实际为 MIT,任何自动审计工具报错属误报。
- 各 crate 的完整许可文本随 crate 源码分发(见 `~/.cargo/registry/src/*/<name>-<ver>/LICENSE*`)。

### Dart / Flutter

| 组件 | 许可 |
|---|---|
| Flutter SDK、`flutter_rust_bridge` | BSD-3-Clause / MIT |
| `cupertino_icons` | MIT |
| `qr_flutter`、`qr`(分享卡片二维码) | BSD-3-Clause |
| `material_color_utilities` | Apache-2.0 |

### Android

| 组件 | 许可 |
|---|---|
| AndroidX Media3(`media3-exoplayer` / `media3-session` / `media3-datasource`) | Apache-2.0 |
| androidx.core | Apache-2.0 |

## 3. 附:关键许可全文

### WTFPL(ncm-api-rs)

```text
        DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
                Version 2, December 2004

 Copyright (C) 2004 Sam Hocevar <sam@hocevar.net>

 Everyone is permitted to copy and distribute verbatim or modified
 copies of this license document, and changing it is allowed as long
 as the name is changed.

        DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION

  0. You just DO WHAT THE FUCK YOU WANT TO.
```

### MIT(api-enhanced / Binaryify)

```text
The MIT License (MIT)

Copyright (c) 2013-2022 Binaryify

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

### BSD-3-Clause(qr_flutter)

```text
BSD 3-Clause License

Copyright (c) 2020, QR.Flutter
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

Apache-2.0 与 MPL-2.0 全文见 <https://www.apache.org/licenses/LICENSE-2.0>
与 <https://mozilla.org/MPL/2.0/>。
