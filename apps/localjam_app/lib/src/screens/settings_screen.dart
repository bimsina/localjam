/// Settings: who you are, how the app looks, and where it came from
/// (DESIGN_SPEC v3 §6.8).
///
/// iOS Settings, inset grouped on `groupedBackground`, no icon tiles. Room
/// behaviour (who may do what, the sound offset, diagnostics) belongs where
/// you can see its effect — in the jam — not in a global list.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show LicensePage, Theme, ThemeMode;
import 'package:flutter/services.dart';
import 'package:localjam_client/localjam_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../state/app_settings.dart';
import '../state/session_controller.dart';
import '../widgets/avatar.dart';
import '../widgets/list.dart';
import '../widgets/rename_dialog.dart';
import '../widgets/scaffold.dart';
import '../widgets/section.dart';

/// Every user-facing string on this screen, in one place.
abstract final class SettingsStrings {
  static const String title = 'Settings';

  static const String you = 'You';
  static const String howYouAppear = 'How you appear in jams';
  static const String loading = 'Loading…';
  static const String rename = 'Change your name';

  static const String appearance = 'Appearance';
  static const String system = 'System';
  static const String light = 'Light';
  static const String dark = 'Dark';
  static const String appearanceFooter =
      'System follows your device’s light or dark setting.';

  static const String about = 'About';
  static const String version = 'Version';
  static const String openSource = 'Source Code';
  static const String openSourceDetail = 'GitHub';
  static const String linkCopied = 'Link copied. Paste it in a browser.';

  /// American spelling, deliberately: the page's own title comes from
  /// `MaterialLocalizations` and says "Licenses".
  static const String licences = 'Licenses';
  static const String aboutFooter =
      'LocalJam is free and open source. It works over local Wi‑Fi, with no '
      'internet and no accounts.';
  static const String appName = 'LocalJam';
  static const String legalese =
      'Listen together, in sync, over local Wi‑Fi — no internet, no accounts.';
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
    // The prompt owns its own controller (see [promptForName]).
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

  /// The licence list, on the app's own canvas.
  ///
  /// Pushing the route by hand is what lets a [Theme] sit above
  /// [LicensePage]; the page title itself still comes from
  /// `MaterialLocalizations` and stays "Licenses".
  void _showLicences() {
    final theme = Theme.of(context);
    final colors = context.jamColors;
    unawaited(
      Navigator.of(context).push(
        CupertinoPageRoute<void>(
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
              applicationIcon: const _AppIcon(),
              applicationLegalese: SettingsStrings.legalese,
            ),
          ),
        ),
      ),
    );
  }

  static String _modeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => SettingsStrings.system,
    ThemeMode.light => SettingsStrings.light,
    ThemeMode.dark => SettingsStrings.dark,
  };

  @override
  Widget build(BuildContext context) {
    final settings = JamSettings.of(context);
    final width = MediaQuery.sizeOf(context).width;
    // A reading column on wide windows; sections bring their own margins.
    final side = width > JamContentWidth.reading
        ? (width - JamContentWidth.reading) / 2
        : 0.0;
    final name = _identity.isEmpty ? SettingsStrings.loading : _identity;

    return JamScaffold(
      title: SettingsStrings.title,
      grouped: true,
      contentPadding: EdgeInsets.fromLTRB(side, JamSpace.sm, side, 0),
      children: [
        JamSectionList(
          children: [
            JamSection(
              children: [
                JamRow(
                  leading: _identity.isEmpty
                      ? const SizedBox.square(dimension: JamAvatarSize.profile)
                      : JamAvatar(name: _identity, size: JamAvatarSize.profile),
                  leadingWidth: JamAvatarSize.profile,
                  title: name,
                  subtitle: SettingsStrings.howYouAppear,
                  chevron: true,
                  onTap: () => unawaited(_rename()),
                  semanticLabel:
                      '${SettingsStrings.you}: $name. '
                      '${SettingsStrings.rename}',
                ),
              ],
            ),
            JamSection(
              header: SettingsStrings.appearance,
              footer: SettingsStrings.appearanceFooter,
              children: [
                for (final mode in ThemeMode.values)
                  JamRow(
                    title: _modeLabel(mode),
                    checked: settings.themeMode == mode,
                    onTap: () {
                      if (settings.themeMode == mode) return;
                      JamHaptics.selection();
                      unawaited(settings.setThemeMode(mode));
                    },
                    semanticLabel:
                        '${SettingsStrings.appearance}: ${_modeLabel(mode)}',
                  ),
              ],
            ),
            JamSection(
              header: SettingsStrings.about,
              footer: SettingsStrings.aboutFooter,
              children: [
                JamRow(title: SettingsStrings.version, value: _version),
                JamRow(
                  title: SettingsStrings.openSource,
                  value: SettingsStrings.openSourceDetail,
                  chevron: true,
                  onTap: () => unawaited(_openRepository()),
                ),
                JamRow(
                  title: SettingsStrings.licences,
                  chevron: true,
                  onTap: _showLicences,
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// The app's own icon, for the licence page.
class _AppIcon extends StatelessWidget {
  const _AppIcon();

  static const double _size = 64;
  static const String _asset = 'assets/brand/icon_1024.png';

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(JamSpace.sm),
    child: ClipRRect(
      // The iOS icon squircle's radius at 64 pt.
      borderRadius: BorderRadius.circular(14),
      child: Image.asset(
        _asset,
        width: _size,
        height: _size,
        cacheWidth: 192,
        excludeFromSemantics: true,
      ),
    ),
  );
}
