/// Licenses, the iOS way (DESIGN_SPEC v3 §6.8, D2): a grouped list of the
/// packages the app ships, each opening its licence text — in place of
/// Material's `LicensePage`, whose app bar, cards and ink were the last
/// Material chrome in the app.
///
/// The text comes from the same [LicenseRegistry] `LicensePage` reads, so
/// nothing a licence requires to be shown goes missing.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

import '../design/breakpoints.dart';
import '../design/tokens.dart';
import '../design/typography.dart';
import '../widgets/list.dart';
import '../widgets/progress.dart';
import '../widgets/scaffold.dart';
import '../widgets/section.dart';

/// Everything these pages say.
abstract final class LicensesStrings {
  static const String title = 'Licenses';
  static const String settings = 'Settings';
  static const String packages = 'Open-Source Software';
  static String count(int n) => n == 1 ? '1 license' : '$n licenses';
}

/// The registry, grouped by package (sorted, case-insensitively).
Future<List<({String package, List<LicenseEntry> entries})>>
jamLicensesByPackage() async {
  final byPackage = <String, List<LicenseEntry>>{};
  await for (final entry in LicenseRegistry.licenses) {
    for (final package in entry.packages) {
      (byPackage[package] ??= <LicenseEntry>[]).add(entry);
    }
  }
  final names = byPackage.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [for (final name in names) (package: name, entries: byPackage[name]!)];
}

/// The list of packages, under the app's own name, version and line.
class JamLicensesScreen extends StatefulWidget {
  const JamLicensesScreen({
    super.key,
    required this.applicationName,
    required this.applicationVersion,
    this.applicationIcon,
    this.applicationLegalese,
  });

  final String applicationName;
  final String applicationVersion;
  final Widget? applicationIcon;
  final String? applicationLegalese;

  @override
  State<JamLicensesScreen> createState() => _JamLicensesScreenState();
}

class _JamLicensesScreenState extends State<JamLicensesScreen> {
  List<({String package, List<LicenseEntry> entries})>? _packages;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final packages = await jamLicensesByPackage();
    if (mounted) setState(() => _packages = packages);
  }

  void _open(String package, List<LicenseEntry> entries) => unawaited(
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => _LicenseDetail(package: package, entries: entries),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final packages = _packages;
    final legalese = widget.applicationLegalese;
    return JamScaffold(
      title: LicensesStrings.title,
      previousPageTitle: LicensesStrings.settings,
      grouped: true,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: JamContentWidth.reading,
            ),
            child: Padding(
              padding: const EdgeInsets.only(top: JamSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    children: [
                      if (widget.applicationIcon != null)
                        widget.applicationIcon!,
                      const SizedBox(height: JamSpace.sm),
                      Text(
                        widget.applicationName,
                        textAlign: TextAlign.center,
                        style: context.jamTitle3,
                      ),
                      const SizedBox(height: JamSpace.xxs),
                      Text(
                        widget.applicationVersion,
                        textAlign: TextAlign.center,
                        style: context.jamSubheadline.copyWith(
                          color: colors.secondaryLabel,
                        ),
                      ),
                      if (legalese != null) ...[
                        const SizedBox(height: JamSpace.sm),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: JamSpace.xxxl,
                          ),
                          child: Text(
                            legalese,
                            textAlign: TextAlign.center,
                            style: context.jamFootnote.copyWith(
                              color: colors.secondaryLabel,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: JamSpace.section),
                  if (packages == null)
                    const Padding(
                      padding: EdgeInsets.all(JamSpace.xxxl),
                      child: Center(child: JamSpinner()),
                    )
                  else
                    JamSection(
                      header: LicensesStrings.packages,
                      children: [
                        for (final p in packages)
                          JamRow(
                            title: p.package,
                            value: LicensesStrings.count(p.entries.length),
                            chevron: true,
                            onTap: () => _open(p.package, p.entries),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One package's licence text.
class _LicenseDetail extends StatelessWidget {
  const _LicenseDetail({required this.package, required this.entries});

  final String package;
  final List<LicenseEntry> entries;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final body = context.jamFootnote.copyWith(color: colors.label);
    final paragraphs = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      if (i > 0) {
        paragraphs.add(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: JamSpace.lg),
            child: JamHairline(),
          ),
        );
      }
      for (final paragraph in entries[i].paragraphs) {
        final centered = paragraph.indent == LicenseParagraph.centeredIndent;
        paragraphs.add(
          Padding(
            padding: EdgeInsetsDirectional.only(
              top: JamSpace.sm,
              start: centered ? 0 : JamSpace.lg * paragraph.indent,
            ),
            child: Text(
              paragraph.text,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: centered
                  ? body.copyWith(fontWeight: FontWeight.w600)
                  : body,
            ),
          ),
        );
      }
    }
    return JamScaffold(
      title: package,
      largeTitle: false,
      previousPageTitle: LicensesStrings.title,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: JamContentWidth.reading,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                JamSpace.page,
                JamSpace.sm,
                JamSpace.page,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: paragraphs,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
