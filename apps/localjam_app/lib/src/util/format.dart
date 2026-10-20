/// Small formatting helpers for microsecond timelines, telemetry and the
/// names we put in front of people.
library;

import 'package:localjam_client/localjam_client.dart';

/// `mm:ss` (or `h:mm:ss`) from a media position in µs.
String formatPositionUs(int positionUs) {
  final totalSeconds = positionUs ~/ 1000000;
  final seconds = totalSeconds % 60;
  final minutes = (totalSeconds ~/ 60) % 60;
  final hours = totalSeconds ~/ 3600;
  final mmss =
      '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  return hours > 0 ? '$hours:$mmss' : mmss;
}

/// Below this many milliseconds a signed figure is shown as plain `0.0 ms`.
///
/// One decimal place means anything under 0.05 ms rounds to zero — and the
/// old formatter then still stamped a sign on it, so a drift hovering around
/// perfect flapped between `+0.0 ms` and `-0.0 ms` several times a second.
/// Two readings that render identically must read identically.
const double kJamZeroMs = 0.05;

/// The typographic minus (U+2212), the same one the Sound Offset uses.
const String kJamMinus = '−';

/// Signed milliseconds with one decimal, e.g. `+12.3 ms` / `−12.3 ms`, from
/// µs. A second or more reads in seconds (`−272.4 s`): a clock offset of
/// "-272391.4 ms" is a number nobody can read.
///
/// Zero — and anything that rounds to it — is unsigned: `0.0 ms`.
String formatSignedMs(int us) {
  final ms = us / 1000;
  if (ms.abs() < kJamZeroMs) return '0.0 ms';
  final sign = ms > 0 ? '+' : kJamMinus;
  final magnitude = ms.abs();
  if (magnitude >= 1000) {
    return '$sign${(magnitude / 1000).toStringAsFixed(1)} s';
  }
  return '$sign${magnitude.toStringAsFixed(1)} ms';
}

/// The sync sheet's drift and clock-offset figures. Same shape as
/// [formatSignedMs]; named for the one place it is read so the deadband is
/// discoverable from the call site.
String formatDriftMs(int us) => formatSignedMs(us);

/// Extensions [stripAudioExtension] will take off a display name.
///
/// Broader than [supportedAudioExtensions] on purpose: this is about what a
/// filename can *end in*, not what this build can play, and the name may have
/// come from another device.
const Set<String> _audioExtensions = {
  'mp3',
  'm4a',
  'm4b',
  'mp4',
  'aac',
  'wav',
  'wave',
  'flac',
  'ogg',
  'oga',
  'opus',
  'aiff',
  'aif',
  'alac',
  'wma',
};

/// A display name with a trailing audio extension removed: `track1.m4a`
/// becomes `track1`.
///
/// A tagless file falls back to its filename, and "track1.m4a" on the
/// now-playing screen reads as a bug. Defensive — the engine trims its own
/// fallback too — and conservative: anything that does not end in a known
/// audio extension is returned untouched.
String stripAudioExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return name;
  final ext = name.substring(dot + 1).toLowerCase();
  return _audioExtensions.contains(ext) ? name.substring(0, dot) : name;
}

/// What to call [item] on screen: its tag title, else its filename without
/// the extension.
String jamDisplayTitle(MediaItem item) =>
    stripAudioExtension(item.displayTitle);

/// What a person who shared no display name is called on screen.
///
/// Never their peer id: that is a wire token ("p-7f3a…"), and a roster or a
/// credit that prints one is machine text on a page about people (§8 check 3).
const String kJamUnnamedPeer = 'Guest';

/// The one order people are listed in (N7): by name, ignoring case, so
/// "Mia" and "mia" sit together and "Funky Macaw" comes before "Mia" on
/// every screen and every phone. The host, when known, goes before
/// everyone ([jamPeopleInOrder]).
int jamCompareNames(String a, String b) {
  final byLetters = a.toLowerCase().compareTo(b.toLowerCase());
  return byLetters != 0 ? byLetters : a.compareTo(b);
}

/// [names] in the one people order (N7): [host] first when it is known and
/// among them, then everyone else by name ([jamCompareNames]). The room's
/// footer, Invite, People, Recent and Past jams all list people this way —
/// they used to disagree ("With Sparkly Kiwi and Mia" in the room, "With
/// Mia and Sparkly Kiwi" in Recent).
List<String> jamPeopleInOrder(Iterable<String> names, {String? host}) {
  final rest = [...names];
  final hostAt = host == null ? -1 : rest.indexOf(host);
  final first = hostAt < 0 ? null : rest.removeAt(hostAt);
  rest.sort(jamCompareNames);
  return [?first, ...rest];
}

/// [peers] in the one people order (N7): by display name, ties by peer id
/// so every phone agrees. Neither the host nor this device is ever in a
/// guest's `peers`; callers put them first.
List<PeerInfo> jamPeersInOrder(Iterable<PeerInfo> peers) =>
    [...peers]..sort((a, b) {
      final byName = jamCompareNames(jamPeerName(a), jamPeerName(b));
      return byName != 0 ? byName : a.peerId.compareTo(b.peerId);
    });

/// [peer]'s display name, or [kJamUnnamedPeer] when they shared none.
String jamPeerName(PeerInfo peer) {
  final name = peer.clientName.trim();
  return name.isEmpty ? kJamUnnamedPeer : name;
}

/// The words people are said in (R9): the same on every screen.
abstract final class JamPeopleStrings {
  /// Nobody but you.
  static const String justYou = 'Just you';

  /// What leads a summary of the people besides you: "With Mia".
  static const String with_ = 'With';
  static const String and = 'and';
  static const String comma = ',';

