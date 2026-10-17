/// The three things worth saying before the first jam.
///
/// Shown once per install and skippable from the first panel — this is a
/// courtesy, not a gate. It deliberately does **not** chain the permission
/// sheets behind it: those appear at the moment the permission is actually
/// needed (before hosting, before the first scan), where the ask makes sense.
///
/// Full-bleed raspberry→plum, white type, and the gradient's angle shifts
/// 12° per panel so swiping feels like turning something over in the light.
library;

import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/onboarding_prefs.dart';
import '../widgets/avatar.dart';

/// Every user-facing string on this screen, in one place.
abstract final class OnboardingStrings {
  static const String skip = 'Skip';
  static const String next = 'Next';
  static const String getStarted = 'Get started';

  static const String oneTitle = 'Everyone hears the same song.';
  static const String oneBody =
      'One phone plays. Everyone else listens on their own headphones, '
      'in sync.';

  static const String twoTitle = 'No internet. No accounts.';
  static const String twoBody = 'It all happens over your Wi-Fi or hotspot.';

  static const String threeTitle = 'It’s their queue too.';
  static const String threeBody =
      'Anyone you allow can add a track. Everyone sees who added what.';

  static String page(int index, int count) => 'Page ${index + 1} of $count';
  static const String logo = 'LocalJam';

  /// The made-up faces and tracks in the panel illustrations. Names, not
  /// data — nothing here reads a real room.
  ///
  /// Chosen so the four land on four different spokes of `JamAvatar`'s hue
  /// wheel — "Amber Fox" hashed to the same teal as "Silky Puffin", and two
  /// identical faces in a four-face cluster is the opposite of the point.
  static const List<String> demoPeople = [
    'Silky Puffin',
    'Neon Walrus',
    'Indigo Wren',
    'Quiet Moth',
  ];
  static const List<(String, String, String)> demoQueue = [
    ('Night Bus', 'Perla', 'Silky Puffin'),
    ('Slow Coast', 'Vega Sound', 'Neon Walrus'),
    ('Hotel Radio', 'Marée', 'Indigo Wren'),
  ];
  static const String addedBy = 'ADDED BY';
}

const String _logoAsset = 'assets/brand/logo.svg';

/// The gradient's starting angle, and how far it turns per panel.
const double _baseAngleDegrees = 135;
const double _angleStepDegrees = 12;

