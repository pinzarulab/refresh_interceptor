import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:refresh_interceptor/refresh_interceptor.dart';

void main() {
  testWidgets('shows the configured session-expired widget once', (
    tester,
  ) async {
    final ui = RefreshInit.instance;
    await ui.initialize(
      sessionExpiredWidget: const AlertDialog(
        title: Text('Session expired'),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(navigatorKey: ui.navigatorKey, home: const Scaffold()),
    );

    ui.showSessionExpired();
    ui.showSessionExpired();
    await tester.pumpAndSettle();

    expect(find.text('Session expired'), findsOneWidget);
  });

  testWidgets('presents a callback queued before navigator is ready', (
    tester,
  ) async {
    final ui = RefreshInit.instance;
    await ui.initialize(
      sessionExpiredWidget: const AlertDialog(
        title: Text('Queued expiry'),
      ),
    );

    ui.showSessionExpired();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: ui.navigatorKey, home: const Scaffold()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Queued expiry'), findsOneWidget);
  });
}
