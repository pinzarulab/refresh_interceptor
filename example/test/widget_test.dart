import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:refresh_interceptor/refresh_interceptor.dart';
import 'package:refresh_interceptor_example/main.dart';

void main() {
  testWidgets('shows both end-to-end refresh scenarios', (tester) async {
    await RefreshInit.instance.initialize(
      sessionExpiredWidget: const AlertDialog(
        title: Text('Session expired'),
      ),
    );

    await tester.pumpWidget(const ExampleApp());

    expect(find.text('Run successful refresh'), findsOneWidget);
    expect(find.text('Run permanent expiry'), findsOneWidget);
    expect(find.textContaining('http://127.0.0.1:8080'), findsOneWidget);
  });
}
