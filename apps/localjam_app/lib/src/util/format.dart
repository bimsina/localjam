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

/// [peer]'s display name, or [kJamUnnamedPeer] when they shared none.
String jamPeerName(PeerInfo peer) {
  final name = peer.clientName.trim();
  return name.isEmpty ? kJamUnnamedPeer : name;
}

/// People in a line, said the same way on every screen — the Now Playing
/// footer, the Invite sheet, Past Jams: "Mia", "Mia and Theo", "Mia, Theo
/// and Ana", "Mia, Theo and 2 others".
///
/// At most [named] names before the rest are counted — except that one
/// person left over is named rather than counted ("Mia, Theo and Ana", not
/// "Mia, Theo and 1 other"), unless [countOne] asks for the short form a
/// narrow line falls back to.
String jamPeopleList(
  List<String> names, {
  int named = 2,
  bool countOne = false,
}) {
  if (names.isEmpty) return '';
  final shown = names.length == named + 1 && !countOne
      ? names.length
      : (names.length < named ? names.length : named);
  final listed = names.take(shown).toList();
  final rest = names.length - shown;
  if (rest > 0) {
    return '${listed.join(', ')} and $rest ${rest == 1 ? 'other' : 'others'}';
  }
  if (listed.length == 1) return listed.single;
  return '${listed.take(listed.length - 1).join(', ')} and ${listed.last}';
}

/// Everyone in [engine]'s jam by peer id, in roster order: this device,
/// then (from a guest) the host, then everyone in `peers`.
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
  for (final peer in engine.peers) peer.peerId,
];

/// [JamEngine.addedByLabel] against the engine's own roster, in the app's
/// words for a contributor who shared no name — "added by Guest", never
/// "added by p-7f3a".
String? jamAddedByLabel(JamEngine engine, MediaItem item) =>
    engine.addedByLabel(item, engine.peers, unnamedLabel: kJamUnnamedPeer);
