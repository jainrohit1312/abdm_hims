import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/app.dart';
import 'config/app_config.dart';
import 'core/utils/logger.dart';
import 'services/local_db.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.init();
  await AppConfig.init();
  // Offline-first local store: Hive on web, drift/SQLite on Android & Windows.
  await initializeLocalDatabase();

  runApp(const ProviderScope(child: MainApp()));
}
