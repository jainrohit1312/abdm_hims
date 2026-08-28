import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'providers.dart';

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

      // Start the offline-first background sync engine (30-second timer) once
      // we have a valid session. Pending records saved while offline will now
      // upload and the dashboard Sync Status indicator will reflect it.
      ref.read(backgroundSyncServiceProvider).start();

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

  void _retry() {
    _startBootstrap(force: true);
  }

  @override
  Widget build(BuildContext context) {
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
