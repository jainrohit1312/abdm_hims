import 'package:abdm_hims/core/utils/logger.dart';
import 'package:abdm_hims/services/dashboard_metrics_service.dart';
import 'package:abdm_hims/services/database_service.dart';
import 'package:abdm_hims/services/local_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDatabaseService extends Mock implements DatabaseService {}

class MockLocalDatabase extends Mock implements LocalDatabase {}

void main() {
  const hospitalId = 'h1';
  const todayIso = '2026-09-12';
  const yesterdayIso = '2026-09-11';
  final day = DateTime(2026, 9, 12, 10, 30);
  final dayStart = DateTime(2026, 9, 12);
  final dayEnd = DateTime(2026, 9, 13);

  late MockDatabaseService dbService;
  late MockLocalDatabase localDb;
  late DashboardMetricsService service;
  late List<Map<String, dynamic>> opdRows;

  setUpAll(() {
    AppLogger.init();
    registerFallbackValue(DateTime(2000));
  });

  setUp(() {
    dbService = MockDatabaseService();
    localDb = MockLocalDatabase();
    opdRows = [];

    when(() => localDb.init()).thenAnswer((_) async {});
    when(
      () => localDb.getRecords(table: LocalTables.opdRegistrations),
    ).thenAnswer((_) async => opdRows);
    when(
      () => dbService.isDatasetProvisioned(LocalTables.opdRegistrations),
    ).thenAnswer((_) async => true);

    // Sensible online defaults; individual tests override as needed.
    when(
      () => dbService.countIpdAdmissionsOn(dayStart, hospitalId: hospitalId),
    ).thenAnswer((_) async => 0);
    when(
      () => dbService.countAvailableBeds(hospitalId),
    ).thenAnswer((_) async => 0);
    when(
      () => dbService.sumCollectionsBetween(
        dayStart,
        dayEnd,
        hospitalId: hospitalId,
      ),
    ).thenAnswer((_) async => 0.0);

    service = DashboardMetricsService(dbService: dbService, localDb: localDb);
  });

  Map<String, dynamic> opd({
    required String id,
    String hospital = hospitalId,
    String visitDate = todayIso,
    String status = 'completed',
    Object? deletedAt,
    String? offlineId,
  }) => {
    'id': id,
    'offline_id': offlineId ?? 'off-$id',
    'hospital_id': hospital,
    'visit_date': visitDate,
    'status': status,
    'deleted_at': deletedAt,
  };

  group('OPD Today (durable local mirror)', () {
    test("counts only today's valid hospital-scoped visits", () async {
      opdRows = [
        opd(id: 'o1'), // today, completed -> counted
        opd(id: 'o2', hospital: 'h2'), // other hospital -> excluded
        opd(id: 'o3', visitDate: yesterdayIso), // not today -> excluded
        opd(id: 'o4', status: 'cancelled'), // cancelled -> excluded
        opd(id: 'o5', deletedAt: '2026-09-12T00:00:00Z'), // soft-deleted
        opd(id: 'o6', status: 'pending'), // valid visit -> counted
      ];

      final metrics = await service.load(hospitalId: hospitalId, now: day);

      expect(metrics.opdToday.value, 2);
      expect(metrics.opdToday.isAvailable, isTrue);
    });

    test('counts an offline row and its synced mirror exactly once', () async {
      // Same business id, different local key (as if the offline row and its
      // pulled mirror never collapsed onto one key).
      opdRows = [
        opd(id: 'o1', offlineId: 'op-local'),
        opd(id: 'o1', offlineId: 'op-synced'),
      ];

      final metrics = await service.load(hospitalId: hospitalId, now: day);

      expect(metrics.opdToday.value, 1);
    });

    test('is unavailable, never zero, before the mirror is provisioned', () async {
      opdRows = [];
      when(
        () => dbService.isDatasetProvisioned(LocalTables.opdRegistrations),
      ).thenAnswer((_) async => false);

      final metrics = await service.load(hospitalId: hospitalId, now: day);

      expect(metrics.opdToday.isAvailable, isFalse);
      expect(metrics.opdToday.value, isNull);
    });

    test('a genuinely empty day is a real zero', () async {
      opdRows = [];

      final metrics = await service.load(hospitalId: hospitalId, now: day);

      expect(metrics.opdToday.isAvailable, isTrue);
      expect(metrics.opdToday.value, 0);
    });

    test(
      'an offline device holding local rows shows a real zero, not "not downloaded"',
      () async {
        opdRows = [opd(id: 'old', visitDate: yesterdayIso)];
        when(
          () => dbService.isDatasetProvisioned(LocalTables.opdRegistrations),
        ).thenAnswer((_) async => false);

        final metrics = await service.load(hospitalId: hospitalId, now: day);

        expect(metrics.opdToday.isAvailable, isTrue);
        expect(metrics.opdToday.value, 0);
      },
    );

    test('another hospital\'s local rows never provision this hospital', () async {
      opdRows = [opd(id: 'other', hospital: 'h2')];
      when(
        () => dbService.isDatasetProvisioned(LocalTables.opdRegistrations),
      ).thenAnswer((_) async => false);

      final metrics = await service.load(hospitalId: hospitalId, now: day);

      expect(metrics.opdToday.isAvailable, isFalse);
    });
  });

  group('online metrics', () {
    test('are scoped to the authenticated hospital and the local day', () async {
      await service.load(hospitalId: hospitalId, now: day);

      verify(
        () => dbService.countIpdAdmissionsOn(dayStart, hospitalId: hospitalId),
      ).called(1);
      verify(() => dbService.countAvailableBeds(hospitalId)).called(1);

      // Timestamp-based collections use the same [local-midnight, next-midnight)
      // window; the date-only visit_date is handled separately by the mirror.
      final captured = verify(
        () => dbService.sumCollectionsBetween(
          captureAny(),
          captureAny(),
          hospitalId: hospitalId,
        ),
      ).captured;
      expect(captured[0], dayStart);
      expect(captured[1], dayEnd);
    });

    test('a failed query renders unavailable, a real empty renders zero', () async {
      when(
        () => dbService.countIpdAdmissionsOn(dayStart, hospitalId: hospitalId),
      ).thenThrow(Exception('ipd query down'));
      when(
        () => dbService.sumCollectionsBetween(
          dayStart,
          dayEnd,
          hospitalId: hospitalId,
        ),
      ).thenThrow(Exception('collections down'));
      when(
        () => dbService.countAvailableBeds(hospitalId),
      ).thenAnswer((_) async => 0);

      final metrics = await service.load(hospitalId: hospitalId, now: day);

      expect(metrics.ipdToday.isAvailable, isFalse);
      expect(metrics.collectionsToday.isAvailable, isFalse);

      expect(metrics.bedsAvailable.isAvailable, isTrue);
      expect(metrics.bedsAvailable.value, 0);
      expect(metrics.opdToday.isAvailable, isTrue);
    });

    test('a failed refresh falls back to a clearly dated cached value', () async {
      var calls = 0;
      when(() => dbService.countAvailableBeds(hospitalId)).thenAnswer((_) async {
        calls++;
        if (calls == 1) return 7;
        throw Exception('network lost');
      });

      final first = await service.load(hospitalId: hospitalId, now: day);
      expect(first.bedsAvailable.isAvailable, isTrue);
      expect(first.bedsAvailable.value, 7);

      final second = await service.load(hospitalId: hospitalId, now: day);
      expect(second.bedsAvailable.isStale, isTrue);
      expect(second.bedsAvailable.value, 7);
      expect(second.bedsAvailable.asOf, day);
    });
  });

  group('collection calculation (pure)', () {
    test('sums amount_paid only, skipping excluded bills', () {
      final logs = [
        {'bill_id': 'b1', 'amount_paid': 300},
        {'bill_id': 'b2', 'amount_paid': 500},
        {'bill_id': 'b3', 'amount_paid': 300},
      ];

      expect(DatabaseService.totalCollected(logs, excludedBillIds: {'b2'}), 600.0);
    });

    test('a real 300 + 500 + 300 day totals 1100 (nothing double counted)', () {
      final logs = [
        {'bill_id': 'b1', 'amount_paid': 300},
        {'bill_id': 'b2', 'amount_paid': 500},
        {'bill_id': 'b3', 'amount_paid': 300},
      ];

      expect(DatabaseService.totalCollected(logs), 1100.0);
    });

    test('reads amount_paid only, never billed charges or lifetime paid', () {
      final logs = [
        {
          'bill_id': 'b1',
          'amount_paid': 300,
          'total_amount': 9999,
          'paid_amount': 8888,
        },
      ];

      expect(DatabaseService.totalCollected(logs), 300.0);
    });

    test('excludes soft-deleted, refunded and waived bills', () {
      final excluded = DatabaseService.excludedCollectionBills([
        {'id': 'b1', 'payment_status': 'paid'},
        {'id': 'b2', 'payment_status': 'refunded'},
        {'id': 'b3', 'payment_status': 'waived'},
        {'id': 'b4', 'payment_status': 'paid', 'deleted_at': '2026-09-12'},
      ]);

      expect(excluded, {'b2', 'b3', 'b4'});
    });
  });
}
