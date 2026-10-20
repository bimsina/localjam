/// The LocalJam wordmark: the installed app's symbol beside its name.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../design/tokens.dart';
import '../design/typography.dart';

/// The symbol's edge in the wordmark: about 1.5× the word's cap height, so
/// the mark sits beside the name instead of overpowering it.
const double kJamWordmarkSymbol = 20;

/// The symbol and the name, in ink.
///
/// Manrope 18/700, tracked in a little, so it reads as a brand rather than
/// a toolbar label next to a 34 pt large title. Both parts are `label`:
/// raspberry is for what you can tap (D8), and the wordmark is not a
/// control.
class JamWordmark extends StatelessWidget {
  const JamWordmark({super.key});

  @override
  Widget build(BuildContext context) {
    final ink = context.jamColors.label;
    return Semantics(
      label: 'LocalJam',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SvgPicture.asset(
            'assets/brand/logo.svg',
            width: kJamWordmarkSymbol,
            height: kJamWordmarkSymbol,
            colorFilter: ColorFilter.mode(ink, BlendMode.srcIn),
          ),
          const SizedBox(width: 6),
          Text(
            'LocalJam',
            style: context.jamTitle3.copyWith(
              fontSize: 18,
              height: 22 / 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              color: ink,
            ),
          ),
        ],
      ),
    );
  }
}
