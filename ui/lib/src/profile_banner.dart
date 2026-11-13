import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'adaptive_text.dart';
import 'cover_art.dart';

/// 背景横幅高度: 艺人页 / 他人主页 / 「我的」页共用同一个值(不再各写 120/130/170).
const double kProfileBannerHeight = 220;

/// 身份卡(头像 + 名字 + 别名/签名)相对横幅上浮的距离 —— 让 surface 卡片"贴"在
/// 图片下沿上, 有层次但**不压图**.
const double kProfileIdentityLift = 12;

/// 背景横幅(纯图片区): 取图按真实像素矩形 + 清晰度档位, 点击看全屏原图.
///
/// 为什么不直接用 NetImage: 之前三处横幅都是 `NetImage(width: infinity, height: 170)`,
/// imageCandidates 丢掉非有限宽度后只剩 `param=170y170` —— 一张 170px 的方图被放大
/// 铺满 1080x510 物理像素, 糊成一片. 这里用 LayoutBuilder 拿到真实逻辑宽高,
/// 交给 [NetImage.useQualityTier] 按「逻辑尺寸 x DPR x 档位」求矩形 param.
class ProfileBannerImage extends StatelessWidget {
  const ProfileBannerImage({
    super.key,
    this.url,
    this.height = kProfileBannerHeight,
    this.overlay,
    this.icon = Icons.image,
    this.showFullscreenHint = true,

    /// 看大图时的取图/保存实现可注入(测试用, 不联网不落盘)
    this.fetchOverride,
    this.saveOverride,
  });

  /// 原始直链(不带 param): 全屏查看 + 保存原图都用它
  final String? url;
  final double height;

  /// 右上角追加的操作(如「账号管理」药丸); 「全屏」提示固定在最右侧
  final Widget? overlay;
  final IconData icon;
  final bool showFullscreenHint;
  final Future<Uint8List> Function(String url)? fetchOverride;
  final Future<String> Function(Uint8List bytes, String filename)? saveOverride;

  String get _src => httpsImageUrl(url);

  bool get _hasImage => _src.isNotEmpty;

  Future<void> _openViewer(BuildContext context) async {
    if (!_hasImage) return;
    await showImageViewer(
      context,
      urls: [_src],
      fetchOverride: fetchOverride,
      saveOverride: saveOverride,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final placeholder = Container(
            color: scheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: Icon(icon, size: 40, color: scheme.outline),
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              if (_hasImage)
                NetImage(
                  url: _src,
                  width: w.isFinite && w > 0 ? w : null,
                  height: height,
                  fit: BoxFit.cover,
                  useQualityTier: true,
                  icon: icon,
                  placeholder: placeholder,
                )
              else
                placeholder,
              // 底部轻渐变: 折叠时顶栏图标仍能读出边界(文字已移到图片下方卡片,
              // 不再靠渐变撑可读性)
              const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black26],
                      stops: [0.55, 1],
                    ),
                  ),
                ),
              ),
              // 点图 = 看全屏原图 + 保存原图
              if (_hasImage)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openViewer(context),
                  ),
                ),
              Positioned(
                top: 8,
                right: 8,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (overlay != null) ...[
                      overlay!,
                      const SizedBox(width: 6),
                    ],
                    if (_hasImage && showFullscreenHint)
                      const _FullscreenHint(),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 「全屏」提示: 「横幅能点开大图」此前毫无可发现性
class _FullscreenHint extends StatelessWidget {
  const _FullscreenHint();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '全屏查看',
      button: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.38),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.open_in_full, size: 13, color: Colors.white),
            SizedBox(width: 4),
            Text('全屏', style: TextStyle(color: Colors.white, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

/// 身份卡: 头像 + 名字(+VIP) + 别名/签名 + 可选附加行(footer, 如统计).
///
/// 关键改动: 文字**不再压在图片上** —— 之前白字直接叠在 170 高的横幅上, 背景稍亮
/// 就完全读不出来。现在落在 surface 卡片里, 颜色跟主题走(onSurface/淡色副标题)。
class ProfileIdentity extends StatelessWidget {
  const ProfileIdentity({
    super.key,
    required this.title,
    this.subtitle,
    this.avatarUrl,
    this.vip = false,
    this.avatarSize = 64,
    this.titleStyle,
    this.trailing,
    this.footer,
  });

  final String title;

  /// 别名/签名(为 null 或空则不占位)
  final String? subtitle;
  final String? avatarUrl;
  final bool vip;
  final double avatarSize;

  /// 主标题样式(艺人页用大一号的)
  final TextStyle? titleStyle;

  /// 名字右侧的追加操作(如关注按钮)
  final Widget? trailing;

  /// 卡片底部附加行(统计/等级等)
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sub = subtitle?.trim() ?? '';
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        // 淡阴影: 主题色相同(卡片内/页面底)时也能看出"这是浮在图上的一层"
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 12,
            offset: Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头像: 主题色描边圈(原来固定白边, 浅色主题下与卡片糊在一起)
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surfaceContainerHighest),
                ),
                child: CircleCover(
                  url: avatarUrl,
                  size: avatarSize,
                  icon: Icons.person,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          // 昵称/艺人名走统一长文字组件: 放不下才单向跑马灯(需求 5/9)。
                          child: AdaptiveText(
                            title,
                            style:
                                titleStyle ??
                                theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                        if (vip) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE0342C),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'VIP',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (sub.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          sub,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
          if (footer != null)
            Padding(padding: const EdgeInsets.only(top: 8), child: footer!),
        ],
      ),
    );
  }
}

/// 完整资料横幅 = 背景图(可点看全屏) + 身份卡(头像/名字/别名/签名/统计).
///
/// 艺人页因为横幅要挂在 SliverAppBar 的 flexibleSpace 里, 自己组合
/// [ProfileBannerImage] + [ProfileIdentity](身份卡放 body, 不跟着折叠被裁).
class ProfileBanner extends StatelessWidget {
  const ProfileBanner({
    super.key,
    required this.title,
    this.subtitle,
    this.avatarUrl,
    this.imageUrl,
    this.vip = false,
    this.avatarSize = 64,
    this.titleStyle,
    this.overlay,
    this.trailing,
    this.footer,
    this.height = kProfileBannerHeight,
    this.fetchOverride,
    this.saveOverride,
  });

  final String title;
  final String? subtitle;
  final String? avatarUrl;
  final String? imageUrl;
  final bool vip;
  final double avatarSize;
  final TextStyle? titleStyle;
  final Widget? overlay;
  final Widget? trailing;
  final Widget? footer;
  final double height;
  final Future<Uint8List> Function(String url)? fetchOverride;
  final Future<String> Function(Uint8List bytes, String filename)? saveOverride;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ProfileBannerImage(
          url: imageUrl,
          height: height,
          overlay: overlay,
          fetchOverride: fetchOverride,
          saveOverride: saveOverride,
        ),
        Transform.translate(
          offset: const Offset(0, -kProfileIdentityLift),
          child: ProfileIdentity(
            title: title,
            subtitle: subtitle,
            avatarUrl: avatarUrl,
            vip: vip,
            avatarSize: avatarSize,
            titleStyle: titleStyle,
            trailing: trailing,
            footer: footer,
          ),
        ),
        // 上浮留出的空档: 用身份卡同色补齐, 免得露出一条卡片底色
        Container(height: kProfileIdentityLift, color: scheme.surface),
      ],
    );
  }
}
