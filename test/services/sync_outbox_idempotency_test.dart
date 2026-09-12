import 'package:abdm_hims/core/utils/logger.dart';
import 'package:abdm_hims/services/cache_service.dart';
import 'package:abdm_hims/services/database_service.dart';
import 'package:abdm_hims/services/local_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MockLocalDatabase extends Mock implements LocalDatabase {}

/// The server-side create-replay / unique-collision behaviour is validated
/// against a real Postgres in `supabase/verify_child_sync.sql` (the PK `id`
/// constraint plus the fixed-id row count). These unit tests cover the
/// client-side decision that rides on it: a retry is only accepted as
/// `alreadyCommitted` when the accounting/immutable payload matches — a
/// same-id-different-payload write is a conflict, never a silent success.
void main() {
  late DatabaseService db;

  setUpAll(() {
    AppLogger.init();
  });

  setUp(() {
    final localDb = MockLocalDatabase();
    db = DatabaseService(
      SupabaseClient(
        'http://localhost',
        'anon',
        accessToken: () async => 'jwt',
      ),
      localDb: localDb,
      cacheService: CacheService.instance,
    );
  });

  Map<String, dynamic> billing({num paid = 300, String uhid = 'X'}) => {
        'id': 'bill-1',
        'offline_id': 'op-1',
        'hospital_id': 'hosp-1',
        'bill_number': 'OPD-1',
        'net_amount': 300,
        'paid_amount': paid,
        'payment_status': 'paid',
        'extra': uhid,
      };

  test('identical payloads hash equal (idempotent replay)', () {
    expect(db.accountingHash(billing()), db.accountingHash(billing()));
  });

  test('different accounting amount hashes differently (conflict)', () {
    expect(
      db.accountingHash(billing(paid: 300)),
      isNot(db.accountingHash(billing(paid: 999))),
    );
  });

  test('key order does not change the hash', () {
    final a = {'a': 1, 'b': 2};
    final b = {'b': 2, 'a': 1};
    expect(db.accountingHash(a), db.accountingHash(b));
  });

  test('server-managed fields do not affect the hash', () {
    final base = billing();
    final withServerFields = {
      ...base,
      'created_at': '2026-09-12T10:00:00Z',
      'updated_at': '2026-09-12T11:00:00Z',
      'sync_status': 'synced',
      'is_synced': true,
      'deleted_at': null,
      'sync_version': 42,
    };
    expect(db.accountingHash(base), db.accountingHash(withServerFields));
  });
}
