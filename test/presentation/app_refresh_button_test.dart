import 'dart:async';

import 'package:abdm_hims/app/providers.dart';
import 'package:abdm_hims/core/utils/logger.dart';
import 'package:abdm_hims/presentation/widgets/app_refresh_button.dart';
import 'package:abdm_hims/services/auth_service.dart';
import 'package:abdm_hims/services/database_service.dart';
import 'package:abdm_hims/services/local_db.dart';
import 'package:abdm_hims/services/outbox.dart';
import 'package:abdm_hims/services/sync_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockDatabaseService extends Mock implements DatabaseService {}

class _MockLocalDatabase extends Mock implements LocalDatabase {}

class _MockAuthService extends Mock implements AuthService {}

class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(AuthState initial)
    : super(_MockAuthService(), _MockDatabaseService()) {
    state = initial;
  }
}

class _ThrowingSyncEngine extends SyncEngine {
  _ThrowingSyncEngine({required super.dbService, required super.localDb});

  @override
  Future<void> refreshNow() async {
    throw Exception('sync boom');
  }
}

void main() {
  late _MockDatabaseService db;
  late _MockLocalDatabase localDb;
  late SyncEngine engine;

  setUpAll(AppLogger.init);

  setUp(() {
    db = _MockDatabaseService();
    localDb = _MockLocalDatabase();
    engine = SyncEngine(dbService: db, localDb: localDb);
  });

  /// Reachable server, empty outbox, no conflicts, successful full reconcile.
  void stubHealthySync() {
    when(() => db.probeSupabase()).thenAnswer((_) async => true);
    when(() => db.hasNetwork()).thenAnswer((_) async => true);
    when(
      () => localDb.getDueOutbox(limit: any(named: 'limit')),
    ).thenAnswer((_) async => const <OutboxEntry>[]);
    when(() => localDb.outboxPendingCount()).thenAnswer((_) async => 0);
    when(() => localDb.getConflicts()).thenAnswer((_) async => const []);
    when(() => db.pullChanges()).thenAnswer((_) async => PullOutcome.complete);
    when(() => db.reconcileAllDetailed()).thenAnswer(
      (_) async => {LocalTables.patients: ReconcileOutcome.complete},
    );
  }

  ProviderContainer container({SyncEngine? syncEngine}) {
    return ProviderContainer(
      overrides: [
        databaseServiceProvider.overrideWithValue(db),
        localDatabaseProvider.overrideWithValue(localDb),
        authStateProvider.overrideWith(
          (ref) => _FakeAuthNotifier(
            const AuthState(
              isAuthenticated: true,
              hasCheckedAuth: true,
              userId: 'user-1',
              hospitalId: 'hospital-1',
            ),
          ),
        ),
        syncEngineProvider.overrideWith((ref) => syncEngine ?? engine),
        patientListProvider.overrideWith(
          (ref) => PatientListNotifier(db, () => 'hospital-1'),
        ),
        opdQueueProvider.overrideWith(
          (ref) => OPDQueueNotifier(db, () => 'hospital-1'),
        ),
        hospitalBedsProvider.overrideWith(
          (ref, hospitalId) async => <Map<String, dynamic>>[],
        ),
        voucherStatsProvider.overrideWith(
          (ref, hospitalId) async => <String, dynamic>{},
        ),
      ],
    );
  }

  Future<void> pumpButton(WidgetTester tester, ProviderContainer c) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(appBar: AppBar(actions: const [AppRefreshButton()])),
        ),
      ),
    );
  }

  testWidgets('invokes one coordinated SyncEngine refresh, then metrics', (
    tester,
  ) async {
    stubHealthySync();
    final c = container();
    addTearDown(c.dispose);
    await pumpButton(tester, c);

    await tester.tap(find.byType(AppRefreshButton));
    await tester.pumpAndSettle();

    verify(() => db.pullChanges()).called(1);
    verify(() => db.reconcileAllDetailed()).called(1);
    expect(engine.status.health, SyncHealth.upToDate);
    // Prompt refresh + post-sync refresh.
    expect(c.read(dashboardMetricsRefreshProvider), 2);
  });

  testWidgets('refreshes metric cards immediately and again after sync', (
    tester,
  ) async {
    stubHealthySync();
    final gate = Completer<void>();
    when(() => db.probeSupabase()).thenAnswer((_) async {
      await gate.future;
      return true;
    });

    final c = container();
    addTearDown(c.dispose);
    await pumpButton(tester, c);

    await tester.tap(find.byType(AppRefreshButton));
    await tester.pump();

    // Prompt refresh: the cards already refreshed while the sync is still
    // in flight (the long reconciliation must not gate them).
    expect(c.read(dashboardMetricsRefreshProvider), 1);

    gate.complete();
    await tester.pumpAndSettle();

    // Post-sync refresh with the pulled data.
    expect(c.read(dashboardMetricsRefreshProvider), 2);
  });

  testWidgets('still refreshes data when the sync attempt throws', (
    tester,
  ) async {
    final throwing = _ThrowingSyncEngine(dbService: db, localDb: localDb);
    final c = container(syncEngine: throwing);
    addTearDown(c.dispose);
    await pumpButton(tester, c);

    await tester.tap(find.byType(AppRefreshButton));
    await tester.pumpAndSettle();

    // Both the prompt and the post-sync refresh ran despite the thrown error.
    expect(c.read(dashboardMetricsRefreshProvider), 2);
  });

  testWidgets('disables repeat clicks while a refresh is in progress', (
    tester,
  ) async {
    stubHealthySync();
    final gate = Completer<void>();
    var probes = 0;
    when(() => db.probeSupabase()).thenAnswer((_) async {
      probes++;
      await gate.future;
      return true;
    });

    final c = container();
    addTearDown(c.dispose);
    await pumpButton(tester, c);

    await tester.tap(find.byType(AppRefreshButton));
    await tester.pump();

    // Button is now disabled (spinner shown); a second tap must not start a
    // second refresh.
    await tester.tap(find.byType(AppRefreshButton));
    await tester.pump();
    expect(probes, 1);

    gate.complete();
    await tester.pumpAndSettle();
    expect(probes, 1);
  });

  testWidgets('keeps a screen-specific onRefresh callback', (tester) async {
    stubHealthySync();
    var callbacks = 0;
    final c = container();
    addTearDown(c.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [AppRefreshButton(onRefresh: () => callbacks++)],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(AppRefreshButton));
    await tester.pumpAndSettle();

    expect(callbacks, 1);
  });
}
