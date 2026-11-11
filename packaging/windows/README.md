# packaging/windows

Windows 安装包(Inno Setup)资产目录。

## ChineseSimplified.isl

安装向导简体中文语言包,由 `installer.iss` 的 `[Languages]` 以
`compiler:Languages\ChineseSimplified.isl` 引用;编译前
`.github/workflows/release.yml` 会把它拷进 Inno Setup 编译器的 `Languages\` 目录
(编译器目录已有该文件时跳过,不覆盖)。

- **来源**: <https://raw.githubusercontent.com/jrsoftware/issrc/is-7_1_1/Files/Languages/ChineseSimplified.isl>
  (jrsoftware/issrc tag `is-7_1_1`,发布于 2026-10-28;该语言文件自 Inno Setup 7.x 起从
  `Files/Languages/Unofficial/` 转正为官方内置,文件头标注 6.5.0+ 兼容)
- **为什么随包携带**: Chocolatey 的 `innosetup` 包当前仍是 **6.7.1**,其官方安装包
  **不包含** ChineseSimplified.isl(v0.3.1 的 Windows job 因此编译失败过);7.x 起才内置。
- **维护者/版权**: 翻译维护 Zhenghan Yang (Kira) <847320916@QQ.com>,
  <https://github.com/kira-96/Inno-Setup-Chinese-Simplified-Translation>;
  随 Inno Setup 仓库许可(见 issrc LICENSE)再分发。
- **校验**: UTF-8(CRLF、无 BOM),21516 字节;`[LangOptions]` 含
  `LanguageName=简体中文` / `LanguageID=$0804` / `LanguageCodePage=936`。
- **更新方法**: 换新 issrc tag 重新下载同名文件覆盖,并更新本节记录。
  本地 Windows 编译若无该文件,手动拷入 `<Inno Setup>\Languages\` 即可。
