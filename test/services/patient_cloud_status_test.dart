import 'package:abdm_hims/services/cache_service.dart';
import 'package:abdm_hims/services/database_service.dart';
import 'package:abdm_hims/services/local_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MockLocalDatabase extends Mock implements LocalDatabase {}

/// Test double: pins network / cloud reachability so `patientCloudStatus` is
/// deterministic without touching real connectivity or Supabase.
class _FakeDatabaseService extends DatabaseService {
  _FakeDatabaseService({
    required LocalDatabase localDb,
    required this.network,
    required this.cloudReachable,
  }) : super(
         SupabaseClient('http://localhost', 'anon'),
         localDb: localDb,
         cacheService: CacheService.instance,
       );

  final bool network;
  final bool cloudReachable;

  @override
  Future<bool> hasNetwork() async => network;

  @override
  Future<bool> probeSupabase() async => cloudReachable;
}

void main() {
  late MockLocalDatabase localDb;

  setUp(() {
    localDb = MockLocalDatabase();
    when(() => localDb.init()).thenAnswer((_) async {});
  });

  DatabaseService service({
    required bool network,
    required bool cloudReachable,
    List<Map<String, dynamic>> pending = const [],
  }) {
    when(
      () => localDb.getRecords(
        table: LocalTables.patients,
        pendingOnly: true,
      ),
    ).thenAnswer((_) async => pending);
    return _FakeDatabaseService(
      localDb: localDb,
      network: network,
      cloudReachable: cloudReachable,
    );
  }

  test('non-pending patient is synced', () async {
    final db = service(network: false, cloudReachable: false);
    expect(
      await db.patientCloudStatus('p1'),
      PatientCloudStatus.synced,
    );
  });

  test('pending patient with no network is offline', () async {
    final db = service(
      network: false,
      cloudReachable: false,
      pending: [
        {'id': 'p1', 'uhid': 'UHID1', 'is_synced': false},
      ],
    );
    expect(await db.patientCloudStatus('p1'), PatientCloudStatus.offline);
  });

  test('pending patient with network but unreachable cloud is cloudUnreachable',
      () async {
    final db = service(
      network: true,
      cloudReachable: false,
      pending: [
        {'id': 'p1', 'uhid': 'UHID1', 'is_synced': false},
      ],
    );
    expect(
      await db.patientCloudStatus('p1'),
      PatientCloudStatus.cloudUnreachable,
    );
  });

  test('pending patient with reachable cloud is pendingLocal', () async {
    final db = service(
      network: true,
      cloudReachable: true,
      pending: [
        {'id': 'p1', 'uhid': 'UHID1', 'is_synced': false},
      ],
    );
    expect(
      await db.patientCloudStatus('p1'),
      PatientCloudStatus.pendingLocal,
    );
  });

  test('pending patient is scoped to the exact patient id', () async {
    final db = service(
      network: false,
      cloudReachable: false,
      pending: [
        {'id': 'p2', 'uhid': 'UHID2', 'is_synced': false},
      ],
    );
    // A different patient is pending, but p1 is not -> synced.
    expect(await db.patientCloudStatus('p1'), PatientCloudStatus.synced);
  });
}
