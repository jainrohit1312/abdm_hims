import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_config.dart';
import '../core/constants/api_constants.dart';
import '../core/utils/logger.dart';
import '../models/compliance_models.dart';
import '../models/employee_attendance_summary.dart';
import '../models/employee_model.dart';
import '../models/employee_salary_summary.dart';
import '../models/marketing_models.dart';
import '../models/personalized_tag_models.dart';
import '../repositories/attendance_repository.dart';
import '../repositories/employee_repository.dart';
import '../repositories/marketing_area_repository.dart';
import '../repositories/marketing_visit_repository.dart';
import '../repositories/patient_referral_repository.dart';
import '../repositories/referral_doctor_repository.dart';
import '../repositories/supabase_attendance_repository.dart';
import '../repositories/supabase_employee_repository.dart';
import '../repositories/supabase_marketing_area_repository.dart';
import '../repositories/supabase_marketing_visit_repository.dart';
import '../repositories/supabase_patient_referral_repository.dart';
import '../repositories/supabase_referral_doctor_repository.dart';
import '../services/attendance_calculator.dart';
import '../services/salary_calculator.dart';
import '../services/abdm_service.dart';
import '../services/auth_service.dart';
import '../services/background_sync.dart';
import '../services/cache_service.dart';
import '../services/compliance_service.dart';
import '../services/counseling_recording_service.dart';
import '../services/database_service.dart';
import '../services/geofence_service.dart';
import '../services/local_db.dart';
import '../services/marketing_analytics_service.dart';
import '../services/personalized_tag_service.dart';
import '../services/push_notification_service.dart';
import '../services/report_generation_service.dart';
import '../services/storage_service.dart';

// Theme Provider
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.light);

/// Tracks the active top-level navigation module.
///
/// The value is the full route path of the current location (for example
/// `/patients/register`). `AppHeader` normalizes it to a root segment
/// (`/patients`) when highlighting the active tab.
///
/// It is kept in sync by `AppNavigationShell` (see
/// `lib/presentation/widgets/app_header.dart`) and is exposed so any widget
/// can watch the active module without needing a `BuildContext`.
final currentTabProvider = StateProvider<String>((ref) => '/dashboard');

// Supabase Services
final supabaseClientProvider = Provider((ref) => AppConfig.supabaseClient);

final authServiceProvider = Provider<AuthService>((ref) {
  final service = AuthService(ref.watch(supabaseClientProvider));
  ref.onDispose(service.dispose);
  return service;
});

/// Process-wide local database (Hive on web, drift/SQLite on Android & Windows).
final localDatabaseProvider = Provider<LocalDatabase>((ref) {
  return getLocalDatabase();
});

/// Hive TTL cache service (doctors_cache, departments_cache, medicines_cache,
/// patients_cache). The same singleton instance is shared across screens.
final cacheServiceProvider = Provider<CacheService>((ref) {
  return CacheService.instance;
});

final databaseServiceProvider = Provider<DatabaseService>((ref) {
  return DatabaseService(
    ref.watch(supabaseClientProvider),
    localDb: ref.watch(localDatabaseProvider),
    cacheService: ref.watch(cacheServiceProvider),
  );
});

final storageServiceProvider = Provider<StorageService>((ref) {
  return StorageService(ref.watch(supabaseClientProvider));
});

// ---------------------------------------------------------------------------
// Offline-First Sync Engine
// ---------------------------------------------------------------------------

/// Background sync engine (30-second timer). Start it from `AppBootstrapGate`
/// once authentication is restored so synced rows carry a valid session.
final backgroundSyncServiceProvider =
    ChangeNotifierProvider<BackgroundSyncService>((ref) {
      final service = BackgroundSyncService(
        dbService: ref.watch(databaseServiceProvider),
        localDb: ref.watch(localDatabaseProvider),
      );
      ref.onDispose(service.dispose);
      return service;
    });

/// Backwards-compatible alias — `app_bootstrap_gate.dart` and older callers
/// ab bhi `syncServiceProvider` use kar sakte hain.
final syncServiceProvider = backgroundSyncServiceProvider;

/// Dashboard "Sync Status" indicator ke liye current status.
final syncStatusProvider = Provider<SyncStatus>((ref) {
  return ref.watch(backgroundSyncServiceProvider).syncStatus;
});

/// True jab saare local records Supabase tak sync ho chuke hain.
final isSyncedProvider = Provider<bool>((ref) {
  return ref.watch(backgroundSyncServiceProvider).isSynced;
});

/// Number of local records still waiting to be synced to Supabase.
final pendingSyncCountProvider = Provider<int>((ref) {
  return ref.watch(backgroundSyncServiceProvider).pendingCount;
});

// ---------------------------------------------------------------------------
// Push Notifications (Firebase Cloud Messaging + in-app notifications)
// ---------------------------------------------------------------------------

/// Simple refresh tick — FCM foreground message aane ya notification tap hone
/// par increment hota hai, jisse notifications providers dobara fetch karte
/// hain.
final notificationRefreshProvider = StateProvider<int>((ref) => 0);

/// `/notifications` screen par selected type filter.
///
/// Value `NotificationType.value` hota hai (e.g. `opd_visit`, `ipd_admission`,
/// `voucher`, `lab_report`, `billing`) — `null` = All.
final notificationTypeFilterProvider = StateProvider<String?>((ref) => null);

final pushNotificationServiceProvider = Provider<PushNotificationService>((
  ref,
) {
  final service = PushNotificationService(
    dbService: ref.watch(databaseServiceProvider),
  );

  // FCM message aane par notifications list + unread badge refresh ho jaye.
  service.onForegroundMessage = (_) {
    ref.read(notificationRefreshProvider.notifier).state++;
  };
  service.onNotificationTap = (_) {
    ref.read(notificationRefreshProvider.notifier).state++;
  };

  ref.onDispose(service.stop);
  return service;
});

/// Saari notifications for a user (newest first). `/notifications` screen
/// isi provider ko watch karti hai.
final notificationsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      userId,
    ) async {
      ref.watch(notificationRefreshProvider);
      return ref.read(databaseServiceProvider).getNotifications(userId);
    });

/// Latest few notifications (dashboard / badge use).
final recentNotificationsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      userId,
    ) async {
      ref.watch(notificationRefreshProvider);
      return ref
          .read(databaseServiceProvider)
          .getRecentNotifications(userId: userId);
    });

/// Unread notification count for the header badge.
final unreadNotificationCountProvider = FutureProvider.family<int, String>((
  ref,
  userId,
) async {
  ref.watch(notificationRefreshProvider);
  return ref.read(databaseServiceProvider).getUnreadNotificationCount(userId);
});

/// Generic cache-first table reader. Any screen can use this for the four
/// offline-enabled tables (`patients`, `opd_registrations`,
/// `ipd_admissions`, `billing`).
class CachedTableParams {
  final String table;
  final Map<String, dynamic>? filters;
  final String? select;
  final String? orderColumn;
  final bool ascending;
  final int? limit;

  const CachedTableParams({
    required this.table,
    this.filters,
    this.select,
    this.orderColumn,
    this.ascending = false,
    this.limit,
  });

  @override
  bool operator ==(Object other) =>
      other is CachedTableParams &&
      other.table == table &&
      other.filters == filters &&
      other.select == select &&
      other.orderColumn == orderColumn &&
      other.ascending == ascending &&
      other.limit == limit;

  @override
  int get hashCode =>
      Object.hash(table, filters, select, orderColumn, ascending, limit);
}

final cachedTableProvider =
    FutureProvider.family<List<Map<String, dynamic>>, CachedTableParams>((
      ref,
      params,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.fetchDataCached(
        table: params.table,
        filters: params.filters,
        select: params.select,
        orderColumn: params.orderColumn,
        ascending: params.ascending,
        limit: params.limit,
      );
    });

// ---------------------------------------------------------------------------
// ABDM (M1 + M2 + M3) Providers
// ---------------------------------------------------------------------------

final abdmServiceProvider = Provider<AbdmService>((ref) {
  return AbdmService(supabaseClient: ref.watch(supabaseClientProvider));
});

/// ABHA profile (abha_profiles) for a patient.
final abhaProfileProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((
      ref,
      patientId,
    ) async {
      final service = ref.read(abdmServiceProvider);
      return DatabaseService.fetchWithRetry(
        () => service.getAbhaProfile(patientId),
      );
    });

/// Care contexts linked to a patient's ABHA.
final patientCareContextsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      patientId,
    ) async {
      final service = ref.read(abdmServiceProvider);
      return DatabaseService.fetchWithRetry(
        () => service.getCareContexts(patientId),
      );
    });

/// Consent artefacts for a patient.
final patientConsentsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      patientId,
    ) async {
      final service = ref.read(abdmServiceProvider);
      return DatabaseService.fetchWithRetry(
        () => service.getConsentArtefacts(patientId),
      );
    });

/// FHIR records stored locally for a patient.
final patientFhirRecordsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      patientId,
    ) async {
      final service = ref.read(abdmServiceProvider);
      return DatabaseService.fetchWithRetry(
        () => service.getFhirRecords(patientId),
      );
    });

/// ABDM data-flow audit log for a patient.
final patientDataFlowLogsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      patientId,
    ) async {
      final service = ref.read(abdmServiceProvider);
      return DatabaseService.fetchWithRetry(
        () => service.getDataFlowLogs(patientId),
      );
    });

// ---------------------------------------------------------------------------
// Patient Full Profile Provider
// ---------------------------------------------------------------------------

/// Aggregated profile for the patient profile screen.
///
/// Combines the core clinical/billing history from
/// [DatabaseService.getPatientFullProfile] with the ABDM records
/// (ABHA profile, care contexts, consents, FHIR records and the data-flow
/// audit trail). ABDM failures are isolated so they never take down the
/// whole profile.
final patientFullProfileProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, patientId) async {
      final db = ref.read(databaseServiceProvider);
      final abdm = ref.read(abdmServiceProvider);

      Future<List<Map<String, dynamic>>> safeList(
        Future<List<Map<String, dynamic>>> Function() fetch,
      ) async {
        try {
          return await fetch();
        } catch (e) {
          AppLogger.e('Patient profile ABDM list fetch failed', e);
          return const [];
        }
      }

      Future<Map<String, dynamic>?> safeMap(
        Future<Map<String, dynamic>?> Function() fetch,
      ) async {
        try {
          return await fetch();
        } catch (e) {
          AppLogger.e('Patient profile ABDM single fetch failed', e);
          return null;
        }
      }

      final results = await Future.wait([
        db.getPatientFullProfile(patientId),
        safeList(() => abdm.getCareContexts(patientId)),
        safeList(() => abdm.getConsentArtefacts(patientId)),
        safeList(() => abdm.getFhirRecords(patientId)),
        safeList(() => abdm.getDataFlowLogs(patientId)),
        safeMap(() => abdm.getAbhaProfile(patientId)),
      ]);

      final core = results[0] as Map<String, dynamic>;
      return <String, dynamic>{
        ...core,
        'care_contexts': results[1],
        'consent_artefacts': results[2],
        'fhir_records': results[3],
        'data_flow_logs': results[4],
        'abha_profile': results[5],
      };
    });

