import 'package:flutter/material.dart';

class ImmichLogo extends StatelessWidget {
  final double size;
  final dynamic heroTag;

  const ImmichLogo({super.key, this.size = 100, this.heroTag});

  @override
  Widget build(BuildContext context) {
    return Image(
      // immich-sync fork: the fork's own mark (§4.1).
      image: const AssetImage('assets/mirrich-logo.png'),
      width: size,
      filterQuality: FilterQuality.high,
      isAntiAlias: true,
    );
  }
}
