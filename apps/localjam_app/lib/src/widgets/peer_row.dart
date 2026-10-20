/// A person in the room (DESIGN_SPEC v3 §6.5).
///
/// An ordinary list row: a 40 avatar, the name, and a subtitle only when it
/// says something — "Host", "You", "Host · You", "Co-host", what the host
/// changed for this person ("Can’t add songs"), or, in `warning`, that they
/// are still loading the song. No pills, no rings, no "Listening": a person
/// who is simply fine gets a name and nothing else (§1.2).
///
/// The host gets a trailing "•••" pull-down per guest ([JamPeerRow.menu]).
///
/// Engine-free: map `JamPermissions.roleOf` and `MediaReadiness` to the plain
/// enums below at the call site.
library;

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../design/tokens.dart';
import '../util/format.dart';
import 'avatar.dart';
import 'list.dart';
import 'menu.dart';

/// Strings this row can put in front of a person.
abstract final class JamPeerRowStrings {
  static const String host = 'Host';
  static const String cohost = 'Co-host';
  static const String you = 'You';

  /// The one warning a person row carries: they cannot hear this song yet.
  static const String loading = 'Still loading songs…';
  static String loadingProgress(int percent) =>
      'Still loading songs… $percent%';

  /// Joins the parts of a subtitle: "Host · You".
  static const String joiner = ' · ';

  /// The "•••" button's spoken name.
  static String more(String name) => 'More for $name';
}

/// What a person may do in the room — the presentational half of
/// `JamPermissions.roleOf`.
enum JamPeerRole { guest, cohost, host }

/// Whether a person has the current track yet — the presentational half of
/// `MediaReadiness`.
enum JamPeerReadiness { ready, fetching, missing }

/// How far the "•••" glyph sits inside its 44 pt box.
const double _kMenuGlyphInset = (JamMetrics.hitTarget - JamMetrics.navIcon) / 2;

/// One person: face, name, and at most one quiet line about them.
class JamPeerRow extends StatelessWidget implements JamSelfSeparatingRow {
  const JamPeerRow({
    super.key,
    required this.name,
    this.role = JamPeerRole.guest,
    this.isYou = false,
    this.detail,
    this.readiness,
    this.fetchProgress,
    this.menu,
    this.trailing,
    this.dimmed = false,
    this.onTap,
    this.color,
  });

  /// Display name — the face's initials and (without [color]) its colour
  /// come from it (D3).
  final String name;

  /// The face's colour as the jam assigned it (`jamRosterColors`), so this
  /// row matches the footer's faces and the queue's credits.
  final Color? color;

  /// Host, co-host or guest. Host and co-host are said in the subtitle.
  final JamPeerRole role;

  /// Whether this row is this device ("You").
  final bool isYou;

  /// Extra words after the role ("Can’t add songs"), sentence case.
  final String? detail;

  /// Whether this person has the current track. Anything but ready replaces
  /// the subtitle with the loading line in `warning`.
  final JamPeerReadiness? readiness;

  /// Their fetch progress, 0–1, while [readiness] is fetching.
  final double? fetchProgress;

  /// The host's per-guest pull-down. Null: no "•••".
  final List<List<JamMenuItem>>? menu;

  /// Any other trailing control (used when [menu] is null).
  final Widget? trailing;

  /// Fades the face — someone who is not in the room right now.
  final bool dimmed;

  final VoidCallback? onTap;

  /// Whether the subtitle is the loading warning.
  bool get isLoading =>
      readiness == JamPeerReadiness.fetching ||
      readiness == JamPeerReadiness.missing;

  /// The subtitle, or null when there is nothing worth saying.
  String? get subtitle {
    if (isLoading) {
      final progress = fetchProgress;
      if (readiness == JamPeerReadiness.fetching && progress != null) {
        final percent = (progress.clamp(0.0, 1.0) * 100).round();
        return JamPeerRowStrings.loadingProgress(percent);
      }
      return JamPeerRowStrings.loading;
    }
    final parts =
        <String>[
            if (role == JamPeerRole.host) JamPeerRowStrings.host,
            if (role == JamPeerRole.cohost) JamPeerRowStrings.cohost,
            if (isYou) JamPeerRowStrings.you,
            if (detail != null && detail!.isNotEmpty) detail!,
          ]
          // A host who shared no name is titled "Host" already.
          ..remove(name);
    return parts.isEmpty ? null : parts.join(JamPeerRowStrings.joiner);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final menu = this.menu;
    return JamRow(
      title: name,
      subtitle: subtitle,
      subtitleColor: isLoading ? colors.warning : null,
      subtitleMaxLines: 1,
      // The name is the row's title; the face must not say it twice.
      leading: ExcludeSemantics(
        child: JamAvatar(
          name: name,
          color: color,
          size: JamAvatarSize.sheet,
          dimmed: dimmed,
        ),
      ),
      leadingWidth: JamAvatarSize.sheet,
      trailing: menu != null
          // A quiet "•••": tint is for the one primary action, and a column
          // of raspberry circles would outshout the names. Its glyph, not
          // its 44 box, ends on the row's trailing inset, where a switch or
          // a value ends on the rows around it (CR-13).
          ? Transform.translate(
              offset: Offset(
                Directionality.of(context) == TextDirection.rtl
                    ? -_kMenuGlyphInset
                    : _kMenuGlyphInset,
                0,
              ),
              child: JamMenuButton(
                groups: menu,
                semanticLabel: JamPeerRowStrings.more(name),
                icon: CupertinoIcons.ellipsis,
                iconColor: colors.secondaryLabel,
              ),
            )
          : trailing,
      onTap: onTap,
    );
  }
}

