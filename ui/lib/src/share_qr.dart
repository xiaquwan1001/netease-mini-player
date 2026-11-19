import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// 分享卡片里的二维码(动态 / 歌曲两处共用).
///
/// 两处原先是各写一份同样的 Container + QrImageView 参数表, 只有 data / size 不同,
/// 收成一处后口径只在这里维护:
/// - 二维码必须落在**白底**上, 深色卡片里直接画深色码会扫不出来;
/// - 眼(定位角)与数据模块统一方形 + 近黑 `#101114`, 缩到 70~90 逻辑像素仍可扫;
/// - `gapless: true` 去掉模块间细缝, 小尺寸下不会因抗锯齿糊成一片。
///
/// 调用方只决定 [data](官方网页链接)与 [size](动态卡片 76 / 歌曲卡片 84)。
class ShareQrCode extends StatelessWidget {
  const ShareQrCode({super.key, required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      child: QrImageView(
        data: data,
        version: QrVersions.auto,
        size: size,
        gapless: true,
        backgroundColor: Colors.white,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Color(0xFF101114),
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Color(0xFF101114),
        ),
      ),
    );
  }
}
