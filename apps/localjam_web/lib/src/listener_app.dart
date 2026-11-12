/// The listener page's shell (docs/design/WEB_GUEST.md "Web page
/// behaviour"): landing → joining → the room, and the terminal states in
/// between. No router: the page is one screen at a time, decided by state.
///
/// Rejected and ended states say what happened in plain language and never
/// show a spinner (§3.1: every reject is final, and trying again is the
/// person's call; §3.4: an announced end is terminal).
library;

import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:localjam_client/localjam_client.dart';
import 'package:material_ui/material_ui.dart';

import 'design.dart';
import 'engine_room.dart';
import 'join_target.dart';
import 'landing_page.dart';
import 'room.dart';
import 'room_page.dart';
import 'widgets.dart';

/// Why a join never got to the room.
enum JoinFailure {
  /// No usable invitation in the page's URL.
  noInvite,

  /// The host could not be reached (wrong Wi-Fi, host gone, a timeout).
  unreachable,

  /// The host refused the join (§3.1); see the reject reason.
  rejected,
}

/// The page: a themed app (light and dark follow the system,
/// `MediaQuery.platformBrightness`) around one [ListenerShell].
class ListenerApp extends StatelessWidget {
  const ListenerApp({
    super.key,
    required this.target,
    required this.joiner,
    required this.defaultName,
    required this.saveName,
    required this.unlockAudio,
    required this.openUrl,
  });

  /// What the page URL invites to.
  final JoinTarget target;

  /// Joins and returns the room (the engine in production).
  final RoomJoiner joiner;

  /// The name to offer: the stored one, or a generated one stored now.
  final Future<String> Function() defaultName;

  /// Stores the name the person chose.
  final Future<void> Function(String name) saveName;

  /// Wakes the page's audio; called synchronously inside the tap.
  final VoidCallback unlockAudio;

  /// Navigates to [Uri] ("Open in app").
  final void Function(Uri uri) openUrl;

  static const String title = 'LocalJam';

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: title,
    debugShowCheckedModeBanner: false,
    theme: pageTheme(Brightness.light),
    darkTheme: pageTheme(Brightness.dark),
    themeMode: ThemeMode.system,
    // One unnamed route, whatever path the page was served at (`/join`,
    // `/`): there is nothing to route, and an unnamed route is never
    // reported back to the address bar, so the URL — fragment and all —
    // stays as it was opened.
    onGenerateInitialRoutes: (_) => [
      PageRouteBuilder<void>(
        pageBuilder: (context, _, _) => ListenerShell(
          target: target,
          joiner: joiner,
          defaultName: defaultName,
          saveName: saveName,
          unlockAudio: unlockAudio,
          openUrl: openUrl,
        ),
      ),
    ],
    onGenerateRoute: (_) => null,
  );
}

/// Landing, joining, the room and the terminal states, one at a time.
class ListenerShell extends StatefulWidget {
  const ListenerShell({
    super.key,
    required this.target,
    required this.joiner,
    required this.defaultName,
    required this.saveName,
    required this.unlockAudio,
    required this.openUrl,
  });

  final JoinTarget target;
  final RoomJoiner joiner;
  final Future<String> Function() defaultName;
  final Future<void> Function(String name) saveName;
  final VoidCallback unlockAudio;
  final void Function(Uri uri) openUrl;

  @override
  State<ListenerShell> createState() => _ListenerShellState();
}

class _ListenerShellState extends State<ListenerShell> {
  final TextEditingController _name = TextEditingController();
  bool _joining = false;
  ListenerRoom? _room;
  JoinFailure? _failure;
  RejectReason? _rejectReason;