  /// "2 others": what is counted after the names. Never "1 other" — one
  /// person left over is named instead.
  static String others(int n) => '$n others';

  /// The last resort when not even a letter of each name fits: "With 8
  /// people".
  static String withCount(int n) => '$with_ $n ${n == 1 ? 'person' : 'people'}';
}

/// "Just you", "With Mia", "With Mia and Theo", "With Mia, Theo and Ana",
/// "With Mia, Theo and 3 others" — the people in a jam besides you (R9),
/// the one summary every screen says them with.
String jamPeopleSummary(List<String> others) =>
    JamPeoplePhrase.summary(others).text;

/// A people phrase in its parts, so a narrow line can cut the *names* and
/// keep the count whole ("With Electric Mongo… and 7 others" rather than
/// "With Electric Mongoose Supreme an…").
class JamPeoplePhrase {
  const JamPeoplePhrase._(this.parts, this.total, {this.lead = ''});

  /// The people besides you, as [jamPeopleSummary] says them.
  factory JamPeoplePhrase.summary(List<String> others, {int named = 2}) {
    if (others.isEmpty) {
      return const JamPeoplePhrase._([
        (text: JamPeopleStrings.justYou, name: false),
      ], 0);
    }
    final list = JamPeoplePhrase.list(others, named: named);
    return JamPeoplePhrase._(
      [(text: '${JamPeopleStrings.with_} ', name: false), ...list.parts],
      others.length,
      lead: JamPeopleStrings.with_,
    );
  }

  /// [names] in a line: "Mia", "Mia and Theo", "Mia, Theo and Ana", "Mia,
  /// Theo and 2 others".
  ///
  /// At most [named] names before the rest are counted — except that one
  /// person left over is always named rather than counted ("Mia, Theo and
  /// Ana", never "Mia, Theo and 1 other": the name is shorter to read and
  /// says more).
  factory JamPeoplePhrase.list(List<String> names, {int named = 2}) {
    if (names.isEmpty) return const JamPeoplePhrase._([], 0);
    final cap = named < 1 ? 1 : named;
    // One left over is named, not counted.
    final shown = names.length <= cap + 1 ? names.length : cap;
    final rest = names.length - shown;
    final parts = <JamPeoplePart>[];
    for (var i = 0; i < shown; i++) {
      if (i > 0) {
        final last = i == shown - 1 && rest == 0;
        parts.add((
          text: last
              ? ' ${JamPeopleStrings.and} '
              : '${JamPeopleStrings.comma} ',
          name: false,
        ));
      }
      parts.add((text: names[i], name: true));
    }
    if (rest > 0) {
      parts.add((
        text: ' ${JamPeopleStrings.and} ${JamPeopleStrings.others(rest)}',
        name: false,
      ));
    }
    return JamPeoplePhrase._(parts, names.length);
  }

  /// The phrase in order: the names ([JamPeoplePart.name]) and the words
  /// between and after them.
  final List<JamPeoplePart> parts;

  /// How many people the phrase is about.
  final int total;

  /// The word before the names ("With"), or empty.
  final String lead;

  /// The whole phrase.
  String get text => parts.map((p) => p.text).join();

  /// The phrase with every name dropped for a count — "With 8 people" —
  /// for a line too narrow for even a letter of each name. Null for a
  /// phrase without names.
  String? get counted {
    if (total == 0) return null;
    if (lead.isNotEmpty) return JamPeopleStrings.withCount(total);
    return total == 1 ? '1 person' : '$total people';
  }
}

/// One piece of a [JamPeoplePhrase]: a person's name (cut first when the
/// line is short) or the words around them (never cut).
typedef JamPeoplePart = ({String text, bool name});

/// [names] with any repeated name told apart in [order] (indices into
/// [names]; default: as given): the first "Sam" stays "Sam", the next is
/// "Sam 2" (RB-19). Two people with one name are two people — two faces,
/// two colours, "With Sam and Sam 2" — not one person counted twice.
List<String> jamDistinctNames(List<String> names, {List<int>? order}) {
  final out = List<String>.of(names);
  final seen = <String, int>{};
  final taken = names.toSet();
  for (final i in order ?? [for (var i = 0; i < names.length; i++) i]) {
    final name = names[i];
    final n = (seen[name] ?? 0) + 1;
    seen[name] = n;
    if (n == 1) continue;
    var k = n;
    var candidate = '$name $k';
    while (taken.contains(candidate)) {
      candidate = '$name ${++k}';
    }
    taken.add(candidate);
    out[i] = candidate;
  }
  return out;
}

/// Everyone in [engine]'s jam by peer id, in roster order: this device,
/// then (from a guest) the host, then everyone else by name
/// ([jamPeersInOrder]) — not in the order they happened to join, which
/// changed the footer after a rejoin.
///
/// The roster every face in the jam is coloured over (`jamRosterColors`),
/// so a person has the same colour in the face pile, the People sheet and
/// the docked panel. Peer ids, because they are the
/// one id every phone in the jam knows a person by (client ids never leave
/// the host).
List<String> jamRosterPeerIds(JamEngine engine) => <String>[
  engine.selfPeerId,
  if (engine is JamGuestEngine)
    engine.hostPeer?.peerId ?? JamPermissions.hostPeerId,
  for (final peer in jamPeersInOrder(engine.peers)) peer.peerId,
];

/// [JamEngine.addedByLabel] against the engine's own roster, in the app's
/// words for a contributor who shared no name — "added by Guest", never
/// "added by p-7f3a".
String? jamAddedByLabel(JamEngine engine, MediaItem item) =>
    engine.addedByLabel(item, engine.peers, unnamedLabel: kJamUnnamedPeer);
