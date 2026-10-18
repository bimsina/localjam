/// One jam at a time, said out loud.
///
/// Every way into a session — a nearby room, a scanned code, a pasted or
/// deep link, "Start a jam", "Host Again" — used to call into the
/// controller while a jam was already running, where the start was refused
/// (`canStart` is false while live) and nothing said so: the tap simply did
/// nothing. This is the one gate they all pass through: idle and ended go
/// straight on, a start already in flight is a no, and a live jam is offered
/// the honest choice — end (or leave) it first, or stay.
library;

import 'package:flutter/widgets.dart';

import '../state/session_controller.dart';
import 'dialogs.dart';

/// Everything the gate says.
abstract final class JamSessionGateStrings {
  static String endTitle(String room) => 'End $room first?';
  static const String endBody =
      'You can only be in one jam at a time. Ending this one disconnects '
      'everyone listening.';
  static String leaveTitle(String room) => 'Leave $room first?';
  static const String leaveBody = 'You can only be in one jam at a time.';
  static const String endJam = 'End Jam';
  static const String leave = 'Leave Jam';
  static const String stay = 'Stay';
}

/// Whether a new session may start now, asking to end or leave the live one
/// first. Returns true once the way is clear — the live jam (if any) is
/// already gone by then — and false when the user stayed, or when another
/// start is still in flight.
Future<bool> jamReadyForNewSession(
  BuildContext context,
  JamSessionController session,
) async {
  // One start at a time; the one in flight has its own spinner.
  if (session.isBusy) return false;
  // Idle, or a terminal end not yet dismissed: startHost and join clear an
  // ended session on their way past.
  final engine = session.engine;
  if (!session.isLive || engine == null) return true;
  final room = engine.sessionName;
  final host = session.isHost;
  final confirmed = await JamDialogs.confirmDestructive(
    context,
    title: host
        ? JamSessionGateStrings.endTitle(room)
        : JamSessionGateStrings.leaveTitle(room),
    message: host
        ? JamSessionGateStrings.endBody
        : JamSessionGateStrings.leaveBody,
    confirmLabel: host
        ? JamSessionGateStrings.endJam
        : JamSessionGateStrings.leave,
    cancelLabel: JamSessionGateStrings.stay,
  );
  if (!confirmed) {
    // Not "Stay" if the jam ended under the dialog: the router unwinds
    // modals over a session that went terminal, which reads as a dismissal
    // here. There is nothing left to stay in, so the way is clear — the
    // link or the start that asked must not be silently dropped.
    if (!session.isLive) return session.canStart;
    return false;
  }
  await session.leave();
  return session.canStart;
}
