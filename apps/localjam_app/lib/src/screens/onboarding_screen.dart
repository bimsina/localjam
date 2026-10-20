/// "Welcome to LocalJam": the three things worth saying before the first
/// jam, and who you will be in it, on one page (DESIGN_SPEC v3 §6.9).
///
/// Typographic, not a template: the wordmark where Nearby's nav bar holds
/// it, a large Manrope headline, three short headlines with a sentence each
/// on the same edge — no glyph column — then, at the foot of the page, the
/// name the app made up for you with a way to change it, and **Continue**
/// exactly where Nearby's Start a Jam appears next. Shown once per install;
/// continuing *is* skipping — leaving the name alone keeps it. It
/// deliberately does not chain the permission sheets: those appear at the
/// moment the permission is actually needed (before hosting, before the
/// first scan), where the ask makes sense.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Scaffold, Theme;
import 'package:flutter/services.dart';
import 'package:localjam_client/localjam_client.dart' show JamIdentity;

import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/onboarding_prefs.dart';
import '../widgets/avatar.dart';
import '../widgets/buttons.dart';
import '../widgets/brand.dart';
import '../widgets/rename_dialog.dart';
import '../widgets/scaffold.dart' show jamBottomBarInset;

/// Every user-facing string on this screen, in one place.
abstract final class OnboardingStrings {
  static const String title = 'Your music.\nBetter together.';

  static const String continueLabel = 'Continue';

  /// One page, one way on: continuing is the skip. Kept as a name for the
  /// router's gate test, which only cares that the intro can be left.
  static const String skip = continueLabel;

  static const String oneTitle = 'Listen together';
  static const String oneBody =
      'One phone plays and everyone hears the same song at the same moment, '
      'on their own headphones.';

  static const String twoTitle = 'No internet, no accounts';
  static const String twoBody = 'It all happens over your Wi‑Fi or hotspot.';

  static const String threeTitle = 'Everyone adds songs';
  static const String threeBody =
      'Anyone you allow can add to the queue, and everyone sees who added '
      'what.';

  /// "You’ll appear as Sparkly Kiwi." — the generated name, said once
  /// before it shows up on someone else's screen.
  static const String appearAsLead = 'You’ll appear as ';
  static String appearAs(String name) => '$appearAsLead$name.';
  static const String change = 'Change';
  static const String changeName = 'Change your name';
}

/// Content never grows past this, so a maximised desktop window shows a
/// column rather than a billboard.
const double _contentWidth = 480;

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

  /// The display name in use; empty until the store has answered.
  String _identity = '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadIdentity());
    // A name adopted from the store after a prefs timeout replaces the
    // ephemeral one already on screen (see [JamIdentity.changes]).
    JamIdentity.changes.addListener(_onIdentityChanged);
  }

  @override
  void dispose() {
    JamIdentity.changes.removeListener(_onIdentityChanged);
    super.dispose();
  }

  void _onIdentityChanged() => unawaited(_loadIdentity());

  Future<void> _loadIdentity() async {
    final name = await JamIdentity.displayName();
    if (mounted && name != _identity) setState(() => _identity = name);
  }

  /// The same rename Settings offers, from the first page you see.
  Future<void> _rename() async {
    final name = await promptForName(context, current: _identity);
    if (name == null) return;
    final saved = await JamIdentity.setDisplayName(name);
    if (mounted) setState(() => _identity = saved);
  }

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
    // One leading edge — the page margin, Nearby's — for the wordmark, the
    // words and Continue, so nothing moves sideways when Continue hands
    // over to Nearby.
    final side = JamSpace.pageFor(width);

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: JamSpace.xxl),
        Semantics(
          header: true,
          child: Text(OnboardingStrings.title, style: context.jamLargeTitle),
        ),
        const SizedBox(height: JamSpace.huge),
        const _Feature(
          title: OnboardingStrings.oneTitle,
          body: OnboardingStrings.oneBody,
        ),
        const _Feature(
          title: OnboardingStrings.twoTitle,
          body: OnboardingStrings.twoBody,
        ),
        const _Feature(
          title: OnboardingStrings.threeTitle,
          body: OnboardingStrings.threeBody,
        ),
        // The room the page has left is deliberate: breathing space before
        // the one personal thing on it.
        const Spacer(),
        _IdentityRow(name: _identity, onChange: () => unawaited(_rename())),
        const SizedBox(height: JamSpace.sm),
      ],
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: jamOverlayStyle(brightness),
      child: Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _contentWidth),
              child: Column(
                children: [
                  // Where Nearby's nav bar holds it.
                  SizedBox(
                    height: JamMetrics.navBarHeight,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: side),
                      child: const Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: JamWordmark(),
                      ),
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        padding: EdgeInsets.symmetric(horizontal: side),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                          ),
                          child: IntrinsicHeight(child: content),
                        ),
                      ),
                    ),
                  ),
                  // Nearby's bottom bar geometry: Continue sits where Start
                  // a Jam appears next.
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      side,
                      JamSpace.lg,
                      side,
                      jamBottomBarInset(MediaQuery.paddingOf(context).bottom),
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

/// One feature: a Manrope headline and one sentence under it, on the page's
/// edge — a typographic list, not a column of glyphs.
class _Feature extends StatelessWidget {
  const _Feature({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: JamSpace.xxl),
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: context.jamTitle3),
            const SizedBox(height: JamSpace.xxs),
            Text(
              body,
              style: context.jamBody.copyWith(color: colors.secondaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}

/// "You’ll appear as / Sparkly Kiwi" with your face and **Change**, on a
/// card of its own — the name the app made up, said before it is on anyone
/// else's screen. Leaving it alone keeps it; Continue is still the one tap.
class _IdentityRow extends StatelessWidget {
  const _IdentityRow({required this.name, required this.onChange});

  /// Empty until the store has answered: the row keeps its place, unseen,
  /// so nothing shifts when the name arrives.
  final String name;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final known = name.isNotEmpty;
    // The same card a nearby jam sits on: the one object on this page that
    // is yours.
    final radius = BorderRadius.circular(JamRadius.section);
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.groupedSurface,
        border: Border.all(
          color: colors.separator,
          width: 1 / MediaQuery.devicePixelRatioOf(context),
        ),
        borderRadius: radius,
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          JamSpace.md,
          JamSpace.md,
          JamSpace.sm,
          JamSpace.md,
        ),
        child: Row(
          children: [
            if (known)
              JamAvatar(name: name, size: JamAvatarSize.sheet)
            else
              const SizedBox.square(dimension: JamAvatarSize.sheet),
            const SizedBox(width: JamSpace.md),
            Expanded(
              child: Semantics(
                label: OnboardingStrings.appearAs(name),
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      OnboardingStrings.appearAsLead.trim(),
                      style: context.jamFootnote.copyWith(
                        color: colors.secondaryLabel,
                      ),
                    ),
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.jamHeadline,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: JamSpace.sm),
            JamButton.plain(
              label: OnboardingStrings.change,
              semanticLabel: OnboardingStrings.changeName,
              size: JamButtonSize.small,
              onPressed: known ? onChange : null,
            ),
          ],
        ),
      ),
    );
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedOpacity(
      opacity: known ? 1 : 0,
      duration: reduceMotion ? Duration.zero : JamDuration.fast,
      curve: JamCurve.standard,
      child: ExcludeSemantics(excluding: !known, child: card),
    );
  }
}
