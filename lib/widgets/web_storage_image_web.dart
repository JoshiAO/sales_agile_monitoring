// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

Widget buildWebStorageImage({
  required String imageUrl,
  required BoxFit fit,
  double? width,
  double? height,
}) {
  return _WebStorageImage(
    imageUrl: imageUrl,
    fit: fit,
    width: width,
    height: height,
  );
}

class _WebStorageImage extends StatefulWidget {
  final String imageUrl;
  final BoxFit fit;
  final double? width;
  final double? height;

  const _WebStorageImage({
    required this.imageUrl,
    required this.fit,
    this.width,
    this.height,
  });

  @override
  State<_WebStorageImage> createState() => _WebStorageImageState();
}

class _WebStorageImageState extends State<_WebStorageImage> {
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _viewType =
        'web-storage-image-${widget.imageUrl.hashCode}-${DateTime.now().microsecondsSinceEpoch}';

    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final img = html.ImageElement()
        ..src = widget.imageUrl
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = _cssObjectFit(widget.fit)
        ..style.display = 'block';
      return img;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: HtmlElementView(viewType: _viewType),
    );
  }

  String _cssObjectFit(BoxFit fit) {
    switch (fit) {
      case BoxFit.fill:
        return 'fill';
      case BoxFit.contain:
        return 'contain';
      case BoxFit.cover:
        return 'cover';
      case BoxFit.fitWidth:
        return 'contain';
      case BoxFit.fitHeight:
        return 'contain';
      case BoxFit.none:
        return 'none';
      case BoxFit.scaleDown:
        return 'scale-down';
    }
  }
}
