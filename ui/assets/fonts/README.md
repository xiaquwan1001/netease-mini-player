# ui/assets/fonts

这里是**只在 arm64 Linux 上生效**的 CJK 兜底字体(2026-11-23)。

## 为什么需要它

Flutter 官方发布的 **linux-arm64 桌面引擎没有链 `libfontconfig.so.1`**(实测:
`readelf -d libflutter_linux_gtk.so | grep fontconfig` 无输出, x64 引擎有),
所以引擎拿不到系统字体链 ⇒ **CJK 字形全部渲染为空**(ASCII 正常, 中文一片空白)。
这不是本项目的问题:同一台平板上 Bettbox(也是 Flutter)表现完全一样;
上游 issue: <https://github.com/flutter/flutter/issues/90951>、
<https://github.com/localsend/localsend/issues/3194>;
上游修复 PR <https://github.com/flutter/flutter/pull/180235>(需要重新构建引擎)。

## 我们怎么绕

把一份**随包分发的"拉丁 + CJK"字体**注册成 Flutter 字体家族(`MiniNcmCjk`), 再在
`src/platform_font.dart` 里**仅当 `Platform.isLinux && Abi.current() == Abi.linuxArm64`**
时把它设为 `ThemeData.fontFamily`(主字体, fallback 只是防御)。

**主字体而不是纯 fallback**: 引擎拿不到系统字体时默认字体本身解析不出来, 所以
只挂 fallback 会出现「中文能出、拉丁变豆腐块」的混合症状(实测: 顶栏「私人FM」的
`FM` 是 □□, 因为纯 CJK 兜底字体不含拉丁)。主字体同时覆盖拉丁 + CJK 才干净。

这样:

- arm64 Linux:引擎自己加载 asset 字体(不走 fontconfig),中文正常显示;
- x64 Linux / Android / Windows:行为完全不变(仍用系统字体,包体只在
  desktop bundle 里多 3.9 MB,金标与 grep 断言不受影响)。

引擎上游修好后,删掉 `platform_font.dart` 的分支与本目录即可(字体留着也无害)。

## 字体与许可

`WenQuanYiMicroHei.ttf` —— 文泉驿微米黑(WenQuanYi Micro Hei 0.2.0-beta),
从 Debian/Ubuntu 的 `fonts-wqy-microhei` 包的 `wqy-microhei.ttc` 里抽出第 0 号字面
(用 fontTools 存成单字面 ttf, 免得 Flutter 对 .ttc 支持不稳)。

- 版权: Digitized data copyright © 2007 Google Corporation;
  Copyright © 2008-2009 WenQuanYi Board of Trustees (http://wenq.org/) and Qianqian Fang
- 许可: **Apache License 2.0**(http://www.apache.org/licenses/LICENSE-2.0) —— 可随应用再分发,
  需保留上面的版权声明(即本文件)。

选它的理由: **同时覆盖拉丁与 CJK**(这是主字体方案的前提), 34,600 字形, 只有 4.5 MB
(Noto Sans CJK 单字重 ~10 MB+, Droid Sans Fallback 只含 CJK 且无拉丁)。
