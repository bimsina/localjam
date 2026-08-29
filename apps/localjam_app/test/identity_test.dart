import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/widgets/peer_avatar.dart';

void main() {
  group('identityColor', () {
    test('is stable for the same name', () {
      // This is the whole point: everyone in the room must see the same
      // colour for the same person, so it cannot use String.hashCode, which
      // Dart does not guarantee across runs or platforms.
      final first = identityColor('Silky Puffin', Brightness.light);
      final second = identityColor('Silky Puffin', Brightness.light);
      expect(first, second);
    });

    test('differs between names', () {
      final colors = {
        for (final name in [
          'Silky Puffin',
          'Golden Pangolin',
          'Neon Walrus',
          'Amber Alpaca',
        ])
          identityColor(name, Brightness.light),
      };
      expect(colors.length, greaterThan(1));
    });

    test('picks a different value per brightness', () {
      expect(
        identityColor('Silky Puffin', Brightness.light),
        isNot(identityColor('Silky Puffin', Brightness.dark)),
      );
    });
  });

  group('identityInitials', () {
    test('takes the first and last word', () {
      expect(identityInitials('Silky Puffin'), 'SP');
      expect(identityInitials('Golden Pangolin'), 'GP');
    });

    test('handles one word, extra spaces, and nothing at all', () {
      expect(identityInitials('Puffin'), 'P');
      expect(identityInitials('  Silky   Puffin  '), 'SP');
      expect(identityInitials(''), '?');
      expect(identityInitials('   '), '?');
    });
  });
}
