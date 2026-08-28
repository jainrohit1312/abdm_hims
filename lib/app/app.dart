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

    // Auth state route ke saath sync rakho:
    //  * Restored session ke saath /login par refresh hua hai -> /dashboard
    //    (ya /subscription) le jao.
    //  * Deliberate logout / session invalidation -> /login le jao.
    // Persistent login ka matlab hai ki in-memory auth state restore hote hi
    // UI bhi sahi route par pahunch jaye.
    ref.listen<AuthState>(authStateProvider, (previous, next) {
      if (!next.hasCheckedAuth) return;

      final router = ref.read(routerProvider);
      final currentPath = router.routerDelegate.currentConfiguration.uri.path;
      final isPublicPath =
          currentPath == '/' ||
          currentPath == '/login' ||
          currentPath == '/register';

      if (!next.isAuthenticated) {
        if (previous?.isAuthenticated == true && !isPublicPath) {
          router.go('/login');
        }
        return;
      }

      // Authenticated state restored/changed.
      if (next.subscriptionExpired) {
        if (currentPath != '/subscription') router.go('/subscription');
      } else if (isPublicPath) {
        router.go('/dashboard');
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