// Hospital Beds & Wards Providers (Family)
final hospitalBedsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      hospitalId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getBedsByWard(hospitalId);
    });

final hospitalWardsProvider = FutureProvider.family<List<String>, String>((
  ref,
  hospitalId,
) async {
  final dbService = ref.read(databaseServiceProvider);
  final wards = await dbService.getWards(hospitalId);
  return wards.map((w) => w['ward_type'] as String).toSet().toList();
});

// ---------------------------------------------------------------------------
// Hospital Onboarding & Multi-User Management Providers
// ---------------------------------------------------------------------------

/// All users belonging to a hospital (admin, doctors, nurses, staff...).
final hospitalUsersProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      hospitalId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getAllUsers(hospitalId);
    });

/// Active role catalogue for a hospital (`user_roles` table).
final userRolesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      hospitalId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getUserRoles(hospitalId);
    });

// ---------------------------------------------------------------------------
// Cache-First Frequently Used Data Providers (Hive TTL, 5 min)
// ---------------------------------------------------------------------------
// Har provider ka flow:
//   1. Screen load → Hive cache se turant data dikhao (agar valid hai).
//   2. Background mein Supabase fetch → Hive cache update + provider state
//      update (isliye UI apne aap fresh data dikhata hai).
//   3. Cache empty/expired → seedha Supabase fetch → cache store.
//   4. Refresh button → `ref.invalidate(provider(hospitalId))`.
// ---------------------------------------------------------------------------

/// Base notifier shared by all four cache-first providers.
abstract class CacheFirstListNotifier
    extends FamilyAsyncNotifier<List<Map<String, dynamic>>, String?> {
  bool _isDisposed = false;

  /// Hive key (`doctors_cache`, `departments_cache`, ...).
  String get cacheKey;

  /// Fetches from Supabase AND stores into Hive before returning.
  Future<List<Map<String, dynamic>>> fetchAndCache(
    DatabaseService db,
    String? hospitalId,
  );

  @override
  Future<List<Map<String, dynamic>>> build(String? hospitalId) async {
    ref.onDispose(() => _isDisposed = true);
    final db = ref.read(databaseServiceProvider);
    final cached = await ref
        .read(cacheServiceProvider)
        .get(cacheKey, hospitalId: hospitalId);
    if (cached != null) {
      unawaited(_refreshInBackground(hospitalId));
      return cached;
    }
    return fetchAndCache(db, hospitalId);
  }

  Future<void> _refreshInBackground(String? hospitalId) async {
    try {
      final db = ref.read(databaseServiceProvider);
      final fresh = await fetchAndCache(db, hospitalId);
      if (_isDisposed) return;
      state = AsyncData(fresh);
    } catch (e) {
      if (!_isDisposed) {
        AppLogger.e('Background refresh failed for $cacheKey', e);
      }
    }
  }
}

class DoctorsCacheNotifier extends CacheFirstListNotifier {
  @override
  String get cacheKey => CacheKeys.doctors;

  @override
  Future<List<Map<String, dynamic>>> fetchAndCache(
    DatabaseService db,
    String? hospitalId,
  ) {
    return db.fetchDoctorsAndCache(hospitalId: hospitalId);
  }
}

class DepartmentsCacheNotifier extends CacheFirstListNotifier {
  @override
  String get cacheKey => CacheKeys.departments;

  @override
  Future<List<Map<String, dynamic>>> fetchAndCache(
    DatabaseService db,
    String? hospitalId,
  ) {
    return db.fetchDepartmentsAndCache(hospitalId: hospitalId);
  }
}

class MedicinesCacheNotifier extends CacheFirstListNotifier {
  @override
  String get cacheKey => CacheKeys.medicines;

  @override
  Future<List<Map<String, dynamic>>> fetchAndCache(
    DatabaseService db,
    String? hospitalId,
  ) {
    return db.fetchMedicinesAndCache(hospitalId: hospitalId);
  }
}

class PatientsCacheNotifier extends CacheFirstListNotifier {
  @override
  String get cacheKey => CacheKeys.patients;

  @override
  Future<List<Map<String, dynamic>>> fetchAndCache(
    DatabaseService db,
    String? hospitalId,
  ) {
    return db.fetchPatientsAndCache(hospitalId: hospitalId);
  }
}

final doctorsCacheProvider =
    AsyncNotifierProvider.family<
      DoctorsCacheNotifier,
      List<Map<String, dynamic>>,
      String?
    >(DoctorsCacheNotifier.new);

final departmentsCacheProvider =
    AsyncNotifierProvider.family<
      DepartmentsCacheNotifier,
      List<Map<String, dynamic>>,
      String?
    >(DepartmentsCacheNotifier.new);

final medicinesCacheProvider =
    AsyncNotifierProvider.family<
      MedicinesCacheNotifier,
      List<Map<String, dynamic>>,
      String?
    >(MedicinesCacheNotifier.new);

final patientsCacheProvider =
    AsyncNotifierProvider.family<
      PatientsCacheNotifier,
      List<Map<String, dynamic>>,
      String?
    >(PatientsCacheNotifier.new);

/// Backwards-compatible name used by the user management screen.
final hospitalDepartmentsProvider = departmentsCacheProvider;

// ---------------------------------------------------------------------------
// Pagination State & Notifiers (Patient List + OPD Queue)
// ---------------------------------------------------------------------------

/// Page size used by the patient list pagination provider.
const int patientListLimit = 20;

/// Page size used by the OPD queue pagination provider.
const int opdQueueLimit = 30;

/// Page size used by the IPD patient list pagination provider.
const int ipdPatientListLimit = 30;

/// Generic pagination state shared by [patientListProvider] and
/// [opdQueueProvider].
///
/// * [page]    — 0-based index of the last page that was loaded.
/// * [hasMore] — whether another page can still be fetched.
/// * [items]   — all records loaded so far (accumulated across pages).
class PaginationState<T> {
  static const Object _unset = Object();

  final List<T> items;
  final int page;
  final bool hasMore;
  final bool isLoading;
  final bool isLoadingMore;
  final String? error;

  const PaginationState({
    this.items = const [],
    this.page = 0,
    this.hasMore = true,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.error,
  });

  PaginationState<T> copyWith({
    List<T>? items,
    int? page,
    bool? hasMore,
    bool? isLoading,
    bool? isLoadingMore,
    Object? error = _unset,
  }) {
    return PaginationState<T>(
      items: items ?? this.items,
      page: page ?? this.page,
      hasMore: hasMore ?? this.hasMore,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: identical(error, _unset) ? this.error : error as String?,
    );
  }
}

/// Base notifier implementing the pagination flow used by both lists:
/// `refresh()` resets to page 0 and `nextPage()` appends the next page.
abstract class PaginationListNotifier<T>
    extends StateNotifier<PaginationState<T>> {
  PaginationListNotifier(
    this._dbService,
    this._hospitalIdReader, {
    required this.limit,
  }) : super(const PaginationState());

  final DatabaseService _dbService;
  final String Function() _hospitalIdReader;

  /// Number of records requested per page (20 for patients, 30 for OPD queue).
  final int limit;

  String get _hospitalId => _hospitalIdReader().trim();

  /// Fetch one page of records. [page] is 0-based.
  Future<List<T>> fetchPage(
    DatabaseService db,
    int page,
    int limit,
    String hospitalId,
  );

  /// (Re)loads the first page and resets the accumulated list.
  Future<void> refresh() async {
    if (state.isLoading) return;
    final hospitalId = _hospitalId;
    if (hospitalId.isEmpty) {
      state = state.copyWith(isLoading: false, error: 'Hospital not assigned');
      return;
    }

    state = state.copyWith(isLoading: true, isLoadingMore: false, error: null);
    try {
      final items = await fetchPage(_dbService, 0, limit, hospitalId);
      state = PaginationState<T>(
        items: items,
        page: 0,
        hasMore: items.length >= limit,
        isLoading: false,
      );
    } catch (e) {
      AppLogger.e('Pagination refresh failed', e);
      state = state.copyWith(isLoading: false, error: 'Failed to load data');
    }
  }

  /// Loads the next page and appends it to [PaginationState.items].
  Future<void> nextPage() async {
    if (state.isLoading || state.isLoadingMore || !state.hasMore) return;
    final hospitalId = _hospitalId;
    if (hospitalId.isEmpty) return;

    final requestedPage = state.page + 1;
    state = state.copyWith(isLoadingMore: true, error: null);
    try {
      final next = await fetchPage(
        _dbService,
        requestedPage,
        limit,
        hospitalId,
      );
      // Ignore the result if a refresh happened while this page was loading.
      if (state.isLoadingMore && state.page == requestedPage - 1) {
        state = state.copyWith(
          isLoadingMore: false,
          items: [...state.items, ...next],
          page: requestedPage,
          hasMore: next.length >= limit,
        );
      }
    } catch (e) {
      AppLogger.e('Pagination nextPage failed', e);
      if (state.isLoadingMore && state.page == requestedPage - 1) {
        state = state.copyWith(
          isLoadingMore: false,
          error: 'Failed to load more patients',
        );
      }
    }
  }
}

/// Paginated patient list (20 records per page).
class PatientListNotifier extends PaginationListNotifier<Map<String, dynamic>> {
  PatientListNotifier(super.dbService, super.hospitalIdReader)
    : super(limit: patientListLimit);

  @override
  Future<List<Map<String, dynamic>>> fetchPage(
    DatabaseService db,
    int page,
    int limit,
    String hospitalId,
  ) {
    return db.getPatients(page: page, limit: limit, hospitalId: hospitalId);
  }
}

final patientListProvider =
    StateNotifierProvider<
      PatientListNotifier,
      PaginationState<Map<String, dynamic>>
    >((ref) {
      final notifier = PatientListNotifier(
        ref.watch(databaseServiceProvider),
        () => ref.read(authStateProvider).hospitalId ?? '',
      );
      // Load the first page as soon as the provider is created.
      Future.microtask(notifier.refresh);
      return notifier;
    });

// ---------------------------------------------------------------------------
// Combined OPD + IPD Patient Search
// ---------------------------------------------------------------------------

