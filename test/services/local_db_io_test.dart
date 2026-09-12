import 'dart:ffi';
import 'dart:io';

import 'package:abdm_hims/services/local_db.dart';
import 'package:abdm_hims/services/local_db_io.dart';
import 'package:abdm_hims/services/outbox.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

/// These are real Drift/SQLite integration tests (not mocks): they exercise
/// the atomic `applyTransaction` and the metadata/outbox stores against an
/// in-memory SQLite database.
///
/// On Windows the `sqlite3` package looks for `sqlite3.dll` on the library
/// search path, which the Dart VM test runner does not provide. Point it at
/// the official precompiled SQLite DLL (sqlite.org) kept project-locally under
/// `.qwen/tmp/sqlite3/`. No global PATH change is made.
bool _sqliteAvailable = true;

void _configureProjectLocalSqlite() {
  if (!Platform.isWindows) return;
  final dll = File(
    '${Directory.current.path}${Platform.pathSeparator}'
    '.qwen${Platform.pathSeparator}tmp${Platform.pathSeparator}'
    'sqlite3${Platform.pathSeparator}sqlite3.dll',
  );
  if (dll.existsSync()) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open(dll.path),
    );
  }
}

void main() {
  LocalDriftDatabase? db;
  DriftLocalDatabase? local;

  setUpAll(() async {
    _configureProjectLocalSqlite();
    try {
      final probe = LocalDriftDatabase(NativeDatabase.memory());
      // Force the sqlite3 native library to actually load (constructing the
      // database is lazy; a real query opens the underlying engine).
      await probe.select(probe.patientRecords).get();
      await probe.close();
    } catch (_) {
      _sqliteAvailable = false;
    }
  });

  setUp(() async {
    if (!_sqliteAvailable) return;
    db = LocalDriftDatabase(NativeDatabase.memory());
    local = DriftLocalDatabase(database: db!);
    await local!.init();
  });

  tearDown(() async {
    await local?.close();
  });

  bool requireSqlite() {
    if (_sqliteAvailable) return true;
    markTestSkipped(
      'Skipped: sqlite3 native library is not loadable by the Dart VM '
      'test runner in this environment.',
    );
    return false;
  }

  OutboxEntry outbox(String id, String entity, String recordId) => OutboxEntry(
    operationId: id,
    hospitalId: 'hosp-1',
    deviceId: 'dev-1',
    entity: entity,
    recordId: recordId,
    operationType: SyncOperationType.create,
    payload: {'id': recordId},
    createdAt: DateTime.now(),
  );

  test('applyTransaction commits records + outbox atomically', () async {
    if (!requireSqlite()) return;
    await local!.applyTransaction(
      LocalTransaction(
        records: [
          LocalRecordWrite(
            table: LocalTables.patients,
            offlineId: 'op-1',
            data: {'id': 'p1', 'uhid': 'UHID1', 'first_name': 'A'},
          ),
          LocalRecordWrite(
            table: LocalTables.billing,
            offlineId: 'b1',
            data: {'id': 'bill1', 'bill_number': 'OPD-1', 'paid_amount': 100},
          ),
        ],
        outbox: [
          outbox('op-1', 'patients', 'p1'),
          outbox('b1', 'billing', 'bill1'),
        ],
      ),
    );

    final patients = await local!.getRecords(
      table: LocalTables.patients,
      pendingOnly: true,
    );
    final bills = await local!.getRecords(
      table: LocalTables.billing,
      pendingOnly: true,
    );
    final due = await local!.getDueOutbox();

    expect(patients.length, 1);
    expect(bills.length, 1);
    expect(due.length, 2);
    expect(await local!.outboxPendingCount(), 2);
  });

  test('metadata store persists scoped identity values', () async {
    if (!requireSqlite()) return;
    await local!.setMetadata('identity:public_user_id', 'pub-1');
    await local!.setMetadata('identity:hospital_id', 'hosp-1');

    expect(await local!.getMetadata('identity:public_user_id'), 'pub-1');
    expect(await local!.getMetadata('identity:hospital_id'), 'hosp-1');

    await local!.removeMetadata('identity:hospital_id');
    expect(await local!.getMetadata('identity:hospital_id'), isNull);
    expect(await local!.getMetadata('identity:public_user_id'), 'pub-1');
  });

  test('outbox status transitions are tracked', () async {
    if (!requireSqlite()) return;
    await local!.enqueueOutbox(outbox('op', 'patients', 'p1'));
    expect(await local!.outboxPendingCount(), 1);

    await local!.markOutboxSynced('op');
    expect(await local!.outboxPendingCount(), 0);
    expect(await local!.getDueOutbox(), isEmpty);
  });

  test('failed outbox entries are retried only after nextRetryAt', () async {
    if (!requireSqlite()) return;
    await local!.enqueueOutbox(outbox('op', 'patients', 'p1'));
    await local!.markOutboxFailed(
      'op',
      'timeout',
      DateTime.now().add(const Duration(minutes: 5)),
    );
    expect(await local!.getDueOutbox(), isEmpty);

    await local!.markOutboxFailed(
      'op',
      'timeout',
      DateTime.now().subtract(const Duration(seconds: 1)),
    );
    expect(await local!.getDueOutbox(), hasLength(1));
  });

  test('a failing transaction rolls back business rows AND outbox entries',
      () async {
    if (!requireSqlite()) return;
    await expectLater(
      local!.applyTransaction(
        LocalTransaction(
          records: [
            LocalRecordWrite(
              table: LocalTables.patients,
              offlineId: 'op-1',
              data: {'id': 'p1', 'uhid': 'UHID1'},
            ),
            // An unsupported table aborts the transaction mid-way.
            LocalRecordWrite(
              table: 'not_a_table',
              offlineId: 'bad',
              data: const {},
            ),
          ],
          outbox: [outbox('op-1', 'patients', 'p1')],
        ),
      ),
      throwsA(isA<ArgumentError>()),
    );

    // Rollback: neither the business row nor the outbox entry persisted.
    expect(await local!.getRecords(table: LocalTables.patients), isEmpty);
    expect(await local!.outboxPendingCount(), 0);
  });

  test('data persists after close and reopen (file-backed)', () async {
    if (!requireSqlite()) return;
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'hims_test_${DateTime.now().microsecondsSinceEpoch}.sqlite',
    );
    try {
      final db1 = LocalDriftDatabase(NativeDatabase(file));
      final local1 = DriftLocalDatabase(database: db1);
      await local1.init();
      await local1.applyTransaction(
        LocalTransaction(
          records: [
            LocalRecordWrite(
              table: LocalTables.patients,
              offlineId: 'op-1',
              data: {'id': 'p1', 'uhid': 'UHID-PERSIST'},
            ),
          ],
          outbox: [outbox('op-1', 'patients', 'p1')],
        ),
      );
      await local1.setMetadata('identity:public_user_id', 'pub-1');
      await local1.close();

      // Reopen the same file.
      final db2 = LocalDriftDatabase(NativeDatabase(file));
      final local2 = DriftLocalDatabase(database: db2);
      await local2.init();

      final rows = await local2.getRecords(table: LocalTables.patients);
      expect(rows, hasLength(1));
      expect(rows.first['uhid'], 'UHID-PERSIST');
      expect(await local2.outboxPendingCount(), 1);
      expect(await local2.getMetadata('identity:public_user_id'), 'pub-1');
      await local2.close();
    } finally {
      if (file.existsSync()) file.deleteSync();
    }
  });
}
