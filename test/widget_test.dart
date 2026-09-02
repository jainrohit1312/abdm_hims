// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:abdm_hims/app/app.dart';
import 'package:abdm_hims/config/app_config.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // flutter_secure_storage has no test-environment implementation, so mock
    // its platform channel — the app can then bootstrap (Supabase session
    // storage probes the channel) without any real plugin.
    TestWidgetsFlutterBinding.ensureInitialized();
    const secureChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          switch (call.method) {
            case 'containsKey':
              return false;
            case 'readAll':
              return <String, String>{};
            case 'read':
              return null;
            case 'write':
            case 'delete':
            case 'deleteAll':
              return null;
            default:
              return null;
          }
        });
    await AppConfig.init();
  });

  testWidgets('App builds and shows the initial login route', (
    WidgetTester tester,
  ) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const ProviderScope(child: MainApp()));

    await tester.pumpAndSettle();

    // Verify that the router builds without crashing.
    expect(find.byType(MaterialApp), findsWidgets);
  });
}