/// Search query parameters for [combinedPatientSearchProvider]. `==` and
/// `hashCode` are overridden so Riverpod can cache per-query results.
class CombinedPatientSearchParams {
  final String query;
  final String? hospitalId;

  const CombinedPatientSearchParams({required this.query, this.hospitalId});

  @override
  bool operator ==(Object other) =>
      other is CombinedPatientSearchParams &&
      other.query == query &&
      other.hospitalId == hospitalId;

  @override
  int get hashCode => Object.hash(query, hospitalId);
}

/// Searches the patient master and enriches each match with that patient's
/// OPD registrations and IPD admissions (see
/// `DatabaseService.searchPatientsAcrossVisits`).
final combinedPatientSearchProvider =
    FutureProvider.family<
      List<Map<String, dynamic>>,
      CombinedPatientSearchParams
    >((ref, params) {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.searchPatientsAcrossVisits(
        params.query,
        hospitalId: params.hospitalId,
      );
    });

// ---------------------------------------------------------------------------
// Free Trial / Subscription Providers
// ---------------------------------------------------------------------------

/// Effective subscription status (trial / active / expired) for a hospital.
final subscriptionStatusProvider =
    FutureProvider.family<Map<String, dynamic>, String>((
      ref,
      hospitalId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getSubscriptionStatus(hospitalId);
    });

/// Subscription payment history for a hospital, newest first.
final paymentHistoryProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      hospitalId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getPaymentHistory(hospitalId);
    });

// Doctor Prescription Providers
class MedicineSearchParams {
  final String query;
  final String? hospitalId;

  const MedicineSearchParams({required this.query, this.hospitalId});

  @override
  bool operator ==(Object other) =>
      other is MedicineSearchParams &&
      other.query == query &&
      other.hospitalId == hospitalId;

  @override
  int get hashCode => Object.hash(query, hospitalId);
}

/// Auto-suggest provider for the medicine search field.
final medicineSearchProvider =
    FutureProvider.family<List<Map<String, dynamic>>, MedicineSearchParams>((
      ref,
      params,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.searchMedicines(
        params.query,
        hospitalId: params.hospitalId,
      );
    });

/// Current logged-in doctor's public `users` record (for name + id).
final currentDoctorProvider = FutureProvider<Map<String, dynamic>?>((
  ref,
) async {
  final dbService = ref.read(databaseServiceProvider);
  return dbService.getCurrentUserRecord();
});

// ---------------------------------------------------------------------------
// Clinical Counseling Recording Providers (video/audio + GPS + consent)
// ---------------------------------------------------------------------------

/// Identifies one OPD/IPD visit (or admission) that counseling sessions are
/// attached to. `visitType` is `opd` or `ipd`; `visitId` is the corresponding
/// `opd_registrations.id` or `ipd_admissions.id`.
class CounselingVisitParams {
  final String visitType;
  final String visitId;

  const CounselingVisitParams({required this.visitType, required this.visitId});

  bool get isIpd => visitType == 'ipd';

  @override
  bool operator ==(Object other) =>
      other is CounselingVisitParams &&
      other.visitType == visitType &&
      other.visitId == visitId;

  @override
  int get hashCode => Object.hash(visitType, visitId);
}

/// All counseling records stacked under one OPD/IPD visit, newest first.
final counselingRecordsByVisitProvider =
    FutureProvider.family<List<Map<String, dynamic>>, CounselingVisitParams>((
      ref,
      params,
    ) {
      final dbService = ref.read(databaseServiceProvider);
      final hospitalId = ref.watch(currentHospitalIdProvider);
      return dbService.getCounselingRecordsByVisit(
        visitType: params.visitType,
        opdRegistrationId: params.isIpd ? null : params.visitId,
        ipdAdmissionId: params.isIpd ? params.visitId : null,
        hospitalId: hospitalId,
      );
    });

/// One counseling record by id (playback screen).
final counselingRecordByIdProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, recordId) {
      final dbService = ref.read(databaseServiceProvider);
      final hospitalId = ref.watch(currentHospitalIdProvider);
      return dbService.getCounselingRecordById(
        recordId,
        hospitalId: hospitalId,
      );
    });

/// Media recorder controller for the Recording tab (camera + audio + GPS).
/// autoDispose keeps the camera/mic free after leaving the counseling screen.
final counselingRecordingServiceProvider =
    ChangeNotifierProvider.autoDispose<CounselingRecordingService>((ref) {
      final service = CounselingRecordingService();
      ref.onDispose(service.dispose);
      return service;
    });

/// Merged session history (records + media + consents) for one visit/admission.
final counselingSessionHistoryByVisitProvider =
    FutureProvider.family<List<Map<String, dynamic>>, CounselingVisitParams>((
      ref,
      params,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      final hospitalId = ref.watch(currentHospitalIdProvider);
      final patientId = await ref.watch(
        patientIdForVisitProvider(params).future,
      );
      return dbService.getCounselingSessionHistoryByVisit(
        patientId: patientId,
        visitType: params.visitType,
        opdRegistrationId: params.isIpd ? null : params.visitId,
        ipdAdmissionId: params.isIpd ? params.visitId : null,
        hospitalId: hospitalId,
      );
    });

/// Resolves the `patient_id` for a visit so visit-scoped counseling queries
/// can still merge patient-scoped media/consent rows.
final patientIdForVisitProvider =
    FutureProvider.family<String, CounselingVisitParams>((ref, params) async {
      final dbService = ref.read(databaseServiceProvider);
      final table = params.isIpd
          ? ApiConstants.ipdAdmissionsTable
          : ApiConstants.opdRegistrationsTable;
      final row = await dbService.getById(table, params.visitId);
      return row?['patient_id']?.toString() ?? '';
    });

/// Media files linked to one counseling record.
final counselingMediaForRecordProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, recordId) {
      return ref
          .read(databaseServiceProvider)
          .getCounselingMediaForRecord(recordId);
    });

/// Latest consent linked to one counseling record (may be null).
final counselingConsentForRecordProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, recordId) {
      return ref
          .read(databaseServiceProvider)
          .getCounselingConsentForRecord(recordId);
    });

/// Saved prescriptions (+ items) for an OPD registration.
final opdPrescriptionsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      opdRegistrationId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getOPDPrescriptions(opdRegistrationId);
    });

/// Unified prescriptions for an IPD admission (medicines-only context).
final ipdPrescriptionsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      ipdAdmissionId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getIPDPrescriptions(ipdAdmissionId);
    });

// IPD Patient Dashboard Provider
/// Loads everything the IPD Patient Dashboard needs for one admission:
/// admission + patient + bed details, vitals, progress notes, medication
/// chart and investigation reports.
///
/// Each record list is decorated with the resolved "recorded by / added by /
/// modified by" user names (and roles/designations) and sorted in
/// chronological order so the dashboard can render complete grouped charts.
final ipdPatientProvider = FutureProvider.family<Map<String, dynamic>, String>((
  ref,
  admissionId,
) async {
  final dbService = ref.read(databaseServiceProvider);

  final results = await Future.wait([
    dbService.getIPDAdmissionDetails(admissionId),
    dbService.getIPDVitals(admissionId),
    dbService.getIPDProgressNotes(admissionId),
    dbService.getIPDMedications(admissionId),
    dbService.getIPDReports(admissionId),
  ]);

  final details = results[0] as Map<String, dynamic>;
  final vitals = (results[1] as List).cast<Map<String, dynamic>>();
  final progressNotes = (results[2] as List).cast<Map<String, dynamic>>();
  final medications = (results[3] as List).cast<Map<String, dynamic>>();
  final reports = (results[4] as List).cast<Map<String, dynamic>>();

  // Resolve every audit/doctor id referenced by these records into a user
  // record (name, role, designation) so the dashboard can show "who".
  final userIds = <String>{};
  for (final row in [...vitals, ...progressNotes, ...medications, ...reports]) {
    for (final key in [
      'recorded_by',
      'created_by',
      'updated_by',
      'doctor_id',
    ]) {
      final value = row[key]?.toString();
      if (value != null && value.isNotEmpty) userIds.add(value);
    }
  }
  final usersById = await dbService.getUsersByIds(userIds);

  return {
    ...details,
    'vitals': _ipdSortChronological(
      _ipdDecorateList(vitals, usersById, isVitals: true),
      'recorded_at',
    ),
    'progress_notes': _ipdSortChronological(
      _ipdDecorateList(progressNotes, usersById),
      'note_date',
      fallbackKey: 'created_at',
    ),
    'medications': _ipdSortChronological(
      _ipdDecorateList(medications, usersById),
      'start_date',
      fallbackKey: 'created_at',
    ),
    'reports': _ipdSortChronological(
      _ipdDecorateList(reports, usersById),
      'report_date',
      fallbackKey: 'created_at',
    ),
    'user_names': usersById,
  };
});

/// Decorates IPD dashboard rows with resolved user names/roles/designations
/// for the audit columns so screens can display who recorded/added/modified
/// each record without performing extra lookups.
List<Map<String, dynamic>> _ipdDecorateList(
  List<Map<String, dynamic>> rows,
  Map<String, Map<String, dynamic>> usersById, {
  bool isVitals = false,
}) {
  return [
    for (final row in rows)
      {
        ...row,
        if (isVitals)
          ..._ipdUserFields(
            row['recorded_by']?.toString(),
            usersById,
            prefix: 'recorded_by',
          ),
        ..._ipdUserFields(
          row['created_by']?.toString(),
          usersById,
          prefix: 'created_by',
        ),
        ..._ipdUserFields(
          row['updated_by']?.toString(),
          usersById,
          prefix: 'updated_by',
        ),
        if (row['doctor_id']?.toString().isNotEmpty == true)
          ..._ipdUserFields(
            row['doctor_id']?.toString(),
            usersById,
            prefix: 'doctor',
          ),
      },
  ];
}

Map<String, dynamic> _ipdUserFields(
  String? userId,
  Map<String, Map<String, dynamic>> usersById, {
  required String prefix,
}) {
  final user = userId == null ? null : usersById[userId];
  return {
    '${prefix}_id': userId ?? '',
    '${prefix}_name': _ipdUserName(user),
    '${prefix}_role': user?['role']?.toString() ?? '',
    '${prefix}_designation': user?['designation']?.toString() ?? '',
  };
}

String _ipdUserName(Map<String, dynamic>? user) {
  if (user == null) return '';
  final first = user['first_name']?.toString() ?? '';
  final last = user['last_name']?.toString() ?? '';
  final name = '$first $last'.trim();
  if (name.isNotEmpty) return name;
  final designation = user['designation']?.toString() ?? '';
  return designation.isNotEmpty ? designation : 'User';
}

