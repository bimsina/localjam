/// Tests for roles/capabilities and the permission document
/// (PROTOCOL.md §5.6).
library;

import 'package:localjam_core/localjam_core.dart';
import 'package:test/test.dart';

void main() {
  group('capability derivation', () {
    test('the host holds every capability regardless of policy', () {
      const perms = JamPermissions.initial(policy: JamPolicy.listenOnly);
      expect(perms.roleOf(JamPermissions.hostPeerId), JamRole.host);
      expect(
        perms.capabilitiesOf(JamPermissions.hostPeerId),
        JamCapability.values.toSet(),
      );
    });

    test('presets map onto guest capabilities', () {
      const open = JamPermissions.initial(policy: JamPolicy.open);
      expect(open.capabilitiesOf('p_1'), {
        JamCapability.addTracks,
        JamCapability.controlPlayback,
        JamCapability.editQueue,
      });

      const jam = JamPermissions.initial();
      expect(jam.policy, JamPolicy.jam);
      expect(jam.capabilitiesOf('p_1'), {
        JamCapability.addTracks,
        JamCapability.editQueue,
      });
      expect(jam.allows('p_1', JamCapability.controlPlayback), isFalse);

      const locked = JamPermissions.initial(policy: JamPolicy.listenOnly);
      expect(locked.capabilitiesOf('p_1'), isEmpty);
    });

    test('a co-host gets the co-host set even under listen-only policy', () {
      final perms = const JamPermissions.initial(
        policy: JamPolicy.listenOnly,
      ).promote('p_2');
      expect(perms.roleOf('p_2'), JamRole.cohost);
      expect(perms.capabilitiesOf('p_2'), JamPermissions.cohostCapabilities);
      // Never member/settings management (host-only in v1).
      expect(perms.allows('p_2', JamCapability.manageMembers), isFalse);
      expect(perms.allows('p_2', JamCapability.changeSettings), isFalse);
      // Other guests remain locked out.
      expect(perms.capabilitiesOf('p_3'), isEmpty);
    });

    test('overrides win over the role base, both directions', () {
      final perms =
          const JamPermissions.initial() // jam: add + edit
              .withOverride('p_4', JamCapability.addTracks, allowed: false)
              .withOverride(
                'p_5',
                JamCapability.controlPlayback,
                allowed: true,
              );
      expect(perms.allows('p_4', JamCapability.addTracks), isFalse);
      expect(perms.allows('p_4', JamCapability.editQueue), isTrue);
      expect(perms.allows('p_5', JamCapability.controlPlayback), isTrue);
    });

    test('host-only capabilities cannot be granted via overrides', () {
      final perms = const JamPermissions.initial()
          .withOverride('p_1', JamCapability.manageMembers, allowed: true)
          .withOverride('p_1', JamCapability.changeSettings, allowed: true);
      expect(perms.allows('p_1', JamCapability.manageMembers), isFalse);
      expect(perms.allows('p_1', JamCapability.changeSettings), isFalse);
    });
  });

  group('mutators', () {
    test('each real change bumps rev exactly once; no-ops return this', () {
      const initial = JamPermissions.initial();
      expect(initial.rev, 0);

      final promoted = initial.promote('p_1');
      expect(promoted.rev, 1);
      expect(identical(promoted.promote('p_1'), promoted), isTrue);

      final demoted = promoted.demote('p_1');
      expect(demoted.rev, 2);
      expect(identical(demoted.demote('p_1'), demoted), isTrue);

      final overridden = demoted.withOverride(
        'p_1',
        JamCapability.addTracks,
        allowed: false,
      );
      expect(overridden.rev, 3);
      expect(
        identical(
          overridden.withOverride(
            'p_1',
            JamCapability.addTracks,
            allowed: false,
          ),
          overridden,
        ),
        isTrue,
      );

      final cleared = overridden.withOverride(
        'p_1',
        JamCapability.addTracks,
        allowed: null,
      );
      expect(cleared.rev, 4);
      expect(cleared.overrides, isEmpty);
      expect(
        identical(
          cleared.withOverride('p_x', JamCapability.editQueue, allowed: null),
          cleared,
        ),
        isTrue,
      );

      final repoliced = cleared.withPolicy(JamPolicy.open);
      expect(repoliced.rev, 5);
    });

    test('forgetPeer drops role and overrides together', () {
      final perms = const JamPermissions.initial()
          .promote('p_1')
          .withOverride('p_1', JamCapability.editQueue, allowed: false);
      final forgotten = perms.forgetPeer('p_1');
      expect(forgotten.cohosts, isEmpty);
      expect(forgotten.overrides, isEmpty);
      expect(forgotten.rev, perms.rev + 1);
      expect(identical(forgotten.forgetPeer('p_1'), forgotten), isTrue);
    });
  });

  group('wire shape', () {
    test('round-trips through JSON', () {
      final perms = const JamPermissions.initial(policy: JamPolicy.open)
          .promote('p_2')
          .withOverride('p_3', JamCapability.addTracks, allowed: false)
          .withOverride('p_3', JamCapability.controlPlayback, allowed: true);
      final decoded = JamPermissions.fromJson(perms.toJson());
      expect(decoded, perms);
      expect(decoded.rev, perms.rev);
      expect(decoded.capabilitiesOf('p_3'), perms.capabilitiesOf('p_3'));
    });

    test('unknown capability strings in overrides are skipped, not fatal', () {
      final decoded = JamPermissions.fromJson({
        'rev': 7,
        'policy': {'addTracks': true},
        'cohosts': ['p_1'],
        'overrides': {
          'p_2': {'add_tracks': false, 'teleport': true},
        },
      });
      expect(decoded.rev, 7);
      expect(decoded.allows('p_2', JamCapability.addTracks), isFalse);
      expect(decoded.overrides['p_2'], hasLength(1));
    });

    test('a missing/empty document decodes to listen-only', () {
      final decoded = JamPermissions.fromJson(const {});
      expect(decoded.policy, JamPolicy.listenOnly);
      expect(decoded.capabilitiesOf('p_1'), isEmpty);
    });
  });
}
