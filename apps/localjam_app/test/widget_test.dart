import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/main.dart';

void main() {
  testWidgets('home screen offers host and join', (tester) async {
    await tester.pumpWidget(const LocalJamApp());
    expect(find.text('LocalJam'), findsOneWidget);
    expect(find.text('Host a Jam'), findsOneWidget);
    expect(find.text('Join a Jam'), findsOneWidget);
  });
}
