/// Settings: identity, appearance, and where this app came from.
///
/// Deliberately short. Room behaviour (who may do what, the sync nudge)
/// belongs where you can see its effect — in the room — not in a global
/// settings list, so there are exactly three groups here and nothing else.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/app_settings.dart';
import '../state/session_controller.dart';
import '../widgets/avatar.dart';
import '../widgets/rename_dialog.dart';
import '../widgets/section.dart';

/// Every user-facing string on this screen, in one place.
abstract final class SettingsStrings {
  static const String title = 'Settings';

  static const String you = 'You';
  static const String howYouAppear = 'How you appear in rooms';
  static const String loading = 'Loading…';

  static const String appearance = 'Appearance';
  static const String system = 'Match my device';
  static const String light = 'Light';
  static const String dark = 'Dark';

  static const String about = 'About';
  static const String version = 'Version';
  static const String openSource = 'Open source';
  static const String openSourceDetail = 'github.com/bimsina/localjam';
  static const String linkCopied = 'Link copied. Paste it in a browser.';

  /// American spelling, deliberately: the page's own title comes from
  /// [MaterialLocalizations] and says "Licenses", and a row that says
  /// "Licences" opening a page that says "Licenses" reads as a typo.
  static const String licences = 'Licenses';
  static const String licencesDetail = 'The software this app is built on';
  static const String appName = 'LocalJam';
  static const String legalese =
      'Listen together, in sync, over local Wi-Fi — no internet, no accounts.';
}

/// The version to show before [PackageInfo] answers, and on a platform where
/// it cannot. Keep it in step with `pubspec.yaml`'s `version:` field.
const String kAppVersion = '1.0.0';

/// The shipped version, read from the build rather than from a constant
/// somebody has to remember to bump.
///
/// Falls back to [kAppVersion] on any platform that cannot answer, so the
/// About row never shows a blank or an error.
Future<String> jamAppVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.version.isEmpty ? kAppVersion : info.version;
  } catch (e) {
    debugPrint('localjam: could not read the package version: $e');
    return kAppVersion;
  }
}

