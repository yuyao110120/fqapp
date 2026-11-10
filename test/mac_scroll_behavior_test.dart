import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/main.dart' show MacMobileScrollBehavior;

void main() {
  testWidgets('macOS mobile shell does not paint auto desktop scrollbars', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const MacMobileScrollBehavior(),
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: ListView(
          children: [
            for (var i = 0; i < 80; i++)
              SizedBox(height: 24, child: Text('$i')),
          ],
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(find.byType(Scrollbar), findsNothing);
  });
}