/// Content never grows past this, so a maximised desktop window shows a
/// column rather than a billboard.
const double _contentWidth = 480;

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, this.prefs, this.onDone});

  /// The flag to write when the intro is finished or skipped. Defaults to
  /// whatever [JamOnboarding] provides above this screen.
  final JamOnboardingPrefs? prefs;

  /// Called after the flag is written. The caller navigates — this screen
  /// knows nothing about routes.
  final VoidCallback? onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pages = PageController();

  /// Fractional page position, so the gradient turns *with* the swipe rather
  /// than snapping when it lands.
  double _position = 0;

  static const int _panelCount = 3;

  @override
  void initState() {
    super.initState();
    _pages.addListener(_onScroll);
  }

  void _onScroll() {
    final page = _pages.hasClients && _pages.position.haveDimensions
        ? _pages.page ?? 0
        : 0.0;
    if ((page - _position).abs() < 0.001) return;
    setState(() => _position = page);
  }

  @override
  void dispose() {
    _pages
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  int get _index => _position.round().clamp(0, _panelCount - 1);

  void _next() {
    if (_index >= _panelCount - 1) {
      unawaited(_finish());
      return;
    }
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    JamHaptics.skip();
    unawaited(
      _pages.animateToPage(
        _index + 1,
        duration: still ? JamDuration.instant : JamDuration.base,
        curve: JamCurve.base,
      ),
    );
  }

  Future<void> _finish() async {
    final prefs = widget.prefs ?? JamOnboarding.maybeOf(context);
    await prefs?.markSeen();
    widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    final last = _index == _panelCount - 1;
    final angle =
        (_baseAngleDegrees + _angleStepDegrees * _position) * math.pi / 180;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Raspberry→plum under both system bars, in either theme.
      value: jamOverlayStyleOnDark,
      child: Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-math.cos(angle), -math.sin(angle)),
              end: Alignment(math.cos(angle), math.sin(angle)),
              colors: const [JamColors.brandRaspberry, Color(0xFF2B1332)],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _contentWidth),
                child: Column(
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: JamSpace.sm,
                          vertical: JamSpace.sm,
                        ),
                        child: TextButton(
                          onPressed: () => unawaited(_finish()),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            minimumSize: const Size(64, 44),
                            textStyle: context.jamRowTitle,
                          ),
                          child: const Text(OnboardingStrings.skip),
                        ),
                      ),
                    ),
                    Expanded(
                      child: PageView(
                        controller: _pages,
                        children: const [
                          _PanelOne(),
                          _PanelTwo(),
                          _PanelThree(),
                        ],
                      ),
                    ),
                    // Left-aligned with the headline above it, on the same
                    // page margin. Centred dots under a left-aligned display
                    // line read as two unrelated layouts.
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: JamSpace.page,
                      ),
                      child: _Pager(index: _index, count: _panelCount),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        JamSpace.page,
                        JamSpace.xxl,
                        JamSpace.page,
                        JamSpace.xl,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: _WhiteButton(
                          label: last
                              ? OnboardingStrings.getStarted
                              : OnboardingStrings.next,
                          onPressed: _next,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The primary action, restated for a coloured ground: the raspberry
/// gradient of [JamButton] would vanish into the panel behind it, so this one
/// is white on the gradient instead.
class _WhiteButton extends StatelessWidget {
  const _WhiteButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: JamColors.light.textPrimary,
        textStyle: Theme.of(context).textTheme.labelLarge,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(JamRadius.md),
        ),
      ),
      child: Text(label),
    ),
  );
}

/// The 3-dot pager. Decorative — the panel count is announced on the panels
/// themselves.
class _Pager extends StatelessWidget {
  const _Pager({required this.index, required this.count});

  final int index;
  final int count;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: JamDuration.fast,
            curve: JamCurve.fast,
            margin: const EdgeInsets.only(right: JamSpace.sm),
            width: i == index ? 20 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: i == index ? 1 : 0.4),
              borderRadius: BorderRadius.circular(JamRadius.pill),
            ),
          ),
      ],
    ),
  );
}

/// The shared panel skeleton: an illustration, a headline, a sentence.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.art,
    required this.title,
    required this.body,
    required this.index,
  });

  final Widget art;
  final String title;
  final String body;
  final int index;

  @override
  Widget build(BuildContext context) => Semantics(
    label: OnboardingStrings.page(index, 3),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: JamSpace.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The art takes everything the words do not, and centres itself in
          // it. Centring the *whole column* instead left a dead 400 dp band
          // between a small illustration and the headline, because both
          // halves were pulled to the middle from opposite directions.
          Expanded(
            child: Center(
              child: FittedBox(fit: BoxFit.scaleDown, child: art),
            ),
          ),
          const SizedBox(height: JamSpace.xxl),
          Text(title, style: context.jamDisplay.copyWith(color: Colors.white)),
          const SizedBox(height: JamSpace.lg),
          Text(
            body,
            style: context.jamBody.copyWith(
              color: Colors.white.withValues(alpha: 0.86),
            ),
          ),
          const SizedBox(height: JamSpace.xl),
        ],
      ),
    ),
  );
}

class _PanelOne extends StatelessWidget {
  const _PanelOne();

  @override
  Widget build(BuildContext context) => _Panel(
    index: 0,
    art: SvgPicture.asset(
      _logoAsset,
      width: 96,
      height: 96,
      fit: BoxFit.contain,
      semanticsLabel: OnboardingStrings.logo,
      colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
    ),
    title: OnboardingStrings.oneTitle,
    body: OnboardingStrings.oneBody,
  );
}