/// How a [JamPeoplePhrase] fits one line: the runs to draw — each name at
/// the width it was given (cut with an ellipsis when that is less than it
/// needs) and the words between them whole — and what a screen reader says
/// for it, which is what the line shows (RB-9).
class JamPeopleFit {
  const JamPeopleFit._(this.runs, this.spoken);

  /// Fits [phrase] in [maxWidth] at [style]. The whole phrase when it fits;
  /// otherwise the names share what the fixed words leave, the shortest
  /// keeping all of theirs and the longest cut first ("With Electric
  /// Mongo… and 7 others"); and when not even a letter of each would show,
  /// the count alone ("With 8 people").
  factory JamPeopleFit.of(
    JamPeoplePhrase phrase, {
    required TextStyle style,
    required double maxWidth,
    TextScaler textScaler = TextScaler.noScaling,
    TextDirection textDirection = TextDirection.ltr,
  }) {
    double measure(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: textDirection,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final full = phrase.text;
    if (measure(full) <= maxWidth) {
      return JamPeopleFit._([(text: full, width: null)], full);
    }
    final parts = phrase.parts;
    final names = [
      for (var i = 0; i < parts.length; i++)
        if (parts[i].name) i,
    ];
    final counted = phrase.counted;
    JamPeopleFit fallback() {
      final text = counted ?? full;
      return JamPeopleFit._([(text: text, width: null)], text);
    }

    if (names.isEmpty) return fallback();
    var fixed = 0.0;
    for (final part in parts) {
      if (!part.name) fixed += measure(part.text);
    }
    final natural = {for (final i in names) i: measure(parts[i].text)};
    // A name cut to less than its first letter and an ellipsis is no name.
    final floor = {
      for (final i in names)
        i: math.min(natural[i]!, measure('${parts[i].text.characters.first}…')),
    };
    // A hair of slack: the runs are measured apart, and a sub-pixel sum must
    // not tip the row into overflow.
    var room = maxWidth - fixed - 1;
    if (room < floor.values.fold<double>(0, (a, b) => a + b)) {
      return fallback();
    }
    // Water-filling: the shortest names first, each up to an equal share of
    // what is left, so a short name is never cut to make room for a long
    // one.
    final order = [...names]
      ..sort((a, b) => natural[a]!.compareTo(natural[b]!));
    final given = <int, double>{};
    for (var k = 0; k < order.length; k++) {
      final i = order[k];
      final share = room / (order.length - k);
      final width = math.max(floor[i]!, math.min(natural[i]!, share));
      given[i] = width;
      room -= width;
    }
    if (room < -0.5) return fallback();
    return JamPeopleFit._([
      for (var i = 0; i < parts.length; i++)
        (
          text: parts[i].text,
          width: parts[i].name && given[i]! < natural[i]! ? given[i] : null,
        ),
    ], full);
  }

  /// What to draw, in order: a run with a width is a name cut to it.
  final List<({String text, double? width})> runs;

  /// The line as a screen reader should say it.
  final String spoken;
}

/// A people phrase on one line that cuts names, never the count (R9) —
/// "With Mia and Theo", "With Electric Mongo… and 7 others". Its spoken
/// label is what it shows.
class JamPeopleLine extends StatelessWidget {
  const JamPeopleLine(this.phrase, {super.key, required this.style})
    : fit = null;

  /// A line already fitted by the caller (who needs its [JamPeopleFit.spoken]
  /// for a label of its own).
  const JamPeopleLine.fitted(
    JamPeopleFit this.fit, {
    super.key,
    required this.style,
  }) : phrase = null;

  final JamPeoplePhrase? phrase;
  final JamPeopleFit? fit;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final fitted = fit;
    if (fitted != null) return _runs(fitted);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fit = JamPeopleFit.of(
          phrase!,
          style: style,
          maxWidth: constraints.maxWidth,
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
        );
        return Semantics(
          label: fit.spoken,
          child: ExcludeSemantics(child: _runs(fit)),
        );
      },
    );
  }

  Widget _runs(JamPeopleFit fit) {
    Text text(String value) => Text(
      value,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: style,
      // A cut name is as wide as what it draws, ellipsis included — not
      // the width it was offered — so no gap opens before the words after
      // it ("Electri…, Mia", not "Electri…  , Mia").
      textWidthBasis: TextWidthBasis.longestLine,
    );
    if (fit.runs.length == 1) return text(fit.runs.single.text);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final run in fit.runs)
          if (run.width case final width?)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: width),
              child: text(run.text),
            )
          else
            text(run.text),
      ],
    );
  }
}
