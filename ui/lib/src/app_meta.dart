/// 应用元信息: 版本 / 仓库 / 许可, 供设置页「关于」分组等引用。
///
/// 项目未引入 package_info, 版本号由发布流程与 [kAppVersion] 手工同步
/// (对应 `ui/pubspec.yaml` 的 `version`)。
library;

/// 应用版本号, 与 `ui/pubspec.yaml` 的 `version` 保持一致。
const String kAppVersion = '0.7.0';

/// 项目 GitHub 仓库地址。
const String kGithubUrl = 'https://github.com/xiaquwan1001/netease-mini-player';

/// 许可摘要: 本项目 MIT; 内置 vendor 的 ncm-api 上游为 WTFPL。
const String kLicenseSummary = '本项目 MIT · vendor ncm-api 上游 WTFPL';