  @override
  void initState() {
    super.initState();
    if (!widget.target.canJoin) _failure = JoinFailure.noInvite;
    widget.defaultName().then((name) {
      if (mounted && _name.text.isEmpty) _name.text = name;
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    _name.dispose();
    _room?.removeListener(_onRoom);
    unawaited(_room?.leave());
    super.dispose();
  }

  void _onRoom() {
    if (mounted) setState(() {});
  }

  /// "Tap to listen" / "Try again": the tap is the user gesture the page's
  /// audio needs, so the unlock happens first, before any await. A second
  /// tap while a join is under way does nothing: [_joining] is set here,
  /// synchronously, not after [_join]'s first await.
  void _listen() {
    if (_joining || widget.target.joinUri == null) return;
    _joining = true;
    widget.unlockAudio();
    unawaited(_join());
  }

  Future<void> _join() async {
    final joinUri = widget.target.joinUri!;
    setState(() {
      _failure = null;
      _rejectReason = null;
    });
    var name = _name.text.trim();
    if (name.isEmpty) {
      try {
        name = await widget.defaultName();
      } catch (_) {
        name = '';
      }
      if (!mounted) return;
    }
    _name.text = name;
    final old = _room;
    if (old != null) {
      old.removeListener(_onRoom);
      _room = null;
      unawaited(old.leave());
    }
    try {
      unawaited(widget.saveName(name).catchError((Object _) {}));
      final room = await widget.joiner(joinUri, name);
      if (!mounted) {
        unawaited(room.leave());
        return;
      }
      room.addListener(_onRoom);
      setState(() {
        _room = room;
        _joining = false;
      });
    } on JamRejectedException catch (e) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _failure = JoinFailure.rejected;
        _rejectReason = e.reason;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _failure = JoinFailure.unreachable;
      });
    }
  }

  void _backToStart() {
    final old = _room;
    if (old != null) {
      old.removeListener(_onRoom);
      unawaited(old.leave());
    }
    setState(() {
      _room = null;
      _failure = widget.target.canJoin ? null : JoinFailure.noInvite;
      _rejectReason = null;
    });
  }

  VoidCallback? get _openApp {
    final link = widget.target.appLink;
    return link == null ? null : () => widget.openUrl(link);
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(backgroundColor: colorsOf(context).background, body: _body());

  Widget _body() {
    final room = _room;
    if (room != null) {
      final end = room.endReason;
      if (end == null || end == JamSessionEndReason.closedLocally) {
        return RoomPage(room: room, onOpenApp: _openApp);
      }
      return _ended(end, room.rejectReason);
    }
    switch (_failure) {
      case JoinFailure.noInvite:
        return const MessageView(
          icon: CupertinoIcons.link,
          title: Copy.noInviteTitle,
          message: Copy.noInviteMessage,
        );
      case JoinFailure.unreachable:
        return MessageView(
          icon: CupertinoIcons.wifi_exclamationmark,
          title: Copy.unreachableTitle,
          message: Copy.unreachableMessage,
          actions: [PageButton(label: Copy.tryAgain, onPressed: _listen)],
        );
      case JoinFailure.rejected:
        return _rejected(_rejectReason ?? RejectReason.unknown);
      case null:
        return LandingPage(
          jamName: widget.target.jamName,
          nameController: _name,
          joining: _joining,
          onListen: _listen,
          onOpenApp: _openApp,
        );
    }
  }

  Widget _rejected(RejectReason reason) {
    final (IconData icon, String title, String message) = switch (reason) {
      RejectReason.badToken => (
        CupertinoIcons.music_note_2,
        Copy.badTokenTitle,
        Copy.badTokenMessage,
      ),
      RejectReason.full => (
        CupertinoIcons.person_3,
        Copy.fullTitle,
        Copy.fullMessage,
      ),
      RejectReason.version => (
        CupertinoIcons.arrow_2_circlepath,
        Copy.versionTitle,
        Copy.versionMessage,
      ),
      RejectReason.kicked => (
        CupertinoIcons.person_crop_circle_badge_xmark,
        Copy.kickedTitle,
        Copy.kickedMessage,
      ),
      RejectReason.unknown => (
        CupertinoIcons.xmark_circle,
        Copy.refusedTitle,
        Copy.refusedMessage,
      ),
    };
    // Only a full room may let you in later; the rest never will.
    final retry = reason == RejectReason.full;
    return MessageView(
      icon: icon,
      title: title,
      message: message,
      actions: [
        if (retry) PageButton(label: Copy.tryAgain, onPressed: _listen),
      ],
    );
  }

  Widget _ended(JamSessionEndReason end, RejectReason? reject) {
    switch (end) {
      case JamSessionEndReason.hostEnded:
        return const MessageView(
          icon: CupertinoIcons.music_note_2,
          title: Copy.endedTitle,
          message: Copy.endedMessage,
        );
      case JamSessionEndReason.hostGone:
        return MessageView(
          icon: CupertinoIcons.wifi_slash,
          title: Copy.hostGoneTitle,
          message: Copy.hostGoneMessage,
          actions: [PageButton(label: Copy.tryAgain, onPressed: _listen)],
        );
      case JamSessionEndReason.kicked:
        return _rejected(RejectReason.kicked);
      case JamSessionEndReason.rejected:
        return _rejected(reject ?? RejectReason.unknown);
      // A host-side reason a guest is never given, and a local close the
      // page never shows (it is the page's own doing): neither may claim
      // the host ended anything.
      case JamSessionEndReason.listenerFailed ||
          JamSessionEndReason.closedLocally:
        return MessageView(
          icon: CupertinoIcons.music_note_2,
          title: Copy.stoppedTitle,
          message: Copy.stoppedMessage,
          actions: [
            PageButton(
              label: Copy.backToStart,
              style: PageButtonStyle.plain,
              onPressed: _backToStart,
            ),
          ],
        );
    }
  }
}

/// The shell's copy (DESIGN_SPEC_V3 §3 copy rules, v3.1 §9 glossary).
abstract final class Copy {
  static const String tryAgain = 'Try again';
  static const String backToStart = 'Start over';
  static const String noInviteTitle = 'No invite in this link';
  static const String noInviteMessage =
      "Scan the jam's code again, or ask the host to share the link.";
  static const String unreachableTitle = "Couldn't reach the jam";
  static const String unreachableMessage =
      "Make sure you're on the same Wi-Fi as the host, then try again.";
  static const String badTokenTitle = 'This jam has ended';
  static const String badTokenMessage =
      'The link is from a jam that is over. Ask the host for the new code.';
  static const String fullTitle = 'This jam is full';
  static const String fullMessage = 'Try again when someone leaves.';
  static const String versionTitle = "Can't join this jam";
  static const String versionMessage =
      "The host's LocalJam is a different version. Ask them to update it.";
  static const String kickedTitle = 'You were removed';
  static const String kickedMessage = 'The host removed you from this jam.';
  static const String refusedTitle = "Couldn't join";
  static const String refusedMessage = "The host's jam didn't let you in.";
  static const String endedTitle = 'The jam has ended';
  static const String endedMessage =
      'The host ended the jam. Thanks for '
      'listening.';
  static const String stoppedTitle = 'Listening stopped';
  static const String stoppedMessage =
      'This page lost the jam. Start over to join it again.';
  static const String hostGoneTitle = 'The host disappeared';
  static const String hostGoneMessage =
      "Their phone may have left the Wi-Fi or run out of battery.";
}
