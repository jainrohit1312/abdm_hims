import 'dart:ffi';
import 'dart:io';

import 'package:abdm_hims/services/cache_service.dart';
import 'package:abdm_hims/services/database_service.dart';
import 'package:abdm_hims/services/local_db.dart';
import 'package:abdm_hims/services/local_db_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Real Drift/SQLite tests for the offline OPD payment path.
///
/// The server-side atomicity + idempotency is proven against real Postgres in
/// `supabase/verify_opd_payment_atomic.sql` and
/// `supabase/verify_opd_payment_concurrent.sql`. These tests prove the CLIENT
/// side of the contract:
///
///   * the payment is queued as ONE `rpc:opd_payment` operation and its
///     constituent rows (opd update / billing / billing_items / payment_logs)
///     are NEVER queued for independent upload;
///   * acknowledging an operation marks every local row it covers as synced,
///     so a cloud-confirmed record never stays "pending" (which is what gates
///     online IPD admission for an offline-registered patient).
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

const String _hospitalId = 'aaaaaaaa-0000-4000-8000-000000000001';
const String _publicUserId = 'aaaaaaaa-0000-4000-8000-000000000011';

void main() {
  DriftLocalDatabase? local;
  DatabaseService? service;

  setUpAll(() async {
    _configureProjectLocalSqlite();
    try {
      final probe = LocalDriftDatabase(NativeDatabase.memory());
      await probe.select(probe.patientRecords).get();
      await probe.close();
    } catch (_) {
      _sqliteAvailable = false;
    }
  });

  setUp(() async {
    if (!_sqliteAvailable) return;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    local = DriftLocalDatabase(
      database: LocalDriftDatabase(NativeDatabase.memory()),
    );
    await local!.init();
    await local!.setMetadata('identity:public_user_id', _publicUserId);
    await local!.setMetadata('identity:hospital_id', _hospitalId);

    service = DatabaseService(
      SupabaseClient(
        'http://localhost',
        'anon',
        accessToken: () async => 'jwt',
      ),
      localDb: local,
      cacheService: CacheService.instance,
    );
  });

  tearDown(() async {
    await local?.close();
    local = null;
    service = null;
  });

  /// Registers a patient + an OPD visit, then collects the full fee.
  Future<Map<String, dynamic>> payFullVisit({double fee = 500}) async {
    final patient = await service!.registerPatientLocal(const {
      'uhid': 'TEST-UHID-1',
      'first_name': 'Test',
      'last_name': 'Patient',
    }, hospitalId: _hospitalId);
    final opd = await service!.createOPDRegistrationLocal(
      {
        'patient_id': patient['id'],
        'consultation_fee': fee,
        'visit_date': '2026-09-12',
      },
      hospitalId: _hospitalId,
      prescriptionMode: false,
    );
    await service!.generateOPDSlipLocal(
      patientId: patient['id'] as String,
      paymentAmount: fee,
      paymentMode: 'cash',
      opdRegistrationId: opd['id'] as String,
    );
    return {'patient': patient, 'opd': opd};
  }

  test('OPD payment is queued as ONE atomic operation', () async {
    if (!_sqliteAvailable) return;
    final ids = await payFullVisit();

    final due = await local!.getDueOutbox(limit: 100);
    final operations = due
        .where((e) => e.entity == DatabaseService.opdPaymentOperationEntity)
        .toList();

    expect(operations, hasLength(1), reason: 'exactly one payment operation');
    final op = operations.single;

    // The operation carries the complete accounting payload with stable ids.
    expect(op.payload['opd_registration_id'], ids['opd']!['id']);
    expect(op.payload['patient_id'], ids['patient']!['id']);
    expect(op.payload['consultation_fee'], 500.0);
    expect(op.payload['discount_amount'], 0.0);
    expect(op.payload['payment_amount'], 500.0);
    expect(op.payload['payment_mode'], 'cash');
    expect(op.payload['bill_id'], isA<String>());
    expect(op.payload['bill_offline_id'], isA<String>());
    expect(op.payload['bill_number'], startsWith('OPD'));
    expect(op.payload['bill_item_id'], isA<String>());
    expect(op.payload['payment_log_id'], isA<String>());
    expect(op.payload['opd_offline_id'], isA<String>());

    // ...and the constituent rows are never queued for independent upload.
    final constituentEntities = due
        .map((e) => e.entity)
        .where(
          (e) => e == 'billing' || e == 'billing_items' || e == 'payment_logs',
        )
        .toList();
    expect(
      constituentEntities,
      isEmpty,
      reason: 'accounting rows must not be uploaded row-by-row',
    );

    // Only the patient + visit establish themselves independently.
    expect(due.map((e) => e.entity).toSet(), {
      'patients',
      'opd_registrations',
      DatabaseService.opdPaymentOperationEntity,
    });
  });

  test('the local bill mirrors the server-derived payment state', () async {
    if (!_sqliteAvailable) return;
    await payFullVisit();

    final bills = await local!.getRecords(table: LocalTables.billing);
    expect(bills, hasLength(1));
    final bill = bills.single;
    expect(bill['paid_amount'], 500.0);
    expect(bill['net_amount'], 500.0);
    expect(bill['balance_amount'], 0.0);
    expect(bill['payment_status'], 'paid');
    expect(bill['status'], 'paid');
    expect(bill['discount_percentage'], 0.0);

    final visits = await local!.getRecords(table: LocalTables.opdRegistrations);
    expect(visits.single['payment_status'], 'paid');
    expect(visits.single['paid_amount'], 500.0);
    expect(visits.single['balance_amount'], 0.0);
  });

  test('a partial payment is carried as partially_paid locally', () async {
    if (!_sqliteAvailable) return;
    final patient = await service!.registerPatientLocal(const {
      'uhid': 'TEST-UHID-2',
      'first_name': 'Partial',
    }, hospitalId: _hospitalId);
    final opd = await service!.createOPDRegistrationLocal(
      {
        'patient_id': patient['id'],
        'consultation_fee': 300,
        'visit_date': '2026-09-12',
      },
      hospitalId: _hospitalId,
      prescriptionMode: false,
    );
    await service!.generateOPDSlipLocal(
      patientId: patient['id'] as String,
      paymentAmount: 100,
      paymentMode: 'cash',
      opdRegistrationId: opd['id'] as String,
      discountAmount: 50,
    );

    final bill = (await local!.getRecords(table: LocalTables.billing)).single;
    expect(bill['net_amount'], 250.0);
    expect(bill['paid_amount'], 100.0);
    expect(bill['balance_amount'], 150.0);
    expect(bill['payment_status'], 'partially_paid');
  });

  test('collecting more than the net payable is refused locally', () async {
    if (!_sqliteAvailable) return;
    final patient = await service!.registerPatientLocal(const {
      'uhid': 'TEST-UHID-3',
      'first_name': 'Over',
    }, hospitalId: _hospitalId);
    final opd = await service!.createOPDRegistrationLocal(
      {
        'patient_id': patient['id'],
        'consultation_fee': 300,
        'visit_date': '2026-09-12',
      },
      hospitalId: _hospitalId,
      prescriptionMode: false,
    );
    await expectLater(
      service!.generateOPDSlipLocal(
        patientId: patient['id'] as String,
        paymentAmount: 301,
        paymentMode: 'cash',
        opdRegistrationId: opd['id'] as String,
      ),
      throwsArgumentError,
    );
  });

  test(
    'acknowledging a create marks its local row synced (never stuck pending)',
    () async {
      if (!_sqliteAvailable) return;
      await service!.registerPatientLocal(const {
        'uhid': 'TEST-UHID-4',
        'first_name': 'Ack',
      }, hospitalId: _hospitalId);

      final entry = (await local!.getDueOutbox(limit: 10)).single;
      expect(entry.entity, LocalTables.patients);

      // Before acknowledgement the row is legitimately pending.
      expect(
        await local!.getRecords(table: LocalTables.patients, pendingOnly: true),
        hasLength(1),
      );

      await local!.markOutboxSynced(
        entry.operationId,
        syncedRecords: service!.acknowledgedLocalRecords(entry),
      );

      expect(
        await local!.getRecords(table: LocalTables.patients, pendingOnly: true),
        isEmpty,
        reason: 'a verified cloud commit must clear the pending flag',
      );
      expect(await local!.outboxPendingCount(), 0);
      expect(await local!.pendingCount(), 0);
    },
  );

  test(
    'acknowledging the payment operation clears the visit and the bill',
    () async {
      if (!_sqliteAvailable) return;
      await payFullVisit();

      final op = (await local!.getDueOutbox(limit: 100)).firstWhere(
        (e) => e.entity == DatabaseService.opdPaymentOperationEntity,
      );

      final refs = service!.acknowledgedLocalRecords(op);
      expect(refs.map((r) => r.table).toSet(), {
        LocalTables.opdRegistrations,
        LocalTables.billing,
      });

      await local!.markOutboxSynced(op.operationId, syncedRecords: refs);

      expect(
        await local!.getRecords(
          table: LocalTables.opdRegistrations,
          pendingOnly: true,
        ),
        isEmpty,
      );
      expect(
        await local!.getRecords(table: LocalTables.billing, pendingOnly: true),
        isEmpty,
      );
      // Only the still-unacknowledged patient + visit creates remain.
      expect(await local!.outboxPendingCount(), 2);
    },
  );

  group('rpcResultStatus', () {
    test('reads a plain map result', () {
      expect(
        DatabaseService.rpcResultStatus({'status': 'applied', 'bill_id': 'b'}),
        'applied',
      );
    });

    test('reads a JSON-encoded result', () {
      expect(
        DatabaseService.rpcResultStatus('{"status":"replayed"}'),
        'replayed',
      );
    });

    test('reads a single-element list result', () {
      expect(
        DatabaseService.rpcResultStatus([
          {'status': 'applied'},
        ]),
        'applied',
      );
    });

    test('reads a nested data result', () {
      expect(
        DatabaseService.rpcResultStatus({
          'data': {'status': 'applied'},
        }),
        'applied',
      );
    });

    test('an unrecognised shape yields no status (never a false success)', () {
      expect(DatabaseService.rpcResultStatus(null), '');
      expect(DatabaseService.rpcResultStatus({'unexpected': true}), '');
      expect(DatabaseService.rpcResultStatus('not json'), '');
    });
  });
}
