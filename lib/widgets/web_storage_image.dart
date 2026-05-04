import 'package:flutter/widgets.dart';

import 'web_storage_image_stub.dart'
    if (dart.library.html) 'web_storage_image_web.dart'
    as web_impl;

class WebStorageImage extends StatelessWidget {
  final String imageUrl;
  final BoxFit fit;
  final double? width;
  final double? height;

  const WebStorageImage({
    super.key,
    required this.imageUrl,
    required this.fit,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    return web_impl.buildWebStorageImage(
      imageUrl: imageUrl,
      fit: fit,
      width: width,
      height: height,
    );
  }
}
