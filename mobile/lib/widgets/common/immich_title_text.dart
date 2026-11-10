import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';

class ImmichTitleText extends StatelessWidget {
  final double fontSize;

  const ImmichTitleText({super.key, this.fontSize = 48});

  @override
  Widget build(BuildContext context) {
    return Image(
      // immich-sync fork
      image: AssetImage(context.isDarkTheme ? 'assets/mirrich-text-dark.png' : 'assets/mirrich-text-light.png'),
      width: fontSize * 4,
      filterQuality: FilterQuality.high,
      color: context.primaryColor,
    );
  }
}