/// Sorts a record list chronologically (oldest first). Rows with missing or
/// unparseable dates sink to the bottom so they never hide dated records.
List<Map<String, dynamic>> _ipdSortChronological(
  List<Map<String, dynamic>> rows,
  String dateKey, {
  String fallbackKey = 'created_at',
}) {
  final sorted = [...rows];
  sorted.sort((a, b) {
    final da = _ipdDate(a, dateKey, fallbackKey);
    final db = _ipdDate(b, dateKey, fallbackKey);
    if (da == null && db == null) return 0;
    if (da == null) return 1;
    if (db == null) return -1;
    return da.compareTo(db);
  });
  return sorted;
}

DateTime? _ipdDate(
  Map<String, dynamic> row,
  String dateKey,
  String fallbackKey,
) {
  for (final key in [dateKey, fallbackKey]) {
    final text = row[key]?.toString().trim();
    if (text == null || text.isEmpty) continue;
    final parsed = DateTime.tryParse(text);
    if (parsed != null) return parsed;
  }
  return null;
}

// IPD Discharge & Billing Providers
final ipdChargeDetailsProvider =
    FutureProvider.family<Map<String, dynamic>, String>((
      ref,
      admissionId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getIPDChargeDetails(admissionId);
    });

final ipdWardPricingProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final dbService = ref.read(databaseServiceProvider);
  return dbService.getIPDWardPricing(activeOnly: false);
});

final ipdPackagesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final dbService = ref.read(databaseServiceProvider);
  return dbService.getIPDPackages(activeOnly: false);
});

final ipdServiceMasterProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final dbService = ref.read(databaseServiceProvider);
  return dbService.getIPDServiceMaster(activeOnly: false);
});

final ipdBillsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      admissionId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      // Cache-first: offline-generated bills bhi turant list mein dikhte hain.
      return dbService.fetchDataCached(
        table: ApiConstants.billingTable,
        filters: {'ipd_admission_id': admissionId},
        orderColumn: 'bill_date',
        ascending: false,
      );
    });

final ipdTransferHistoryProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      admissionId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getIPDTransferHistory(admissionId);
    });

// OPD Queue Pagination Provider (30 records per page)
class OPDQueueNotifier extends PaginationListNotifier<Map<String, dynamic>> {
  OPDQueueNotifier(super.dbService, super.hospitalIdReader)
    : super(limit: opdQueueLimit);

  @override
  Future<List<Map<String, dynamic>>> fetchPage(
    DatabaseService db,
    int page,
    int limit,
    String hospitalId,
  ) {
    return db.getOPDQueue(page: page, limit: limit, hospitalId: hospitalId);
  }
}

final opdQueueProvider =
    StateNotifierProvider<
      OPDQueueNotifier,
      PaginationState<Map<String, dynamic>>
    >((ref) {
      final notifier = OPDQueueNotifier(
        ref.watch(databaseServiceProvider),
        () => ref.read(authStateProvider).hospitalId ?? '',
      );
      // Load the first page as soon as the provider is created.
      Future.microtask(notifier.refresh);
      return notifier;
    });

// IPD Patient List Pagination Provider (30 records per page)
class IPDPatientListNotifier
    extends PaginationListNotifier<Map<String, dynamic>> {
  IPDPatientListNotifier(super.dbService, super.hospitalIdReader)
    : super(limit: ipdPatientListLimit);

  @override
  Future<List<Map<String, dynamic>>> fetchPage(
    DatabaseService db,
    int page,
    int limit,
    String hospitalId,
  ) {
    return db.getIPDAdmissions(
      hospitalId: hospitalId,
      page: page,
      limit: limit,
    );
  }
}

final ipdPatientListProvider =
    StateNotifierProvider<
      IPDPatientListNotifier,
      PaginationState<Map<String, dynamic>>
    >((ref) {
      final notifier = IPDPatientListNotifier(
        ref.watch(databaseServiceProvider),
        () => ref.read(authStateProvider).hospitalId ?? '',
      );
      // Load the first page as soon as the provider is created.
      Future.microtask(notifier.refresh);
      return notifier;
    });

// ---------------------------------------------------------------------------
// Smart OPD & Prescription Workflow Providers
// ---------------------------------------------------------------------------

/// Doctor ki prescription mode:
/// true  = printed prescription (OPD pending),
/// false = direct OPD (registration ke saath completed).
final doctorPrescriptionModeProvider = FutureProvider.family<bool, String>((
  ref,
  doctorId,
) async {
  final dbService = ref.read(databaseServiceProvider);
  return dbService.getDoctorsPrescriptionMode(doctorId);
});

/// Payment details of one OPD registration (slip screen ke liye).
final opdPaymentDetailsProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((
      ref,
      opdRegistrationId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getOPDPaymentDetails(opdRegistrationId);
    });

/// Slip screen ke liye combined details:
/// payment + hospital + doctor + department.
final opdSlipDetailsProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((
      ref,
      opdRegistrationId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      final payment = await dbService.getOPDPaymentDetails(opdRegistrationId);
      if (payment == null) return null;

      final hospitalId = ref.read(authStateProvider).hospitalId;

      Map<String, dynamic>? hospital;
      Map<String, dynamic>? doctor;
      Map<String, dynamic>? department;

      if (hospitalId != null && hospitalId.isNotEmpty) {
        hospital = await dbService.getById(
          ApiConstants.hospitalsTable,
          hospitalId,
        );
      }

      final doctorId = payment['doctor_id']?.toString();
      if (doctorId != null && doctorId.isNotEmpty) {
        doctor = await dbService.getById(ApiConstants.doctorsTable, doctorId);
      }

      final departmentId = payment['department_id']?.toString();
      if (departmentId != null && departmentId.isNotEmpty) {
        department = await dbService.getById(
          ApiConstants.departmentsTable,
          departmentId,
        );
      }

      return {
        'payment': payment,
        'hospital': hospital,
        'doctor': doctor,
        'department': department,
      };
    });

// Auth State
final authStateProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(
    ref.watch(authServiceProvider),
    ref.watch(databaseServiceProvider),
  );
});

/// Convenience provider: the current user's hospital id, or null when the
/// account is not linked to a hospital. Screens should null-check this (or
/// `authStateProvider.hasHospitalId`) before loading tenant data and show an
/// error message when it is null.
final currentHospitalIdProvider = Provider<String?>((ref) {
  return ref.watch(authStateProvider).hospitalId;
});

/// Public `users.id` for the current logged-in user.
///
/// NOTE: `authState.userId` Supabase **auth.users** ka UUID hota hai, jabki
/// `notifications.user_id` aur `user_devices.user_id` public `users.id`
/// store karte hain. Isliye notifications/push flows ko is provider se
/// resolved public id use karni chahiye.
final currentPublicUserIdProvider = FutureProvider<String?>((ref) async {
  final session = ref.watch(supabaseClientProvider).auth.currentSession;
  if (session == null) return null;
  return ref.read(databaseServiceProvider).getCurrentUsersTableId();
});

class AuthState {
  static const Object _unset = Object();

  final bool isLoading;
  final bool isAuthenticated;
  final String? userId;
  final String? userRole;
  final String? hospitalId;
  final String? error;
  final bool hasCheckedAuth;
  final bool subscriptionExpired;

  /// Lockout window applied after [AuthService.maxLoginAttempts] failed
  /// login attempts. Non-null while the account is locked.
  final DateTime? accountLockedUntil;

  /// Failed login attempts recorded for the email being used on the login
  /// screen (mirrors the secure-storage counter).
  final int failedLoginAttempts;

  const AuthState({
    this.isLoading = false,
    this.isAuthenticated = false,
    this.userId,
    this.userRole,
    this.hospitalId,
    this.error,
    this.hasCheckedAuth = false,
    this.subscriptionExpired = false,
    this.accountLockedUntil,
    this.failedLoginAttempts = 0,
  });

  /// True when a non-empty hospital id is available. Screens must check this
  /// (or null-check [hospitalId]) before querying tenant data.
  bool get hasHospitalId => hospitalId != null && hospitalId!.isNotEmpty;

  /// True while the account is inside the 15-minute lockout window.
  bool get isAccountLocked =>
      accountLockedUntil != null && accountLockedUntil!.isAfter(DateTime.now());

