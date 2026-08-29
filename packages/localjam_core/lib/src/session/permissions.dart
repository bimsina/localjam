/// Roles, capabilities, and the room permission document
/// (PROTOCOL.md §5.6).
///
/// The host is the single authority: guests learn the current
/// [JamPermissions] from `welcome` and `permissions` broadcasts, use it to
/// enable/disable their own controls, and every request is re-validated
/// host-side anyway (the broadcast is UX, the validation is the contract).
library;

import 'package:meta/meta.dart';

/// One grantable capability (PROTOCOL.md §5.6).
enum JamCapability {
  /// Contribute tracks (uploads, §6.4).
  addTracks('add_tracks'),

  /// Play/pause/seek/select/skip (§5.2).
  controlPlayback('control_playback'),

  /// Reorder the queue and remove OTHER peers' tracks (§5.6; removing your
  /// own track is always allowed).
  editQueue('edit_queue'),

  /// Kick peers, promote/demote co-hosts. Host-only in v1.
  manageMembers('manage_members'),

  /// Change the room policy. Host-only in v1.
  changeSettings('change_settings');

  const JamCapability(this.wire);

  /// Wire string for this capability.
  final String wire;

  static JamCapability fromWire(String wire) => values.firstWhere(
        (c) => c.wire == wire,
        orElse: () => throw FormatException('Unknown capability: "$wire"'),
      );
}

/// A peer's role (PROTOCOL.md §5.6). The host itself is not a peer; its
/// reserved peer id is [JamPermissions.hostPeerId].
enum JamRole {
  host('host'),
  cohost('cohost'),
  guest('guest');

  const JamRole(this.wire);

  /// Wire string for this role.
  final String wire;

  static JamRole fromWire(String wire) => values.firstWhere(
        (r) => r.wire == wire,
        orElse: () => throw FormatException('Unknown role: "$wire"'),
      );
}

/// What the GUEST role may do — the room-wide policy the host's presets
/// (Open / Jam / Listen-only) map onto (PROTOCOL.md §5.6). Co-hosts are
/// unaffected by it.
@immutable
class JamPolicy {
  const JamPolicy({
    required this.addTracks,
    required this.controlPlayback,
    required this.editQueue,
  });

  /// Everyone adds, controls, and edits.
  static const open = JamPolicy(
    addTracks: true,
    controlPlayback: true,
    editQueue: true,
  );

  /// The default: guests add and shape the queue; playback is the host's
  /// (and co-hosts').
  static const jam = JamPolicy(
    addTracks: true,
    controlPlayback: false,
    editQueue: true,
  );

  /// Guests listen; the host runs the room.
  static const listenOnly = JamPolicy(
    addTracks: false,
    controlPlayback: false,
    editQueue: false,
  );

  final bool addTracks;
  final bool controlPlayback;
  final bool editQueue;

  Map<String, Object?> toJson() => {
        'addTracks': addTracks,
        'controlPlayback': controlPlayback,
        'editQueue': editQueue,
      };

  factory JamPolicy.fromJson(Map<String, Object?> json) => JamPolicy(
        addTracks: (json['addTracks'] as bool?) ?? false,
        controlPlayback: (json['controlPlayback'] as bool?) ?? false,
        editQueue: (json['editQueue'] as bool?) ?? false,
      );

  JamPolicy copyWith({
    bool? addTracks,
    bool? controlPlayback,
    bool? editQueue,
  }) =>
      JamPolicy(
        addTracks: addTracks ?? this.addTracks,
        controlPlayback: controlPlayback ?? this.controlPlayback,
        editQueue: editQueue ?? this.editQueue,
      );

  @override
  bool operator ==(Object other) =>
      other is JamPolicy &&
      other.addTracks == addTracks &&
      other.controlPlayback == controlPlayback &&
      other.editQueue == editQueue;

  @override
  int get hashCode => Object.hash(addTracks, controlPlayback, editQueue);

