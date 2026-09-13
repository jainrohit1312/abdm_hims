import 'dart:async';

import 'package:abdm_hims/core/utils/logger.dart';
import 'package:abdm_hims/services/database_service.dart';
import 'package:abdm_hims/services/local_db.dart';
import 'package:abdm_hims/services/outbox.dart';
import 'package:abdm_hims/services/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDatabaseService extends Mock implements DatabaseService {}

class MockLocalDatabase extends Mock implements LocalDatabase {}

void main() {
  setUpAll(() {
    AppLogger.init();
    registerFallbackValue(DateTime(2000));
    registerFallbackValue(const <LocalRecordRef>[]);
    registerFallbackValue(
      OutboxEntry(
        operationId: 'fallback',
        hospitalId: 'h',
        deviceId: 'd',
        entity: 'patients',
        recordId: 'r',
        operationType: SyncOperationType.create,
        payload: const {},
      ),
    );
  });

  late MockDatabaseService dbService;
  late MockLocalDatabase localDb;
  late SyncEngine engine;

  setUp(() {
    dbService = MockDatabaseService();
    localDb = MockLocalDatabase();
    engine = SyncEngine(dbService: dbService, localDb: localDb);
  });

  tearDown(() => engine.dispose());

  test('offline device never reports green (no false "up to date")', () async {
    when(() => dbService.probeSupabase()).thenAnswer((_) async => false);
    when(() => dbService.hasNetwork()).thenAnswer((_) async => false);

    await engine.syncNow();

    expect(engine.status.health, SyncHealth.offline);
    expect(engine.status.pullVerified, isFalse);
    expect(engine.status.isGreen, isFalse);
  });

  test(
    'network up but cloud unreachable reports cloudUnreachable (red)',
    () async {
      when(() => dbService.probeSupabase()).thenAnswer((_) async => false);
      when(() => dbService.hasNetwork()).thenAnswer((_) async => true);

      await engine.syncNow();

      expect(engine.status.health, SyncHealth.cloudUnreachable);
      expect(engine.status.pullVerified, isFalse);
    },
  );

  test('reconciled + verified pull => upToDate (green)', () async {
    when(() => dbService.probeSupabase()).thenAnswer((_) async => true);
    when(
      () => localDb.getDueOutbox(limit: any(named: 'limit')),
    ).thenAnswer((_) async => const <OutboxEntry>[]);
    when(() => localDb.outboxPendingCount()).thenAnswer((_) async => 0);
    when(
      () => localDb.getConflicts(),
    ).thenAnswer((_) async => const <SyncConflict>[]);
    when(
      () => dbService.pullChanges(),
    ).thenAnswer((_) async => PullOutcome.complete);
    when(() => dbService.reconcileAllDetailed()).thenAnswer(
      (_) async => {LocalTables.patients: ReconcileOutcome.complete},
    );

    await engine.reconcileNow();
    await engine.syncNow();

    expect(engine.status.health, SyncHealth.upToDate);
    expect(engine.status.pullVerified, isTrue);
    expect(engine.status.reconciliationComplete, isTrue);
    expect(engine.status.pendingUploadCount, 0);
  });

  test('incremental caught up but not reconciled => not green', () async {
    when(() => dbService.probeSupabase()).thenAnswer((_) async => true);
    when(
      () => localDb.getDueOutbox(limit: any(named: 'limit')),
    ).thenAnswer((_) async => const <OutboxEntry>[]);
    when(() => localDb.outboxPendingCount()).thenAnswer((_) async => 0);
    when(
      () => localDb.getConflicts(),
    ).thenAnswer((_) async => const <SyncConflict>[]);
    when(
      () => dbService.pullChanges(),
    ).thenAnswer((_) async => PullOutcome.complete);

    await engine.syncNow();

    expect(engine.status.health, SyncHealth.downloading);
    expect(engine.status.isGreen, isFalse);
    expect(engine.status.reconciliationComplete, isFalse);
  });

  test('missing migration => setupRequired (never green)', () async {
    when(() => dbService.probeSupabase()).thenAnswer((_) async => true);
    when(
      () => localDb.getDueOutbox(limit: any(named: 'limit')),
    ).thenAnswer((_) async => const <OutboxEntry>[]);
    when(() => localDb.outboxPendingCount()).thenAnswer((_) async => 0);
    when(
      () => localDb.getConflicts(),
    ).thenAnswer((_) async => const <SyncConflict>[]);
    when(
      () => dbService.pullChanges(),
    ).thenAnswer((_) async => PullOutcome.setupIncomplete);

    await engine.syncNow();

    expect(engine.status.health, SyncHealth.setupRequired);
    expect(engine.status.pullVerified, isFalse);
    expect(engine.status.isGreen, isFalse);
  });

  test('pending upload that fails stays amber (awaiting upload)', () async {
    final entry = OutboxEntry(
      operationId: 'op-1',
      hospitalId: 'h',
      deviceId: 'd',
      entity: 'patients',
      recordId: 'r',
      operationType: SyncOperationType.create,
      payload: const {'first_name': 'A'},
    );

    when(() => dbService.probeSupabase()).thenAnswer((_) async => true);
    when(
      () => localDb.getDueOutbox(limit: any(named: 'limit')),
    ).thenAnswer((_) async => [entry]);
    when(
      () => dbService.syncOutboxEntry(any()),
    ).thenAnswer((_) async => OutboxUploadResult.retryableFailure);
    when(
      () => localDb.markOutboxFailed(any(), any(), any()),
    ).thenAnswer((_) async {});
    when(() => localDb.outboxPendingCount()).thenAnswer((_) async => 1);
    when(
      () => localDb.getConflicts(),
    ).thenAnswer((_) async => const <SyncConflict>[]);
    when(
      () => dbService.pullChanges(),
    ).thenAnswer((_) async => PullOutcome.failed);

    await engine.syncNow();

    expect(engine.status.health, SyncHealth.awaitingUpload);
    expect(engine.status.pendingUploadCount, 1);
    expect(engine.status.pullVerified, isFalse);
  });

  test('acknowledged upload is marked synced', () async {
    final entry = OutboxEntry(
      operationId: 'op-1',
      hospitalId: 'h',
      deviceId: 'd',
      entity: 'patients',
      recordId: 'r',
      operationType: SyncOperationType.create,
      payload: const {'first_name': 'A'},
    );

    when(() => dbService.probeSupabase()).thenAnswer((_) async => true);
    when(
      () => localDb.getDueOutbox(limit: any(named: 'limit')),
    ).thenAnswer((_) async => [entry]);
    when(
      () => dbService.syncOutboxEntry(any()),
    ).thenAnswer((_) async => OutboxUploadResult.acknowledged);
    when(
      () => dbService.acknowledgedLocalRecords(any()),
    ).thenAnswer((_) => const <LocalRecordRef>[]);
    when(
      () => localDb.markOutboxSynced(
        'op-1',
        syncedRecords: any(named: 'syncedRecords'),
      ),
    ).thenAnswer((_) async {});
    when(() => localDb.outboxPendingCount()).thenAnswer((_) async => 0);
    when(
      () => localDb.getConflicts(),
    ).thenAnswer((_) async => const <SyncConflict>[]);
    when(
      () => dbService.pullChanges(),
    ).thenAnswer((_) async => PullOutcome.complete);
    when(() => dbService.reconcileAllDetailed()).thenAnswer(
      (_) async => {LocalTables.patients: ReconcileOutcome.complete},
    );

    await engine.reconcileNow();
    await engine.syncNow();

    verify(
      () => localDb.markOutboxSynced(
        'op-1',
        syncedRecords: any(named: 'syncedRecords'),
      ),
    ).called(1);
    expect(engine.status.health, SyncHealth.upToDate);
  });

  test('unresolved conflict forces attention state', () async {
    when(() => dbService.probeSupabase()).thenAnswer((_) async => true);
    when(
      () => localDb.getDueOutbox(limit: any(named: 'limit')),
    ).thenAnswer((_) async => const <OutboxEntry>[]);
    when(() => localDb.outboxPendingCount()).thenAnswer((_) async => 0);
    when(() => localDb.getConflicts()).thenAnswer(
      (_) async => [
        SyncConflict(
          entity: 'patients',
          recordId: 'r',
          localPayload: const {'first_name': 'Local'},
          remotePayload: const {'first_name': 'Remote'},
          baseVersion: 1,
          detectedAt: DateTime.now(),
        ),
      ],
    );
    when(
      () => dbService.pullChanges(),
    ).thenAnswer((_) async => PullOutcome.complete);

    await engine.syncNow();

    expect(engine.status.health, SyncHealth.conflict);
    expect(engine.status.conflictCount, 1);
  });

  group('coordinated refreshNow', () {
    /// Stubs a reachable server with an empty outbox and no conflicts.
    void stubHealthySync() {
      when(() => dbService.probeSupabase()).thenAnswer((_) async => true);
      when(() => dbService.hasNetwork()).thenAnswer((_) async => true);
      when(
        () => localDb.getDueOutbox(limit: any(named: 'limit')),
      ).thenAnswer((_) async => const <OutboxEntry>[]);
      when(() => localDb.outboxPendingCount()).thenAnswer((_) async => 0);
      when(
        () => localDb.getConflicts(),
      ).thenAnswer((_) async => const <SyncConflict>[]);
      when(
        () => dbService.pullChanges(),
      ).thenAnswer((_) async => PullOutcome.complete);
    }

    test('runs pull then reconciliation once and ends upToDate', () async {
      stubHealthySync();
      var reconciled = 0;
      when(() => dbService.reconcileAllDetailed()).thenAnswer((_) async {
        reconciled++;
        return {LocalTables.patients: ReconcileOutcome.complete};
      });

      await engine.refreshNow();

      expect(reconciled, 1);
      expect(engine.status.health, SyncHealth.upToDate);
      expect(engine.status.reconciliationComplete, isTrue);
      expect(engine.status.isGreen, isTrue);
    });

    test('overlapping manual refreshes coalesce into one pass', () async {
      final gate = Completer<void>();
      var probes = 0;
      when(() => dbService.probeSupabase()).thenAnswer((_) async {
        probes++;
        await gate.future;
        return true;
      });
      when(() => dbService.hasNetwork()).thenAnswer((_) async => true);
      when(
        () => localDb.getDueOutbox(limit: any(named: 'limit')),
      ).thenAnswer((_) async => const <OutboxEntry>[]);
      when(() => localDb.outboxPendingCount()).thenAnswer((_) async => 0);
      when(
        () => localDb.getConflicts(),
      ).thenAnswer((_) async => const <SyncConflict>[]);
      when(
        () => dbService.pullChanges(),
      ).thenAnswer((_) async => PullOutcome.complete);
      var reconciled = 0;
      when(() => dbService.reconcileAllDetailed()).thenAnswer((_) async {
        reconciled++;
        return {LocalTables.patients: ReconcileOutcome.complete};
      });

      final first = engine.refreshNow();
      final second = engine.refreshNow();
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future.wait([first, second]);

      expect(probes, 1);
      expect(reconciled, 1);
    });

    test(
      'manual refresh during a scheduled sync is serialized (one upload)',
      () async {
        final gate = Completer<void>();
        final entry = OutboxEntry(
          operationId: 'op-1',
          hospitalId: 'h',
          deviceId: 'd',
          entity: 'patients',
          recordId: 'r',
          operationType: SyncOperationType.create,
          payload: const {'first_name': 'A'},
        );

        var probes = 0;
        when(() => dbService.probeSupabase()).thenAnswer((_) async {
          probes++;
          await gate.future;
          return true;
        });
        when(() => dbService.hasNetwork()).thenAnswer((_) async => true);
        when(
          () => localDb.getDueOutbox(limit: any(named: 'limit')),
        ).thenAnswer((_) async => [entry]);
        var uploads = 0;
        when(() => dbService.syncOutboxEntry(any())).thenAnswer((_) async {
          uploads++;
          return OutboxUploadResult.acknowledged;
        });
        when(
          () => dbService.acknowledgedLocalRecords(any()),
        ).thenAnswer((_) => const <LocalRecordRef>[]);
        when(
          () => localDb.markOutboxSynced(
            any(),
            syncedRecords: any(named: 'syncedRecords'),
          ),
        ).thenAnswer((_) async {});
        when(() => localDb.outboxPendingCount()).thenAnswer((_) async => 0);
        when(
          () => localDb.getConflicts(),
        ).thenAnswer((_) async => const <SyncConflict>[]);
        when(
          () => dbService.pullChanges(),
        ).thenAnswer((_) async => PullOutcome.complete);
        when(() => dbService.reconcileAllDetailed()).thenAnswer(
          (_) async => {LocalTables.patients: ReconcileOutcome.complete},
        );

        final scheduled = engine.syncNow();
        final manual = engine.refreshNow();
        await Future<void>.delayed(Duration.zero);
        gate.complete();
        await Future.wait([scheduled, manual]);

        expect(probes, 1);
        expect(uploads, 1);
        expect(engine.status.health, SyncHealth.upToDate);
      },
    );

    test('reconciliation failure becomes a visible failure status', () async {
      stubHealthySync();
      when(() => dbService.reconcileAllDetailed()).thenAnswer(
        (_) async => {LocalTables.patients: ReconcileOutcome.failed},
      );

      await engine.refreshNow();

      expect(engine.status.health, SyncHealth.syncFailed);
      expect(engine.status.isGreen, isFalse);
      expect(engine.status.failureReason, isNotNull);
    });

    test('reconciliation exception becomes a visible failure status', () async {
      stubHealthySync();
      when(
        () => dbService.reconcileAllDetailed(),
      ).thenThrow(Exception('db down'));

      await engine.refreshNow();

      expect(engine.status.health, SyncHealth.syncFailed);
      expect(engine.status.failureReason, contains('Reconciliation failed'));
    });

    test('a partial reconciliation stays downloading, never green', () async {
      stubHealthySync();
      when(() => dbService.reconcileAllDetailed()).thenAnswer(
        (_) async => {LocalTables.patients: ReconcileOutcome.partial},
      );

      await engine.refreshNow();

      expect(engine.status.health, SyncHealth.downloading);
      expect(engine.status.reconciliationComplete, isFalse);
      expect(engine.status.isGreen, isFalse);
    });

    test('a later successful refresh clears the previous failure', () async {
      stubHealthySync();
      when(() => dbService.reconcileAllDetailed()).thenAnswer(
        (_) async => {LocalTables.patients: ReconcileOutcome.failed},
      );

      await engine.refreshNow();
      expect(engine.status.health, SyncHealth.syncFailed);

      when(() => dbService.reconcileAllDetailed()).thenAnswer(
        (_) async => {LocalTables.patients: ReconcileOutcome.complete},
      );
      await engine.refreshNow();

      expect(engine.status.health, SyncHealth.upToDate);
      expect(engine.status.failureReason, isNull);
    });

    test(
      'offline refresh never claims up to date and does not reconcile',
      () async {
        when(() => dbService.probeSupabase()).thenAnswer((_) async => false);
        when(() => dbService.hasNetwork()).thenAnswer((_) async => true);
        var reconciled = 0;
        when(() => dbService.reconcileAllDetailed()).thenAnswer((_) async {
          reconciled++;
          return <String, ReconcileOutcome>{};
        });

        await engine.refreshNow();

        expect(engine.status.health, SyncHealth.cloudUnreachable);
        expect(reconciled, 0);
        expect(engine.status.isGreen, isFalse);
      },
    );

    test('a sync-pass failure stays failed and skips reconciliation', () async {
      when(() => dbService.probeSupabase()).thenThrow(Exception('probe boom'));
      var reconciled = 0;
      when(() => dbService.reconcileAllDetailed()).thenAnswer((_) async {
        reconciled++;
        return <String, ReconcileOutcome>{};
      });

      await engine.refreshNow();

      expect(engine.status.health, SyncHealth.syncFailed);
      expect(engine.status.isGreen, isFalse);
      expect(reconciled, 0);
    });

    test('start immediately runs a coordinated pass', () async {
      stubHealthySync();
      when(() => dbService.reconcileAllDetailed()).thenAnswer(
        (_) async => {LocalTables.patients: ReconcileOutcome.complete},
      );

      engine.start();
      await pumpEventQueue();

      expect(engine.status.health, SyncHealth.upToDate);
      engine.stop();
    });

    test('reset returns the engine to neutral', () async {
      when(() => dbService.probeSupabase()).thenAnswer((_) async => false);
      when(() => dbService.hasNetwork()).thenAnswer((_) async => true);

      engine.start();
      engine.reset();

      expect(engine.status.health, SyncHealth.neutral);
    });
  });
}
