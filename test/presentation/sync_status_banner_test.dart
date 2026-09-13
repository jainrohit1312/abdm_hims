import 'package:abdm_hims/app/providers.dart';
import 'package:abdm_hims/core/utils/logger.dart';
import 'package:abdm_hims/presentation/widgets/sync_status_banner.dart';
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

void main() {
  late _MockDatabaseService db;
  late _MockLocalDatabase localDb;
  late SyncEngine engine;
  late ProviderContainer container;

  setUpAll(AppLogger.init);

  setUp(() {
    db = _MockDatabaseService();
    localDb = _MockLocalDatabase();
    engine = SyncEngine(dbService: db, localDb: localDb);
    container = ProviderContainer(
      overrides: [syncEngineProvider.overrideWith((ref) => engine)],
    );
    addTearDown(container.dispose);

    when(() => db.probeSupabase()).thenAnswer((_) async => true);
    when(() => db.hasNetwork()).thenAnswer((_) async => true);
    when(
      () => localDb.getDueOutbox(limit: any(named: 'limit')),
    ).thenAnswer((_) async => const <OutboxEntry>[]);
    when(() => localDb.outboxPendingCount()).thenAnswer((_) async => 0);
    when(() => localDb.getConflicts()).thenAnswer((_) async => const []);
    when(() => db.pullChanges()).thenAnswer((_) async => PullOutcome.complete);
  });

  Future<void> pumpBanner(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SyncStatusBanner())),
      ),
    );
  }

  testWidgets('rebuilds to up to date when the engine finishes a refresh', (
    tester,
  ) async {
    when(() => db.reconcileAllDetailed()).thenAnswer(
      (_) async => {LocalTables.patients: ReconcileOutcome.complete},
    );

    await pumpBanner(tester);
    expect(find.text('Not synced yet'), findsOneWidget);

    await engine.refreshNow();
    await tester.pump();

    expect(find.text('Up to date'), findsOneWidget);
    expect(find.text('Not synced yet'), findsNothing);
  });

  testWidgets('rebuilds to a visible failure when reconciliation fails', (
    tester,
  ) async {
    when(
      () => db.reconcileAllDetailed(),
    ).thenAnswer((_) async => {LocalTables.patients: ReconcileOutcome.failed});

    await pumpBanner(tester);
    expect(find.text('Not synced yet'), findsOneWidget);

    await engine.refreshNow();
    await tester.pump();

    expect(find.text('Sync failed'), findsOneWidget);
  });

  testWidgets('does not claim up to date when the device is offline', (
    tester,
  ) async {
    when(() => db.probeSupabase()).thenAnswer((_) async => false);
    when(() => db.hasNetwork()).thenAnswer((_) async => false);

    await pumpBanner(tester);

    await engine.refreshNow();
    await tester.pump();

    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Up to date'), findsNothing);
  });
}