  @override
  String toString() =>
      'JamPolicy(addTracks: $addTracks, controlPlayback: $controlPlayback, '
      'editQueue: $editQueue)';
}

/// The room's authoritative permission document (PROTOCOL.md §5.6):
/// revisioned like the playlist, broadcast on every change, included in
/// `welcome`. Immutable — mutators return a new document with `rev + 1`.
@immutable
class JamPermissions {
  const JamPermissions({
    required this.rev,
    required this.policy,
    this.cohosts = const {},
    this.overrides = const {},
  });

  /// A fresh document at rev 0 with [policy].
  const JamPermissions.initial({JamPolicy policy = JamPolicy.jam})
      : this(rev: 0, policy: policy);

  /// The host's reserved peer id, used for attribution ([JamRole.host] in
  /// [roleOf]) — the host is not a joined peer.
  static const hostPeerId = 'host';

  /// Increments on every change; guests keep the highest seen.
  final int rev;

  /// What plain guests may do.
  final JamPolicy policy;

  /// Peers promoted to co-host.
  final Set<String> cohosts;

  /// Per-peer capability overrides, applied after the role base — e.g.
  /// revoke one noisy guest's [JamCapability.addTracks] without touching
  /// the room policy. Only the three policy-grade capabilities are
  /// meaningful here; [JamCapability.manageMembers] and
  /// [JamCapability.changeSettings] stay host-only regardless.
  final Map<String, Map<JamCapability, bool>> overrides;

  /// What co-hosts may do (v1: everything except member/settings
  /// management).
  static const Set<JamCapability> cohostCapabilities = {
    JamCapability.addTracks,
    JamCapability.controlPlayback,
    JamCapability.editQueue,
  };

  /// [peerId]'s role.
  JamRole roleOf(String peerId) => peerId == hostPeerId
      ? JamRole.host
      : cohosts.contains(peerId)
          ? JamRole.cohost
          : JamRole.guest;

  /// [peerId]'s effective capability set: the role base ([JamRole.host] =
  /// everything, [JamRole.cohost] = [cohostCapabilities], [JamRole.guest] =
  /// what [policy] grants), then [overrides] applied on top.
  Set<JamCapability> capabilitiesOf(String peerId) {
    switch (roleOf(peerId)) {
      case JamRole.host:
        return Set.unmodifiable(JamCapability.values.toSet());
      case JamRole.cohost:
      case JamRole.guest:
        final base = roleOf(peerId) == JamRole.cohost
            ? Set<JamCapability>.of(cohostCapabilities)
            : {
                if (policy.addTracks) JamCapability.addTracks,
                if (policy.controlPlayback) JamCapability.controlPlayback,
                if (policy.editQueue) JamCapability.editQueue,
              };
        for (final entry in (overrides[peerId] ?? const {}).entries) {
          // manageMembers/changeSettings are not override-grantable in v1.
          if (entry.key == JamCapability.manageMembers ||
              entry.key == JamCapability.changeSettings) {
            continue;
          }
          entry.value ? base.add(entry.key) : base.remove(entry.key);
        }
        return Set.unmodifiable(base);
    }
  }

  /// Whether [peerId] may exercise [capability] right now.
  bool allows(String peerId, JamCapability capability) =>
      capabilitiesOf(peerId).contains(capability);

  // --- Mutators (each returns a new document at rev + 1) -------------------

  JamPermissions withPolicy(JamPolicy newPolicy) =>
      _next(policy: newPolicy);

  JamPermissions promote(String peerId) => cohosts.contains(peerId)
      ? this
      : _next(cohosts: {...cohosts, peerId});

  JamPermissions demote(String peerId) => !cohosts.contains(peerId)
      ? this
      : _next(cohosts: {...cohosts}..remove(peerId));