  /// Remaining lock duration (never negative), or null when not locked.
  Duration? get accountLockRemaining {
    final until = accountLockedUntil;
    if (until == null) return null;
    final remaining = until.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  AuthState copyWith({
    bool? isLoading,
    bool? isAuthenticated,
    String? userId,
    String? userRole,
    String? hospitalId,
    String? error,
    bool? hasCheckedAuth,
    bool? subscriptionExpired,
    Object? accountLockedUntil = _unset,
    int? failedLoginAttempts,
  }) {
    return AuthState(
      isLoading: isLoading ?? this.isLoading,
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      userId: userId ?? this.userId,
      userRole: userRole ?? this.userRole,
      hospitalId: hospitalId ?? this.hospitalId,
      error: error,
      hasCheckedAuth: hasCheckedAuth ?? this.hasCheckedAuth,
      subscriptionExpired: subscriptionExpired ?? this.subscriptionExpired,
      accountLockedUntil: identical(accountLockedUntil, _unset)
          ? this.accountLockedUntil
          : accountLockedUntil as DateTime?,
      failedLoginAttempts: failedLoginAttempts ?? this.failedLoginAttempts,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  final AuthService _authService;
  final DatabaseService _dbService;
  Future<void>? _bootstrapFuture;

  AuthNotifier(this._authService, this._dbService) : super(const AuthState());

  Future<void> bootstrap({bool force = false}) {
    if (force) _bootstrapFuture = null;
    return _bootstrapFuture ??= _restoreSessionAndHospital();
  }

  Future<void> _restoreSessionAndHospital() async {
    state = state.copyWith(isLoading: true, error: null);

    // Secure storage se session restore + expired hone par refresh.
    final session = await _authService.ensureFreshSession();
    if (session == null) {
      state = const AuthState(
        isAuthenticated: false,
        isLoading: false,
        hasCheckedAuth: true,
      );
      return;
    }

    // NOTE: Persistent-login requirement — inactivity timeout monitor is NOT
    // started here. Sirf deliberate logout session khatam karta hai.

    // Prefer the full public record so `userRole` is restored as well. Jab
    // network available na ho (offline restore), secure storage mein cached
    // public user record use karo — isse hospital context bhi offline milta hai.
    var userRecord = await _dbService.getCurrentUserRecord();
    userRecord ??= await _authService.getCachedUserRecord();

    var hospitalId = userRecord?['hospital_id'] as String?;
    if (hospitalId == null || hospitalId.isEmpty) {
      try {
        hospitalId = await _dbService.getHospitalIdForUser(session.user.id);
      } catch (e) {
        AppLogger.e('Could not fetch hospital id during restore', e);
      }
    }

    // Fresh network record mile toh cache update kar do taaki agla offline
    // restore bhi latest hospital context use kare.
    if (userRecord != null) {
      if (hospitalId != null && hospitalId.isNotEmpty) {
        userRecord = {...userRecord, 'hospital_id': hospitalId};
      }
      await _authService.cacheUserRecord(userRecord);
    }
    if (hospitalId == null || hospitalId.isEmpty) {
      state = AuthState(
        isAuthenticated: true,
        userId: session.user.id,
        hospitalId: null,
        isLoading: false,
        error:
            'Your account is not assigned to any hospital. '
            'Please contact your administrator.',
        hasCheckedAuth: true,
      );
      throw StateError('No hospital is assigned to user ${session.user.id}');
    }

    _applyUserRecord(
      userRecord,
      authUserId: session.user.id,
      hospitalIdOverride: hospitalId,
    );
    await _refreshSubscriptionBlocked(hospitalId);
  }

  void _applyUserRecord(
    Map<String, dynamic>? record, {
    String? authUserId,
    String? hospitalIdOverride,
  }) {
    final userId = authUserId ?? record?['auth_id'] as String?;
    final userRole = record?['role'] as String?;
    final hospitalId = hospitalIdOverride ?? record?['hospital_id'] as String?;

    print('✅ Hospital ID set: $hospitalId');
    if (hospitalId == null || hospitalId.isEmpty) {
      print('⚠️ WARNING: hospital_id is NULL for user "$userId".');
    }

    state = AuthState(
      isAuthenticated: true,
      userId: userId,
      userRole: userRole,
      hospitalId: hospitalId,
      isLoading: false,
      error: (hospitalId == null || hospitalId.isEmpty)
          ? 'Your account is not assigned to any hospital. '
                'Please contact your administrator.'
          : null,
      hasCheckedAuth: true,
    );
  }

  Future<void> checkAuthStatus() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final session = await _authService.getCurrentSession();
      if (session == null) {
        state = state.copyWith(
          isLoading: false,
          isAuthenticated: false,
          hasCheckedAuth: true,
        );
        return;
      }

      var userRecord = await _dbService.getCurrentUserRecord();
      print('🔎 [checkAuthStatus] userRecord: $userRecord');

      const maxRetries = 3;
      var attempt = 0;
      while ((userRecord == null ||
              (userRecord['hospital_id'] as String?)?.isEmpty == true) &&
          attempt < maxRetries) {
        attempt++;
        print(
          '🔁 [checkAuthStatus] Retry $attempt/$maxRetries fetching user record...',
        );
        await Future.delayed(const Duration(milliseconds: 300));
        userRecord = await _dbService.getCurrentUserRecord();
      }

      // Offline fallback: secure storage ka cached public user record use
      // karo jab network fetch fail ho jaye.
      userRecord ??= await _authService.getCachedUserRecord();
      if (userRecord != null &&
          (userRecord['hospital_id'] as String?)?.isEmpty == true) {
        final cached = await _authService.getCachedUserRecord();
        if (cached != null &&
            (cached['hospital_id'] as String?)?.isNotEmpty == true) {
          userRecord = cached;
        }
      }

      if (userRecord == null) {
        // Handle userRecord == null gracefully: keep the user authenticated
        // but leave hospitalId null. The UI can then prompt the user to be
        // linked to a hospital, or retry fetching the record later.
        state = state.copyWith(
          isAuthenticated: true,
          userId: session.user.id,
          userRole: null,
          hospitalId: null,
          isLoading: false,
          error:
              'Your account is not assigned to any hospital. '
              'Please contact your administrator.',
          hasCheckedAuth: true,
        );
        print(
          '⚠️ [checkAuthStatus] userRecord is null. User authenticated without a hospital ID.',
        );
        return;
      }

      final hospitalId = userRecord['hospital_id'] as String?;
      if (hospitalId == null || hospitalId.isEmpty) {
        state = state.copyWith(
          isAuthenticated: true,
          userId: userRecord['auth_id'] as String? ?? session.user.id,
          userRole: userRecord['role'] as String?,
          hospitalId: null,
          isLoading: false,
          error:
              'Your account is not assigned to any hospital. '
              'Please contact your administrator.',
          hasCheckedAuth: true,
        );
        print(
          '⚠️ [checkAuthStatus] user record found but hospital_id is null/empty.',
        );
        return;
      }

      await _authService.cacheUserRecord(userRecord);
      _applyUserRecord(userRecord, authUserId: session.user.id);
      await _refreshSubscriptionBlocked(hospitalId);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
        hasCheckedAuth: true,
      );
    }
  }

  String _parseAuthError(dynamic e) {
    if (e is AccountLockedException) {
      return e.message;
    }
    if (e is AuthException) {
      final statusCode = int.tryParse(e.statusCode ?? '') ?? 0;
      switch (statusCode) {
        case 400:
          if (e.message.contains('Invalid login credentials')) {
            return 'Invalid email or password. Please check your credentials.\n'
                'ईमेल या पासवर्ड गलत है। कृपया अपनी जानकारी जांचें।';
          }
          return 'Invalid request. Please check your input.\n'
              'अमान्य अनुरोध। कृपया अपनी इनपुट जांचें।';
        case 429:
          return 'Too many login attempts. Please try again later.\n'
              'बहुत सारे लॉगिन प्रयास। कृपया बाद में पुनः प्रयास करें।';
        default:
          return 'Login failed: ${e.message}\nलॉगिन विफल: ${e.message}';
      }
    }
    if (e is SocketException) {
      return 'Unable to connect to server. Please check your internet connection.\n'
          'सर्वर से कनेक्ट नहीं हो पा रहा। कृपया इंटरनेट कनेक्शन जांचें।';
    }
    if (e is TimeoutException) {
      return 'The server took too long to respond. Please try again.\n'
          'सर्वर प्रतिक्रिया देने में बहुत समय ले रहा है। कृपया पुनः प्रयास करें।\n\n'
          'If this keeps happening, the Supabase project may be paused or '
          'restarting — please try again in a few minutes.';
    }
    return 'Login failed. Please try again.\nलॉगिन विफल। कृपया पुनः प्रयास करें।';
  }

  Future<bool> login(String email, String password) async {
    state = state.copyWith(
      isLoading: true,
      error: null,
      accountLockedUntil: null,
    );
    try {
      final userRecord = await _authService.loginWithRateLimit(
        email: email,
        password: password,
      );
      // Offline restore ke liye public user record cache kar lo.
      await _authService.cacheUserRecord(userRecord);
      _applyUserRecord(userRecord);
      final hospitalId = userRecord['hospital_id'] as String?;
      if (hospitalId != null && hospitalId.isNotEmpty) {
        await _refreshSubscriptionBlocked(hospitalId);
      }
      // NOTE: Persistent-login requirement — inactivity auto-logout timer is
      // not started. Sirf deliberate logout session khatam karta hai.
      return true;
    } on AccountLockedException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message,
        accountLockedUntil: e.lockedUntil,
        failedLoginAttempts: AuthService.maxLoginAttempts,
      );
      return false;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _parseAuthError(e),
        failedLoginAttempts: await _authService.getFailedLoginAttempts(email),
      );
      return false;
    }
  }

  /// Re-reads the hospital's subscription status and updates
  /// [AuthState.subscriptionExpired]. Fails open (never blocks login) when
  /// the status cannot be fetched.
  Future<void> refreshSubscriptionStatus() async {
    final hospitalId = state.hospitalId;
    if (hospitalId == null || hospitalId.isEmpty) return;
    await _refreshSubscriptionBlocked(hospitalId);
  }

  /// Clears the subscription block after a successful renewal.
  void markSubscriptionActive() {
    state = state.copyWith(subscriptionExpired: false);
  }

  Future<void> _refreshSubscriptionBlocked(String hospitalId) async {
    try {
      final status = await _dbService.getSubscriptionStatus(hospitalId);
      state = state.copyWith(subscriptionExpired: status['is_expired'] == true);
    } catch (e) {
      AppLogger.e('Could not load subscription status — failing open', e);
      state = state.copyWith(subscriptionExpired: false);
    }
  }

  /// Deliberate logout only — persistent login requirement ke tahat session
  /// sirf yahin (user action) khatam hota hai.
  Future<void> logout() async {
    try {
      await _authService.signOut();
    } catch (e) {
      AppLogger.e('Logout error (continuing with local cleanup)', e);
    } finally {
      _authService.stopSessionTimeoutMonitor();
      // `hasCheckedAuth: true` keeps the router guard active after logout so
      // a back-button / manual URL can't re-enter a protected route.
      state = const AuthState(hasCheckedAuth: true);
    }
  }
}

// ---------------------------------------------------------------------------
// Unified Lab / Diagnostics Module Providers
// ---------------------------------------------------------------------------

/// Full diagnostic test master for a hospital (including inactive tests).
/// The admin master screen uses this so disabled tests stay visible.
final diagnosticTestsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String?>((
      ref,
      hospitalId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getDiagnosticTests(
        hospitalId: hospitalId,
        activeOnly: false,
      );
    });

/// Active tests only — used by the test ordering screen.
final activeDiagnosticTestsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String?>((
      ref,
      hospitalId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getDiagnosticTests(
        hospitalId: hospitalId,
        activeOnly: true,
      );
    });

class DiagnosticOrdersParams {
  final String? hospitalId;
  final String? status;

  const DiagnosticOrdersParams({this.hospitalId, this.status});

  @override
  bool operator ==(Object other) =>
      other is DiagnosticOrdersParams &&
      other.hospitalId == hospitalId &&
      other.status == status;

  @override
  int get hashCode => Object.hash(hospitalId, status);
}

final diagnosticOrdersProvider =
    FutureProvider.family<List<Map<String, dynamic>>, DiagnosticOrdersParams>((
      ref,
      params,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getDiagnosticOrders(
        hospitalId: params.hospitalId,
        status: params.status,
      );
    });

final diagnosticOrderItemsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      orderId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getDiagnosticOrderItems(orderId);
    });

/// Aggregated revenue statistics for the Lab Revenue dashboard.
final diagnosticsRevenueStatsProvider =
    FutureProvider.family<Map<String, dynamic>, String>((
      ref,
      hospitalId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getLabRevenueStats(hospitalId);
    });

// ---------------------------------------------------------------------------
// Voucher / Expense Module Providers
// ---------------------------------------------------------------------------

