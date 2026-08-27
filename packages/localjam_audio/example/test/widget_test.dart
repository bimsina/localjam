import 'package:flutter_test/flutter_test.dart';

import 'package:localjam_audio_example/main.dart';

void main() {
  testWidgets('harness renders its controls', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Load'), findsOneWidget);
    expect(find.text('Play in 2s'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
  });
}