  /// Sets (or, with `allowed: null`, clears) one per-peer override.
  JamPermissions withOverride(
    String peerId,
    JamCapability capability, {
    required bool? allowed,
  }) {
    final peerOverrides = Map<JamCapability, bool>.of(
      overrides[peerId] ?? const {},
    );
    if (allowed == null) {
      if (!peerOverrides.containsKey(capability)) return this;
      peerOverrides.remove(capability);
    } else {
      if (peerOverrides[capability] == allowed) return this;
      peerOverrides[capability] = allowed;
    }
    final next = Map<String, Map<JamCapability, bool>>.of(overrides);
    if (peerOverrides.isEmpty) {
      next.remove(peerId);
    } else {
      next[peerId] = Map.unmodifiable(peerOverrides);
    }
    return _next(overrides: next);
  }

  /// Drops every trace of [peerId] (role + overrides) — for peers that left
  /// for good. Returns `this` (no rev bump) when there was nothing to drop.
  JamPermissions forgetPeer(String peerId) {
    if (!cohosts.contains(peerId) && !overrides.containsKey(peerId)) {
      return this;
    }
    return _next(
      cohosts: {...cohosts}..remove(peerId),
      overrides: Map.of(overrides)..remove(peerId),
    );
  }

  JamPermissions _next({
    JamPolicy? policy,
    Set<String>? cohosts,
    Map<String, Map<JamCapability, bool>>? overrides,
  }) =>
      JamPermissions(
        rev: rev + 1,
        policy: policy ?? this.policy,
        cohosts: Set.unmodifiable(cohosts ?? this.cohosts),
        overrides: Map.unmodifiable(overrides ?? this.overrides),
      );

  // --- Wire shape ----------------------------------------------------------

  Map<String, Object?> toJson() => {
        'rev': rev,
        'policy': policy.toJson(),
        'cohosts': [...cohosts]..sort(),
        'overrides': {
          for (final entry in overrides.entries)
            entry.key: {
              for (final o in entry.value.entries) o.key.wire: o.value,
            },
        },
      };

  factory JamPermissions.fromJson(Map<String, Object?> json) {
    final rawPolicy = json['policy'];
    final rawOverrides = json['overrides'];
    return JamPermissions(
      rev: (json['rev'] as int?) ?? 0,
      policy: rawPolicy is Map
          ? JamPolicy.fromJson(rawPolicy.cast<String, Object?>())
          : JamPolicy.listenOnly,
      cohosts: Set.unmodifiable({
        if (json['cohosts'] is List)
          ...(json['cohosts'] as List).whereType<String>(),
      }),
      overrides: Map.unmodifiable({
        if (rawOverrides is Map)
          for (final entry in rawOverrides.cast<String, Object?>().entries)
            if (entry.value is Map)
              entry.key: Map<JamCapability, bool>.unmodifiable({
                for (final o
                    in (entry.value as Map).cast<String, Object?>().entries)
                  if (o.value is bool)
                    // Unknown capability strings from a newer peer are
                    // skipped, not fatal (§2 forward compatibility).
                    ...?_tryCapability(o.key, o.value as bool),
              }),
      }),
    );
  }

  static Map<JamCapability, bool>? _tryCapability(String wire, bool allowed) {
    try {
      return {JamCapability.fromWire(wire): allowed};
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! JamPermissions ||
        other.rev != rev ||
        other.policy != policy ||
        other.cohosts.length != cohosts.length ||
        !other.cohosts.containsAll(cohosts) ||
        other.overrides.length != overrides.length) {
      return false;
    }
    for (final entry in overrides.entries) {
      final theirs = other.overrides[entry.key];
      if (theirs == null || theirs.length != entry.value.length) return false;
      for (final o in entry.value.entries) {
        if (theirs[o.key] != o.value) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(rev, policy, cohosts.length, overrides.length);

  @override
  String toString() =>
      'JamPermissions(rev: $rev, policy: $policy, cohosts: $cohosts, '
      'overrides: $overrides)';
}