/// Active custom voucher categories (merged with the built-in list on the
/// entry screen).
final voucherCategoriesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String?>((
      ref,
      hospitalId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getVoucherCategories(
        hospitalId: hospitalId,
        activeOnly: true,
      );
    });

/// All custom voucher categories (including inactive) for the settings screen.
final allVoucherCategoriesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      hospitalId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getVoucherCategories(
        hospitalId: hospitalId,
        activeOnly: false,
      );
    });

/// Date-range filter for the voucher list. `==`/`hashCode` are overridden so
/// Riverpod can cache per-filter results.
class VoucherFilter {
  final String hospitalId;
  final DateTime? from;
  final DateTime? to;

  const VoucherFilter({required this.hospitalId, this.from, this.to});

  @override
  bool operator ==(Object other) =>
      other is VoucherFilter &&
      other.hospitalId == hospitalId &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(hospitalId, from, to);
}

final vouchersProvider =
    FutureProvider.family<List<Map<String, dynamic>>, VoucherFilter>((
      ref,
      filter,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getVouchers(
        hospitalId: filter.hospitalId,
        from: filter.from,
        to: filter.to,
      );
    });

/// Today's + current-month voucher expense totals for the dashboard.
final voucherStatsProvider =
    FutureProvider.family<Map<String, dynamic>, String>((
      ref,
      hospitalId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getVoucherStats(hospitalId);
    });

/// Approver name + approval limit for a hospital (null = not configured).
final voucherSettingsProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((
      ref,
      hospitalId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getVoucherSettings(hospitalId);
    });

// ---------------------------------------------------------------------------
// Unified Billing Module Providers
// ---------------------------------------------------------------------------

/// Filter for the unified billing list. `==`/`hashCode` are overridden so
/// Riverpod can cache per-tab results.
///
/// Prefer [sourceType] (`opd` / `ipd` / `lab` / `pharmacy` / `manual`) for the
/// unified tabs; [visitType] is kept for backwards compatibility.
class BillingFilter {
  final String? hospitalId;
  final String? visitType;
  final String? sourceType;

  const BillingFilter({this.hospitalId, this.visitType, this.sourceType});

  @override
  bool operator ==(Object other) =>
      other is BillingFilter &&
      other.hospitalId == hospitalId &&
      other.visitType == visitType &&
      other.sourceType == sourceType;

  @override
  int get hashCode => Object.hash(hospitalId, visitType, sourceType);
}

/// Page size used by the unified billing history list.
const int billingPageSize = 30;

/// Paginated unified billing history notifier (30 records per page).
///
/// One notifier instance exists per [BillingFilter] (hospital + source tab)
/// and stays cached by Riverpod, so switching tabs back and forth does not
/// re-download data.
class BillingListNotifier
    extends PaginationListNotifier<Map<String, dynamic>> {
  BillingListNotifier(
    super.dbService,
    super.hospitalIdReader, {
    required this.sourceType,
  }) : super(limit: billingPageSize);

  final String? sourceType;

  @override
  Future<List<Map<String, dynamic>>> fetchPage(
    DatabaseService db,
    int page,
    int limit,
    String hospitalId,
  ) {
    return db.getBillingHistoryPage(
      hospitalId: hospitalId,
      sourceType: sourceType,
      page: page,
      limit: limit,
    );
  }
}

/// Unified billing history for a hospital, optionally filtered by source
/// type (`opd` / `ipd` / `lab` / `manual`; null = every source).
///
/// Only the active tab's provider instance is created and fetched; Riverpod
/// keeps already-visited tab instances alive so switching back is instant.
final allBillsProvider =
    StateNotifierProvider.family<
      BillingListNotifier,
      PaginationState<Map<String, dynamic>>,
      BillingFilter
    >((ref, filter) {
      final notifier = BillingListNotifier(
        ref.watch(databaseServiceProvider),
        () => filter.hospitalId ?? ref.read(authStateProvider).hospitalId ?? '',
        sourceType: filter.sourceType,
      );
      // Load the first page as soon as the provider is created.
      Future.microtask(notifier.refresh);
      return notifier;
    });

/// One bill with items, payment logs, edit history and billing audit attached.
final billDetailProvider = FutureProvider.family<Map<String, dynamic>?, String>(
  (ref, billId) async {
    final dbService = ref.read(databaseServiceProvider);
    return dbService.getBillById(billId);
  },
);

/// Payment/transaction history for a bill.
final billPaymentLogsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      billId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getPaymentLogs(billId);
    });

/// Edit audit trail for a bill.
final billEditHistoryProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      billId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getBillEditHistory(billId);
    });

/// JSONB audit trail (`billing_audit`) for a bill.
final billAuditProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      billId,
    ) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getBillingAudit(billId);
    });

// ---------------------------------------------------------------------------
// Reports Module Providers
// ---------------------------------------------------------------------------

/// All generated reports for the current hospital, newest first.
///
/// Watch this from the reports list screen; pull-to-refresh /
/// [AppRefreshButton] should `ref.invalidate(reportsProvider(hospitalId))`.
final reportsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      hospitalId,
    ) {
      ref.watch(reportsRefreshProvider);
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getReports(hospitalId: hospitalId);
    });

/// Refresh tick for the reports list — increment karke list refresh hoti hai
/// without recreating the provider family.
final reportsRefreshProvider = StateProvider<int>((ref) => 0);

/// A single report (may be null) for the report detail screen.
final reportDetailProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, reportId) async {
      final dbService = ref.read(databaseServiceProvider);
      return dbService.getReportById(reportId);
    });

/// Service that generates reports from real tenant-scoped database records
/// and persists them into the existing `reports` table.
final reportGenerationServiceProvider = Provider<ReportGenerationService>((ref) {
  return ReportGenerationService(ref.watch(databaseServiceProvider));
});

// ---------------------------------------------------------------------------
// Compliance & Renewal Reminder Module Providers
// ---------------------------------------------------------------------------

final complianceServiceProvider = Provider<ComplianceService>((ref) {
  return ComplianceService(
    ref.watch(supabaseClientProvider),
    dbService: ref.watch(databaseServiceProvider),
    storageService: ref.watch(storageServiceProvider),
  );
});

/// Refresh tick for compliance lists — increment karke list/stats refresh
/// hote hain without recreating the provider family.
final complianceRefreshProvider = StateProvider<int>((ref) => 0);

/// Search/filter/sort state for the compliance dashboard.
class ComplianceFilter {
  final String search;
  final ComplianceCategory? category;
  final ComplianceStatus? status;
  final bool favoriteOnly;
  final String sortBy;
  final bool ascending;

  const ComplianceFilter({
    this.search = '',
    this.category,
    this.status,
    this.favoriteOnly = false,
    this.sortBy = 'expiry',
    this.ascending = false,
  });

  @override
  bool operator ==(Object other) =>
      other is ComplianceFilter &&
      other.search == search &&
      other.category == category &&
      other.status == status &&
      other.favoriteOnly == favoriteOnly &&
      other.sortBy == sortBy &&
      other.ascending == ascending;

  @override
  int get hashCode =>
      Object.hash(search, category, status, favoriteOnly, sortBy, ascending);
}

/// Hospital-scoped compliance records (enriched with document counts).
final complianceRecordsProvider =
    FutureProvider.family<List<ComplianceRecord>, String>((ref, hospitalId) {
      ref.watch(complianceRefreshProvider);
      return ref.read(complianceServiceProvider).getRecords(hospitalId);
    });

/// Aggregated compliance stats for the dashboard header cards.
final complianceStatsProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, hospitalId) {
      ref.watch(complianceRefreshProvider);
      return ref.read(complianceServiceProvider).getStats(hospitalId);
    });

/// One compliance record by id (detail screen).
final complianceRecordDetailProvider =
    FutureProvider.family<ComplianceRecord?, String>((ref, recordId) {
      ref.watch(complianceRefreshProvider);
      final hospitalId = ref.watch(currentHospitalIdProvider);
      return ref
          .read(complianceServiceProvider)
          .getRecordById(recordId, hospitalId: hospitalId);
    });

/// Versioned documents attached to one record.
final complianceDocumentsProvider =
    FutureProvider.family<List<ComplianceDocumentFile>, String>((
      ref,
      recordId,
    ) {
      ref.watch(complianceRefreshProvider);
      return ref.read(complianceServiceProvider).getDocuments(recordId);
    });

/// Flattened "All Documents" list across records (search/filter/export screen).
final allComplianceDocumentsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      hospitalId,
    ) {
      ref.watch(complianceRefreshProvider);
      return ref.read(complianceServiceProvider).getAllDocuments(hospitalId);
    });

/// Reminder history for a hospital.
final complianceRemindersProvider =
    FutureProvider.family<List<ComplianceReminderEntry>, String>((
      ref,
      hospitalId,
    ) {
      ref.watch(complianceRefreshProvider);
      return ref.read(complianceServiceProvider).getReminders(hospitalId);
    });

/// Audit logs for a hospital (newest first, capped at 200 rows).
final complianceAuditLogsProvider =
    FutureProvider.family<List<ComplianceAuditEntry>, String>((
      ref,
      hospitalId,
    ) {
      ref.watch(complianceRefreshProvider);
      return ref.read(complianceServiceProvider).getAuditLogs(hospitalId);
    });

/// One document file by id (viewer screen).
final complianceDocumentByIdProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((
      ref,
      documentId,
    ) async {
      final service = ref.read(complianceServiceProvider);
      final doc = await service.getDocumentById(documentId);
      return doc?.toJson();
    });

// ---------------------------------------------------------------------------
// Personalized User Tag System Providers
// ---------------------------------------------------------------------------

final personalizedTagServiceProvider = Provider<PersonalizedTagService>((ref) {
  return PersonalizedTagService(ref.watch(supabaseClientProvider));
});

/// Identifies one per-user tag collection: the logged-in user + the field
/// context (`patient`, `opd`, `ipd`, `compliance`, ...). `==`/`hashCode` are
/// overridden so Riverpod can cache per-collection results.
class UserTagParams {
  final String userId;
  final String fieldKey;

  const UserTagParams({required this.userId, required this.fieldKey});

  @override
  bool operator ==(Object other) =>
      other is UserTagParams &&
      other.userId == userId &&
      other.fieldKey == fieldKey;

  @override
  int get hashCode => Object.hash(userId, fieldKey);
}

/// The logged-in user's personal tag collection for one field context,
/// ordered by usage frequency (most-used first). The tag field widget uses
/// this to render "Based on your history..." suggestions.
final userTagsProvider =
    FutureProvider.family<List<PersonalizedTag>, UserTagParams>((ref, params) {
      return ref
          .read(personalizedTagServiceProvider)
          .getUserTags(params.userId, params.fieldKey);
    });

