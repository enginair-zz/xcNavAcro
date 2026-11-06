import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Upside down paraglider. Takes its color and size from the surrounding [IconTheme], like an [Icon].
class AcroModeIcon extends StatelessWidget {
  const AcroModeIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final size = theme.size ?? 24;
    return SvgPicture.asset("assets/images/acro_mode.svg",
        width: size, height: size, colorFilter: ColorFilter.mode(theme.color ?? Colors.white, BlendMode.srcIn));
  }
}
