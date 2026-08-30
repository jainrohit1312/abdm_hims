import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/app.dart';
import 'config/app_config.dart';
import 'core/utils/keyboard_inset.dart';
import 'core/utils/logger.dart';
import 'services/local_db.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Web (mobile browser) mein virtual keyboard ki height khud track karte hain
  // taaki keyboard khulne par form fields chhupe nahi. Native par no-op hai.
  KeyboardInset.ensureConfigured();
  AppLogger.init();
  await AppConfig.init();
  // Offline-first local store: Hive on web, drift/SQLite on Android & Windows.
  await initializeLocalDatabase();

  runApp(const ProviderScope(child: MainApp()));
}