/// Identifies the tags attached to one record (patient, OPD registration,
/// IPD admission, ...) by the current user.
class EntityTagParams {
  final String userId;
  final String entityType;
  final String entityId;

  const EntityTagParams({
    required this.userId,
    required this.entityType,
    required this.entityId,
  });

  @override
  bool operator ==(Object other) =>
      other is EntityTagParams &&
      other.userId == userId &&
      other.entityType == entityType &&
      other.entityId == entityId;

  @override
  int get hashCode => Object.hash(userId, entityType, entityId);
}

/// Tags currently applied to one record by the current user. Used to
/// pre-populate the tag field when editing an existing record.
final entityTagsProvider =
    FutureProvider.family<List<PersonalizedTag>, EntityTagParams>((
      ref,
      params,
    ) {
      return ref
          .read(personalizedTagServiceProvider)
          .getEntityTags(params.userId, params.entityType, params.entityId);
    });

// ---------------------------------------------------------------------------
// Reusable Error + Retry UI (FutureProvider error state ke liye)
// ---------------------------------------------------------------------------

/// Reusable error widget for provider error states.
///
/// Usage:
/// ```dart
/// ref.watch(someProvider).when(
///   data: (data) => ...,
///   error: (error, stackTrace) => ProviderErrorRetry(
///     provider: someProvider,
///     error: error,
///   ),
///   loading: () => const CircularProgressIndicator(),
/// );
/// ```
class ProviderErrorRetry extends ConsumerWidget {
  const ProviderErrorRetry({
    super.key,
    required this.provider,
    this.message = 'Failed to load data',
    this.error,
  });

  /// Provider jise Retry button par `ref.invalidate` karna hai.
  final ProviderOrFamily provider;

  final String message;
  final Object? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              message,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error.toString(),
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => ref.invalidate(provider),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Employee / HRMS Module Providers
// ---------------------------------------------------------------------------
// Dependency Inversion: UI depends on the focused repository abstractions and
// pure calculators below, never on SupabaseClient directly.

/// Persistence for the employee master (employee CRUD only).
final employeeRepositoryProvider = Provider<EmployeeRepository>((ref) {
  return SupabaseEmployeeRepository(ref.watch(supabaseClientProvider));
});

/// Persistence/querying for raw attendance punch events (punches only).
final attendanceRepositoryProvider = Provider<AttendanceRepository>((ref) {
  return SupabaseAttendanceRepository(ref.watch(supabaseClientProvider));
});

/// Pure daily/monthly attendance aggregation (no Supabase dependency).
final attendanceCalculatorProvider = Provider<AttendanceCalculator>((ref) {
  return const AttendanceCalculator();
});

/// Pure salary calculation (no Supabase dependency).
final salaryCalculatorProvider = Provider<SalaryCalculator>((ref) {
  return const SalaryCalculator();
});

/// Refresh tick for the employee master list.
final employeesRefreshProvider = StateProvider<int>((ref) => 0);

/// All employees of the current hospital (employee master only — no
/// attendance history is loaded here).
final employeesProvider =
    FutureProvider.family<List<Employee>, String>((ref, hospitalId) {
      ref.watch(employeesRefreshProvider);
      return ref
          .read(employeeRepositoryProvider)
          .getEmployees(hospitalId: hospitalId);
    });

/// Identifies one employee by id inside the current hospital (form screen).
class EmployeeDetailParams {
  final String hospitalId;
  final String employeeId;

  const EmployeeDetailParams({
    required this.hospitalId,
    required this.employeeId,
  });

  @override
  bool operator ==(Object other) =>
      other is EmployeeDetailParams &&
      other.hospitalId == hospitalId &&
      other.employeeId == employeeId;

  @override
  int get hashCode => Object.hash(hospitalId, employeeId);
}

final employeeByIdProvider =
    FutureProvider.family<Employee?, EmployeeDetailParams>((ref, params) {
      ref.watch(employeesRefreshProvider);
      return ref
          .read(employeeRepositoryProvider)
          .getEmployeeById(
            hospitalId: params.hospitalId,
            id: params.employeeId,
          );
    });

/// Identifies one daily attendance board: hospital + selected date.
class AttendanceDayParams {
  final String hospitalId;
  final DateTime date;

  const AttendanceDayParams({required this.hospitalId, required this.date});

  @override
  bool operator ==(Object other) =>
      other is AttendanceDayParams &&
      other.hospitalId == hospitalId &&
      other.date.year == date.year &&
      other.date.month == date.month &&
      other.date.day == date.day;

  @override
  int get hashCode => Object.hash(hospitalId, date.year, date.month, date.day);
}

/// Daily attendance summaries for every eligible active employee.
///
/// Fetches employees once and punches once for the selected date, then
/// aggregates in memory via [AttendanceCalculator] — never N+1.
final dailyAttendanceProvider =
    FutureProvider.family<List<EmployeeDailyAttendance>, AttendanceDayParams>((
      ref,
      params,
    ) async {
      final employees = await ref.watch(
        employeesProvider(params.hospitalId).future,
      );
      final punches = await ref
          .read(attendanceRepositoryProvider)
          .getPunchesForDate(hospitalId: params.hospitalId, date: params.date);
      return ref
          .read(attendanceCalculatorProvider)
          .dailyAttendanceForDate(
            date: params.date,
            employees: employees,
            punches: punches,
          );
    });

/// Identifies one monthly attendance board: hospital + month + year.
class AttendanceMonthParams {
  final String hospitalId;
  final int year;
  final int month;

  const AttendanceMonthParams({
    required this.hospitalId,
    required this.year,
    required this.month,
  });

  @override
  bool operator ==(Object other) =>
      other is AttendanceMonthParams &&
      other.hospitalId == hospitalId &&
      other.year == year &&
      other.month == month;

  @override
  int get hashCode => Object.hash(hospitalId, year, month);
}

/// Monthly attendance aggregation for every employee (one entry each).
///
/// Fetches punches once for the whole month and aggregates in memory.
final monthlyAttendanceProvider =
    FutureProvider.family<List<EmployeeMonthlyAttendance>, AttendanceMonthParams>((
      ref,
      params,
    ) async {
      final employees = await ref.watch(
        employeesProvider(params.hospitalId).future,
      );
      final punches = await ref
          .read(attendanceRepositoryProvider)
          .getPunchesForRange(
            hospitalId: params.hospitalId,
            from: DateTime(params.year, params.month, 1),
            to: DateTime(params.year, params.month + 1, 1),
          );
      return ref
          .read(attendanceCalculatorProvider)
          .monthlyAttendanceFor(
            year: params.year,
            month: params.month,
            employees: employees,
            punches: punches,
          );
    });

/// Salary summaries for a month, computed locally from monthly attendance.
///
/// [SalaryCalculator] receives employee + attendance data and never queries
/// Supabase (DIP).
final employeeSalarySummaryProvider =
    FutureProvider.family<List<EmployeeSalarySummary>, AttendanceMonthParams>((
      ref,
      params,
    ) async {
      final employees = await ref.watch(
        employeesProvider(params.hospitalId).future,
      );
      final monthly = await ref.watch(
        monthlyAttendanceProvider(params).future,
      );
      final calculator = ref.read(salaryCalculatorProvider);

      final employeesById = {for (final e in employees) e.id: e};
      return [
        for (final attendance in monthly)
          if (attendance.eligibleDays > 0 &&
              employeesById[attendance.employeeId] != null)
            calculator.calculate(
              employee: employeesById[attendance.employeeId]!,
              attendance: attendance,
              year: params.year,
              month: params.month,
            ),
      ];
    });

// ---------------------------------------------------------------------------
// PRO / Marketing Module Providers
// ---------------------------------------------------------------------------
// Dependency Inversion: UI depends on the focused repository abstractions and
// pure services (GeoFenceService / MarketingAnalyticsService) below, never on
// SupabaseClient directly.

/// Persistence for marketing areas (CRUD only).
final marketingAreaRepositoryProvider = Provider<MarketingAreaRepository>((ref) {
  return SupabaseMarketingAreaRepository(ref.watch(supabaseClientProvider));
});

/// Persistence for the REFERRAL DOCTOR master (separate from `doctors`).
final referralDoctorRepositoryProvider = Provider<ReferralDoctorRepository>((
  ref,
) {
  return SupabaseReferralDoctorRepository(ref.watch(supabaseClientProvider));
});

/// Persistence for marketing visit punches.
final marketingVisitRepositoryProvider = Provider<MarketingVisitRepository>((
  ref,
) {
  return SupabaseMarketingVisitRepository(ref.watch(supabaseClientProvider));
});

/// Persistence for patient referral history.
final patientReferralRepositoryProvider = Provider<PatientReferralRepository>((
  ref,
) {
  return SupabasePatientReferralRepository(ref.watch(supabaseClientProvider));
});

/// Pure geofence verification (Haversine, no Supabase, no UI).
final geofenceServiceProvider = Provider<GeoFenceService>((ref) {
  return const GeoFenceService();
});

/// Pure marketing analytics (no Supabase queries inside).
final marketingAnalyticsServiceProvider = Provider<MarketingAnalyticsService>((
  ref,
) {
  return const MarketingAnalyticsService();
});

/// Refresh tick for all marketing lists/stats.
final marketingRefreshProvider = StateProvider<int>((ref) => 0);

/// All marketing areas for the current hospital (name ascending).
final marketingAreasProvider =
    FutureProvider.family<List<MarketingArea>, String>((ref, hospitalId) {
      ref.watch(marketingRefreshProvider);
      return ref
          .read(marketingAreaRepositoryProvider)
          .getAreas(hospitalId: hospitalId);
    });

/// All referral doctors for the current hospital (including inactive).
final referralDoctorsProvider =
    FutureProvider.family<List<ReferralDoctor>, String>((ref, hospitalId) {
      ref.watch(marketingRefreshProvider);
      return ref
          .read(referralDoctorRepositoryProvider)
          .getReferralDoctors(hospitalId: hospitalId);
    });

/// Identifies one referral doctor inside the current hospital.
class ReferralDoctorDetailParams {
  final String hospitalId;
  final String doctorId;

  const ReferralDoctorDetailParams({
    required this.hospitalId,
    required this.doctorId,
  });

  @override
  bool operator ==(Object other) =>
      other is ReferralDoctorDetailParams &&
      other.hospitalId == hospitalId &&
      other.doctorId == doctorId;

