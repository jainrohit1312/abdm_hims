import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../services/sync_engine.dart';
import 'providers.dart';
import 'sync_lifecycle.dart';

class AppBootstrapGate extends ConsumerStatefulWidget {
  const AppBootstrapGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppBootstrapGate> createState() => _AppBootstrapGateState();
}

class _AppBootstrapGateState extends ConsumerState<AppBootstrapGate> {
  Future<void>? _bootstrapFuture;
  String? _error;
  bool _isLoading = true;

  /// Hospital id the sync engine is currently running for. Used to detect a
  /// hospital change and to reset on logout.
  SyncEngine? _syncEngine;
  SyncLifecycleCoordinator? _syncLifecycle;

  @override
  void initState() {
    super.initState();
    // ✅ Provider ko modify karne ke liye widget tree build hone ke BAAD wait karo
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startBootstrap();
    });
  }

  void _startBootstrap({bool force = false}) {
    if (_bootstrapFuture != null) return;
    _bootstrapFuture = _bootstrap(force: force).whenComplete(() {
      _bootstrapFuture = null;
    });
  }

  Future<void> _bootstrap({required bool force}) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await ref.read(authStateProvider.notifier).bootstrap(force: force);

      final session = Supabase.instance.client.auth.currentSession;
      final authState = ref.read(authStateProvider);
      final hospitalId = authState.hospitalId;

      if (session != null && hospitalId == null) {
        throw StateError(
          'Authentication restored, but hospital context was not loaded',
        );
      }

      // Register this device for FCM push notifications and subscribe it to
      // the hospital topic (`hospital_{hospitalId}`). `user_devices.user_id`
      // public `users.id` store karta hai, isliye public id resolve karke
      // pass karte hain (auth.users UUID nahi).
      if (hospitalId != null && hospitalId.isNotEmpty) {
        final publicUserId = await ref
            .read(databaseServiceProvider)
            .getCurrentUsersTableId();
        if (publicUserId != null) {
          unawaited(
            ref
                .read(pushNotificationServiceProvider)
                .initialize(userId: publicUserId, hospitalId: hospitalId),
          );
        }
      }

      // Pre-warm the 5-minute Hive cache (doctors, departments, medicines,
      // patients) so the first screen load of every module is instant.
      if (hospitalId != null && hospitalId.isNotEmpty) {
        unawaited(
          ref
              .read(databaseServiceProvider)
              .fetchAndCacheData(hospitalId: hospitalId),
        );
        // Durably mirror read-only master data (doctors, departments, hospital
        // profile) for offline OPD + slip printing.
        unawaited(
          ref
              .read(databaseServiceProvider)
              .cacheMasterData(hospitalId: hospitalId),
        );
      }

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Keeps the single [SyncEngine] in lock-step with the authenticated session.
  ///
  /// It starts as soon as a session + hospital context exist, restarts on a
  /// hospital change, and resets on logout — all without a process restart, so
  /// login after logout starts syncing again instead of staying neutral.
  void _syncWithAuth(AuthState authState) {
    final engine = ref.read(syncEngineProvider);
    if (!identical(_syncEngine, engine)) {
      // The engine provider was rebuilt — drive the new instance.
      _syncEngine = engine;
      _syncLifecycle = SyncLifecycleCoordinator(engine);
    }
    _syncLifecycle!.onAuthStateChanged(authState);
  }

  void _retry() {
    _startBootstrap(force: true);
  }

  @override
  Widget build(BuildContext context) {
    // React to session/hospital changes so sync never silently stays off after
    // a logout → login cycle or a hospital switch.
    ref.listen<AuthState>(authStateProvider, (_, next) => _syncWithAuth(next));

    if (_isLoading) {
      return const Directionality(
        textDirection: TextDirection.ltr,
        child: Material(
          color: Colors.white,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (_error != null) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Material(
          color: Colors.white,
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 52),
                  const SizedBox(height: 16),
                  Text(
                    'Application startup failed:\n$_error',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(onPressed: _retry, child: const Text('Retry')),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return widget.child;
  }
}
