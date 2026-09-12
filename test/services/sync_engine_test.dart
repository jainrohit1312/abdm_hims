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
    when(() => dbService.reconcileAll()).thenAnswer((_) async => true);

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
    when(() => dbService.reconcileAll()).thenAnswer((_) async => true);

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
}