  @override
  int get hashCode => Object.hash(hospitalId, doctorId);
}

final referralDoctorByIdProvider =
    FutureProvider.family<ReferralDoctor?, ReferralDoctorDetailParams>((
      ref,
      params,
    ) {
      ref.watch(marketingRefreshProvider);
      return ref
          .read(referralDoctorRepositoryProvider)
          .getReferralDoctorById(
            hospitalId: params.hospitalId,
            id: params.doctorId,
          );
    });

/// Date range for visit queries. `==`/`hashCode` compare date parts only so
/// Riverpod can cache per-range results.
class MarketingVisitRangeParams {
  final String hospitalId;
  final DateTime from;
  final DateTime to;

  const MarketingVisitRangeParams({
    required this.hospitalId,
    required this.from,
    required this.to,
  });

  @override
  bool operator ==(Object other) =>
      other is MarketingVisitRangeParams &&
      other.hospitalId == hospitalId &&
      _sameDay(other.from, from) &&
      _sameDay(other.to, to);

  @override
  int get hashCode =>
      Object.hash(hospitalId, from.year, from.month, from.day, to.year, to.month, to.day);

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Visit punches in `[from, to)`, newest first.
final marketingVisitsProvider =
    FutureProvider.family<List<MarketingVisit>, MarketingVisitRangeParams>((
      ref,
      params,
    ) {
      ref.watch(marketingRefreshProvider);
      return ref
          .read(marketingVisitRepositoryProvider)
          .getVisitsForRange(
            hospitalId: params.hospitalId,
            from: params.from,
            to: params.to,
          );
    });

/// Date range for patient-referral queries.
class PatientReferralRangeParams {
  final String hospitalId;
  final DateTime from;
  final DateTime to;

  const PatientReferralRangeParams({
    required this.hospitalId,
    required this.from,
    required this.to,
  });

  @override
  bool operator ==(Object other) =>
      other is PatientReferralRangeParams &&
      other.hospitalId == hospitalId &&
      _sameDay(other.from, from) &&
      _sameDay(other.to, to);

  @override
  int get hashCode =>
      Object.hash(hospitalId, from.year, from.month, from.day, to.year, to.month, to.day);

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Patient referrals in `[from, to)`, newest first.
final patientReferralsProvider =
    FutureProvider.family<List<PatientReferral>, PatientReferralRangeParams>((
      ref,
      params,
    ) {
      ref.watch(marketingRefreshProvider);
      return ref
          .read(patientReferralRepositoryProvider)
          .getReferralsForRange(
            hospitalId: params.hospitalId,
            from: params.from,
            to: params.to,
          );
    });

/// Search params for the patient picker in the referral entry screen.
class MarketingPatientSearchParams {
  final String query;
  final String hospitalId;

  const MarketingPatientSearchParams({
    required this.query,
    required this.hospitalId,
  });

  @override
  bool operator ==(Object other) =>
      other is MarketingPatientSearchParams &&
      other.query == query &&
      other.hospitalId == hospitalId;

  @override
  int get hashCode => Object.hash(query, hospitalId);
}

/// Patient search enriched with the patient's recent OPD/IPD visits so the
/// referral form can offer an optional OPD/IPD link without N+1 queries.
final marketingPatientSearchProvider =
    FutureProvider.family<List<Map<String, dynamic>>, MarketingPatientSearchParams>((
      ref,
      params,
    ) {
      if (params.query.trim().isEmpty) return Future.value(const []);
      return ref
          .read(databaseServiceProvider)
          .searchPatientsAcrossVisits(
            params.query,
            hospitalId: params.hospitalId,
          );
    });

/// Identifies the dashboard context: hospital + reference date.
class MarketingDashboardParams {
  final String hospitalId;
  final DateTime date;

  const MarketingDashboardParams({required this.hospitalId, required this.date});

  @override
  bool operator ==(Object other) =>
      other is MarketingDashboardParams &&
      other.hospitalId == hospitalId &&
      other.date.year == date.year &&
      other.date.month == date.month &&
      other.date.day == date.day;

  @override
  int get hashCode => Object.hash(hospitalId, date.year, date.month, date.day);
}

/// Dashboard summary: fetches doctors, the current month's visits and the
/// current month's referrals ONCE each, then aggregates via the pure
/// [MarketingAnalyticsService] (never N+1).
final marketingDashboardProvider =
    FutureProvider.family<MarketingDashboardSummary, MarketingDashboardParams>((
      ref,
      params,
    ) async {
      ref.watch(marketingRefreshProvider);

      final monthStart = DateTime(params.date.year, params.date.month, 1);
      final nextMonth = DateTime(params.date.year, params.date.month + 1, 1);

      final doctors = await ref.watch(
        referralDoctorsProvider(params.hospitalId).future,
      );
      final areas = await ref.watch(
        marketingAreasProvider(params.hospitalId).future,
      );
      final visits = await ref
          .read(marketingVisitRepositoryProvider)
          .getVisitsForRange(
            hospitalId: params.hospitalId,
            from: monthStart,
            to: nextMonth,
          );
      final referrals = await ref
          .read(patientReferralRepositoryProvider)
          .getReferralsForRange(
            hospitalId: params.hospitalId,
            from: monthStart,
            to: nextMonth,
          );

      return ref.read(marketingAnalyticsServiceProvider).buildDashboard(
        doctors: doctors,
        visits: visits,
        referrals: referrals,
        areas: areas,
        now: params.date,
      );
    });

/// Identifies the area-activity context: hospital + area + month.
class MarketingAreaActivityParams {
  final String hospitalId;
  final String areaId;
  final DateTime month;

  const MarketingAreaActivityParams({
    required this.hospitalId,
    required this.areaId,
    required this.month,
  });

  @override
  bool operator ==(Object other) =>
      other is MarketingAreaActivityParams &&
      other.hospitalId == hospitalId &&
      other.areaId == areaId &&
      other.month.year == month.year &&
      other.month.month == month.month;

  @override
  int get hashCode =>
      Object.hash(hospitalId, areaId, month.year, month.month);
}

/// Area detail: doctors of one area + that area's month activity.
final marketingAreaActivityProvider =
    FutureProvider.family<AreaActivitySummary, MarketingAreaActivityParams>((
      ref,
      params,
    ) async {
      ref.watch(marketingRefreshProvider);

      final monthStart = DateTime(params.month.year, params.month.month, 1);
      final nextMonth = DateTime(params.month.year, params.month.month + 1, 1);

      final doctors = await ref.watch(
        referralDoctorsProvider(params.hospitalId).future,
      );
      final areas = await ref.watch(
        marketingAreasProvider(params.hospitalId).future,
      );
      final visits = await ref
          .read(marketingVisitRepositoryProvider)
          .getVisitsForRange(
            hospitalId: params.hospitalId,
            from: monthStart,
            to: nextMonth,
          );
      final referrals = await ref
          .read(patientReferralRepositoryProvider)
          .getReferralsForRange(
            hospitalId: params.hospitalId,
            from: monthStart,
            to: nextMonth,
          );

      final summary = ref
          .read(marketingAnalyticsServiceProvider)
          .areaSummaries(
            doctors: doctors,
            visits: visits,
            referrals: referrals,
            areas: areas,
            now: params.month,
          )
          .where((s) => s.areaId == params.areaId)
          .firstOrNull;

      return summary ??
          AreaActivitySummary(
            areaId: params.areaId,
            areaName: params.areaId,
            referralDoctorCount: 0,
            visitedToday: 0,
            visitedThisMonth: 0,
            referralsThisMonth: 0,
          );
    });

/// Identifies the bounded detail window for one referral doctor.
class ReferralDoctorDetailAnalyticsParams {
  final String hospitalId;
  final String doctorId;
  final DateTime now;

  const ReferralDoctorDetailAnalyticsParams({
    required this.hospitalId,
    required this.doctorId,
    required this.now,
  });

  @override
  bool operator ==(Object other) =>
      other is ReferralDoctorDetailAnalyticsParams &&
      other.hospitalId == hospitalId &&
      other.doctorId == doctorId &&
      other.now.year == now.year &&
      other.now.month == now.month &&
      other.now.day == now.day;

  @override
  int get hashCode =>
      Object.hash(hospitalId, doctorId, now.year, now.month, now.day);
}

/// Aggregated detail for the referral-doctor detail screen.
///
/// Fetches a bounded 90-day window of visits/referrals (never the entire
/// lifetime history) plus two cheap lifetime COUNT queries.
final referralDoctorDetailProvider =
    FutureProvider.family<ReferralDoctorDetail?, ReferralDoctorDetailAnalyticsParams>((
      ref,
      params,
    ) async {
      ref.watch(marketingRefreshProvider);

      final doctor = await ref.read(
        referralDoctorByIdProvider(
          ReferralDoctorDetailParams(
            hospitalId: params.hospitalId,
            doctorId: params.doctorId,
          ),
        ).future,
      );
      if (doctor == null) return null;

      final from = DateTime(params.now.year, params.now.month, params.now.day)
          .subtract(const Duration(days: 90));
      final to = DateTime(params.now.year, params.now.month, params.now.day)
          .add(const Duration(days: 1));

      final visitRepo = ref.read(marketingVisitRepositoryProvider);
      final referralRepo = ref.read(patientReferralRepositoryProvider);

      final results = await Future.wait([
        visitRepo.getVisitsForDoctorRange(
          hospitalId: params.hospitalId,
          doctorId: doctor.id,
          from: from,
          to: to,
        ),
        referralRepo.getReferralsForDoctorRange(
          hospitalId: params.hospitalId,
          doctorId: doctor.id,
          from: from,
          to: to,
        ),
        visitRepo.countVisitsForDoctor(
          hospitalId: params.hospitalId,
          doctorId: doctor.id,
        ),
        referralRepo.countReferralsForDoctor(
          hospitalId: params.hospitalId,
          doctorId: doctor.id,
        ),
      ]);

      final visits = (results[0] as List).cast<MarketingVisit>();
      final referrals = (results[1] as List).cast<PatientReferral>();
      final totalVisits = results[2] as int;
      final totalReferrals = results[3] as int;

      final summaries = ref
          .read(marketingAnalyticsServiceProvider)
          .referralDoctorSummaries(
            doctors: [doctor],
            visits: visits,
            referrals: referrals,
            now: params.now,
          );
      final doctorSummary = summaries.firstOrNull;

      return ReferralDoctorDetail(
        doctor: doctor,
        totalVisits: totalVisits,
        visitsThisMonth: doctorSummary?.visitsThisMonth ?? 0,
        patientsReferred: totalReferrals,
        patientsReferredThisMonth: doctorSummary?.referralsThisMonth ?? 0,
        lastVisit: doctorSummary?.lastVisit,
        recentVisits: visits.take(5).toList(),
        recentReferrals: referrals.take(5).toList(),
      );
    });

