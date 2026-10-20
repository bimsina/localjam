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
          // The app's one "•••", its dots quiet: tint is for the one
          // primary action, and a column of raspberry would outshout the
          // names. Its circle, not its 44 box, ends on the row's trailing
          // inset, where a switch or a value ends on the rows around it
          // (CR-13).
          ? JamMenuButton(
              groups: menu,
              semanticLabel: JamPeerRowStrings.more(name),
              iconColor: colors.secondaryLabel,
              triggerAlignment: AlignmentDirectional.centerEnd,
            )
          : trailing,
      onTap: onTap,
    );
  }
}

/// How a [JamPeoplePhrase] fits one line: the runs to draw — each name
/// whole, or cut to the width it was given and ended with an ellipsis, and
/// the words between them whole — and what a screen reader says for it,
/// which is what the line shows (RB-9).
class JamPeopleFit {
  const JamPeopleFit._(this.runs, this.spoken, {this.maxLines = 1});

  /// From this text scale up the line may wrap to two lines (N7): at the
  /// largest sizes cutting names left "With S… and F…" — letters, not
  /// people.
  static const double wrapScale = 1.5;

  /// The fewest letters a cut name keeps before its ellipsis. Fewer is a
  /// letter, not a name, and the count says more ("With 2 people").
  static const int minLetters = 3;

  /// Fits [phrase] in [maxWidth] at [style]. The whole phrase when it fits;
  /// otherwise the names share what the fixed words leave, the shortest
  /// keeping all of theirs and the longest cut first ("With Electric
  /// Mongo… and 7 others"); and when a name would keep fewer than
  /// [minLetters] letters, the count alone ("With 8 people").
  ///
  /// At large text ([wrapScale] and up) nothing is cut: the phrase wraps
  /// onto a second line between words, and when it does not fit two lines
  /// the count is said instead (N7).
  factory JamPeopleFit.of(
    JamPeoplePhrase phrase, {
    required TextStyle style,
    required double maxWidth,
    TextScaler textScaler = TextScaler.noScaling,
    TextDirection textDirection = TextDirection.ltr,
  }) {
    final fontSize = style.fontSize ?? kDefaultFontSize;
    final large = textScaler.scale(fontSize) / fontSize >= wrapScale;
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
      return JamPeopleFit._([(text: full, cut: false)], full);
    }
    if (large) {
      // Whole words on up to two lines, or the count.
      bool fitsTwoLines(String text) {
        for (final word in text.split(' ')) {
          if (measure(word) > maxWidth) return false;
        }
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: textDirection,
          textScaler: textScaler,
          maxLines: 2,
        )..layout(maxWidth: maxWidth);
        final fits = !painter.didExceedMaxLines;
        painter.dispose();
        return fits;
      }

      final text = fitsTwoLines(full) ? full : phrase.counted ?? full;
      return JamPeopleFit._([(text: text, cut: false)], text, maxLines: 2);
    }
    final parts = phrase.parts;
    final names = [
      for (var i = 0; i < parts.length; i++)
        if (parts[i].name) i,
    ];
    final counted = phrase.counted;
    JamPeopleFit fallback() {
      final text = counted ?? full;
      return JamPeopleFit._([(text: text, cut: false)], text);
    }

    if (names.isEmpty) return fallback();
    var fixed = 0.0;
    for (final part in parts) {
      if (!part.name) fixed += measure(part.text);
    }
    final natural = {for (final i in names) i: measure(parts[i].text)};
    // A name cut to fewer than [minLetters] letters is no name ("S…").
    final floor = {
      for (final i in names)
        i: math.min(
          natural[i]!,
          measure('${parts[i].text.characters.take(minLetters)}…'),
        ),
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
    // A name cut to [width]: as many of its letters as fit before an
    // ellipsis, with no space left between the two ("Electric…", never
    // "Electric …"). Widths only grow with the letters kept, so the longest
    // that fits is found by halving.
    String cut(String name, double width) {
      final letters = name.characters.toList();
      String shown(int count) => '${letters.take(count).join().trimRight()}…';
      var fits = math.min(minLetters, letters.length);
      var low = fits + 1;
      var high = letters.length - 1;
      while (low <= high) {
        final mid = (low + high) ~/ 2;
        if (measure(shown(mid)) <= width) {
          fits = mid;
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }
      return shown(fits);
    }

    return JamPeopleFit._([
      for (var i = 0; i < parts.length; i++)
        if (parts[i].name && given[i]! < natural[i]!)
          (text: cut(parts[i].text, given[i]!), cut: true)
        else
          (text: parts[i].text, cut: false),
    ], full);
  }

  /// What to draw, in order: a [cut] run is a name already cut to the width
  /// it was given, its ellipsis included.
  final List<({String text, bool cut})> runs;

  /// The line as a screen reader should say it.
  final String spoken;

  /// How many lines it may take: two at large text, else one.
  final int maxLines;
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
      maxLines: fit.maxLines,
      softWrap: fit.maxLines > 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (fit.runs.length == 1) return text(fit.runs.single.text);
    // Every run is drawn at its own width — a cut name already ends in its
    // ellipsis — so the words after a name follow straight on ("Electric…,
    // Mia"), their spaces kept.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [for (final run in fit.runs) text(run.text)],
    );
  }
}
