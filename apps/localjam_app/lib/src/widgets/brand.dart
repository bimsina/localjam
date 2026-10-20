import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../design/tokens.dart';
import '../design/typography.dart';

/// The same mark as the installed app, paired with its own display face.
class JamWordmark extends StatelessWidget {
  const JamWordmark({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'LocalJam',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SvgPicture.asset(
          'assets/brand/logo.svg',
          width: 24,
          height: 24,
          colorFilter: ColorFilter.mode(
            context.jamColors.tint,
            BlendMode.srcIn,
          ),
        ),
        const SizedBox(width: 8),
        Text('LocalJam', style: context.jamTitle3.copyWith(fontSize: 16)),
      ],
    ),
  );
}