/// Where the source lives.
const String kRepositoryUrl = 'https://github.com/bimsina/localjam';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _identity = '';
  String _version = kAppVersion;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_loadVersion());
    JamIdentity.changes.addListener(_onIdentityChanged);
  }

  @override
  void dispose() {
    JamIdentity.changes.removeListener(_onIdentityChanged);
    super.dispose();
  }

  /// A stored name adopted after a prefs timeout, replacing the ephemeral
  /// one this row is showing (see [JamIdentity.changes]).
  void _onIdentityChanged() => unawaited(_load());

  Future<void> _load() async {
    final name = await JamIdentity.displayName();
    if (mounted && name != _identity) setState(() => _identity = name);
  }

  Future<void> _loadVersion() async {
    final version = await jamAppVersion();
    if (mounted) setState(() => _version = version);
  }

  Future<void> _rename() async {
    // The prompt owns its own controller (see [promptForName]); the copy that
    // used to live here disposed one mid-exit-transition and red-screened.
    final name = await promptForName(context, current: _identity);
    if (name == null) return;
    await JamIdentity.setDisplayName(name);
    if (mounted) setState(() => _identity = name);
  }

  /// Opens the repository in a browser, and falls back to the clipboard.
  ///
  /// A device with no browser to hand the URL to is rare but real (a locked
  /// down Android build, a desktop with no default handler), and the address
  /// is short enough to paste — so the failure has an answer rather than a
  /// dead row.
  Future<void> _openRepository() async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(kRepositoryUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      debugPrint('localjam: could not open $kRepositoryUrl: $e');
    }
    if (opened || !mounted) return;
    await Clipboard.setData(const ClipboardData(text: kRepositoryUrl));
    if (!mounted) return;
    JamSession.read(context).notify(SettingsStrings.linkCopied);
  }

  /// The licence list, wearing the app's own clothes.
  ///
  /// `showLicensePage` on its own pushes a page with no icon, no name and the
  /// stock Material palette — a white screen in the middle of a cream app,
  /// which is where the review found it. Pushing the route by hand is what
  /// lets a [Theme] sit above [LicensePage]; the page title itself still
  /// comes from [MaterialLocalizations] and stays "Licenses".
  void _showLicences() {
    final theme = Theme.of(context);
    final colors = context.jamColors;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => Theme(
            data: theme.copyWith(
              scaffoldBackgroundColor: colors.background,
              canvasColor: colors.background,
              cardColor: colors.background,
              colorScheme: theme.colorScheme.copyWith(
                surface: colors.background,
              ),
            ),
            child: LicensePage(
              applicationName: SettingsStrings.appName,
              applicationVersion: _version,
              applicationIcon: const _AppMark(),
              applicationLegalese: SettingsStrings.legalese,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = JamSettings.of(context);
    final colors = context.jamColors;

    return Scaffold(
      // As on Home and Past jams: the title is a large one in the page, and
      // the bar carries only the way back (§3).
      appBar: AppBar(toolbarHeight: 56),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: JamContentWidth.reading,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                JamSpace.page,
                JamSpace.sm,
                JamSpace.page,
                JamSpace.huge,
              ),
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    SettingsStrings.title,
                    style: context.jamLargeTitle,
                  ),
                ),
                const SizedBox(height: JamSpace.xxl),
                JamSectionList(
                  children: [
                    JamSection(
                      header: SettingsStrings.you,
                      child: _Row(
                        onTap: () => unawaited(_rename()),
                        semanticLabel:
                            '${SettingsStrings.you}: '
                            '${_identity.isEmpty ? SettingsStrings.loading : _identity}. '
                            '${SettingsStrings.howYouAppear}',
                        leading: _identity.isEmpty
                            ? const SizedBox(
                                width: JamAvatarSize.profile,
                                height: JamAvatarSize.profile,
                              )
                            : JamAvatar(
                                name: _identity,
                                size: JamAvatarSize.profile,
                              ),
                        title: _identity.isEmpty
                            ? SettingsStrings.loading
                            : _identity,
                        detail: SettingsStrings.howYouAppear,
                        trailing: Icon(
                          Icons.chevron_right_rounded,
                          color: colors.tertiaryLabel,
                        ),
                      ),
                    ),
                    JamSection(
                      header: SettingsStrings.appearance,
                      children: [
                        for (final mode in ThemeMode.values)
                          _AppearanceRow(
                            mode: mode,
                            selected: settings.themeMode == mode,
                            onTap: () => unawaited(settings.setThemeMode(mode)),
                          ),
                      ],
                    ),
                    JamSection(
                      header: SettingsStrings.about,
                      children: [
                        _Row(
                          title: SettingsStrings.version,
                          trailing: Text(
                            _version,
                            style: context.jamNumeric.copyWith(
                              color: colors.secondaryLabel,
                            ),
                          ),
                        ),
                        _Row(
                          onTap: () => unawaited(_openRepository()),
                          title: SettingsStrings.openSource,
                          detail: SettingsStrings.openSourceDetail,
                          trailing: Icon(
                            Icons.open_in_new_rounded,
                            size: 18,
                            color: colors.tertiaryLabel,
                          ),
                        ),
                        _Row(
                          onTap: _showLicences,
                          title: SettingsStrings.licences,
                          detail: SettingsStrings.licencesDetail,
                          trailing: Icon(
                            Icons.chevron_right_rounded,
                            color: colors.tertiaryLabel,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The app's mark, for the licence page: the white logo knocked into a 64 dp
/// raspberry rounded square, the same shape the QR carries at its centre.
class _AppMark extends StatelessWidget {
  const _AppMark();

  static const double _size = 64;
  static const String _asset = 'assets/brand/logo.svg';

  @override
  Widget build(BuildContext context) => Container(
    width: _size,
    height: _size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: context.jamColors.tint,
      borderRadius: BorderRadius.circular(JamRadius.lg),
    ),
    child: SvgPicture.asset(
      _asset,
      width: _size * 0.5,
      height: _size * 0.5,
      fit: BoxFit.contain,
      colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
    ),
  );
}

/// One settings row. A hand-rolled row rather than a `ListTile` so the 56 dp
/// profile avatar and the 44×28 swatches sit at the same left margin as
/// everything else in the group.
class _Row extends StatelessWidget {
  const _Row({
    required this.title,
    this.detail,
    this.leading,
    this.trailing,
    this.onTap,
    this.semanticLabel,
    this.selected = false,
  });

  final String title;
  final String? detail;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final String? semanticLabel;

  /// Marks the row as the chosen one in a mutually exclusive group.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final detailText = detail;

    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: JamSpace.card,
        vertical: JamSpace.md,
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: JamSpace.md),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.jamHeadline,
                ),
                if (detailText != null) ...[
                  const SizedBox(height: JamSpace.xxs),
                  Text(
                    detailText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.jamFootnote.copyWith(
                      color: colors.secondaryLabel,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: JamSpace.md),
            trailing!,
          ],
        ],
      ),
    );

    final tap = onTap;
    final label = semanticLabel;
    final body = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: tap == null ? content : InkWell(onTap: tap, child: content),
    );
    return Semantics(
      button: tap != null,
      selected: selected ? true : null,
      inMutuallyExclusiveGroup: selected ? true : null,
      label: label,
      // Only collapse the row's own text into the label when there *is* one —
      // otherwise an unlabelled row would announce nothing at all.
      child: label == null ? body : ExcludeSemantics(child: body),
    );
  }
}

