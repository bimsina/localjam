import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  testWidgets('home leads with live discovery, not a pitch', (tester) async {
    final session = testSession();
    await pumpApp(tester, session);
    await tester.pump();

    // The screen's job is to answer "is there a jam here?".
    expect(find.text('Nearby'), findsOneWidget);
    expect(find.text('Start a jam'), findsOneWidget);

    // None of the landing-page copy the overhaul removed. The app is already
    // installed; it does not need to sell itself.
    expect(find.textContaining('No internet'), findsNothing);
    expect(find.textContaining('No accounts'), findsNothing);
    expect(find.textContaining('Same Wi-Fi'), findsNothing);
    expect(find.textContaining('Synchronized playback'), findsNothing);
    expect(find.text('Host a Jam'), findsNothing);
    expect(find.text('Join a Jam'), findsNothing);
  });

  testWidgets('home shows your identity and lets you rename', (tester) async {
    // JamIdentity.displayName caches per process, so every test in this file
    // sees the identity the first one resolved.
    final session = testSession();
    await pumpApp(tester, session);
    await tester.pump();

    expect(find.text('Silky Puffin'), findsOneWidget);

    await tester.tap(find.text('Silky Puffin'));
    await tester.pumpAndSettle();
    // JamIdentity.setDisplayName shipped in v1 with no caller anywhere.
    expect(find.text('Your name in the room'), findsOneWidget);
  });

  testWidgets('the empty state names the situation', (tester) async {
    final session = testSession();
    await pumpApp(tester, session);
    await tester.pumpAndSettle();

    // Whichever branch the test machine's network lands on, the screen must
    // say something concrete rather than shrug.
    expect(
      find.textContaining(RegExp('No network|Nothing nearby')),
      findsWidgets,
    );
  });
}
