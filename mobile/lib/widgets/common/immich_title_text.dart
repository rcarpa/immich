import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';

class ImmichTitleText extends StatelessWidget {
  final double fontSize;
  final Color? color;

  const ImmichTitleText({super.key, this.fontSize = 48, this.color});

  @override
  Widget build(BuildContext context) {
    return Image(
      // immich-sync fork: the fork's own wordmark (§4.1).
      image: AssetImage(context.isDarkTheme ? 'assets/mirrich-text-dark.png' : 'assets/mirrich-text-light.png'),
      width: fontSize * 4,
      filterQuality: FilterQuality.high,
      color: context.primaryColor,
    );
  }
}
