/// Licenses (DESIGN_SPEC v3 §6.8, D2): a list of the packages the app ships,
/// each opening its licence text — in place of Material's `LicensePage`,
/// whose app bar, cards and ink were the last Material chrome in the app.
/// On the same paper as Settings and its licence pages, so the ground never
/// changes on the way in.
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
  static const String packages = 'Open-source software';
  static String count(int n) => n == 1 ? '1 license' : '$n licenses';
}

/// The platform suffixes of federated plugin packages.
const List<String> _kPlatformSuffixes = [
  '_android',
  '_ios',
  '_darwin',
  '_foundation',
  '_macos',
  '_linux',
  '_windows',
  '_web',
];

/// Whether [package] is another platform's implementation of a plugin —
/// `app_links_linux` on an iPhone — and so not part of this build.
bool jamLicenseIsOtherPlatform(String package, TargetPlatform platform) {
  final mine = switch (platform) {
    TargetPlatform.iOS ||
    TargetPlatform.macOS => const ['_ios', '_darwin', '_foundation', '_macos'],
    TargetPlatform.android => const ['_android'],
    TargetPlatform.linux => const ['_linux'],
    TargetPlatform.windows => const ['_windows'],
    TargetPlatform.fuchsia => const <String>[],
  };
  for (final suffix in _kPlatformSuffixes) {
    if (package.endsWith(suffix)) return !mine.contains(suffix);
  }
  return false;
}

/// A licence paragraph as it should read: runs of spaces (the plain-text
/// licences' column padding, "Apache License  Version 2.0") collapsed.
String jamLicenseParagraph(String text) =>
    text.replaceAll(RegExp(r' {2,}'), ' ');

/// A rule drawn in characters — the OFL's lines of "-----" around its
/// title — which reads as a hairline, not as text.
final RegExp _kLicenseRule = RegExp(r'[-=_*~]{8,}');

/// Whether a licence paragraph carries a character rule.
bool jamLicenseHasRule(String text) => _kLicenseRule.hasMatch(text);

/// A licence paragraph without its character rules, spaces collapsed: what
/// is left is said; the rules become one hairline above it.
String jamLicenseWithoutRules(String text) =>
    jamLicenseParagraph(text.replaceAll(_kLicenseRule, ' ')).trim();

/// The registry, grouped by package (sorted, case-insensitively), without
/// other platforms' plugin implementations.
Future<List<({String package, List<LicenseEntry> entries})>>
jamLicensesByPackage({TargetPlatform? platform}) async {
  final target = platform ?? defaultTargetPlatform;
  final byPackage = <String, List<LicenseEntry>>{};
  await for (final entry in LicenseRegistry.licenses) {
    for (final package in entry.packages) {
      if (jamLicenseIsOtherPlatform(package, target)) continue;
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
      // The large title shares the reading column's leading edge.
      maxContentWidth: JamContentWidth.reading,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: JamSpace.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Column(
                children: [
                  if (widget.applicationIcon != null) widget.applicationIcon!,
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
                  child: Center(
                    child: JamProgressRing(size: JamProgressRing.controlSize),
                  ),
                )
              else
                JamSection(
                  header: LicensesStrings.packages,
                  bordered: true,
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
        final ruled = jamLicenseHasRule(paragraph.text);
        if (ruled) {
          paragraphs.add(
            const Padding(
              padding: EdgeInsets.only(top: JamSpace.lg, bottom: JamSpace.xs),
              child: JamHairline(),
            ),
          );
        }
        final text = ruled
            ? jamLicenseWithoutRules(paragraph.text)
            : jamLicenseParagraph(paragraph.text);
        if (text.isEmpty) continue;
        final centered = paragraph.indent == LicenseParagraph.centeredIndent;
        // One step of indent at most: deeper levels pushed the body into a
        // ragged column well right of the title.
        final indent = centered ? 0 : (paragraph.indent > 0 ? 1 : 0);
        paragraphs.add(
          Padding(
            padding: EdgeInsetsDirectional.only(
              top: JamSpace.sm,
              start: JamSpace.lg * indent,
            ),
            child: Text(
              text,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              // A ruled-off line is the licence's own heading.
              style: centered || ruled
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
      maxContentWidth: JamContentWidth.reading,
      children: [
        Padding(
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
      ],
    );
  }
}