class _PanelTwo extends StatelessWidget {
  const _PanelTwo();

  @override
  Widget build(BuildContext context) => _Panel(
    index: 1,
    art: const _PeopleCluster(),
    title: OnboardingStrings.twoTitle,
    body: OnboardingStrings.twoBody,
  );
}

class _PanelThree extends StatelessWidget {
  const _PanelThree();

  @override
  Widget build(BuildContext context) => _Panel(
    index: 2,
    art: const _QueueMock(),
    title: OnboardingStrings.threeTitle,
    body: OnboardingStrings.threeBody,
  );
}

/// Four faces, overlapped — the panel that says a jam is people.
///
/// Not [JamAvatarStack]: its separating ring is the page canvas, and the page
/// here is a gradient. Everything else is the app's own identity colouring,
/// which is the point: four translucent white discs on pink were one face
/// repeated, with the ring of each cutting through its neighbour's initials.
/// Real hues make them four people, and a ring in the gradient's own colour
/// separates them without drawing a second circle over the letters.
class _PeopleCluster extends StatelessWidget {
  const _PeopleCluster();

  static const double _size = 72;

  /// §4's overlap, restored. It was pulled back to 0.24 to stop the face in
  /// front crossing the *second* letter of the one behind it; at this size
  /// there is no second letter any more, so the group can close up and read
  /// as people standing together rather than as four discs in a row.
  static const double _overlap = 0.32;

  /// A wider ring than the 2 dp a list uses: at 72 dp a hairline between two
  /// saturated discs disappears, and the four ran into one shape.
  static const double _ring = 4;

  /// The gradient's colour where the cluster sits — the middle of panel two,
  /// which is most of the way from raspberry to plum. Sampled as a constant
  /// rather than read from the painter: the ring is standing in for the
  /// ground behind it, and the ground is a fixed two-stop gradient.
  static const Color _ground = Color(0xFF9B2A5C);

  @override
  Widget build(BuildContext context) {
    const names = OnboardingStrings.demoPeople;
    const step = _size * (1 - _overlap);
    return ExcludeSemantics(
      child: SizedBox(
        width: step * (names.length - 1) + _size,
        height: _size,
        child: Stack(
          children: [
            for (var i = 0; i < names.length; i++)
              Positioned(
                left: i * step,
                child: Container(
                  width: _size,
                  height: _size,
                  padding: const EdgeInsets.all(_ring),
                  decoration: const BoxDecoration(
                    color: _ground,
                    shape: BoxShape.circle,
                  ),
                  child: JamAvatar(
                    name: names[i],
                    size: _size - _ring * 2,
                    // One letter, not two: at this overlap the face in front
                    // ate the second initial of the one behind it, and "SP"
                    // under "NW" is not a name.
                    initials: identityInitials(names[i]).characters.first,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Three queue rows with a credit under each — the point of the panel is the
/// attribution, so the mock shows nothing else.
class _QueueMock extends StatelessWidget {
  const _QueueMock();

  static const double _mockWidth = 340;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    // A fixed width, because the panel scales the whole mock down on a short
    // window and a Row with an Expanded child cannot shrink-wrap.
    child: SizedBox(
      width: _mockWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (title, artist, who) in OnboardingStrings.demoQueue)
            Container(
              margin: const EdgeInsets.only(bottom: JamSpace.md),
              padding: const EdgeInsets.all(JamSpace.md),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(JamRadius.md),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.16),
                  width: 0.5,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(JamRadius.sm),
                    ),
                    child: Icon(
                      Icons.music_note_rounded,
                      size: 20,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(width: JamSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.jamRowTitle.copyWith(
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.jamFootnote.copyWith(
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: JamSpace.sm),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        OnboardingStrings.addedBy,
                        style: context.jamCaption.copyWith(
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                      ),
                      Text(
                        who.split(' ').first.toUpperCase(),
                        style: context.jamCaption.copyWith(color: Colors.white),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
