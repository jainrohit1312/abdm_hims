import 'package:abdm_hims/services/cache_service.dart';
import 'package:abdm_hims/services/database_service.dart';
import 'package:abdm_hims/services/local_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MockLocalDatabase extends Mock implements LocalDatabase {}

void main() {
  late MockLocalDatabase localDb;
  late DatabaseService service;
  late Map<String, List<Map<String, dynamic>>> records;

  setUp(() {
    localDb = MockLocalDatabase();
    records = {};

    when(() => localDb.init()).thenAnswer((_) async {});

    // getRecords returns the per-table data seeded by each test.
    when(() => localDb.getRecords(table: any(named: 'table'))).thenAnswer((
      inv,
    ) async {
      final table = inv.namedArguments[#table] as String;
      return records[table] ?? const [];
    });

    service = DatabaseService(
      SupabaseClient('http://localhost', 'anon'),
      localDb: localDb,
      cacheService: CacheService.instance,
    );
  });

  Map<String, dynamic> patient(String id, String name, String uhid) => {
    'id': id,
    'hospital_id': 'h1',
    'first_name': name,
    'last_name': '',
    'uhid': uhid,
    'mobile_number': '999',
    'created_at': '2026-09-12T10:00:00.000Z',
  };

  Map<String, dynamic> opd(
    String id,
    String patientId,
    String createdAt, {
    String hospitalId = 'h1',
    int? token,
    String sourceStatus = 'completed',
  }) => {
    'id': id,
    'hospital_id': hospitalId,
    'patient_id': patientId,
    'token_number': token,
    'status': sourceStatus,
    'consultation_fee': 300,
    'payment_amount': 300,
    'paid_amount': 300,
    'balance_amount': 0,
    'payment_status': 'paid',
    'payment_mode': 'cash',
    'visit_date': '2026-09-12',
    'created_at': createdAt,
  };

  test(
    'searchPatientsLocal filters by query and hospital, newest first',
    () async {
      records[LocalTables.patients] = [
        patient('p1', 'Alice', 'OPD1'),
        patient('p2', 'Bob', 'OPD2'),
        patient('p3', 'Ali', 'IPD1'),
        {...patient('p4', 'Other Hospital', 'OPD9'), 'hospital_id': 'h2'},
      ];

      final result = await service.searchPatientsLocal('ali', hospitalId: 'h1');

      expect(result.map((p) => p['id']), containsAll(['p3', 'p1']));
      expect(result.length, 2);
      // The other-hospital patient must never leak in.
      expect(result.map((p) => p['id']), isNot(contains('p4')));
    },
  );

  test('getPatientsLocal paginates hospital-scoped rows', () async {
    records[LocalTables.patients] = [
      patient('p1', 'A', '1'),
      patient('p2', 'B', '2'),
      patient('p3', 'C', '3'),
      {'id': 'p4', 'hospital_id': 'h2', 'first_name': 'D', 'uhid': '4'},
    ];

    final page = await service.getPatientsLocal(
      page: 0,
      limit: 2,
      hospitalId: 'h1',
    );

    expect(page.length, 2);
    expect(page.map((p) => p['hospital_id']).toSet(), {'h1'});
  });

  test('getOPDQueueLocal embeds patient name/uhid and paginates', () async {
    records[LocalTables.patients] = [patient('p1', 'Alice', 'UHID-1')];
    records[LocalTables.opdRegistrations] = [
      opd('o1', 'p1', '2026-09-12T10:00:00.000Z', token: 1),
      opd('o2', 'p1', '2026-09-12T09:00:00.000Z', token: 2),
      opd('o3', 'p1', '2026-09-12T08:00:00.000Z', token: 3, hospitalId: 'h2'),
    ];

    final page = await service.getOPDQueueLocal(
      page: 0,
      limit: 2,
      hospitalId: 'h1',
    );

    expect(page.length, 2);
    expect(page.first['id'], 'o1'); // newest first
    expect(page.first['patients']['first_name'], 'Alice');
    expect(page.first['patients']['uhid'], 'UHID-1');
  });

  test(
    'getBillingHistoryPageLocal merges billing + raw OPD, no duplicates',
    () async {
      records[LocalTables.billing] = [
        {
          'id': 'b1',
          'hospital_id': 'h1',
          'patient_id': 'p1',
          'opd_registration_id': 'o1',
          'source_type': 'opd',
          'bill_number': 'OPD-1',
          'bill_date': '2026-09-12',
          'total_amount': 300,
          'net_amount': 300,
          'paid_amount': 300,
          'balance_amount': 0,
          'payment_status': 'paid',
          'created_at': '2026-09-12T10:00:00.000Z',
        },
      ];
      records[LocalTables.opdRegistrations] = [
        opd('o1', 'p1', '2026-09-12T10:00:00.000Z'), // already materialised
        opd('o2', 'p1', '2026-09-12T11:00:00.000Z'), // raw, not materialised
      ];

      final page = await service.getBillingHistoryPageLocal(
        hospitalId: 'h1',
        sourceType: null,
        page: 0,
        limit: 10,
      );

      // billing o1 + raw o2 => 2 rows, no duplicate for o1.
      expect(page.length, 2);
      final ids = page.map((r) => r['id'] ?? r['opd_registration_id']).toList();
      expect(ids, containsAll(['b1', 'o2']));
      expect(ids.where((i) => i == 'o1').length, 0);
    },
  );
}
