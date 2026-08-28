import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_bootstrap_gate.dart';
import 'theme.dart';
import 'routes.dart';
import 'providers.dart';

class MainApp extends ConsumerWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);

    // Session timeout / forced logout par authenticated user ko wapas
    // /login bhejo (session timeout monitor isi listener ke through
    // navigation trigger karta hai).
    ref.listen<AuthState>(authStateProvider, (previous, next) {
      if (previous?.isAuthenticated == true &&
          !next.isAuthenticated &&
          next.hasCheckedAuth) {
        ref.read(routerProvider).go('/login');
      }
    });

    return MaterialApp.router(
      title: 'HIMS - Hospital Information Management System',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      routerConfig: router,
      // Keep MaterialApp.router mounted from the first frame. The gate covers
      // its routed child while session/hospital state is being restored, so a
      // browser deep link is parsed once and is never consumed by a temporary
      // app or lost when the root widget changes.
      builder: (context, child) =>
          AppBootstrapGate(child: child ?? const SizedBox.shrink()),
    );
  }
}
