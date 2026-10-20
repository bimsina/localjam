/// "Welcome to LocalJam": the three things worth saying before the first
/// jam, on one page (DESIGN_SPEC v3 §6.9).
///
/// Apple's welcome sheet: a large left-aligned title, three feature rows
/// (tint glyph, headline, one sentence), and **Continue** pinned at the
/// bottom. Shown once per install; continuing *is* skipping — there is
/// nothing behind it. It deliberately does not chain the permission sheets:
/// those appear at the moment the permission is actually needed (before
/// hosting, before the first scan), where the ask makes sense.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Scaffold, Theme;
import 'package:flutter/services.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/onboarding_prefs.dart';
import '../widgets/buttons.dart';
import '../widgets/brand.dart';

/// Every user-facing string on this screen, in one place.
abstract final class OnboardingStrings {
  static const String title = 'Your music.\nBetter together.';

  static const String continueLabel = 'Continue';

  /// One page, one way on: continuing is the skip. Kept as a name for the
  /// router's gate test, which only cares that the intro can be left.
  static const String skip = continueLabel;

  static const String oneTitle = 'Listen Together';
  static const String oneBody =
      'One phone plays and everyone hears the same song at the same moment, '
      'on their own headphones.';

  static const String twoTitle = 'No Internet, No Accounts';
  static const String twoBody = 'It all happens over your Wi‑Fi or hotspot.';

  static const String threeTitle = 'Everyone Adds Songs';
  static const String threeBody =
      'Anyone you allow can add to the queue, and everyone sees who added '
      'what.';
}

/// Content never grows past this, so a maximised desktop window shows a
/// column rather than a billboard.
const double _contentWidth = 480;

/// The title's distance from the safe area's top: a little lower than §6.9's
/// 60, as Apple's own welcome screens sit.
const double _titleTop = 48;

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, this.prefs, this.onDone});

  /// The flag to write when the intro is finished. Defaults to whatever
  /// [JamOnboarding] provides above this screen.
  final JamOnboardingPrefs? prefs;

  /// Called after the flag is written. The caller navigates — this screen
  /// knows nothing about routes.
  final VoidCallback? onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  /// Once continued, stays continued: the caller is navigating away.
  bool _finishing = false;

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    final prefs = widget.prefs ?? JamOnboarding.maybeOf(context);
    await prefs?.markSeen();
    widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final brightness = Theme.of(context).brightness;
    final width = MediaQuery.sizeOf(context).width;
    // One leading edge for the title, the feature glyphs and Continue —
    // Apple's welcome screens hold everything to a single margin.
    final side = JamSpace.pageFor(width) + JamSpace.lg;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: jamOverlayStyle(brightness),
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _contentWidth),
              child: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(side, _titleTop, side, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const JamWordmark(),
                          const SizedBox(height: JamSpace.huge),
                          Semantics(
                            header: true,
                            // Title 1, not Large Title: at 34 pt "Welcome to
                            // LocalJam" wrapped on a 402 pt iPhone and fit on
                            // Android, so the two looked different.
                            child: Text(
                              OnboardingStrings.title,
                              style: context.jamLargeTitle,
                            ),
                          ),
                          const SizedBox(height: JamSpace.huge),
                          const _Feature(
                            icon: CupertinoIcons.headphones,
                            title: OnboardingStrings.oneTitle,
                            body: OnboardingStrings.oneBody,
                          ),
                          const _Feature(
                            icon: CupertinoIcons.wifi,
                            title: OnboardingStrings.twoTitle,
                            body: OnboardingStrings.twoBody,
                          ),
                          const _Feature(
                            icon: CupertinoIcons.music_note_list,
                            title: OnboardingStrings.threeTitle,
                            body: OnboardingStrings.threeBody,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      side,
                      JamSpace.lg,
                      side,
                      JamSpace.lg,
                    ),
                    child: JamButton.filled(
                      label: OnboardingStrings.continueLabel,
                      expand: true,
                      onPressed: () => unawaited(_finish()),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One feature: a tint glyph, a headline and one sentence — drawn exactly as
/// the permission primers draw theirs (24 glyph in a 30 column, 12 to the
/// text), since a new user sees the two back to back.
class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  /// The glyph column, so every headline starts on the same line.
  static const double _iconBox = 30;
  static const double _iconSize = 24;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: JamSpace.xxl),
      child: MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _iconBox,
              // Leading-aligned in its column, so the glyph's edge is the
              // title's edge.
              child: Align(
                alignment: AlignmentDirectional.topStart,
                child: Icon(icon, size: _iconSize, color: colors.tint),
              ),
            ),
            const SizedBox(width: JamSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: context.jamHeadline),
                  const SizedBox(height: JamSpace.xxs),
                  Text(
                    body,
                    style: context.jamSubheadline.copyWith(
                      color: colors.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
