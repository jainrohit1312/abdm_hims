import 'dart:convert';

import 'package:abdm_hims/core/utils/logger.dart';
import 'package:abdm_hims/services/cache_service.dart';
import 'package:abdm_hims/services/database_service.dart';
import 'package:abdm_hims/services/local_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MockLocalDatabase extends Mock implements LocalDatabase {}

/// `fetchDataCached` writes a *subset* back into a shared table whenever it is
/// given filters (for example one admission's bills out of every bill). It must
/// merge those rows, never clear the table: the local `billing` cache also
/// holds offline-created records the server has not seen yet.
void main() {
  late MockLocalDatabase localDb;
  late Map<String, List<Map<String, dynamic>>> records;
  late List<Map<String, dynamic>> saved;

  setUpAll(AppLogger.init);

  DatabaseService serviceReturning(List<Map<String, dynamic>> rows) {
    return DatabaseService(
      SupabaseClient(
        'http://localhost',
        'anon',
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode(rows),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          ),
        ),
      ),
      localDb: localDb,
      cacheService: CacheService.instance,
    );
  }

  Map<String, dynamic> bill(String id, {required String admissionId}) => {
    'id': id,
    'hospital_id': 'h1',
    'ipd_admission_id': admissionId,
    'total_amount': 100,
  };

  setUp(() {
    localDb = MockLocalDatabase();
    records = {};
    saved = [];

    when(() => localDb.init()).thenAnswer((_) async {});

    when(() => localDb.getRecords(table: any(named: 'table'))).thenAnswer((
      inv,
    ) async {
      final table = inv.namedArguments[#table] as String;
      return records[table] ?? const [];
    });
    when(
      () => localDb.getRecords(
        table: any(named: 'table'),
        pendingOnly: any(named: 'pendingOnly'),
      ),
    ).thenAnswer((inv) async {
      final table = inv.namedArguments[#table] as String;
      final pendingOnly = inv.namedArguments[#pendingOnly] as bool;
      if (!pendingOnly) return records[table] ?? const [];
      return (records[table] ?? const [])
          .where((r) => r['is_synced'] == false)
          .toList();
    });

    when(
      () => localDb.saveRecord(
        table: any(named: 'table'),
        offlineId: any(named: 'offlineId'),
        data: any(named: 'data'),
        isSynced: any(named: 'isSynced'),
      ),
    ).thenAnswer((inv) async {
      saved.add(inv.namedArguments[#data] as Map<String, dynamic>);
    });
    when(
      () => localDb.replaceRecords(
        table: any(named: 'table'),
        records: any(named: 'records'),
      ),
    ).thenAnswer((_) async {});
  });

  test('a filtered fetch merges rows instead of wiping the local cache', () async {
    // Another admission's bill is already cached; a fetch scoped to `a1` must
    // not delete it.
    records[LocalTables.billing] = [bill('b-other', admissionId: 'a2')];
    final service = serviceReturning([bill('b1', admissionId: 'a1')]);

    final rows = await service.fetchDataCached(
      table: LocalTables.billing,
      filters: {'ipd_admission_id': 'a1'},
    );

    // The local mirror of the other admission is not returned either.
    expect(rows.map((r) => r['id']), ['b1']);
    expect(saved.map((r) => r['id']), ['b1']);
    expect(saved.single['is_synced'], isTrue);
    verifyNever(
      () => localDb.replaceRecords(
        table: any(named: 'table'),
        records: any(named: 'records'),
      ),
    );
  });

  test('a filtered fetch never overwrites a row with pending local writes', () async {
    records[LocalTables.billing] = [
      {
        ...bill('b-offline', admissionId: 'a1'),
        'offline_id': 'b-offline',
        'is_synced': false,
      },
    ];
    final service = serviceReturning([
      {
        ...bill('b-offline', admissionId: 'a1'),
        'offline_id': 'b-offline',
        'bill_type': 'ipd',
      },
    ]);

    // Filtered on a field the pending row does not have, so the fetch reaches
    // the cloud and comes back with that same record.
    await service.fetchDataCached(
      table: LocalTables.billing,
      filters: {'bill_type': 'ipd'},
    );

    expect(saved, isEmpty, reason: 'an unsynced local row must survive');
  });

  test('an unfiltered fetch still replaces the whole cache', () async {
    final service = serviceReturning([bill('b1', admissionId: 'a1')]);

    await service.fetchDataCached(table: LocalTables.billing);

    verify(
      () => localDb.replaceRecords(
        table: LocalTables.billing,
        records: any(named: 'records'),
      ),
    ).called(1);
    expect(saved, isEmpty);
  });
}
