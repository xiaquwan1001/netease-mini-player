/// 应用元信息: 版本 / 仓库 / 许可, 供设置页「关于」分组等引用。
///
/// 项目未引入 package_info, 版本号由发布流程与 [kAppVersion] 手工同步
/// (对应 `ui/pubspec.yaml` 的 `version`)。
library;

/// 应用版本号, 与 `ui/pubspec.yaml` 的 `version` 保持一致。
const String kAppVersion = '0.9.0';

/// 匿名诊断「一键提交」的上传端点(Cloudflare Worker 代理建 GitHub issue)。
///
/// **留空 = 未配置**: 设置 → 诊断与数据 里的「一键提交」显示为不可用, 只保留
/// 「生成匿名诊断包」本地落盘。部署步骤见 `tools/diag-worker/README.md`。
///
/// 安全口径: Worker 里只用 `wrangler secret put GH_TOKEN` 存 token(由用户部署时
/// 手动创建 fine-grained PAT, 只勾 Issues: write + 单仓库), 客户端与仓库都不含
/// 任何 token; 客户端只拿到一个匿名 URL。
const String kDiagUploadEndpoint = '';

/// 项目 GitHub 仓库地址。
const String kGithubUrl = 'https://github.com/xiaquwan1001/netease-mini-player';

/// 许可摘要: 本项目 MIT; 内置 vendor 的 ncm-api 上游为 WTFPL。
const String kLicenseSummary = '本项目 MIT · vendor ncm-api 上游 WTFPL';