/// An appearance choice, previewed rather than described: the swatch is the
/// palette the app will actually be wearing.
class _AppearanceRow extends StatelessWidget {
  const _AppearanceRow({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final ThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  static String label(ThemeMode mode) => switch (mode) {
    ThemeMode.system => SettingsStrings.system,
    ThemeMode.light => SettingsStrings.light,
    ThemeMode.dark => SettingsStrings.dark,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return _Row(
      onTap: onTap,
      selected: selected,
      semanticLabel: '${SettingsStrings.appearance}: ${label(mode)}',
      leading: _ThemeSwatch(mode: mode),
      title: label(mode),
      trailing: selected
          ? Icon(Icons.check_circle_rounded, color: colors.tint)
          : Icon(
              Icons.circle_outlined,
              color: colors.tertiaryLabel.withValues(alpha: 0.6),
            ),
    );
  }
}

/// A 44×28 miniature of the app in that appearance: canvas, a surface card,
/// and the accent. "Match my device" shows both, split on the diagonal.
class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({required this.mode});

  final ThemeMode mode;

  static const double _width = 44;
  static const double _height = 28;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    return Container(
      width: _width,
      height: _height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(JamRadius.xs),
        border: Border.all(color: colors.separator, width: 0.5),
      ),
      child: switch (mode) {
        ThemeMode.light => const _SwatchFace(palette: JamColors.light),
        ThemeMode.dark => const _SwatchFace(palette: JamColors.dark),
        // In dark the plum half sat on a plum card and the split simply
        // vanished — the swatch read as one solid light rectangle. The two
        // canvases are drawn against each other and the diagonal is a real
        // line, so "both" survives either theme.
        ThemeMode.system => Stack(
          fit: StackFit.expand,
          children: [
            const _SwatchFace(palette: JamColors.light),
            const ClipPath(
              clipper: _DiagonalClipper(),
              child: _SwatchFace(palette: JamColors.dark),
            ),
            CustomPaint(painter: _DiagonalRule(color: colors.separator)),
          ],
        ),
      },
    );
  }
}

class _SwatchFace extends StatelessWidget {
  const _SwatchFace({required this.palette});

  final JamColors palette;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: palette.background,
    child: Padding(
      padding: const EdgeInsets.all(5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            width: 22,
            height: 5,
            decoration: BoxDecoration(
              color: palette.groupedSurface,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          Container(
            width: 14,
            height: 5,
            decoration: BoxDecoration(
              color: palette.tint,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The seam itself, so the split is legible even when the two canvases are
/// close to whatever they sit on.
class _DiagonalRule extends CustomPainter {
  const _DiagonalRule({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(0, size.height),
      Paint()
        ..color = color
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_DiagonalRule old) => old.color != color;
}

/// The bottom-right half, so a split swatch reads as "both".
class _DiagonalClipper extends CustomClipper<Path> {
  const _DiagonalClipper();

  @override
  Path getClip(Size size) => Path()
    ..moveTo(size.width, 0)
    ..lineTo(size.width, size.height)
    ..lineTo(0, size.height)
    ..close();

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
