import 'dart:async';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/constants/api_constants.dart';
import '../core/utils/logger.dart';
import 'cache_service.dart';
import 'local_db.dart';

class DatabaseService {
  final SupabaseClient _client;
  final LocalDatabase _localDb;
  final CacheService _cache;
  bool _syncInProgress = false;

  DatabaseService(
    this._client, {
    LocalDatabase? localDb,
    CacheService? cacheService,
  }) : _localDb = localDb ?? getLocalDatabase(),
       _cache = cacheService ?? CacheService.instance;

  // ---------------------------------------------------------------------------
  // API Timeout & Retry Logic
  // ---------------------------------------------------------------------------

  /// Har Supabase API call ke liye default timeout.
  static const Duration apiTimeout = Duration(seconds: 10);

  /// Retry attempts ke beech ka delay.
  static const Duration retryDelay = Duration(seconds: 2);

  /// Initial attempt ke alawa kitni baar retry karna hai.
  static const int maxRetries = 2;

  /// [function] ko timeout + retry ke saath run karta hai.
  ///
  /// * Har attempt par [timeout] (default 10s) apply hota hai; timeout hone par
  ///   [TimeoutException] throw hota hai.
  /// * Timeout / network error par [retries] baar retry hota hai (default 2),
  ///   har retry se pehle [delay] (default 2s) ka wait hota hai.
  /// * Saare attempts fail hone par [AppLogger.e] mein error log hota hai aur
  ///   last error rethrow hota hai.
  static Future<T> fetchWithRetry<T>(
    Future<T> Function() function, {
    Duration timeout = apiTimeout,
    int retries = maxRetries,
    Duration delay = retryDelay,
  }) async {
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        return await function().timeout(
          timeout,
          onTimeout: () => throw TimeoutException(
            'API call timed out after ${timeout.inSeconds} seconds',
          ),
        );
      } catch (e, stackTrace) {
        lastError = e;
        lastStackTrace = stackTrace;

        final isLastAttempt = attempt >= retries;
        if (isLastAttempt || !_isRetryableError(e)) {
          if (isLastAttempt) {
            AppLogger.e(
              'API call failed after $retries retries: $e',
              lastError,
              lastStackTrace,
            );
          } else {
            AppLogger.e('API call failed (non-retryable): $e', e, stackTrace);
          }
          rethrow;
        }

        AppLogger.w(
          'API call failed (${e.runtimeType}) — retry ${attempt + 1}/$retries '
          'in ${delay.inSeconds}s',
        );
        await Future.delayed(delay);
      }
    }

    // Compiler ko khush rakhne ke liye; upar wala loop hamesha return/rethrow
    // kar deta hai.
    throw lastError ?? Exception('API call failed');
  }

  /// True jab error timeout ya network-level ho (retry karne layak).
  ///
  /// Platform-specific types (`SocketException`, `ClientException`, ...) ko
  /// type-name se check karte hain taaki `dart:io` import na karna pade aur
  /// web build bhi safe rahe.
  static bool _isRetryableError(Object error) {
    if (error is TimeoutException) return true;
    final type = error.runtimeType.toString();
    return type == 'SocketException' ||
        type == 'ClientException' ||
        type == 'HandshakeException' ||
        type == 'HttpException' ||
        type == 'ConnectionException' ||
        type == 'ConnectionClosedException';
  }

  // Generic CRUD Operations
  Future<List<Map<String, dynamic>>> getAll(
    String table, {
    Map<String, dynamic>? filters,
    String? hospitalId,
  }) async {
    try {
      final response = await fetchWithRetry(() async {
        dynamic query = _client.from(table).select();
        if (hospitalId != null && hospitalId.isNotEmpty) {
          query = query.eq('hospital_id', hospitalId);
        }
        if (filters != null) {
          filters.forEach((key, value) {
            query = query.eq(key, value);
          });
        }
        return await query;
      });
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching from $table', e);
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> getById(
    String table,
    String id, {
    String? hospitalId,
  }) async {
    try {
      final response = await fetchWithRetry(() async {
        dynamic query = _client.from(table).select().eq('id', id);
        if (hospitalId != null && hospitalId.isNotEmpty) {
          query = query.eq('hospital_id', hospitalId);
        }
        return await query.single();
      });
      return response;
    } catch (e) {
      AppLogger.e('Error fetching from $table by id', e);
      return null;
    }
  }

  Future<Map<String, dynamic>> create(
    String table,
    Map<String, dynamic> data, {
    String? hospitalId,
  }) async {
    try {
      // Tenant-tag the row when the caller passes a hospital id and the data
      // doesn't already carry one. Tables without a hospital_id column should
      // simply not pass [hospitalId].
      final payload =
          (hospitalId != null &&
              hospitalId.isNotEmpty &&
              data['hospital_id'] == null)
          ? <String, dynamic>{...data, 'hospital_id': hospitalId}
          : data;
      final response = await fetchWithRetry(
        () => _client.from(table).insert(payload).select(),
      );
      if (response.isEmpty) {
        throw Exception('Insert returned 0 rows');
      }
      await _invalidateFrequentCacheForTable(table);
      return response.first;
    } catch (e) {
      AppLogger.e('Error creating in $table', e);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> update(
    String table,
    String id,
    Map<String, dynamic> data, {
    String? hospitalId,
  }) async {
    try {
      final response = await fetchWithRetry(() async {
        dynamic query = _client.from(table).update(data).eq('id', id);
        if (hospitalId != null && hospitalId.isNotEmpty) {
          query = query.eq('hospital_id', hospitalId);
        }
        return await query.select().single();
      });
      await _invalidateFrequentCacheForTable(table);
      return response;
    } catch (e) {
      AppLogger.e('Error updating in $table', e);
      rethrow;
    }
  }

  Future<void> delete(String table, String id, {String? hospitalId}) async {
    try {
      await fetchWithRetry(() async {
        dynamic query = _client.from(table).delete().eq('id', id);
        if (hospitalId != null && hospitalId.isNotEmpty) {
          query = query.eq('hospital_id', hospitalId);
        }
        return await query;
      });
      await _invalidateFrequentCacheForTable(table);
    } catch (e) {
      AppLogger.e('Error deleting from $table', e);
      rethrow;
    }
  }

  // Patient-specific Operations
  Future<Map<String, dynamic>> registerPatient(
    Map<String, dynamic> patientData, {
    String? hospitalId,
  }) async {
    try {
      final payload = _tenantPayload(
        patientData,
        hospitalId,
        table: ApiConstants.patientsTable,
      );
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.patientsTable)
            .insert(payload)
            .select()
            .single(),
      );
      await _invalidateFrequentCacheForTable(ApiConstants.patientsTable);
      return response;
    } catch (e) {
      AppLogger.e('Error registering patient', e);
      rethrow;
    }
  }

  /// Paginated patient list fetch.
  ///
  /// [page] is 0-based. [limit] controls the page size and `.range(from, to)`
  /// is used so Supabase returns only the requested window of rows.
  Future<List<Map<String, dynamic>>> getPatients({
    required int page,
    required int limit,
    required String hospitalId,
  }) async {
    final from = page * limit;
    final to = from + limit - 1;
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.patientsTable)
            .select()
            .eq('hospital_id', hospitalId)
            .order('created_at', ascending: false)
            .range(from, to),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching patients', e);
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> searchPatients(
    String query, {
    String? hospitalId,
  }) async {
    try {
      dynamic dbQuery = _client.from(ApiConstants.patientsTable).select();

      if (hospitalId != null) {
        dbQuery = dbQuery.eq('hospital_id', hospitalId);
      }

      dbQuery = dbQuery.or(
        'uhid.ilike.%$query%,first_name.ilike.%$query%,last_name.ilike.%$query%,mobile_number.ilike.%$query%',
      );

      final response = await fetchWithRetry(() => dbQuery.limit(20));
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error searching patients', e);
      rethrow;
    }
  }

  /// Searches patients by exact mobile number match.
  Future<List<Map<String, dynamic>>> searchPatientByPhone(
    String phone, {
    String? hospitalId,
  }) async {
    try {
      dynamic query = _client.from(ApiConstants.patientsTable).select();

      if (hospitalId != null) {
        query = query.eq('hospital_id', hospitalId);
      }

      query = query.eq('mobile_number', phone);

      final response = await fetchWithRetry(() => query.limit(10));
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error searching patient by phone', e);
      rethrow;
    }
  }

  /// Combined search across the patient master, OPD registrations and IPD
  /// admissions.
  ///
  /// First the patient master is searched by UHID/name/mobile, then the OPD
  /// and IPD visit rows for those patients are fetched in one `inFilter` call
  /// each. Each returned patient row is enriched with:
  ///
  ///   * `opd_visits`     — recent OPD registration rows for the patient
  ///   * `ipd_admissions` — recent IPD admission rows for the patient
  ///
  /// This lets the combined search screen show "OPD + IPD" context per
  /// patient without issuing N+1 queries.
  Future<List<Map<String, dynamic>>> searchPatientsAcrossVisits(
    String query, {
    String? hospitalId,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    try {
      final patients = await searchPatients(trimmed, hospitalId: hospitalId);
      if (patients.isEmpty) return const [];

      final patientIds = patients
          .map((p) => p['id']?.toString())
          .whereType<String>()
          .toList();
      if (patientIds.isEmpty) return const [];

      final results = await Future.wait([
        _listVisitsForPatients(
          ApiConstants.opdRegistrationsTable,
          patientIds,
          hospitalId,
          select: 'patient_id, id, visit_date, status',
        ),
        _listVisitsForPatients(
          ApiConstants.ipdAdmissionsTable,
          patientIds,
          hospitalId,
          select: 'patient_id, id, admission_date, discharge_date, status',
        ),
      ]);

      final opdByPatient = <String, List<Map<String, dynamic>>>{};
      for (final row in results[0]) {
        final pid = row['patient_id']?.toString();
        if (pid != null) (opdByPatient[pid] ??= []).add(row);
      }

      final ipdByPatient = <String, List<Map<String, dynamic>>>{};
      for (final row in results[1]) {
        final pid = row['patient_id']?.toString();
        if (pid != null) (ipdByPatient[pid] ??= []).add(row);
      }

      return [
        for (final patient in patients)
          {
            ...patient,
            'opd_visits': opdByPatient[patient['id']] ?? const [],
            'ipd_admissions': ipdByPatient[patient['id']] ?? const [],
          },
      ];
    } catch (e) {
      AppLogger.e('Error searching patients across visits', e);
      return const [];
    }
  }

  /// Shared helper used by [searchPatientsAcrossVisits]: fetches rows from
  /// [table] for a batch of patient ids in a single request.
  Future<List<Map<String, dynamic>>> _listVisitsForPatients(
    String table,
    List<String> patientIds,
    String? hospitalId, {
    String select = '*',
  }) async {
    try {
      final response = await fetchWithRetry(() {
        dynamic query = _client
            .from(table)
            .select(select)
            .inFilter('patient_id', patientIds);

        if (hospitalId != null && hospitalId.isNotEmpty) {
          query = query.eq('hospital_id', hospitalId);
        }

        return query.limit(200);
      });
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching $table rows for patient batch', e);
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // Patient Full Profile (aggregated history for the profile screen)
  // ---------------------------------------------------------------------------

  /// Aggregates every patient-scoped record for the full patient profile screen.
  ///
  /// Every source is fetched independently inside [safeList]/[safeMap] so a
  /// missing table, revoked grant or a transient network failure never blocks
  /// the rest of the profile. The returned map uses plural record keys whose
  /// values are `List<Map<String, dynamic>>` (or `Map<String, dynamic>?` for
  /// singular lookups).
  Future<Map<String, dynamic>> getPatientFullProfile(
    String patientId, {
    String? hospitalId,
  }) async {
    Future<List<Map<String, dynamic>>> safeList(
      String label,
      Future<List<Map<String, dynamic>>> Function() fetch,
    ) async {
      try {
        return await fetch();
      } catch (e) {
        AppLogger.e('Patient profile: could not load $label', e);
        return const [];
      }
    }

    final results = await Future.wait([
      safeList('patient', () async {
        final p = await getById(ApiConstants.patientsTable, patientId);
        return p == null ? const [] : [p];
      }),
      safeList(
        'opd visits',
        () => _listByPatient(
          ApiConstants.opdRegistrationsTable,
          patientId,
          limit: 50,
        ),
      ),
      safeList(
        'ipd admissions',
        () => _listByPatient(
          ApiConstants.ipdAdmissionsTable,
          patientId,
          limit: 50,
        ),
      ),
      safeList(
        'prescriptions',
        () => _listByPatient(
          ApiConstants.prescriptionsTable,
          patientId,
          select: '*, prescription_items(*)',
          orderColumn: 'prescription_date',
          limit: 50,
        ),
      ),
      safeList(
        'vitals',
        () => _listByPatient(
          ApiConstants.vitalsTable,
          patientId,
          orderColumn: 'recorded_at',
          limit: 30,
        ),
      ),
      safeList(
        'progress notes',
        () => _listByPatient(
          ApiConstants.progressNotesTable,
          patientId,
          orderColumn: 'note_date',
          limit: 30,
        ),
      ),
      safeList(
        'investigations',
        () => _listByPatient(
          ApiConstants.investigationsTable,
          patientId,
          select: '*, investigation_results(*)',
          orderColumn: 'ordered_date',
          limit: 50,
        ),
      ),
      safeList(
        'legacy lab orders',
        () => _listByPatient(
          ApiConstants.labOrdersTable,
          patientId,
          select: '*, lab_results(*)',
          orderColumn: 'order_date',
          limit: 50,
        ),
      ),
      safeList(
        'diagnostic orders',
        () => _listByPatient(
          ApiConstants.diagnosticOrdersTable,
          patientId,
          select: '*, diagnostic_order_items(*, diagnostic_results(*))',
          limit: 50,
        ),
      ),
      safeList(
        'bills',
        () => _listByPatient(
          ApiConstants.billingTable,
          patientId,
          select: '*, billing_items(*), payment_logs(*)',
          orderColumn: 'bill_date',
          limit: 100,
        ),
      ),
      safeList(
        'insurances',
        () => _listByPatient(
          ApiConstants.patientInsurancesTable,
          patientId,
          limit: 20,
        ),
      ),
      safeList(
        'abha linking logs',
        () => _listByPatient(
          ApiConstants.abhaLinkingLogsTable,
          patientId,
          limit: 20,
        ),
      ),
      safeList(
        'whatsapp messages',
        () => _listByPatient(
          ApiConstants.whatsappMessagesTable,
          patientId,
          orderColumn: 'sent_at',
          limit: 50,
        ),
      ),
    ]);

    final patient = (results[0] as List).isEmpty
        ? null
        : (results[0] as List).first as Map<String, dynamic>;
    final admissions = (results[2] as List).cast<Map<String, dynamic>>();

    // `ipd_reports` is admission-scoped (it has no patient_id column), so the
    // most recent admissions are resolved in parallel and indexed by admission
    // id for the profile's Files tab.
    final ipdReportsByAdmission = <String, List<Map<String, dynamic>>>{};
    if (admissions.isNotEmpty) {
      final recent = admissions.take(10).toList();
      final reportBatches = await Future.wait([
        for (final admission in recent)
          safeList('ipd reports for admission ${admission['id']}', () async {
            final response = await fetchWithRetry(
              () => _client
                  .from(ApiConstants.ipdReportsTable)
                  .select()
                  .eq('admission_id', admission['id'])
                  .order('report_date', ascending: false),
            );
            return List<Map<String, dynamic>>.from(response);
          }),
      ]);
      for (var i = 0; i < recent.length; i++) {
        final admissionId = recent[i]['id']?.toString();
        if (admissionId != null) {
          ipdReportsByAdmission[admissionId] = (reportBatches[i] as List)
              .cast<Map<String, dynamic>>();
        }
      }
    }

    // `beds` is admission-scoped via `ipd_admissions.bed_id`. Resolve the bed
    // number per admission (in parallel, one lookup per unique bed) so the
    // profile's IPD cards can show "Ward + Bed" without a hard join that
    // could fail on deployments that have not run the bed_id migration yet.
    final bedNumbersByAdmission = <String, String>{};
    if (admissions.isNotEmpty) {
      final bedIds = <String>[];
      for (final admission in admissions) {
        final bedId = admission['bed_id']?.toString();
        if (bedId != null && bedId.isNotEmpty && !bedIds.contains(bedId)) {
          bedIds.add(bedId);
        }
      }

      if (bedIds.isNotEmpty) {
        final bedBatches = await Future.wait([
          for (final bedId in bedIds)
            safeList('bed $bedId', () async {
              final bed = await getById(ApiConstants.bedsTable, bedId);
              return bed == null ? const [] : [bed];
            }),
        ]);

        final bedNumberById = <String, String>{};
        for (var i = 0; i < bedIds.length; i++) {
          final rows = bedBatches[i] as List;
          if (rows.isNotEmpty) {
            bedNumberById[bedIds[i]] =
                (rows.first as Map<String, dynamic>)['bed_number']
                    ?.toString() ??
                '';
          }
        }

        for (final admission in admissions) {
          final bedId = admission['bed_id']?.toString();
          final admissionId = admission['id']?.toString();
          if (bedId == null || admissionId == null) continue;
          final bedNumber = bedNumberById[bedId];
          if (bedNumber != null && bedNumber.isNotEmpty) {
            bedNumbersByAdmission[admissionId] = bedNumber;
          }
        }
      }
    }

    return {
      'patient': patient,
      'opd_visits': results[1],
      'ipd_admissions': admissions,
      'prescriptions': results[3],
      'vitals': results[4],
      'progress_notes': results[5],
      'investigations': results[6],
      'lab_orders': results[7],
      'diagnostic_orders': results[8],
      'bills': results[9],
      'insurances': results[10],
      'abha_linking_logs': results[11],
      'whatsapp_messages': results[12],
      'ipd_reports_by_admission': ipdReportsByAdmission,
      'admission_beds': bedNumbersByAdmission,
    };
  }

  /// Shared helper: patient-scoped rows from [table], newest first by default.
  Future<List<Map<String, dynamic>>> _listByPatient(
    String table,
    String patientId, {
    String select = '*',
    String orderColumn = 'created_at',
    bool ascending = false,
    int? limit,
  }) {
    return fetchWithRetry(() async {
      dynamic query = _client
          .from(table)
          .select(select)
          .eq('patient_id', patientId);
      if (orderColumn.isNotEmpty) {
        query = query.order(orderColumn, ascending: ascending);
      }
      if (limit != null) {
        query = query.limit(limit);
      }
      final response = await query;
      return List<Map<String, dynamic>>.from(response);
    });
  }

  // OPD Operations
  Future<List<Map<String, dynamic>>> getTodayOPDQueue(
    String doctorId, {
    String? hospitalId,
  }) async {
    try {
      final today = DateTime.now().toIso8601String().split('T')[0];
      final response = await fetchWithRetry(() async {
        dynamic query = _client
            .from(ApiConstants.opdRegistrationsTable)
            .select()
            .eq('visit_date', today)
            .eq('doctor_id', doctorId);

        if (hospitalId != null) {
          query = query.eq('hospital_id', hospitalId);
        }

        query = query.order('visit_time', ascending: true);

        return await query;
      });
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching OPD queue', e);
      rethrow;
    }
  }

  /// Paginated OPD queue fetch with joined patient details (name, UHID).
  ///
  /// [page] is 0-based. [limit] controls the page size and `.range(from, to)`
  /// is used so Supabase returns only the requested window of rows.
  /// No status filter — returns every row. Sorted newest-first.
  Future<List<Map<String, dynamic>>> getOPDQueue({
    required int page,
    required int limit,
    required String hospitalId,
  }) async {
    final from = page * limit;
    final to = from + limit - 1;
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.opdRegistrationsTable)
            .select('*, patients(first_name, last_name, uhid)')
            .eq('hospital_id', hospitalId)
            .order('created_at', ascending: false)
            .range(from, to),
      );

      final entries = List<Map<String, dynamic>>.from(response);
      AppLogger.i('getOPDQueue page $page entries length: ${entries.length}');
      return entries;
    } catch (e, stackTrace) {
      AppLogger.e('Error fetching OPD queue: $e', stackTrace);
      rethrow;
    }
  }

  /// Returns IPD admissions for a hospital, newest first, with the patient's
  /// name/UHID and (when the FK is present) bed number embedded.
  ///
  /// When [page] is provided the result is a paginated window using
  /// `.range(from, to)`; otherwise up to [limit] rows are returned.
  Future<List<Map<String, dynamic>>> getIPDAdmissions({
    required String hospitalId,
    int limit = 100,
    int? page,
  }) async {
    try {
      final response = await fetchWithRetry(() {
        dynamic query = _client
            .from(ApiConstants.ipdAdmissionsTable)
            .select(
              '*, patients(first_name, last_name, uhid), beds(bed_number)',
            )
            .eq('hospital_id', hospitalId)
            .order('created_at', ascending: false);

        if (page != null) {
          final from = page * limit;
          final to = from + limit - 1;
          query = query.range(from, to);
        } else {
          query = query.limit(limit);
        }

        return query;
      });
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching IPD admissions', e);
      return [];
    }
  }

  // Get all departments
  Future<List<Map<String, dynamic>>> getDepartments({
    String? hospitalId,
  }) async {
    try {
      final response = await fetchWithRetry(() async {
        dynamic query = _client.from(ApiConstants.departmentsTable).select();
        if (hospitalId != null) {
          query = query.eq('hospital_id', hospitalId);
        }
        return await query.order('name', ascending: true);
      });
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching departments', e);
      rethrow;
    }
  }

  // Get doctors by department ID
  Future<List<Map<String, dynamic>>> getDoctorsByDepartment(
    String departmentId, {
    String? hospitalId,
  }) async {
    try {
      final response = await fetchWithRetry(() async {
        dynamic query = _client
            .from('doctors')
            .select()
            .eq('department_id', departmentId)
            .eq('is_active', true);

        if (hospitalId != null) {
          query = query.eq('hospital_id', hospitalId);
        }

        return await query.order('name', ascending: true);
      });
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching doctors', e);
      return [];
    }
  }

  // IPD Operations
  Future<List<Map<String, dynamic>>> getBedsByStatus(
    String status, {
    String? hospitalId,
    String? wardType,
  }) async {
    try {
      final response = await fetchWithRetry(() async {
        dynamic query = _client
            .from(ApiConstants.bedsTable)
            .select()
            .ilike('status', status); // 🔥 Case-insensitive search

        if (hospitalId != null) {
          query = query.eq('hospital_id', hospitalId);
        }
        if (wardType != null) {
          query = query.ilike('ward_type', wardType);
        }

        return await query;
      });
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching beds', e);
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> getWards(String hospitalId) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.bedsTable)
            .select('ward_type')
            .eq('hospital_id', hospitalId)
            .not('ward_type', 'is', null)
            .order('ward_type', ascending: true),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching wards', e);
      return [];
    }
  }

  Future<int> getBedCount(String status, {String? hospitalId}) async {
    try {
      dynamic query = _client
          .from(ApiConstants.bedsTable)
          .select('*')
          .eq('status', status);

      if (hospitalId != null) {
        query = query.eq('hospital_id', hospitalId);
      }

      final response = await fetchWithRetry(
        () => query.count(CountOption.exact),
      );
      return response.count;
    } catch (e) {
      AppLogger.e('Error counting beds', e);
      return 0;
    }
  }

  /// Returns all beds for a hospital.
  Future<List<Map<String, dynamic>>> getBedsByWard(String? hospitalId) async {
    try {
      final response = await fetchWithRetry(() async {
        dynamic query = _client.from(ApiConstants.bedsTable).select();
        if (hospitalId != null && hospitalId.isNotEmpty) {
          query = query.eq('hospital_id', hospitalId);
        }
        return await query.order('bed_number', ascending: true);
      });
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching beds by ward', e);
      return [];
    }
  }

  /// Admits a patient by inserting a row into ipd_admissions.
  Future<Map<String, dynamic>> admitIPDPatient(
    Map<String, dynamic> data, {
    String? hospitalId,
  }) async {
    try {
      final payload = _tenantPayload(
        data,
        hospitalId,
        table: ApiConstants.ipdAdmissionsTable,
      );
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.ipdAdmissionsTable)
            .insert(payload)
            .select()
            .single(),
      );
      return response;
    } catch (e) {
      AppLogger.e('Error admitting IPD patient', e);
      rethrow;
    }
  }

  /// Updates a bed's occupancy.
  ///
  /// The beds table stores occupancy in the `status` column
  /// (e.g. 'available', 'occupied') rather than a boolean
  /// `is_occupied` flag, so `status` maps directly to that column.
  Future<void> updateBedStatus(
    String bedId,
    String status, {
    String? hospitalId,
  }) async {
    try {
      await fetchWithRetry(() async {
        dynamic query = _client
            .from(ApiConstants.bedsTable)
            .update({
              'status': status,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', bedId);
        if (hospitalId != null && hospitalId.isNotEmpty) {
          query = query.eq('hospital_id', hospitalId);
        }
        return await query;
      });
    } catch (e) {
      AppLogger.e('Error updating bed status', e);
      rethrow;
    }
  }

  /// Returns ward-wise occupied vs available bed counts for a hospital.
  Future<List<Map<String, dynamic>>> getWardStats(String hospitalId) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.bedsTable)
            .select('ward_name, ward_type, status')
            .eq('hospital_id', hospitalId)
            .eq('is_active', true),
      );

      final beds = List<Map<String, dynamic>>.from(response);
      final Map<String, Map<String, int>> stats = {};

      for (final bed in beds) {
        final wardName =
            (bed['ward_name'] as String?) ??
            (bed['ward_type'] as String?) ??
            'Unknown';
        final status = bed['status'] as String? ?? 'available';

        final entry = stats.putIfAbsent(
          wardName,
          () => {'occupied': 0, 'available': 0},
        );

        if (status == 'occupied') {
          entry['occupied'] = entry['occupied']! + 1;
        } else if (status == 'available') {
          entry['available'] = entry['available']! + 1;
        }
      }

      return stats.entries
          .map(
            (entry) => {
              'ward_name': entry.key,
              'occupied_beds': entry.value['occupied'],
              'available_beds': entry.value['available'],
            },
          )
          .toList();
    } catch (e) {
      AppLogger.e('Error fetching ward stats', e);
      return [];
    }
  }

  /// Discharges an IPD admission and frees its allocated bed.
  Future<Map<String, dynamic>> dischargePatient(
    String admissionId,
    Map<String, dynamic> dischargeData,
  ) async {
    try {
      final admission = await getById(
        ApiConstants.ipdAdmissionsTable,
        admissionId,
      );
      if (admission == null) {
        throw Exception('IPD admission not found: $admissionId');
      }

      final now = DateTime.now().toUtc().toIso8601String();
      final dischargeDate =
          dischargeData['discharge_date'] ??
          DateTime.now().toIso8601String().split('T')[0];

      final updatedAdmission = await _client
          .from(ApiConstants.ipdAdmissionsTable)
          .update({
            ...dischargeData,
            'status': 'discharged',
            'discharge_date': dischargeDate,
            'updated_at': now,
          })
          .eq('id', admissionId)
          .select()
          .single();

      // Free the bed and close the active allocation(s) for this admission.
      // Prefer the admission's current `bed_id` (admission + transfer keep it
      // in sync); fall back to the active bed allocation, then to the legacy
      // linked allocation. This covers:
      // * admissions where `bed_allocation_id` was never linked
      // * patients transferred after admission (current bed must be freed,
      //   not the original one)
      String? bedId = admission['bed_id'] as String?;

      final activeAllocations = await _client
          .from(ApiConstants.bedAllocationsTable)
          .select('id, bed_id')
          .eq('ipd_admission_id', admissionId)
          .eq('status', 'active');

      for (final allocation in activeAllocations) {
        bedId ??= allocation['bed_id']?.toString();

        await _client
            .from(ApiConstants.bedAllocationsTable)
            .update({
              'status': 'discharged',
              'discharge_date': dischargeDate,
              'updated_at': now,
            })
            .eq('id', allocation['id']);
      }

      // Legacy fallback: rows linked only through `bed_allocation_id`.
      if (bedId == null || bedId.isEmpty) {
        final bedAllocationId = admission['bed_allocation_id'];
        if (bedAllocationId != null) {
          final allocationResponse = await _client
              .from(ApiConstants.bedAllocationsTable)
              .select('bed_id, status')
              .eq('id', bedAllocationId)
              .maybeSingle();

          bedId = allocationResponse?['bed_id']?.toString();
          if (allocationResponse != null &&
              allocationResponse['status'] != 'discharged') {
            await _client
                .from(ApiConstants.bedAllocationsTable)
                .update({
                  'status': 'discharged',
                  'discharge_date': dischargeDate,
                  'updated_at': now,
                })
                .eq('id', bedAllocationId);
          }
        }
      }

      if (bedId != null && bedId.isNotEmpty) {
        await updateBedStatus(bedId, 'available');
      }

      return updatedAdmission;
    } catch (e) {
      AppLogger.e('Error discharging IPD patient', e);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // IPD Patient Dashboard Operations
  // ---------------------------------------------------------------------------

  /// Fetches combined details for the IPD patient dashboard:
  /// admission (ipd_admissions) + patient (patients) + bed (beds).
  Future<Map<String, dynamic>> getIPDAdmissionDetails(
    String admissionId,
  ) async {
    try {
      final admission = await getById(
        ApiConstants.ipdAdmissionsTable,
        admissionId,
      );
      if (admission == null) {
        throw Exception('IPD admission not found: $admissionId');
      }

      final patientId = admission['patient_id'] as String?;
      final bedId = admission['bed_id'] as String?;

      Map<String, dynamic>? patient;
      Map<String, dynamic>? bed;

      if (patientId != null && patientId.isNotEmpty) {
        patient = await getById(ApiConstants.patientsTable, patientId);
      }
      if (bedId != null && bedId.isNotEmpty) {
        bed = await getById(ApiConstants.bedsTable, bedId);
      }

      return {'admission': admission, 'patient': patient, 'bed': bed};
    } catch (e) {
      AppLogger.e('Error fetching IPD admission details', e);
      rethrow;
    }
  }

  /// Returns vitals for an admission, newest first.
  Future<List<Map<String, dynamic>>> getIPDVitals(String admissionId) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.ipdVitalsTable)
            .select()
            .eq('admission_id', admissionId)
            .order('recorded_at', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching IPD vitals', e);
      return [];
    }
  }

  /// Returns progress notes for an admission, newest first.
  Future<List<Map<String, dynamic>>> getIPDProgressNotes(
    String admissionId,
  ) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.ipdProgressNotesTable)
            .select()
            .eq('admission_id', admissionId)
            .order('note_date', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching IPD progress notes', e);
      return [];
    }
  }

  /// Returns medication chart entries for an admission.
  Future<List<Map<String, dynamic>>> getIPDMedications(
    String admissionId,
  ) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.ipdMedicationsTable)
            .select()
            .eq('admission_id', admissionId)
            .order('start_date', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching IPD medications', e);
      return [];
    }
  }

  /// Returns lab/investigation reports for an admission, newest first.
  Future<List<Map<String, dynamic>>> getIPDReports(String admissionId) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.ipdReportsTable)
            .select()
            .eq('admission_id', admissionId)
            .order('report_date', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching IPD reports', e);
      return [];
    }
  }

  /// Returns users (id, first_name, last_name, role, designation) for the
  /// given user ids, keyed by id. Used by the IPD dashboard to resolve the
  /// "recorded by / added by / modified by" display names.
  Future<Map<String, Map<String, dynamic>>> getUsersByIds(
    Iterable<String> userIds,
  ) async {
    final ids = userIds.where((id) => id.isNotEmpty).toSet().toList();
    final result = <String, Map<String, dynamic>>{};
    if (ids.isEmpty) return result;

    try {
      // Chunked so the Supabase `in` filter stays small and URL-safe.
      const chunkSize = 100;
      for (var i = 0; i < ids.length; i += chunkSize) {
        final chunk = ids.sublist(i, math.min(i + chunkSize, ids.length));
        final response = await fetchWithRetry(
          () => _client
              .from(ApiConstants.usersTable)
              .select('id, first_name, last_name, role, designation')
              .inFilter('id', chunk),
        );
        for (final row in response) {
          final id = row['id']?.toString();
          if (id != null && id.isNotEmpty) {
            result[id] = row;
          }
        }
      }
    } catch (e) {
      AppLogger.e('Error fetching users by ids', e);
    }
    return result;
  }

  /// Resolves the active (admitted) admission id for an occupied bed.
  ///
  /// The ward screen stores bed ids, while the patient dashboard route expects
  /// an admission id — this bridges the two.
  Future<String?> getActiveAdmissionIdForBed(String bedId) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.ipdAdmissionsTable)
            .select('id')
            .eq('bed_id', bedId)
            .eq('status', 'admitted')
            .maybeSingle(),
      );
      return response?['id'] as String?;
    } catch (e) {
      AppLogger.e('Error fetching active admission for bed', e);
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Doctor Prescription Operations
  // ---------------------------------------------------------------------------

  /// Searches active medicines for the e-prescription autocomplete.
  ///
  /// Matches [query] against medicine_name, generic_name and brand_name.
  /// Returns at most [limit] results (default 25) ordered by medicine name.
  Future<List<Map<String, dynamic>>> searchMedicines(
    String query, {
    String? hospitalId,
    int limit = 25,
  }) async {
    try {
      var dbQuery = _client
          .from(ApiConstants.pharmacyMedicinesTable)
          .select()
          .eq('is_active', true);

      if (hospitalId != null && hospitalId.isNotEmpty) {
        dbQuery = dbQuery.eq('hospital_id', hospitalId);
      }

      final trimmedQuery = query.trim();
      if (trimmedQuery.isNotEmpty) {
        final pattern = '%$trimmedQuery%';
        dbQuery = dbQuery.or(
          'medicine_name.ilike.$pattern,generic_name.ilike.$pattern,brand_name.ilike.$pattern',
        );
      }

      final response = await fetchWithRetry(
        () => dbQuery.order('medicine_name', ascending: true).limit(limit),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error searching medicines', e);
      return [];
    }
  }

  /// Inserts a new medicine into pharmacy_medicines and returns the row.
  Future<Map<String, dynamic>> addNewMedicine(
    Map<String, dynamic> data, {
    String? hospitalId,
  }) async {
    try {
      final payload = _tenantPayload(
        data,
        hospitalId,
        table: ApiConstants.pharmacyMedicinesTable,
      );
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.pharmacyMedicinesTable)
            .insert({...payload, 'is_active': true})
            .select()
            .single(),
      );
      await _invalidateFrequentCacheForTable(
        ApiConstants.pharmacyMedicinesTable,
      );
      return response;
    } catch (e) {
      AppLogger.e('Error adding new medicine', e);
      rethrow;
    }
  }

  /// Saves a unified prescription (OPD = full clinical document,
  /// IPD = medicines only).
  ///
  /// [medicines] is a list of maps with keys: medicine_name, generic_name,
  /// strength, dosage, frequency, duration, route, instructions and
  /// custom_times (a `List<String>` of "HH:MM AM/PM" values, stored as jsonb).
  ///
  /// [visitType] is derived from the linked visit ids when not supplied:
  /// `ipd_admission_id` -> `ipd`, `opd_registration_id` -> `opd`, else `opd`.
  ///
  /// [history], [investigations] and [advice] are the new JSONB section maps;
  /// [clinicalNotes] is the legacy `clinical_notes` map (kept in sync so older
  /// prints keep working).
  Future<Map<String, dynamic>> savePrescription({
    required String patientId,
    required String doctorId,
    String? hospitalId,
    String? opdRegistrationId,
    String? ipdAdmissionId,
    String? visitType,
    required List<Map<String, dynamic>> medicines,
    Map<String, dynamic>? history,
    Map<String, dynamic>? investigations,
    Map<String, dynamic>? advice,
    Map<String, dynamic>? clinicalNotes,
  }) async {
    try {
      final tenantId = _requireHospitalId(
        hospitalId,
        source: ApiConstants.prescriptionsTable,
      );

      final today = DateTime.now().toIso8601String().split('T')[0];

      // Context: IPD admission wins (agar dono somehow pass hue hon).
      final resolvedVisitType = visitType?.trim().toLowerCase() ??
          ((ipdAdmissionId != null && ipdAdmissionId.isNotEmpty)
              ? 'ipd'
              : 'opd');

      // Legacy inline medicine columns keep the old single-medicine rows
      // working; naya JSONB `medicines` array is the source of truth now.
      final first = medicines.isEmpty ? null : medicines.first;
      final singleMedicine = medicines.length == 1;
      final medicineName = medicines.isEmpty
          ? 'No medicines prescribed'
          : singleMedicine
          ? first!['medicine_name']
          : 'Multiple medicines';
      final dosage = singleMedicine ? first!['dosage'] : null;
      final frequency = singleMedicine ? first!['frequency'] : null;
      final duration = singleMedicine ? first!['duration'] : null;
      final instructions = singleMedicine ? first!['instructions'] : null;

      final resolvedHistory = history ?? <String, dynamic>{};
      final resolvedInvestigations = investigations ?? <String, dynamic>{};
      final resolvedAdvice = advice ?? <String, dynamic>{};
      final legacyClinicalNotes = clinicalNotes ?? <String, dynamic>{};

      final prescription = await fetchWithRetry(
        () => _client
            .from(ApiConstants.prescriptionsTable)
            .insert({
              'hospital_id': tenantId,
              'patient_id': patientId,
              'opd_registration_id': opdRegistrationId,
              'ipd_admission_id': ipdAdmissionId,
              'doctor_id': doctorId,
              'created_by': doctorId,
              'prescription_date': today,
              'status': 'active',
              'visit_type': resolvedVisitType,
              'history': resolvedHistory,
              'investigations': resolvedInvestigations,
              'medicines': medicines,
              'advice': resolvedAdvice,
              'clinical_notes': legacyClinicalNotes,
              // Legacy inline columns (backward compatibility).
              'medicine_name': medicineName,
              'dosage': dosage,
              'frequency': frequency,
              'duration': duration,
              'instructions': instructions,
            })
            .select()
            .single(),
      );

      final prescriptionId = prescription['id'] as String;

      // Legacy line-item table bhi sync rakho (purane prints/UI ke liye).
      for (final medicine in medicines) {
        await _client.from(ApiConstants.prescriptionItemsTable).insert({
          'prescription_id': prescriptionId,
          'medicine_name': medicine['medicine_name'],
          'dosage': medicine['dosage'],
          'frequency': medicine['frequency'],
          'duration': medicine['duration'],
          'instructions': medicine['instructions'],
          'custom_times': medicine['custom_times'] ?? const <String>[],
        });
      }

      // Smart OPD workflow: prescription generate hote hi linked OPD
      // registration `completed` ho jata hai (Doctor Mode = "Yes" wala flow).
      if (opdRegistrationId != null && opdRegistrationId.isNotEmpty) {
        await _markOPDRegistrationCompleted(opdRegistrationId);
      }

      return prescription;
    } catch (e) {
      AppLogger.e('Error saving prescription', e);
      rethrow;
    }
  }

  /// Returns all prescriptions for an OPD registration, newest first.
  ///
  /// Har row mein naya `medicines` JSONB array bhi normalized hota hai:
  /// jab column empty ho (legacy row) to `prescription_items` se medicines
  /// bhar di jaati hain taaki UI/print dono ko ek jaisa data mile.
  Future<List<Map<String, dynamic>>> getOPDPrescriptions(
    String opdRegistrationId,
  ) async {
    return _getPrescriptionsForVisit(
      column: 'opd_registration_id',
      visitId: opdRegistrationId,
      label: 'OPD prescriptions',
    );
  }

  /// Returns all unified prescriptions for an IPD admission, newest first.
  Future<List<Map<String, dynamic>>> getIPDPrescriptions(
    String ipdAdmissionId,
  ) async {
    return _getPrescriptionsForVisit(
      column: 'ipd_admission_id',
      visitId: ipdAdmissionId,
      label: 'IPD prescriptions',
    );
  }

  /// Shared visit-scoped prescription fetch + medicine normalisation.
  Future<List<Map<String, dynamic>>> _getPrescriptionsForVisit({
    required String column,
    required String visitId,
    required String label,
  }) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.prescriptionsTable)
            .select()
            .eq(column, visitId)
            .order('created_at', ascending: false),
      );

      final prescriptions = List<Map<String, dynamic>>.from(response);

      for (final prescription in prescriptions) {
        // Naya JSONB array na ho (legacy rows) to items table se fill karo.
        final rawMedicines = prescription['medicines'];
        final hasJsonMedicines = rawMedicines is List && rawMedicines.isNotEmpty;

        final itemsResponse = await fetchWithRetry(
          () => _client
              .from(ApiConstants.prescriptionItemsTable)
              .select()
              .eq('prescription_id', prescription['id'])
              .order('created_at', ascending: true),
        );
        final items = List<Map<String, dynamic>>.from(itemsResponse);
        prescription['items'] = items;

        if (!hasJsonMedicines) {
          prescription['medicines'] = [
            for (final item in items)
              {
                'medicine_name': item['medicine_name']?.toString() ?? '',
                'generic_name': null,
                'strength': null,
                'dosage': item['dosage']?.toString() ?? '',
                'frequency': item['frequency']?.toString() ?? '',
                'duration': item['duration']?.toString() ?? '',
                'route': null,
                'instructions': item['instructions']?.toString() ?? '',
                'custom_times': item['custom_times'] ?? const <String>[],
              },
          ];
        }
      }

      return prescriptions;
    } catch (e) {
      AppLogger.e('Error fetching $label', e);
      return [];
    }
  }

  /// Updates a prescription's status (`active` / `completed` / `cancelled`).
  Future<void> updatePrescriptionStatus(
    String prescriptionId,
    String status,
  ) async {
    try {
      await fetchWithRetry(
        () => _client
            .from(ApiConstants.prescriptionsTable)
            .update({'status': status})
            .eq('id', prescriptionId),
      );
      await _invalidateFrequentCacheForTable(
        ApiConstants.prescriptionsTable,
      );
    } catch (e) {
      AppLogger.e('Error updating prescription status', e);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Smart OPD & Prescription Workflow
  // ---------------------------------------------------------------------------

  /// Returns doctor ki `prescription_mode`:
  ///
  /// * `true`  -> Doctor printed prescription generate karega. OPD registration
  ///              `pending` rahegi jab tak prescription nahi banti.
  /// * `false` -> Direct OPD. OPD registration create hote hi `completed`.
  ///
  /// Doctor row na mile ya column missing ho to safe default `false` return
  /// hota hai (direct OPD behaviour).
  Future<bool> getDoctorsPrescriptionMode(String doctorId) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.doctorsTable)
            .select('prescription_mode')
            .eq('id', doctorId)
            .maybeSingle(),
      );
      return response?['prescription_mode'] == true;
    } catch (e) {
      AppLogger.e('Error fetching doctor prescription mode', e);
      return false;
    }
  }

  /// Updates doctor ki `prescription_mode` (Settings screen se).
  Future<void> updateDoctorPrescriptionMode(
    String doctorId,
    bool prescriptionMode,
  ) async {
    try {
      await fetchWithRetry(
        () => _client
            .from(ApiConstants.doctorsTable)
            .update({'prescription_mode': prescriptionMode})
            .eq('id', doctorId),
      );
      await _invalidateFrequentCacheForTable(ApiConstants.doctorsTable);
    } catch (e) {
      AppLogger.e('Error updating doctor prescription mode', e);
      rethrow;
    }
  }

  /// Smart OPD registration create karta hai.
  ///
  /// Doctor ki `prescription_mode` ke hisaab se:
  /// * `false` -> `status = completed`, `completed_at` set.
  /// * `true`  -> `status = pending` (prescription banne tak).
  ///
  /// Payment columns (`payment_amount`, `paid_amount`, `balance_amount`,
  /// `payment_status`) registration ke waqt hi seedhe `opd_registrations`
  /// mein save ho jaate hain — unified billing screen inhi rows ko OPD bills
  /// ki tarah dikhata hai, isliye consultation fee billing mein add ho jaati
  /// hai. Slip generate hone par `generateOPDSlip` inhe `paid` kar deta hai.
  Future<Map<String, dynamic>> createOPDRegistration(
    Map<String, dynamic> opdData, {
    String? hospitalId,
    required String doctorId,
  }) async {
    try {
      final prescriptionMode = await getDoctorsPrescriptionMode(doctorId);
      final fee = _toDouble(opdData['consultation_fee']);
      final now = DateTime.now().toUtc().toIso8601String();

      final payload = _tenantPayload(
        opdData,
        hospitalId,
        table: ApiConstants.opdRegistrationsTable,
      );
      // NOTE: opd_registrations.doctor_id FK -> users(id) hota hai jabki OPD
      // screen `doctors` table se doctor select karti hai. Dono ids alag hain,
      // isliye doctors.id yahan store nahi karte — sirf prescription_mode
      // lookup ke liye use hota hai. (Screen doctor ka naam slip route ko
      // query param ke through deti hai.)
      payload['status'] = prescriptionMode ? 'pending' : 'completed';
      payload['payment_amount'] = fee;
      payload['paid_amount'] = 0;
      payload['balance_amount'] = fee;
      payload['payment_status'] = 'unpaid';
      if (!prescriptionMode) {
        payload['completed_at'] = now;
      }

      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.opdRegistrationsTable)
            .insert(payload)
            .select()
            .single(),
      );
      await _invalidateFrequentCacheForTable(
        ApiConstants.opdRegistrationsTable,
      );
      return response;
    } catch (e) {
      AppLogger.e('Error creating OPD registration', e);
      rethrow;
    }
  }

  /// Returns payment details of one OPD registration (slip screen ke liye).
  ///
  /// `*` isliye use karte hain kyunki har deployment mein columns alag ho
  /// sakte hain (jaise doctor_id sab jagah exist nahi karta). Isse query
  /// kabhi bhi missing column ki wajah se fail nahi hoti.
  Future<Map<String, dynamic>?> getOPDPaymentDetails(
    String opdRegistrationId,
  ) async {
    try {
      return await fetchWithRetry(
        () => _client
            .from(ApiConstants.opdRegistrationsTable)
            .select('*, patients(first_name, last_name, uhid, mobile_number)')
            .eq('id', opdRegistrationId)
            .maybeSingle(),
      );
    } catch (e) {
      AppLogger.e('Error fetching OPD payment details', e);
      return null;
    }
  }

  /// Generates the OPD payment slip:
  ///
  /// * [opdRegistrationId] de to usi registration par payment save hota hai;
  ///   nahi de to patient ki sabse latest OPD registration use hoti hai.
  /// * `payment_amount`, `payment_mode` save karta hai aur payment status
  ///   `paid` + `paid_amount` + `balance_amount = 0` set karta hai.
  /// * Updated row (patient details embedded) return karta hai jo slip print
  ///   ke kaam aata hai.
  /// * Unified billing integration: the OPD registration is also materialised
  ///   into the `billing` table (source_type = opd) with a payment log + audit
  ///   row, so the bill shows up in the unified billing list.
  Future<Map<String, dynamic>> generateOPDSlip({
    required String patientId,
    required double paymentAmount,
    required String paymentMode,
    String? opdRegistrationId,
  }) async {
    try {
      var resolvedOpdId = (opdRegistrationId ?? '').trim();

      if (resolvedOpdId.isEmpty) {
        final latest = await fetchWithRetry(
          () => _client
              .from(ApiConstants.opdRegistrationsTable)
              .select('id')
              .eq('patient_id', patientId)
              .order('created_at', ascending: false)
              .limit(1)
              .maybeSingle(),
        );
        resolvedOpdId = latest?['id']?.toString() ?? '';
      }

      if (resolvedOpdId.isEmpty) {
        throw Exception('No OPD registration found for this patient.');
      }

      final amount = (paymentAmount * 100).roundToDouble() / 100;

      final updated = await fetchWithRetry(
        () => _client
            .from(ApiConstants.opdRegistrationsTable)
            .update({
              'payment_amount': amount,
              'payment_mode': paymentMode.toLowerCase(),
              'payment_status': 'paid',
              'paid_amount': amount,
              'balance_amount': 0,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', resolvedOpdId)
            .select('*, patients(first_name, last_name, uhid)')
            .single(),
      );

      // Unified billing integration — keep `billing` in sync so the bill is
      // visible/editable from the billing module without a separate step.
      await _syncOpdSlipToBilling(
        opd: updated,
        amount: amount,
        paymentMode: paymentMode.toLowerCase(),
        paymentStatus: 'paid',
      );

      return updated;
    } catch (e) {
      AppLogger.e('Error generating OPD slip', e);
      rethrow;
    }
  }

  /// Creates or updates the `billing` row backing an OPD slip.
  ///
  /// Idempotent: repeated slip generation reuses the existing billing row and
  /// does not duplicate payment logs / audit rows.
  Future<Map<String, dynamic>> _syncOpdSlipToBilling({
    required Map<String, dynamic> opd,
    required double amount,
    required String paymentMode,
    required String paymentStatus,
  }) async {
    final opdId = opd['id'].toString();
    final now = DateTime.now().toUtc().toIso8601String();
    final userId = await getCurrentUsersTableId();
    final total = _toDouble(opd['consultation_fee']);
    final discount = 0.0;
    final net = total - discount;
    final billDate =
        opd['visit_date']?.toString() ?? DateTime.now().toIso8601String().split('T')[0];

    final existing = await _client
        .from(ApiConstants.billingTable)
        .select('*')
        .eq('opd_registration_id', opdId)
        .maybeSingle();

    Map<String, dynamic> bill;
    var isNew = false;
    if (existing != null) {
      final billId = existing['id'].toString();
      bill = await _client
          .from(ApiConstants.billingTable)
          .update({
            'subtotal': total,
            'total_amount': total,
            'net_amount': net,
            'paid_amount': amount,
            'balance_amount': 0,
            'payment_status': paymentStatus,
            'payment_mode': paymentMode,
            'status': paymentStatus == 'paid' ? 'paid' : 'generated',
            'updated_by': userId,
            'updated_at': now,
          })
          .eq('id', billId)
          .select()
          .single();
    } else {
      isNew = true;
      bill = await _client
          .from(ApiConstants.billingTable)
          .insert({
            'hospital_id': opd['hospital_id'],
            'patient_id': opd['patient_id'],
            'opd_registration_id': opdId,
            'source_type': 'opd',
            'bill_number': _generateBillNumber('OPD'),
            'bill_date': billDate,
            'bill_type': 'opd',
            'visit_type': 'opd',
            'subtotal': total,
            'total_amount': total,
            'discount_amount': discount,
            'discount_percentage': 0,
            'tax_amount': 0,
            'net_amount': net,
            'paid_amount': amount,
            'balance_amount': 0,
            'payment_status': paymentStatus,
            'payment_mode': paymentMode,
            'payment_date': amount > 0 ? now : null,
            'status': paymentStatus == 'paid' ? 'paid' : 'generated',
            'created_by': userId,
            'updated_by': userId,
          })
          .select()
          .single();

      await _client.from(ApiConstants.billingItemsTable).insert({
        'bill_id': bill['id'],
        'item_type': 'consultation',
        'item_name': 'Consultation Fee',
        'quantity': 1,
        'unit_price': total,
        'total_price': total,
      });
    }

    final billId = bill['id'].toString();

    if (amount > 0) {
      // Avoid duplicate payment rows when the slip is generated repeatedly.
      final alreadyPaid = _toDouble(existing?['paid_amount'] ?? 0) > 0;
      if (!alreadyPaid) {
        await _recordPaymentLog(
          billId: billId,
          amountPaid: amount,
          paymentMode: paymentMode,
          paidBy: null,
        );
        await recordBillingAudit(
          billId: billId,
          action: 'payment_added',
          oldValue: {'paid_amount': 0},
          newValue: {'paid_amount': amount},
          description: 'OPD slip payment of $amount received via ${paymentMode.toUpperCase()}',
        );
      }
    }

    if (isNew) {
      await recordBillingAudit(
        billId: billId,
        action: 'created',
        oldValue: null,
        newValue: _auditSnapshot(bill),
        description: 'OPD slip materialised into the unified billing system',
      );
    }

    return bill;
  }

  /// Internal helper: prescription generate hone par OPD registration ko
  /// `completed` mark karta hai.
  Future<void> _markOPDRegistrationCompleted(String opdRegistrationId) async {
    try {
      await _client
          .from(ApiConstants.opdRegistrationsTable)
          .update({
            'status': 'completed',
            'completed_at': DateTime.now().toUtc().toIso8601String(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', opdRegistrationId);
    } catch (e) {
      AppLogger.e('Error marking OPD registration completed', e);
    }
  }

  // ---------------------------------------------------------------------------
  // IPD Discharge & Billing Operations
  // ---------------------------------------------------------------------------

  /// Fetches everything the IPD discharge screen needs:
  /// admission + patient + doctor + hospital + bed details, ward pricing,
  /// active packages, service master, saved charges and ward-stay history.
  Future<Map<String, dynamic>> getIPDChargeDetails(String admissionId) async {
    try {
      final admission = await getById(
        ApiConstants.ipdAdmissionsTable,
        admissionId,
      );
      if (admission == null) {
        throw Exception('IPD admission not found: $admissionId');
      }

      final patientId = admission['patient_id'] as String?;
      final doctorId = admission['doctor_id'] as String?;
      final hospitalId = admission['hospital_id'] as String?;
      final bedId = admission['bed_id'] as String?;

      Map<String, dynamic>? patient;
      Map<String, dynamic>? doctor;
      Map<String, dynamic>? hospital;
      Map<String, dynamic>? bed;

      if (patientId != null) {
        patient = await getById(ApiConstants.patientsTable, patientId);
      }
      if (doctorId != null && doctorId.isNotEmpty) {
        // IPD admission screen selects doctors from the `doctors` table and
        // stores `doctors.id` in ipd_admissions.doctor_id. Legacy rows may
        // still point at `users.id`, so try doctors first and fall back to
        // users for backward compatibility.
        doctor = await getById(ApiConstants.doctorsTable, doctorId);
        doctor ??= await getById(ApiConstants.usersTable, doctorId);

        // The `doctors` table uses `name` (e.g. "Dr. R. Sharma") while the
        // billing/discharge screens read `first_name`/`last_name`. Normalize
        // the shape so those screens keep showing the doctor without changes.
        if (doctor != null &&
            doctor['name'] != null &&
            doctor['first_name'] == null) {
          final rawName = doctor['name']?.toString() ?? '';
          final displayName = rawName
              .replaceFirst(RegExp(r'^Dr\.?\s*', caseSensitive: false), '')
              .trim();
          doctor = <String, dynamic>{
            ...doctor,
            'first_name': displayName.isEmpty ? rawName : displayName,
            'last_name': null,
            'doctor_name': rawName,
          };
        }
      }
      if (hospitalId != null) {
        hospital = await getById(ApiConstants.hospitalsTable, hospitalId);
      }
      if (bedId != null) {
        bed = await getById(ApiConstants.bedsTable, bedId);
      }

      final chargesResponse = await _client
          .from(ApiConstants.ipdChargesTable)
          .select()
          .eq('admission_id', admissionId)
          .order('charge_date', ascending: false);

      final wardPricingResponse = await _client
          .from(ApiConstants.ipdWardPricingTable)
          .select()
          .eq('is_active', true)
          .order('daily_rate', ascending: true);

      final packagesResponse = await _client
          .from(ApiConstants.ipdPackagesTable)
          .select()
          .eq('is_active', true)
          .order('name', ascending: true);

      final serviceMasterResponse = await _client
          .from(ApiConstants.ipdServiceMasterTable)
          .select()
          .eq('is_active', true)
          .order('name', ascending: true);

      // Auto-suggest doctor-visit count from clinical progress notes.
      var doctorVisitCount = 0;
      if (patientId != null) {
        final notesResponse = await _client
            .from(ApiConstants.progressNotesTable)
            .select('id')
            .eq('ipd_admission_id', admissionId)
            .count(CountOption.exact);
        doctorVisitCount = notesResponse.count;
      }

      // Ward-stay segments for dynamic ward charges. Prefer the direct
      // admission link, fall back to patient_id for legacy rows.
      var staysResponse = await _client
          .from(ApiConstants.bedAllocationsTable)
          .select('*, beds(bed_number, ward_type, daily_charge)')
          .eq('ipd_admission_id', admissionId)
          .order('allocation_date', ascending: true);

      if ((staysResponse as List).isEmpty && patientId != null) {
        staysResponse = await _client
            .from(ApiConstants.bedAllocationsTable)
            .select('*, beds(bed_number, ward_type, daily_charge)')
            .eq('patient_id', patientId)
            .order('allocation_date', ascending: true);
      }

      return {
        'admission': admission,
        'patient': patient,
        'doctor': doctor,
        'hospital': hospital,
        'bed': bed,
        'charges': List<Map<String, dynamic>>.from(chargesResponse),
        'ward_pricing': List<Map<String, dynamic>>.from(wardPricingResponse),
        'packages': List<Map<String, dynamic>>.from(packagesResponse),
        'service_master': List<Map<String, dynamic>>.from(
          serviceMasterResponse,
        ),
        'ward_stays': List<Map<String, dynamic>>.from(staysResponse),
        'doctor_visit_count': doctorVisitCount,
      };
    } catch (e) {
      AppLogger.e('Error fetching IPD charge details', e);
      rethrow;
    }
  }

  /// Calculates the final IPD bill for an admission.
  ///
  /// * Ward charges are computed dynamically from bed-allocation history
  ///   (ICU → General etc.): `Days in ward × Ward daily rate`.
  /// * Falls back to a single segment using the admission's ward when no
  ///   transfer history exists.
  /// * All rows in `ipd_charges` for the admission are summed on top.
  /// * Final payable = Total − Advance payment.
  Future<Map<String, dynamic>> calculateFinalBill(
    String admissionId, {
    DateTime? dischargeDate,
  }) async {
    final details = await getIPDChargeDetails(admissionId);
    final admission = details['admission'] as Map<String, dynamic>;
    final pricing = (details['ward_pricing'] as List)
        .cast<Map<String, dynamic>>();
    final stays = (details['ward_stays'] as List).cast<Map<String, dynamic>>();
    final charges = (details['charges'] as List).cast<Map<String, dynamic>>();

    final admissionDate =
        _parseDate(admission['admission_date']) ?? DateTime.now();
    final discharge =
        dischargeDate ??
        _parseDate(admission['discharge_date']) ??
        DateTime.now();
    final los = math.max(1, _calendarDays(admissionDate, discharge));

    // ward_type (lower-cased) → daily rate lookup table.
    final pricingMap = <String, double>{
      for (final p in pricing)
        (p['ward_type']?.toString().toLowerCase() ?? ''): _toDouble(
          p['daily_rate'],
        ),
    };

    final wardSegments = <Map<String, dynamic>>[];

    if (stays.isEmpty) {
      final bed =
          (details['bed'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final wardType = _firstNonEmpty(
        admission['ward_type'],
        bed['ward_type'],
        fallback: 'general',
      );
      final rate =
          pricingMap[wardType.toLowerCase()] ?? _toDouble(bed['daily_charge']);
      wardSegments.add({
        'ward_type': wardType,
        'bed_number': bed['bed_number']?.toString() ?? '',
        'days': los,
        'daily_rate': rate,
        'amount': (los * rate).roundToDouble(),
      });
    } else {
      for (var i = 0; i < stays.length; i++) {
        final stay = stays[i];
        final bed =
            (stay['beds'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
        final wardType = _firstNonEmpty(
          bed['ward_type'],
          admission['ward_type'],
          fallback: 'general',
        );

        final start = _parseDate(stay['allocation_date']) ?? admissionDate;
        var end = _parseDate(stay['discharge_date']);
        // Active/last segment runs until discharge; intermediate segments
        // run until the next transfer begins.
        end ??= (i == stays.length - 1)
            ? discharge
            : _parseDate(stays[i + 1]['allocation_date']) ?? discharge;

        var days = math.max(0, _calendarDays(start, end));
        if (days == 0) days = 1; // bill at least one day per ward segment

        final rate =
            pricingMap[wardType.toLowerCase()] ??
            _toDouble(bed['daily_charge']);
        wardSegments.add({
          'ward_type': wardType,
          'bed_number': bed['bed_number']?.toString() ?? '',
          'days': days,
          'daily_rate': rate,
          'amount': (days * rate).roundToDouble(),
        });
      }
    }

    final wardTotal = _sumOf(wardSegments, 'amount');
    final otherTotal = _sumOf(charges, 'amount');
    final totalAmount = (wardTotal + otherTotal).roundToDouble();
    final advance = _toDouble(admission['advance_payment']);
    final finalPayable = (totalAmount - advance).roundToDouble();

    return {
      'admission_id': admissionId,
      'admission_date': admissionDate.toIso8601String(),
      'discharge_date': discharge.toIso8601String(),
      'length_of_stay': los,
      'ward_segments': wardSegments,
      'ward_total': wardTotal,
      'other_charges': charges,
      'other_total': otherTotal,
      'total_amount': totalAmount,
      'advance_payment': advance,
      'final_payable': finalPayable,
    };
  }

  // -- IPD charge line CRUD ------------------------------------------------

  Future<Map<String, dynamic>> insertIPDCharge(
    Map<String, dynamic> data,
  ) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.ipdChargesTable)
            .insert(data)
            .select()
            .single(),
      );
      return response;
    } catch (e) {
      AppLogger.e('Error inserting IPD charge', e);
      rethrow;
    }
  }

  Future<void> deleteIPDCharge(String chargeId) async {
    try {
      await _client
          .from(ApiConstants.ipdChargesTable)
          .delete()
          .eq('id', chargeId);
    } catch (e) {
      AppLogger.e('Error deleting IPD charge', e);
      rethrow;
    }
  }

  // -- Ward pricing / packages / service master ----------------------------

  Future<List<Map<String, dynamic>>> getIPDWardPricing({
    bool activeOnly = true,
  }) async {
    try {
      var query = _client.from(ApiConstants.ipdWardPricingTable).select();
      if (activeOnly) query = query.eq('is_active', true);
      final response = await fetchWithRetry(
        () => query.order('ward_type', ascending: true),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching IPD ward pricing', e);
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getIPDPackages({
    bool activeOnly = false,
  }) async {
    try {
      var query = _client.from(ApiConstants.ipdPackagesTable).select();
      if (activeOnly) query = query.eq('is_active', true);
      final response = await fetchWithRetry(
        () => query.order('name', ascending: true),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching IPD packages', e);
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getIPDServiceMaster({
    bool activeOnly = false,
  }) async {
    try {
      var query = _client.from(ApiConstants.ipdServiceMasterTable).select();
      if (activeOnly) query = query.eq('is_active', true);
      final response = await fetchWithRetry(
        () => query.order('name', ascending: true),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching IPD service master', e);
      return [];
    }
  }

  Future<Map<String, dynamic>> saveIPDServiceMaster(
    Map<String, dynamic> data, {
    String? id,
  }) async {
    if (id == null) return create(ApiConstants.ipdServiceMasterTable, data);
    return update(ApiConstants.ipdServiceMasterTable, id, {
      ...data,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> deleteIPDServiceMaster(String id) async {
    await delete(ApiConstants.ipdServiceMasterTable, id);
  }

  Future<Map<String, dynamic>> saveIPDPackage(
    Map<String, dynamic> data, {
    String? id,
  }) async {
    if (id == null) return create(ApiConstants.ipdPackagesTable, data);
    return update(ApiConstants.ipdPackagesTable, id, {
      ...data,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> deleteIPDPackage(String id) async {
    await delete(ApiConstants.ipdPackagesTable, id);
  }

  // -- Ward transfers ---------------------------------------------------------

  /// Transfers an admitted patient to a new ward/bed:
  /// * saves a `ward_transfers` record
  /// * old bed → available, new bed → occupied
  /// * admission `ward_type` + `bed_id` updated
  /// * active bed_allocation closed and a new one created
  Future<Map<String, dynamic>> transferPatient(
    String admissionId, {
    required String newWardType,
    required String newBedId,
    required String reason,
  }) async {
    try {
      final admission = await getById(
        ApiConstants.ipdAdmissionsTable,
        admissionId,
      );
      if (admission == null) {
        throw Exception('IPD admission not found: $admissionId');
      }

      final oldBedId = admission['bed_id'] as String?;
      var oldWardType = admission['ward_type']?.toString();

      // Fallback: read the old bed's ward type when admission has none.
      if (oldBedId != null && (oldWardType == null || oldWardType.isEmpty)) {
        final oldBed = await getById(ApiConstants.bedsTable, oldBedId);
        oldWardType = oldBed?['ward_type']?.toString();
      }
      oldWardType ??= 'general';

      final today = DateTime.now().toIso8601String().split('T')[0];
      final now = DateTime.now().toUtc().toIso8601String();

      // 1. Save transfer history.
      final transfer = await _client
          .from(ApiConstants.wardTransfersTable)
          .insert({
            'admission_id': admissionId,
            'old_ward_type': oldWardType,
            'new_ward_type': newWardType,
            'old_bed_id': oldBedId,
            'new_bed_id': newBedId,
            'transfer_reason': reason,
            'transfer_date': today,
          })
          .select()
          .single();

      // 2. Free the old bed.
      if (oldBedId != null) {
        await updateBedStatus(oldBedId, 'available');
      }

      // 3. Occupy the new bed.
      await updateBedStatus(newBedId, 'occupied');

      // 4. Update the admission with the new ward/bed.
      await _client
          .from(ApiConstants.ipdAdmissionsTable)
          .update({
            'ward_type': newWardType,
            'bed_id': newBedId,
            'updated_at': now,
          })
          .eq('id', admissionId);

      // 5. Close the active bed allocation and open a new one.
      final activeAllocation = await _client
          .from(ApiConstants.bedAllocationsTable)
          .select('id')
          .eq('ipd_admission_id', admissionId)
          .eq('status', 'active')
          .maybeSingle();

      if (activeAllocation != null) {
        await _client
            .from(ApiConstants.bedAllocationsTable)
            .update({
              'status': 'transfer_out',
              'discharge_date': today,
              'updated_at': now,
            })
            .eq('id', activeAllocation['id']);
      }

      final newAllocation = await _client
          .from(ApiConstants.bedAllocationsTable)
          .insert({
            'bed_id': newBedId,
            'patient_id': admission['patient_id'],
            'hospital_id': admission['hospital_id'],
            'ipd_admission_id': admissionId,
            'status': 'active',
            'allocation_date': today,
          })
          .select()
          .single();

      // Keep the admission's linked allocation current so discharge frees
      // the right bed.
      await _client
          .from(ApiConstants.ipdAdmissionsTable)
          .update({'bed_allocation_id': newAllocation['id'], 'updated_at': now})
          .eq('id', admissionId);

      return transfer;
    } catch (e) {
      AppLogger.e('Error transferring IPD patient', e);
      rethrow;
    }
  }

  /// Returns the ward-transfer history for an admission (newest first).
  Future<List<Map<String, dynamic>>> getIPDTransferHistory(
    String admissionId,
  ) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.wardTransfersTable)
            .select()
            .eq('admission_id', admissionId)
            .order('transfer_date', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching IPD transfer history', e);
      return [];
    }
  }

  // -- IPD bill generation ----------------------------------------------------

  /// Generates a bill in `billing` + `billing_items` for an admission.
  Future<Map<String, dynamic>> generateIPDBill({
    required String admissionId,
    required List<Map<String, dynamic>> items,
    required double totalAmount,
    required double paidAmount,
    required String paymentStatus, // paid, unpaid, partially_paid
    String? paymentMode,
    String? transactionReference,
  }) async {
    try {
      final admission = await getById(
        ApiConstants.ipdAdmissionsTable,
        admissionId,
      );
      if (admission == null) {
        throw Exception('IPD admission not found: $admissionId');
      }

      final today = DateTime.now().toIso8601String().split('T')[0];
      final now = DateTime.now().toUtc().toIso8601String();
      final billNumber = _generateBillNumber('IPD');
      final balanceAmount = (totalAmount - paidAmount).roundToDouble();
      final createdBy = await getCurrentUsersTableId();

      final bill = await _client
          .from(ApiConstants.billingTable)
          .insert({
            'hospital_id': admission['hospital_id'],
            'patient_id': admission['patient_id'],
            'ipd_admission_id': admissionId,
            'source_type': 'ipd',
            'bill_number': billNumber,
            'bill_date': today,
            'bill_type': 'ipd',
            'visit_type': 'ipd',
            'subtotal': totalAmount,
            'total_amount': totalAmount,
            'discount_amount': 0,
            'discount_percentage': 0,
            'tax_amount': 0,
            'net_amount': totalAmount,
            'paid_amount': paidAmount,
            'balance_amount': balanceAmount,
            'payment_status': paymentStatus,
            'payment_mode': paymentMode,
            'transaction_reference': transactionReference,
            'payment_date': paidAmount > 0 ? now : null,
            'status': paymentStatus == 'paid'
                ? 'paid'
                : paidAmount > 0
                ? 'partially_paid'
                : 'generated',
            'created_by': createdBy,
            'updated_by': createdBy,
          })
          .select()
          .single();

      final billId = bill['id'] as String;
      for (final item in items) {
        await _client.from(ApiConstants.billingItemsTable).insert({
          'bill_id': billId,
          'item_type': item['item_type'] ?? 'others',
          'item_name': item['item_name'] ?? 'Charge',
          'quantity': item['quantity'] ?? 1,
          'unit_price': item['unit_price'] ?? 0,
          'total_price': item['total_price'] ?? item['unit_price'] ?? 0,
        });
      }

      if (paidAmount > 0) {
        await _recordPaymentLog(
          billId: billId,
          amountPaid: paidAmount,
          paymentMode: paymentMode ?? 'cash',
          paidBy: null,
          transactionReference: transactionReference,
        );
      }

      await recordBillingAudit(
        billId: billId,
        action: 'created',
        oldValue: null,
        newValue: _auditSnapshot(bill),
        description: 'IPD final bill generated for admission $admissionId',
      );

      return _normalizeBillingRow(bill);
    } catch (e) {
      AppLogger.e('Error generating IPD bill', e);
      rethrow;
    }
  }

  /// Returns all bills generated for an admission (newest first).
  Future<List<Map<String, dynamic>>> getIPDBills(String admissionId) async {
    try {
      final response = await _client
          .from(ApiConstants.billingTable)
          .select()
          .eq('ipd_admission_id', admissionId)
          .order('bill_date', ascending: false);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching IPD bills', e);
      return [];
    }
  }

  /// Creates a manual bill (source_type = manual) from the billing module.
  ///
  /// This is the "Manual" tab's create flow: it writes a `billing` row +
  /// `billing_items`, records any up-front payment and logs the creation in
  /// `billing_audit`.
  Future<Map<String, dynamic>> createManualBill({
    required String hospitalId,
    required String patientId,
    required List<Map<String, dynamic>> items,
    double discountAmount = 0,
    String? discountReason,
    double paidAmount = 0,
    String? paymentMode,
    String? transactionReference,
    String? paymentStatus,
    String? notes,
    String? internalNotes,
  }) async {
    try {
      _requireHospitalId(hospitalId, source: 'manual bill');
      if (items.isEmpty) {
        throw ArgumentError('Add at least one bill item.');
      }

      final now = DateTime.now().toUtc().toIso8601String();
      final today = DateTime.now().toIso8601String().split('T')[0];
      final userId = await getCurrentUsersTableId();

      final subtotal = _sumOf(items, 'total_price');
      final net = math.max(0, (subtotal - discountAmount) * 100).roundToDouble() / 100;
      final paid = (paidAmount * 100).roundToDouble() / 100;
      final balance = ((net - paid) * 100).roundToDouble() / 100;
      final status =
          paymentStatus?.toString() ?? _derivePaymentStatus(net, paid);
      final discountPercentage = subtotal > 0
          ? ((discountAmount / subtotal) * 100 * 100).roundToDouble() / 100
          : 0.0;

      final bill = await _client
          .from(ApiConstants.billingTable)
          .insert({
            'hospital_id': hospitalId,
            'patient_id': patientId,
            'source_type': 'manual',
            'bill_number': _generateBillNumber('BILL'),
            'bill_date': today,
            'bill_type': 'manual',
            'visit_type': 'manual',
            'subtotal': subtotal,
            'total_amount': subtotal,
            'discount_amount': discountAmount,
            'discount_percentage': discountPercentage,
            'discount_reason': discountReason,
            'tax_amount': 0,
            'net_amount': net,
            'paid_amount': paid,
            'balance_amount': balance,
            'payment_status': status,
            'payment_mode': paymentMode,
            'transaction_reference': transactionReference,
            'payment_date': paid > 0 ? now : null,
            'status': status == 'paid' ? 'paid' : 'generated',
            'notes': notes,
            'internal_notes': internalNotes,
            'created_by': userId,
            'updated_by': userId,
          })
          .select()
          .single();

      final billId = bill['id'].toString();
      for (final item in items) {
        await _client.from(ApiConstants.billingItemsTable).insert({
          'bill_id': billId,
          'item_type': item['item_type'] ?? 'others',
          'item_name': item['item_name'] ?? 'Item',
          'quantity': item['quantity'] ?? 1,
          'unit_price': item['unit_price'] ?? 0,
          'total_price': item['total_price'] ?? item['unit_price'] ?? 0,
        });
      }

      if (paid > 0) {
        await _recordPaymentLog(
          billId: billId,
          amountPaid: paid,
          paymentMode: paymentMode ?? 'cash',
          paidBy: null,
          transactionReference: transactionReference,
        );
      }

      await recordBillingAudit(
        billId: billId,
        action: 'created',
        oldValue: null,
        newValue: _auditSnapshot(bill),
        description: 'Manual bill created from the billing module',
      );

      return _normalizeBillingRow(bill);
    } catch (e) {
      AppLogger.e('Error creating manual bill', e);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Unified Billing Module (OPD / IPD / Lab)
  // ---------------------------------------------------------------------------

  /// Returns raw `billing` rows for a hospital (newest first), optionally
  /// filtered by visit type (`opd` / `ipd` / `lab`).
  Future<List<Map<String, dynamic>>> getBilling({
    required String hospitalId,
    String? visitType,
    int limit = 500,
  }) async {
    try {
      dynamic query = _client
          .from(ApiConstants.billingTable)
          .select('*, patients(first_name, last_name, uhid)')
          .eq('hospital_id', hospitalId);
      if (visitType != null && visitType.isNotEmpty) {
        query = query.eq('visit_type', visitType);
      }
      final response = await fetchWithRetry(
        () => query
            .order('bill_date', ascending: false)
            .order('created_at', ascending: false)
            .limit(limit),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching billing', e);
      return [];
    }
  }

  /// Fetches all bills for the unified billing screen.
  ///
  /// * IPD/Lab/materialised-OPD/Manual bills come from the `billing` table
  ///   with `billing_items` and `payment_logs` embedded.
  /// * OPD bills are sourced from `opd_registrations` (consultation fee + the
  ///   payment columns added by the billing migration). OPD rows that already
  ///   have a materialised `billing` row are excluded so they never appear
  ///   twice.
  ///
  /// [sourceType] accepts `opd`, `ipd`, `lab`, `pharmacy` or `manual`
  /// (null = every source). [visitType] is kept for backwards compatibility
  /// and accepts `opd`, `ipd` or `lab`.
  Future<List<Map<String, dynamic>>> getAllBills({
    String? hospitalId,
    String? visitType,
    String? sourceType,
  }) async {
    try {
      final normalized = <Map<String, dynamic>>[];

      // 1. Billing-backed bills. Always fetched so OPD tab can also show
      //    materialised OPD bills and can dedupe the raw OPD registrations.
      //    If `payment_logs` has not been created yet (migration pending),
      //    fall back to a query without the embedded payment history.
      List<Map<String, dynamic>> billingRows;
      try {
        var billingQuery = _client
            .from(ApiConstants.billingTable)
            .select(
              '*, patients(first_name, last_name, uhid), '
              'billing_items(*), payment_logs(*)',
            );
        if (hospitalId != null && hospitalId.isNotEmpty) {
          billingQuery = billingQuery.eq('hospital_id', hospitalId);
        }
        if (sourceType != null && sourceType.isNotEmpty) {
          billingQuery = billingQuery.eq('source_type', sourceType);
        }
        if (visitType != null && visitType.isNotEmpty) {
          billingQuery = billingQuery.eq('visit_type', visitType);
        }
        billingRows = List<Map<String, dynamic>>.from(
          await fetchWithRetry(
            () => billingQuery
                .order('bill_date', ascending: false)
                .order('created_at', ascending: false)
                .limit(500),
          ),
        );
      } on PostgrestException catch (e) {
        if (!e.message.toLowerCase().contains('could not find the table')) {
          rethrow;
        }
        var billingQuery = _client
            .from(ApiConstants.billingTable)
            .select(
              '*, patients(first_name, last_name, uhid), billing_items(*)',
            );
        if (hospitalId != null && hospitalId.isNotEmpty) {
          billingQuery = billingQuery.eq('hospital_id', hospitalId);
        }
        if (sourceType != null && sourceType.isNotEmpty) {
          billingQuery = billingQuery.eq('source_type', sourceType);
        }
        if (visitType != null && visitType.isNotEmpty) {
          billingQuery = billingQuery.eq('visit_type', visitType);
        }
        billingRows = List<Map<String, dynamic>>.from(
          await fetchWithRetry(
            () => billingQuery
                .order('bill_date', ascending: false)
                .order('created_at', ascending: false)
                .limit(500),
          ),
        );
      }

      final materialisedOpdIds = <String>{};
      for (final row in billingRows) {
        if (_billingSourceType(row) == 'opd') {
          final opdId = row['opd_registration_id']?.toString();
          if (opdId != null && opdId.isNotEmpty) {
            materialisedOpdIds.add(opdId);
          }
        }
        if (sourceType != null && sourceType.isNotEmpty) {
          normalized.add(_normalizeBillingRow(row));
          continue;
        }
        if (visitType == null || _billingVisitType(row) == visitType) {
          normalized.add(_normalizeBillingRow(row));
        }
      }

      // 2. Raw OPD registrations as bills (deduped against materialised rows).
      //    Only included when the caller wants every source or OPD bills.
      final includeRawOpd = (sourceType == null || sourceType == 'opd') &&
          (visitType == null || visitType == 'opd');
      if (includeRawOpd) {
        var opdQuery = _client
            .from(ApiConstants.opdRegistrationsTable)
            .select('*, patients(first_name, last_name, uhid)');
        if (hospitalId != null && hospitalId.isNotEmpty) {
          opdQuery = opdQuery.eq('hospital_id', hospitalId);
        }
        final opdRows = List<Map<String, dynamic>>.from(
          await fetchWithRetry(
            () => opdQuery
                .order('visit_date', ascending: false)
                .order('created_at', ascending: false)
                .limit(500),
          ),
        );
        for (final row in opdRows) {
          final id = row['id']?.toString();
          if (id == null || materialisedOpdIds.contains(id)) continue;
          normalized.add(_normalizeOpdBill(row));
        }
      }

      // 3. Newest first across all sources.
      normalized.sort((a, b) {
        final aDate = _parseDate(a['bill_date'] ?? a['created_at']);
        final bDate = _parseDate(b['bill_date'] ?? b['created_at']);
        return (bDate ?? DateTime(1970)).compareTo(aDate ?? DateTime(1970));
      });

      return normalized;
    } catch (e) {
      AppLogger.e('Error fetching all bills', e);
      return [];
    }
  }

  /// Returns one bill (billing-backed or OPD-sourced) with items, payment
  /// logs and edit history attached.
  Future<Map<String, dynamic>?> getBillById(String billId) async {
    try {
      final billing = await fetchWithRetry(
        () => _client
            .from(ApiConstants.billingTable)
            .select('*, patients(first_name, last_name, uhid)')
            .eq('id', billId)
            .maybeSingle(),
      );

      if (billing != null) {
        final normalized = _normalizeBillingRow(billing);
        normalized['billing_items'] = await getBillItems(billId);
        normalized['payment_logs'] = await getPaymentLogs(billId);
        normalized['bill_edits'] = await getBillEditHistory(billId);
        normalized['billing_audit'] = await getBillingAudit(billId);
        return normalized;
      }

      // A deep link may still carry the original OPD registration id even
      // after the bill was materialised into `billing`; resolve it to the
      // materialised billing row when one exists.
      final materialisedForOpd = await fetchWithRetry(
        () => _client
            .from(ApiConstants.billingTable)
            .select('*, patients(first_name, last_name, uhid)')
            .eq('opd_registration_id', billId)
            .maybeSingle(),
      );
      if (materialisedForOpd != null) {
        final billingId = materialisedForOpd['id'].toString();
        final normalized = _normalizeBillingRow(materialisedForOpd);
        normalized['billing_items'] = await getBillItems(billingId);
        normalized['payment_logs'] = await getPaymentLogs(billingId);
        normalized['bill_edits'] = await getBillEditHistory(billingId);
        normalized['billing_audit'] = await getBillingAudit(billingId);
        return normalized;
      }

      final opd = await fetchWithRetry(
        () => _client
            .from(ApiConstants.opdRegistrationsTable)
            .select('*, patients(first_name, last_name, uhid)')
            .eq('id', billId)
            .maybeSingle(),
      );

      if (opd != null) {
        final normalized = _normalizeOpdBill(opd);
        normalized['payment_logs'] = await getPaymentLogs(billId);
        normalized['bill_edits'] = await getBillEditHistory(billId);
        normalized['billing_audit'] = const <Map<String, dynamic>>[];
        return normalized;
      }

      return null;
    } catch (e) {
      AppLogger.e('Error fetching bill by id', e);
      return null;
    }
  }

  /// Returns line items for a billing-backed bill.
  Future<List<Map<String, dynamic>>> getBillItems(String billId) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.billingItemsTable)
            .select()
            .eq('bill_id', billId)
            .order('created_at', ascending: true),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching bill items', e);
      return [];
    }
  }

  /// Returns the payment/transaction history for a bill, newest first.
  Future<List<Map<String, dynamic>>> getPaymentLogs(String billId) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.paymentLogsTable)
            .select()
            .eq('bill_id', billId)
            .order('payment_date', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching payment logs', e);
      return [];
    }
  }

  /// Returns the edit history for a bill, newest first.
  Future<List<Map<String, dynamic>>> getBillEditHistory(String billId) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.billEditsTable)
            .select('*, users(first_name, last_name)')
            .eq('bill_id', billId)
            .order('edit_date', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching bill edit history', e);
      return [];
    }
  }

  /// Returns the JSONB audit trail (`billing_audit`) for a bill, newest first.
  Future<List<Map<String, dynamic>>> getBillingAudit(String billId) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.billingAuditTable)
            .select('*, users(first_name, last_name)')
            .eq('bill_id', billId)
            .order('performed_at', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } on PostgrestException catch (e) {
      if (e.message.toLowerCase().contains('could not find the table') ||
          e.message.toLowerCase().contains('could not find the')) {
        AppLogger.e('billing_audit table missing — run unified billing migration', e);
        return [];
      }
      AppLogger.e('Error fetching billing audit', e);
      return [];
    } catch (e) {
      AppLogger.e('Error fetching billing audit', e);
      return [];
    }
  }

  /// Writes one row into the `billing_audit` JSONB audit trail.
  ///
  /// Missing-table errors (migration pending) are swallowed so bill edits
  /// still succeed; run the unified billing migration to enable the trail.
  Future<void> recordBillingAudit({
    required String billId,
    required String action,
    Map<String, dynamic>? oldValue,
    Map<String, dynamic>? newValue,
    String? description,
  }) async {
    try {
      await _client.from(ApiConstants.billingAuditTable).insert({
        'bill_id': billId,
        'action': action,
        'old_value': oldValue,
        'new_value': newValue,
        'description': description,
        'performed_by': await getCurrentUsersTableId(),
        'performed_at': DateTime.now().toUtc().toIso8601String(),
      });
    } on PostgrestException catch (e) {
      final message = e.message.toLowerCase();
      if (message.contains('could not find the table') ||
          message.contains('could not find the')) {
        AppLogger.e('billing_audit table missing — run unified billing migration', e);
        return;
      }
      AppLogger.e('Error recording billing audit', e);
      rethrow;
    }
  }

  /// Generates a unique, human-readable bill number.
  String _generateBillNumber(String prefix) {
    final now = DateTime.now();
    final stamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    final random = math.Random().nextInt(9999).toString().padLeft(4, '0');
    return '$prefix-$stamp-$random';
  }

  /// Updates a bill.
  ///
  /// * Billing-backed bill -> direct `billing` update.
  /// * OPD-sourced bill   -> materialises it into `billing` (with a seeded
  ///   consultation item) and keeps the `opd_registrations` payment columns
  ///   in sync.
  ///
  /// Every update also writes a `billing_audit` row so the unified audit
  /// trail captures who changed what and when.
  Future<Map<String, dynamic>> updateBill(
    String billId,
    Map<String, dynamic> newData,
  ) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final currentUserId = await getCurrentUsersTableId();

      final existingBilling = await _client
          .from(ApiConstants.billingTable)
          .select('*')
          .eq('id', billId)
          .maybeSingle();

      if (existingBilling != null) {
        final updated = await _client
            .from(ApiConstants.billingTable)
            .update({
              ...newData,
              'updated_by': currentUserId,
              'updated_at': now,
            })
            .eq('id', billId)
            .select()
            .single();
        await recordBillingAudit(
          billId: billId,
          action: 'edited',
          oldValue: _auditSnapshot(existingBilling),
          newValue: _auditSnapshot(updated),
          description: 'Bill updated from the billing module',
        );
        return _normalizeBillingRow(updated);
      }

      // Idempotency guard: if this OPD registration was already materialised
      // into a billing row, update that row instead of creating a duplicate.
      final existingMaterialised = await _client
          .from(ApiConstants.billingTable)
          .select('*')
          .eq('opd_registration_id', billId)
          .maybeSingle();
      if (existingMaterialised != null) {
        final updated = await _client
            .from(ApiConstants.billingTable)
            .update({
              ...newData,
              'updated_by': currentUserId,
              'updated_at': now,
            })
            .eq('id', existingMaterialised['id'])
            .select()
            .single();
        await recordBillingAudit(
          billId: existingMaterialised['id'].toString(),
          action: 'edited',
          oldValue: _auditSnapshot(existingMaterialised),
          newValue: _auditSnapshot(updated),
          description: 'OPD-sourced bill updated from the billing module',
        );
        return _normalizeBillingRow(updated);
      }

      final opd = await _client
          .from(ApiConstants.opdRegistrationsTable)
          .select()
          .eq('id', billId)
          .maybeSingle();
      if (opd == null) {
        throw Exception('Bill not found: $billId');
      }

      final total = newData['total_amount'] != null
          ? _toDouble(newData['total_amount'])
          : _toDouble(opd['consultation_fee']);
      final discount = newData['discount_amount'] != null
          ? _toDouble(newData['discount_amount'])
          : 0.0;
      final paid = newData['paid_amount'] != null
          ? _toDouble(newData['paid_amount'])
          : _toDouble(opd['paid_amount']);
      final net = math.max(0, (total - discount) * 100).roundToDouble() / 100;
      final balance = ((net - paid) * 100).roundToDouble() / 100;
      final paymentStatus =
          newData['payment_status']?.toString() ??
          _derivePaymentStatus(net, paid);
      final discountPercentage = total > 0
          ? ((discount / total) * 100 * 100).roundToDouble() / 100
          : 0.0;

      final bill = await _client
          .from(ApiConstants.billingTable)
          .insert({
            'hospital_id': opd['hospital_id'],
            'patient_id': opd['patient_id'],
            'opd_registration_id': opd['id'],
            'source_type': 'opd',
            'bill_number': _generateBillNumber('OPD'),
            'bill_date':
                opd['visit_date'] ??
                DateTime.now().toIso8601String().split('T')[0],
            'bill_type': 'opd',
            'visit_type': 'opd',
            'subtotal': total,
            'total_amount': total,
            'discount_amount': discount,
            'discount_percentage': discountPercentage,
            'discount_reason': newData['discount_reason'],
            'tax_amount': 0,
            'net_amount': net,
            'paid_amount': paid,
            'balance_amount': balance,
            'payment_status': paymentStatus,
            'payment_mode': newData['payment_mode'] ?? opd['payment_mode'],
            'status': paymentStatus == 'paid' ? 'paid' : 'generated',
            'notes': newData['notes'],
            'internal_notes': newData['internal_notes'],
            'created_by': currentUserId,
            'updated_by': currentUserId,
          })
          .select()
          .single();

      await _client.from(ApiConstants.billingItemsTable).insert({
        'bill_id': bill['id'],
        'item_type': 'consultation',
        'item_name': 'Consultation Fee',
        'quantity': 1,
        'unit_price': total,
        'total_price': total,
      });

      await _client
          .from(ApiConstants.opdRegistrationsTable)
          .update({
            'consultation_fee': total,
            'paid_amount': paid,
            'balance_amount': balance,
            'payment_status': paymentStatus,
            'payment_mode': newData['payment_mode'] ?? opd['payment_mode'],
            'updated_at': now,
          })
          .eq('id', opd['id']);

      await recordBillingAudit(
        billId: bill['id'].toString(),
        action: 'created',
        oldValue: null,
        newValue: _auditSnapshot(bill),
        description: 'OPD registration materialised into a permanent billing record',
      );

      return _normalizeBillingRow(bill);
    } catch (e) {
      AppLogger.e('Error updating bill', e);
      rethrow;
    }
  }

  /// Extracts the financially-relevant fields used for audit comparisons.
  Map<String, dynamic> _auditSnapshot(Map<String, dynamic> row) {
    return {
      'total_amount': row['total_amount'],
      'discount_amount': row['discount_amount'],
      'net_amount': row['net_amount'],
      'paid_amount': row['paid_amount'],
      'balance_amount': row['balance_amount'],
      'payment_status': row['payment_status'],
      'payment_mode': row['payment_mode'],
      'source_type': row['source_type'],
      'status': row['status'],
    };
  }

  /// Adds a line item to a billing-backed bill and recalculates totals.
  Future<Map<String, dynamic>> addBillItem(
    String billId,
    Map<String, dynamic> item,
  ) async {
    try {
      final before = await _client
          .from(ApiConstants.billingTable)
          .select('*')
          .eq('id', billId)
          .maybeSingle();
      await _client.from(ApiConstants.billingItemsTable).insert({
        'bill_id': billId,
        'item_type': item['item_type'] ?? 'others',
        'item_name': item['item_name'] ?? 'Item',
        'quantity': item['quantity'] ?? 1,
        'unit_price': item['unit_price'] ?? 0,
        'total_price': item['total_price'] ?? item['unit_price'] ?? 0,
      });
      final updated = await recalculateBill(billId);
      await recordBillingAudit(
        billId: billId,
        action: 'item_added',
        oldValue: before == null ? null : _auditSnapshot(before),
        newValue: _auditSnapshot(updated),
        description: 'Added item: ${item['item_name'] ?? 'Item'}',
      );
      return updated;
    } catch (e) {
      AppLogger.e('Error adding bill item', e);
      rethrow;
    }
  }

  /// Removes a line item from a billing-backed bill and recalculates totals.
  Future<Map<String, dynamic>> deleteBillItem(
    String billId,
    String itemId,
  ) async {
    try {
      final before = await _client
          .from(ApiConstants.billingTable)
          .select('*')
          .eq('id', billId)
          .maybeSingle();
      await _client
          .from(ApiConstants.billingItemsTable)
          .delete()
          .eq('id', itemId);
      final updated = await recalculateBill(billId);
      await recordBillingAudit(
        billId: billId,
        action: 'item_removed',
        oldValue: before == null ? null : _auditSnapshot(before),
        newValue: _auditSnapshot(updated),
        description: 'Removed billing item $itemId',
      );
      return updated;
    } catch (e) {
      AppLogger.e('Error deleting bill item', e);
      rethrow;
    }
  }

  /// Recomputes `total_amount`, `net_amount`, `balance_amount` and
  /// `payment_status` from the current line items + header discount.
  Future<Map<String, dynamic>> recalculateBill(String billId) async {
    final items = await getBillItems(billId);
    final bill = await _client
        .from(ApiConstants.billingTable)
        .select()
        .eq('id', billId)
        .maybeSingle();
    if (bill == null) throw Exception('Bill not found: $billId');

    final total = _sumOf(items, 'total_price');
    final discount = _toDouble(bill['discount_amount']);
    final net = math.max(0, (total - discount) * 100).roundToDouble() / 100;
    final paid = _toDouble(bill['paid_amount']);
    final balance = ((net - paid) * 100).roundToDouble() / 100;
    final status = _derivePaymentStatus(net, paid);

    final updated = await _client
        .from(ApiConstants.billingTable)
        .update({
          'total_amount': total,
          'subtotal': total,
          'net_amount': net,
          'balance_amount': balance,
          'payment_status': status,
          'status': status == 'paid' ? 'paid' : 'generated',
          'updated_by': await getCurrentUsersTableId(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', billId)
        .select()
        .single();
    return _normalizeBillingRow(updated);
  }

  /// Records an additional payment against a bill and updates its paid /
  /// balance / status.
  ///
  /// * Billing-backed bill -> `payment_logs` + `billing` update.
  /// * OPD-sourced bill    -> the OPD registration is materialised into
  ///   `billing` first (so `payment_logs.bill_id` keeps its FK), then the
  ///   payment is recorded against the materialised bill. The returned map
  ///   carries the materialised bill id.
  Future<Map<String, dynamic>> recordPayment({
    required String billId,
    required double amountPaid,
    required String paymentMode,
    String? paidBy,
  }) async {
    try {
      final bill = await getBillById(billId);
      if (bill == null) throw Exception('Bill not found: $billId');

      final source = bill['source']?.toString() == 'opd' ? 'opd' : 'billing';
      final total = _toDouble(bill['total_amount']);
      final currentPaid = _toDouble(bill['paid_amount']);
      final newPaid = ((currentPaid + amountPaid) * 100).roundToDouble() / 100;
      final balance = ((total - newPaid) * 100).roundToDouble() / 100;
      final status = _derivePaymentStatus(total, newPaid);
      final now = DateTime.now().toUtc().toIso8601String();

      var targetBillId = billId;
      String? opdId;
      if (source == 'opd') {
        opdId = billId;
        // Materialise so payment_logs.bill_id (FK -> billing.id) is valid.
        final materialized = await updateBill(billId, {
          'total_amount': total,
          'paid_amount': currentPaid,
          'payment_status': bill['payment_status'],
          'payment_mode': bill['payment_mode'],
        });
        targetBillId = materialized['id'].toString();
      }

      await _recordPaymentLog(
        billId: targetBillId,
        amountPaid: amountPaid,
        paymentMode: paymentMode,
        paidBy: paidBy,
      );

      final currentUserId = await getCurrentUsersTableId();
      await _client
          .from(ApiConstants.billingTable)
          .update({
            'paid_amount': newPaid,
            'balance_amount': balance,
            'payment_status': status,
            'payment_mode': paymentMode,
            'status': status == 'paid' ? 'paid' : 'generated',
            'updated_by': currentUserId,
            'updated_at': now,
          })
          .eq('id', targetBillId);

      await recordBillingAudit(
        billId: targetBillId,
        action: 'payment_added',
        oldValue: {'paid_amount': currentPaid, 'balance_amount': _toDouble(bill['balance_amount'])},
        newValue: {'paid_amount': newPaid, 'balance_amount': balance},
        description: 'Payment of $amountPaid received via ${paymentMode.toUpperCase()}',
      );

      // Keep the source OPD registration in sync so the OPD tab/queue still
      // reflects the latest payment state.
      if (opdId != null) {
        await _client
            .from(ApiConstants.opdRegistrationsTable)
            .update({
              'paid_amount': newPaid,
              'balance_amount': balance,
              'payment_status': status,
              'payment_mode': paymentMode,
              'updated_at': now,
            })
            .eq('id', opdId);
      }

      return (await getBillById(targetBillId))!;
    } catch (e) {
      AppLogger.e('Error recording payment', e);
      rethrow;
    }
  }

  /// Writes an audit row into `bill_edits`.
  ///
  /// Missing-table errors (migration pending) are swallowed so bill edits
  /// still succeed; run the migration to enable the audit trail.
  Future<void> recordBillEdit({
    required String billId,
    required double oldAmount,
    required double newAmount,
    required String editReason,
  }) async {
    try {
      await _client.from(ApiConstants.billEditsTable).insert({
        'bill_id': billId,
        'edited_by': await getCurrentUsersTableId(),
        'old_amount': oldAmount,
        'new_amount': newAmount,
        'edit_reason': editReason,
        'edit_date': DateTime.now().toUtc().toIso8601String(),
      });
    } on PostgrestException catch (e) {
      if (e.message.toLowerCase().contains('could not find the table')) {
        AppLogger.e('bill_edits table missing — run billing migration', e);
        return;
      }
      AppLogger.e('Error recording bill edit', e);
      rethrow;
    }
  }

  // -- Billing helpers ------------------------------------------------------

  /// Inserts one row into `payment_logs` (internal helper).
  ///
  /// If the `payment_logs` table is missing (billing migration not run yet)
  /// the error is swallowed so the main bill flow still completes; the
  /// transaction history can be backfilled by running the migration.
  Future<void> _recordPaymentLog({
    required String billId,
    required double amountPaid,
    required String paymentMode,
    String? paidBy,
    String? transactionReference,
  }) async {
    try {
      await _client.from(ApiConstants.paymentLogsTable).insert({
        'bill_id': billId,
        'amount_paid': amountPaid,
        'payment_amount': amountPaid,
        'payment_mode': paymentMode,
        'payment_date': DateTime.now().toUtc().toIso8601String(),
        'paid_by': paidBy,
        'transaction_reference': transactionReference,
        'recorded_by': await getCurrentUsersTableId(),
      });
    } on PostgrestException catch (e) {
      if (e.message.toLowerCase().contains('could not find the table')) {
        AppLogger.e('payment_logs table missing — run billing migration', e);
        return;
      }
      rethrow;
    }
  }

  /// Resolves the effective visit type of a `billing` row, falling back to
  /// the legacy `bill_type` column for rows created before the migration.
  String _billingVisitType(Map<String, dynamic> row) {
    final visitType = row['visit_type']?.toString();
    if (visitType != null && visitType.isNotEmpty) return visitType;

    switch (row['bill_type']?.toString()) {
      case 'ipd':
      case 'discharge':
        return 'ipd';
      case 'diagnostics':
      case 'lab':
      case 'radiology':
        return 'lab';
      default:
        return 'opd';
    }
  }

  /// Resolves the effective source type of a `billing` row.
  ///
  /// The migration adds `source_type`; rows created before it are classified
  /// from their linked visit ids or visit type.
  String _billingSourceType(Map<String, dynamic> row) {
    final sourceType = row['source_type']?.toString();
    if (sourceType != null && sourceType.isNotEmpty) return sourceType;

    if (row['opd_registration_id'] != null) return 'opd';
    if (row['ipd_admission_id'] != null) return 'ipd';

    switch (_billingVisitType(row)) {
      case 'ipd':
        return 'ipd';
      case 'lab':
        return 'lab';
      case 'opd':
        return 'opd';
      default:
        return 'manual';
    }
  }

  /// Normalises a `billing` row into the unified bill shape used by the UI.
  Map<String, dynamic> _normalizeBillingRow(Map<String, dynamic> row) {
    final patient =
        (row['patients'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final total = _toDouble(row['total_amount']);
    final discount = _toDouble(row['discount_amount']);
    final net = _toDouble(row['net_amount']);
    final paid = _toDouble(row['paid_amount']);
    final balance = _toDouble(row['balance_amount']);
    final patientName =
        '${patient['first_name'] ?? ''} ${patient['last_name'] ?? ''}'.trim();
    final sourceType = _billingSourceType(row);
    final id = row['id']?.toString() ?? '';

    return {
      ...row,
      'source': 'billing',
      'source_type': sourceType,
      'patient_name': patientName.isEmpty ? 'Unknown Patient' : patientName,
      'uhid': patient['uhid']?.toString() ?? 'N/A',
      'visit_type': _billingVisitType(row),
      'bill_number':
          row['bill_number']?.toString() ??
          'BILL-${id.length > 8 ? id.substring(0, 8) : id}',
      'subtotal': _toDouble(row['subtotal'] ?? row['total_amount']),
      'total_amount': total,
      'discount_amount': discount,
      'net_amount': net > 0 ? net : total - discount,
      'paid_amount': paid,
      'balance_amount': balance,
      'bill_date': row['bill_date'] ?? row['created_at'],
    };
  }

  /// Normalises an `opd_registrations` row into the unified bill shape.
  Map<String, dynamic> _normalizeOpdBill(Map<String, dynamic> row) {
    final patient =
        (row['patients'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final total = _toDouble(row['consultation_fee']);
    final paid = _toDouble(row['paid_amount']);
    final balance = _toDouble(row['balance_amount']);
    final status =
        row['payment_status']?.toString() ?? _derivePaymentStatus(total, paid);
    final patientName =
        '${patient['first_name'] ?? ''} ${patient['last_name'] ?? ''}'.trim();
    final id = row['id']?.toString() ?? '';
    final idPrefix = id.length > 8 ? id.substring(0, 8) : id;

    return {
      'id': id,
      'source': 'opd',
      'source_type': 'opd',
      'opd_registration_id': id,
      'bill_number':
          'OPD-${(row['token_number']?.toString() ?? idPrefix).toUpperCase()}',
      'patient_id': row['patient_id'],
      'patient_name': patientName.isEmpty ? 'Unknown Patient' : patientName,
      'uhid': patient['uhid']?.toString() ?? 'N/A',
      'visit_type': 'opd',
      'bill_type': 'opd',
      'bill_date': row['visit_date'] ?? row['created_at'],
      'created_at': row['created_at'],
      'subtotal': total,
      'total_amount': total,
      'discount_amount': 0,
      'discount_percentage': 0,
      'net_amount': total,
      'paid_amount': paid,
      'balance_amount': balance,
      'payment_status': status,
      'payment_mode': row['payment_mode'],
      'status': status == 'paid' ? 'paid' : 'generated',
      'billing_items': [
        {
          'id': null,
          'item_type': 'consultation',
          'item_name': 'Consultation Fee',
          'quantity': 1,
          'unit_price': total,
          'total_price': total,
        },
      ],
      'payment_logs': const <Map<String, dynamic>>[],
    };
  }

  /// Derives `paid` / `partially_paid` / `unpaid` from amounts.
  String _derivePaymentStatus(double total, double paid) {
    if (paid >= total && total > 0) return 'paid';
    if (paid > 0) return 'partially_paid';
    return 'unpaid';
  }

  // ---------------------------------------------------------------------------
  // Multi-tenant helpers
  // ---------------------------------------------------------------------------

  /// Returns a non-empty hospital id or throws.
  ///
  /// Multi-tenant writes must never create rows without a `hospital_id`; the
  /// server-side RLS policy is the final guard, but failing fast here gives
  /// the UI a much clearer error message.
  String _requireHospitalId(String? hospitalId, {String? source}) {
    final id = (hospitalId ?? '').trim();
    if (id.isEmpty) {
      throw ArgumentError(
        'hospital_id is required'
        '${source == null ? '' : ' for $source'} — your account is not '
        'assigned to any hospital. Please contact your administrator.',
      );
    }
    return id;
  }

  /// Returns a copy of [data] with a guaranteed non-empty `hospital_id`.
  ///
  /// The explicit [hospitalId] argument wins; otherwise the `hospital_id`
  /// already present in [data] is used. Throws when both are null/empty.
  Map<String, dynamic> _tenantPayload(
    Map<String, dynamic> data,
    String? hospitalId, {
    String? table,
  }) {
    final payload = Map<String, dynamic>.from(data);
    final tenantId = _requireHospitalId(
      hospitalId ?? payload['hospital_id'] as String?,
      source: table,
    );
    payload['hospital_id'] = tenantId;
    return payload;
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text);
  }

  double _toDouble(dynamic value) {
    if (value == null) return 0;
    return double.tryParse(value.toString()) ?? 0;
  }

  String _firstNonEmpty(
    dynamic first,
    dynamic second, {
    required String fallback,
  }) {
    if (first != null && first.toString().trim().isNotEmpty) {
      return first.toString().trim();
    }
    if (second != null && second.toString().trim().isNotEmpty) {
      return second.toString().trim();
    }
    return fallback;
  }

  int _calendarDays(DateTime start, DateTime end) {
    final a = DateTime(start.year, start.month, start.day);
    final b = DateTime(end.year, end.month, end.day);
    return b.difference(a).inDays;
  }

  double _sumOf(List<Map<String, dynamic>> rows, String key) {
    var total = 0.0;
    for (final row in rows) {
      total += _toDouble(row[key]);
    }
    return (total * 100).roundToDouble() / 100;
  }

  // ---------------------------------------------------------------------------
  // Hospital Onboarding & Multi-User Management
  // ---------------------------------------------------------------------------

  /// Creates a new hospital row. Kept separate so it can be reused by other
  /// flows (e.g. an Edge Function) if needed.
  Future<Map<String, dynamic>> insertHospital(Map<String, dynamic> data) async {
    try {
      final payload = <String, dynamic>{
        ...data,
        'is_active': data['is_active'] ?? true,
      };
      // `hospitals.code` is NOT NULL + UNIQUE in the initial schema; generate
      // a fallback code when the caller didn't provide one.
      final code = data['code']?.toString().trim();
      if (code == null || code.isEmpty) {
        payload['code'] = 'HOSP${DateTime.now().millisecondsSinceEpoch}';
      }

      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.hospitalsTable)
            .insert(payload)
            .select()
            .single(),
      );
      return response;
    } catch (e) {
      AppLogger.e('Error creating hospital', e);
      rethrow;
    }
  }

  /// Returns all users of a hospital, newest first, with the department name
  /// embedded (via `departments(name)`).
  Future<List<Map<String, dynamic>>> getAllUsers(String hospitalId) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.usersTable)
            .select('*, departments(id, name)')
            .eq('hospital_id', hospitalId)
            .order('created_at', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching users', e);
      return [];
    }
  }

  /// Creates a new user for a hospital.
  ///
  /// * Creates the Supabase Auth identity via client-side `signUp`.
  /// * Restores the previous (admin) session afterwards so creating another
  ///   user never logs the current admin out.
  /// * The password is only used for the auth account and is never written to
  ///   the public `users` table.
  ///
  /// Expected keys in [userData]:
  ///   email, password, hospital_id, first_name, last_name, role,
  ///   department_id (optional), phone (optional), is_active (optional).
  Future<Map<String, dynamic>> createUser(Map<String, dynamic> userData) async {
    try {
      final email = (userData['email'] as String? ?? '').trim();
      final password = userData['password'] as String? ?? '';
      final firstName = (userData['first_name'] as String? ?? '').trim();
      final lastName = (userData['last_name'] as String? ?? '').trim();
      final role = (userData['role'] as String? ?? 'receptionist').trim();

      if (email.isEmpty || password.isEmpty) {
        throw ArgumentError(
          'Email and password are required to create a user.',
        );
      }

      // Capture the current (admin) session. `signUp` replaces the session
      // with the new user's session (when email confirmation is off), so we
      // restore the admin session right after.
      final previousSession = _client.auth.currentSession;

      String? authUserId;
      try {
        final authResponse = await _client.auth.signUp(
          email: email,
          password: password,
          data: {'role': role, 'first_name': firstName, 'last_name': lastName},
        );
        authUserId = authResponse.user?.id ?? authResponse.session?.user.id;
      } finally {
        if (previousSession != null) {
          try {
            final refreshToken = previousSession.refreshToken;
            if (refreshToken != null && refreshToken.isNotEmpty) {
              await _client.auth.setSession(refreshToken);
            }
          } catch (e) {
            AppLogger.e(
              'Could not restore admin session after creating user',
              e,
            );
          }
        }
      }

      if (authUserId == null) {
        throw Exception(
          'The Supabase Auth account could not be created. Check that email '
          'confirmation settings allow new sign-ups.',
        );
      }

      final record = <String, dynamic>{
        'auth_id': authUserId,
        'hospital_id': userData['hospital_id'],
        'first_name': firstName,
        'last_name': lastName.isEmpty ? null : lastName,
        'email': email,
        'role': role,
        'department_id': userData['department_id'],
        'phone': userData['phone'],
        'is_active': userData['is_active'] ?? true,
      };

      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.usersTable)
            .insert(record)
            .select()
            .single(),
      );
      return response;
    } catch (e) {
      AppLogger.e('Error creating user', e);
      rethrow;
    }
  }

  /// Updates a public `users` row (name, role, department, phone, active).
  ///
  /// NOTE: the Supabase Auth password cannot be changed for another user from
  /// the client. Use a service-role Edge Function if password reset is needed.
  Future<Map<String, dynamic>> updateUser(
    String userId,
    Map<String, dynamic> userData,
  ) async {
    try {
      final payload = <String, dynamic>{
        ...userData,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      payload.remove('password');

      final response = await _client
          .from(ApiConstants.usersTable)
          .update(payload)
          .eq('id', userId)
          .select()
          .single();
      return response;
    } catch (e) {
      AppLogger.e('Error updating user', e);
      rethrow;
    }
  }

  /// Deletes a public `users` row.
  ///
  /// NOTE: this removes the hospital link; the Supabase Auth account still
  /// exists but can no longer log in (login requires a matching `users` row).
  /// Delete the auth account from the Auth dashboard (or a service-role Edge
  /// Function) to fully remove the user.
  Future<void> deleteUser(String userId) async {
    try {
      await fetchWithRetry(
        () => _client.from(ApiConstants.usersTable).delete().eq('id', userId),
      );
    } catch (e) {
      AppLogger.e('Error deleting user', e);
      rethrow;
    }
  }

  /// Toggles a user's active state (soft enable/disable).
  Future<void> setUserActive(String userId, bool isActive) async {
    await updateUser(userId, {'is_active': isActive});
  }

  /// Returns the active role catalogue for a hospital.
  Future<List<Map<String, dynamic>>> getUserRoles(String hospitalId) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.userRolesTable)
            .select()
            .eq('hospital_id', hospitalId)
            .eq('is_active', true)
            .order('role_name', ascending: true),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching user roles', e);
      return [];
    }
  }

  // User Helpers
  /// Returns the current user's record from the public users table.
  /// Uses auth_id to match against the Supabase Auth user.
  Future<Map<String, dynamic>?> getCurrentUserRecord() async {
    try {
      print('🚀 [getCurrentUserRecord] STARTED');
      final authId = _client.auth.currentUser?.id;
      print('🟡 [getCurrentUserRecord] authId: $authId');
      if (authId == null) return null;

      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.usersTable)
            .select()
            .eq('auth_id', authId)
            .maybeSingle(),
      );
      print('🟢 [getCurrentUserRecord] response: $response');
      return response;
    } catch (e) {
      print('🔴 [getCurrentUserRecord] Error: $e');
      AppLogger.e('Error fetching current user record', e);
      return null;
    }
  }

  /// Returns the hospital_id for a given auth user id.
  Future<String?> getHospitalIdForUser(String userId) async {
    final response = await fetchWithRetry(
      () => _client
          .from(ApiConstants.usersTable)
          .select('hospital_id')
          .eq('auth_id', userId)
          .maybeSingle(),
    );
    return response?['hospital_id'] as String?;
  }

  /// Returns the current user's id from the public users table.
  /// Falls back to the raw auth.users UUID if no public record exists.
  Future<String?> getCurrentUsersTableId() async {
    final record = await getCurrentUserRecord();
    if (record != null) {
      return record['id'] as String?;
    }
    // Fallback: attempt to use the raw auth user id (for local dev where
    // the public.users record may not exist yet).
    return _client.auth.currentUser?.id;
  }

  // Dashboard Statistics
  Future<Map<String, dynamic>> getDashboardStats(String hospitalId) async {
    try {
      final today = DateTime.now().toIso8601String().split('T')[0];

      final opdRes = await _client
          .from(ApiConstants.opdRegistrationsTable)
          .select('*')
          .eq('hospital_id', hospitalId)
          .eq('visit_date', today)
          .count(CountOption.exact);

      final ipdRes = await _client
          .from(ApiConstants.ipdAdmissionsTable)
          .select('*')
          .eq('hospital_id', hospitalId)
          .eq('admission_date', today)
          .count(CountOption.exact);

      final occupiedRes = await _client
          .from(ApiConstants.bedsTable)
          .select('*')
          .eq('hospital_id', hospitalId)
          .eq('status', 'occupied')
          .count(CountOption.exact);

      final totalRes = await _client
          .from(ApiConstants.bedsTable)
          .select('*')
          .eq('hospital_id', hospitalId)
          .count(CountOption.exact);

      return {
        'opd_count': opdRes.count,
        'ipd_count': ipdRes.count,
        'occupied_beds': occupiedRes.count,
        'total_beds': totalRes.count,
      };
    } catch (e) {
      AppLogger.e('Error fetching dashboard stats', e);
      return {
        'opd_count': 0,
        'ipd_count': 0,
        'occupied_beds': 0,
        'total_beds': 0,
      };
    }
  }

  // ---------------------------------------------------------------------------
  // Voucher / Expense Module
  // ---------------------------------------------------------------------------

  /// Returns vouchers for a hospital within an inclusive date range, newest
  /// first. [from] and [to] are compared against `voucher_date` (DATE).
  Future<List<Map<String, dynamic>>> getVouchers({
    required String hospitalId,
    DateTime? from,
    DateTime? to,
  }) async {
    try {
      var query = _client.from(ApiConstants.vouchersTable).select();

      if (hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }
      if (from != null) {
        query = query.gte('voucher_date', from.toIso8601String().split('T')[0]);
      }
      if (to != null) {
        query = query.lte('voucher_date', to.toIso8601String().split('T')[0]);
      }

      final response = await fetchWithRetry(
        () => query
            .order('voucher_date', ascending: false)
            .order('created_at', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching vouchers', e);
      return [];
    }
  }

  /// Generates the next voucher number for a hospital on a given date.
  ///
  /// Format: `VCH-YYYYMMDD-####` where #### is a per-hospital, per-day running
  /// sequence. `createVoucher` retries on the rare unique-constraint collision.
  Future<String> generateVoucherNumber(
    String hospitalId, {
    String? voucherDate,
  }) async {
    final date = voucherDate ?? DateTime.now().toIso8601String().split('T')[0];

    try {
      final last = await fetchWithRetry(
        () => _client
            .from(ApiConstants.vouchersTable)
            .select('voucher_number')
            .eq('hospital_id', hospitalId)
            .eq('voucher_date', date)
            .order('voucher_number', ascending: false)
            .limit(1)
            .maybeSingle(),
      );

      var sequence = 1;
      final lastNumber = last?['voucher_number']?.toString();
      if (lastNumber != null) {
        final match = RegExp(r'(\d+)$').firstMatch(lastNumber);
        if (match != null) {
          sequence = (int.tryParse(match.group(1)!) ?? 0) + 1;
        }
      }

      final compact = date.replaceAll('-', '');
      return 'VCH-$compact-${sequence.toString().padLeft(4, '0')}';
    } catch (e) {
      AppLogger.e('Error generating voucher number', e);
      // Fallback: timestamp-based number so entry is never blocked.
      final compact = date.replaceAll('-', '');
      final stamp = DateTime.now().millisecondsSinceEpoch.toString().substring(
        8,
      );
      return 'VCH-$compact-$stamp';
    }
  }

  /// Inserts a voucher. `voucher_number` is auto-generated; on a unique
  /// collision the sequence is regenerated and retried.
  Future<Map<String, dynamic>> createVoucher(
    Map<String, dynamic> data, {
    String? hospitalId,
  }) async {
    final payload = _tenantPayload(
      data,
      hospitalId,
      table: ApiConstants.vouchersTable,
    );
    final tenantId = payload['hospital_id'] as String;
    Object? lastError;

    for (var attempt = 0; attempt < 3; attempt++) {
      final voucherNumber = await generateVoucherNumber(
        tenantId,
        voucherDate: payload['voucher_date']?.toString(),
      );

      try {
        return await fetchWithRetry(
          () => _client
              .from(ApiConstants.vouchersTable)
              .insert({...payload, 'voucher_number': voucherNumber})
              .select()
              .single(),
        );
      } on PostgrestException catch (e) {
        lastError = e;
        // 23505 = unique_violation (two users created the same number).
        if (e.code == '23505') continue;
        rethrow;
      }
    }

    throw lastError ?? Exception('Could not create voucher after retries');
  }

  /// Today's and current-month expense totals for the dashboard.
  Future<Map<String, dynamic>> getVoucherStats(String hospitalId) async {
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final monthStart = DateTime(now.year, now.month, 1);
      final monthEnd = DateTime(now.year, now.month + 1, 0);

      final todayRows = await getVouchers(
        hospitalId: hospitalId,
        from: today,
        to: today,
      );
      final monthRows = await getVouchers(
        hospitalId: hospitalId,
        from: monthStart,
        to: monthEnd,
      );

      return {
        'today_total': _sumOf(todayRows, 'amount'),
        'today_count': todayRows.length,
        'month_total': _sumOf(monthRows, 'amount'),
        'month_count': monthRows.length,
      };
    } catch (e) {
      AppLogger.e('Error fetching voucher stats', e);
      return {
        'today_total': 0.0,
        'today_count': 0,
        'month_total': 0.0,
        'month_count': 0,
      };
    }
  }

  /// Returns custom voucher categories for a hospital.
  Future<List<Map<String, dynamic>>> getVoucherCategories({
    String? hospitalId,
    bool activeOnly = true,
  }) async {
    try {
      var query = _client.from(ApiConstants.voucherCategoriesTable).select();
      if (activeOnly) query = query.eq('is_active', true);
      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }
      final response = await fetchWithRetry(
        () => query.order('category_name', ascending: true),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching voucher categories', e);
      return [];
    }
  }

  /// Adds a custom voucher category for a hospital.
  Future<Map<String, dynamic>> createVoucherCategory({
    required String hospitalId,
    required String categoryName,
  }) async {
    try {
      return await fetchWithRetry(
        () => _client
            .from(ApiConstants.voucherCategoriesTable)
            .insert({
              'hospital_id': hospitalId,
              'category_name': categoryName.trim(),
              'is_active': true,
            })
            .select()
            .single(),
      );
    } catch (e) {
      AppLogger.e('Error creating voucher category', e);
      rethrow;
    }
  }

  /// Soft-enables/disables a custom voucher category.
  Future<void> setVoucherCategoryActive(String id, bool isActive) async {
    try {
      await fetchWithRetry(
        () => _client
            .from(ApiConstants.voucherCategoriesTable)
            .update({'is_active': isActive})
            .eq('id', id),
      );
    } catch (e) {
      AppLogger.e('Error updating voucher category', e);
      rethrow;
    }
  }

  /// Deletes a custom voucher category.
  Future<void> deleteVoucherCategory(String id) async {
    try {
      await fetchWithRetry(
        () => _client
            .from(ApiConstants.voucherCategoriesTable)
            .delete()
            .eq('id', id),
      );
    } catch (e) {
      AppLogger.e('Error deleting voucher category', e);
      rethrow;
    }
  }

  /// Returns the voucher approval settings (approver name + limit) for a
  /// hospital, or null when not configured yet.
  Future<Map<String, dynamic>?> getVoucherSettings(String hospitalId) async {
    try {
      return await fetchWithRetry(
        () => _client
            .from(ApiConstants.voucherSettingsTable)
            .select()
            .eq('hospital_id', hospitalId)
            .maybeSingle(),
      );
    } catch (e) {
      AppLogger.e('Error fetching voucher settings', e);
      return null;
    }
  }

  /// Creates or updates the voucher approval settings for a hospital.
  Future<Map<String, dynamic>> saveVoucherSettings({
    required String hospitalId,
    required String approverName,
    required double approvalLimit,
  }) async {
    final payload = {
      'approver_name': approverName.trim(),
      'approval_limit': approvalLimit,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };

    final existing = await _client
        .from(ApiConstants.voucherSettingsTable)
        .select('hospital_id')
        .eq('hospital_id', hospitalId)
        .maybeSingle();

    if (existing != null) {
      return await _client
          .from(ApiConstants.voucherSettingsTable)
          .update(payload)
          .eq('hospital_id', hospitalId)
          .select()
          .single();
    }

    return await _client
        .from(ApiConstants.voucherSettingsTable)
        .insert({'hospital_id': hospitalId, ...payload})
        .select()
        .single();
  }

  // ---------------------------------------------------------------------------
  // Unified Lab / Diagnostics Module
  // ---------------------------------------------------------------------------

  /// Returns the diagnostic test master for a hospital.
  ///
  /// Pass [activeOnly] = false on the admin master screen so inactive tests
  /// remain visible and can be re-enabled.
  Future<List<Map<String, dynamic>>> getDiagnosticTests({
    String? hospitalId,
    bool activeOnly = true,
  }) async {
    try {
      var query = _client.from(ApiConstants.diagnosticTestsTable).select();
      if (activeOnly) query = query.eq('is_active', true);
      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }
      final response = await fetchWithRetry(
        () => query
            .order('category', ascending: true)
            .order('test_name', ascending: true),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching diagnostic tests', e);
      return [];
    }
  }

  /// Creates or updates a test in the diagnostics master.
  Future<Map<String, dynamic>> saveDiagnosticTest(
    Map<String, dynamic> data, {
    String? id,
  }) async {
    if (id == null || id.isEmpty) {
      return create(ApiConstants.diagnosticTestsTable, {
        ...data,
        'is_active': data['is_active'] ?? true,
      });
    }
    return update(ApiConstants.diagnosticTestsTable, id, {
      ...data,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Hard-deletes a test. Existing order items keep their test_name because
  /// the FK on diagnostic_order_items.test_id is ON DELETE SET NULL.
  Future<void> deleteDiagnosticTest(String id) async {
    await delete(ApiConstants.diagnosticTestsTable, id);
  }

  /// Toggles a test's active state (soft disable instead of delete).
  Future<void> setDiagnosticTestActive(String id, bool isActive) async {
    await update(ApiConstants.diagnosticTestsTable, id, {
      'is_active': isActive,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Generates a walk-in (direct) patient UHID: `D` + timestamp with
  /// millisecond precision. Practically unique per patient.
  String generateWalkInUHID() {
    final now = DateTime.now();
    final ts =
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}'
        '${now.millisecond.toString().padLeft(3, '0')}';
    return 'D$ts';
  }

  /// Creates a walk-in (direct) patient record with an auto-generated UHID.
  ///
  /// The same UHID/mobile number can later be used to register the patient
  /// for OPD or IPD from the patient module.
  Future<Map<String, dynamic>> registerWalkInPatient({
    required String hospitalId,
    required String firstName,
    String? lastName,
    required String mobileNumber,
  }) async {
    var attempt = 0;
    while (attempt < 3) {
      attempt++;
      final uhid = generateWalkInUHID();
      try {
        return await registerPatient({
          'hospital_id': hospitalId,
          'uhid': uhid,
          'first_name': firstName.trim(),
          'last_name': (lastName ?? '').trim().isEmpty
              ? null
              : lastName!.trim(),
          'mobile_number': mobileNumber.trim(),
        });
      } catch (_) {
        // Retry on the rare UHID collision.
        if (attempt >= 3) rethrow;
      }
    }
    throw Exception('Could not generate a unique UHID');
  }

  /// Creates a diagnostic order header + line items, and records a
  /// `lab_revenue` collection row for the revenue dashboard.
  Future<Map<String, dynamic>> createDiagnosticOrder({
    required String hospitalId,
    required String patientId,
    required String doctorId,
    required String urgency,
    required List<Map<String, dynamic>> items,
  }) async {
    return _insertDiagnosticOrder(
      hospitalId: hospitalId,
      patientId: patientId,
      doctorId: doctorId,
      urgency: urgency,
      items: items,
    );
  }

  Future<Map<String, dynamic>> _insertDiagnosticOrder({
    required String hospitalId,
    required String patientId,
    required String doctorId,
    required String urgency,
    required List<Map<String, dynamic>> items,
  }) async {
    if (items.isEmpty) {
      throw ArgumentError('At least one test is required.');
    }

    final total = items.fold<double>(
      0,
      (sum, item) => sum + _toDouble(item['price']),
    );
    final today = DateTime.now().toIso8601String().split('T')[0];

    final order = await _client
        .from(ApiConstants.diagnosticOrdersTable)
        .insert({
          'hospital_id': hospitalId,
          'patient_id': patientId,
          'doctor_id': doctorId,
          'order_date': today,
          'urgency': urgency,
          'status': 'pending',
          'total_amount': total,
        })
        .select()
        .single();

    final orderId = order['id'] as String;

    for (final item in items) {
      await _client.from(ApiConstants.diagnosticOrderItemsTable).insert({
        'order_id': orderId,
        'test_id': item['test_id'],
        'test_name': item['test_name'],
        'category': item['category'],
        'price': item['price'],
      });
    }

    await _client.from(ApiConstants.labRevenueTable).insert({
      'hospital_id': hospitalId,
      'order_id': orderId,
      'total_amount': total,
      'collected_at': DateTime.now().toUtc().toIso8601String(),
    });

    return order;
  }

  /// Full "cut receipt" flow for diagnostics:
  /// 1. diagnostic order + items + lab_revenue
  /// 2. turnover billing row (`billing` + `billing_items`, bill_type =
  ///    'diagnostics')
  /// 3. daily_hisab total_income update (money actually collected)
  ///
  /// Returns `order`, `bill`, totals and the printed `receipt_number`.
  Future<Map<String, dynamic>> createDiagnosticOrderWithBilling({
    required String hospitalId,
    required String patientId,
    required String doctorId,
    required String urgency,
    required List<Map<String, dynamic>> items,
    required double paidAmount,
    required String paymentMode,
  }) async {
    final order = await _insertDiagnosticOrder(
      hospitalId: hospitalId,
      patientId: patientId,
      doctorId: doctorId,
      urgency: urgency,
      items: items,
    );

    final total = _toDouble(order['total_amount']);
    final bill = await _recordDiagnosticBilling(
      hospitalId: hospitalId,
      patientId: patientId,
      totalAmount: total,
      paidAmount: paidAmount,
      paymentMode: paymentMode,
      items: items,
    );

    if (paidAmount > 0) {
      await _addToDailyTurnover(hospitalId: hospitalId, amount: paidAmount);
    }

    return {
      'order': order,
      'bill': bill,
      'total_amount': total,
      'paid_amount': paidAmount,
      'balance_amount': (total - paidAmount).roundToDouble(),
      'receipt_number': bill['bill_number']?.toString(),
    };
  }

  /// Inserts a `billing` header + `billing_items` for a diagnostic receipt.
  Future<Map<String, dynamic>> _recordDiagnosticBilling({
    required String hospitalId,
    required String patientId,
    required double totalAmount,
    required double paidAmount,
    required String paymentMode,
    required List<Map<String, dynamic>> items,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final today = DateTime.now().toIso8601String().split('T')[0];
    final billNumber = _generateBillNumber('DIAG');
    final balanceAmount = (totalAmount - paidAmount).roundToDouble();
    final isPaid = paidAmount >= totalAmount;
    final createdBy = await getCurrentUsersTableId();

    final bill = await _client
        .from(ApiConstants.billingTable)
        .insert({
          'hospital_id': hospitalId,
          'patient_id': patientId,
          'source_type': 'lab',
          'bill_number': billNumber,
          'bill_date': today,
          'bill_type': 'diagnostics',
          'visit_type': 'lab',
          'subtotal': totalAmount,
          'total_amount': totalAmount,
          'discount_amount': 0,
          'discount_percentage': 0,
          'tax_amount': 0,
          'net_amount': totalAmount,
          'paid_amount': paidAmount,
          'balance_amount': balanceAmount,
          'payment_status': isPaid
              ? 'paid'
              : paidAmount > 0
              ? 'partially_paid'
              : 'unpaid',
          'payment_mode': paidAmount > 0 ? paymentMode : null,
          'payment_date': paidAmount > 0 ? now : null,
          'status': isPaid ? 'paid' : 'generated',
          'created_by': createdBy,
          'updated_by': createdBy,
        })
        .select()
        .single();

    final billId = bill['id'] as String;
    for (final item in items) {
      await _client.from(ApiConstants.billingItemsTable).insert({
        'bill_id': billId,
        'item_type': 'lab_test',
        'item_name': item['test_name'],
        'quantity': 1,
        'unit_price': item['price'],
        'total_price': item['price'],
      });
    }

    if (paidAmount > 0) {
      await _recordPaymentLog(
        billId: billId,
        amountPaid: paidAmount,
        paymentMode: paymentMode,
        paidBy: null,
      );
    }

    await recordBillingAudit(
      billId: billId,
      action: 'created',
      oldValue: null,
      newValue: _auditSnapshot(bill),
      description: 'Lab/diagnostic bill generated',
    );

    return bill;
  }

  /// Adds collected amount into today's daily_hisab turnover (total_income).
  Future<void> _addToDailyTurnover({
    required String hospitalId,
    required double amount,
  }) async {
    final today = DateTime.now().toIso8601String().split('T')[0];

    final existing = await _client
        .from(ApiConstants.dailyHisabTable)
        .select('id, total_income, total_expense')
        .eq('hospital_id', hospitalId)
        .eq('entry_date', today)
        .maybeSingle();

    if (existing == null) {
      await _client.from(ApiConstants.dailyHisabTable).insert({
        'hospital_id': hospitalId,
        'entry_date': today,
        'opening_balance': 0,
        'total_income': amount,
        'total_expense': 0,
        'closing_balance': amount,
      });
    } else {
      final income = _toDouble(existing['total_income']) + amount;
      final expense = _toDouble(existing['total_expense']);
      await _client
          .from(ApiConstants.dailyHisabTable)
          .update({
            'total_income': income,
            'closing_balance': (income - expense).roundToDouble(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', existing['id']);
    }
  }

  /// Returns diagnostic orders (with embedded patient name/UHID) for a
  /// hospital, newest first. Optionally filtered by [status].
  Future<List<Map<String, dynamic>>> getDiagnosticOrders({
    String? hospitalId,
    String? status,
  }) async {
    try {
      var query = _client
          .from(ApiConstants.diagnosticOrdersTable)
          .select('*, patients(first_name, last_name, uhid)');

      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }
      if (status != null && status.isNotEmpty) {
        query = query.eq('status', status);
      }

      final response = await fetchWithRetry(
        () => query.order('created_at', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching diagnostic orders', e);
      return [];
    }
  }

  /// Returns line items for an order. Each item embeds its
  /// `diagnostic_results` array (usually zero or one row).
  Future<List<Map<String, dynamic>>> getDiagnosticOrderItems(
    String orderId,
  ) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.diagnosticOrderItemsTable)
            .select('*, diagnostic_results(*)')
            .eq('order_id', orderId)
            .order('created_at', ascending: true),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching diagnostic order items', e);
      return [];
    }
  }

  /// Creates or updates a diagnostic result. The result date is always
  /// auto-filled with today's date.
  Future<Map<String, dynamic>> saveDiagnosticResult(
    Map<String, dynamic> data, {
    String? id,
  }) async {
    final payload = {
      ...data,
      'result_date': DateTime.now().toIso8601String().split('T')[0],
    };
    if (id == null || id.isEmpty) {
      return create(ApiConstants.diagnosticResultsTable, payload);
    }
    return update(ApiConstants.diagnosticResultsTable, id, {
      ...payload,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Updates the status of a diagnostic order
  /// (pending / in_progress / completed / cancelled).
  Future<void> updateDiagnosticOrderStatus(
    String orderId,
    String status,
  ) async {
    await update(ApiConstants.diagnosticOrdersTable, orderId, {
      'status': status,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Raw revenue rows within an inclusive date range, newest first.
  Future<List<Map<String, dynamic>>> getLabRevenue({
    String? hospitalId,
    DateTime? from,
    DateTime? to,
  }) async {
    try {
      var query = _client.from(ApiConstants.labRevenueTable).select();
      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }
      if (from != null) {
        query = query.gte('collected_at', from.toUtc().toIso8601String());
      }
      if (to != null) {
        query = query.lte('collected_at', to.toUtc().toIso8601String());
      }
      final response = await fetchWithRetry(
        () => query.order('collected_at', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching lab revenue', e);
      return [];
    }
  }

  /// Aggregated statistics for the Lab Revenue dashboard:
  /// daily/monthly revenue, category-wise breakdown of completed tests and
  /// pending vs completed order counts.
  Future<Map<String, dynamic>> getLabRevenueStats(String hospitalId) async {
    try {
      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day).toUtc();
      final monthStart = DateTime(now.year, now.month, 1).toUtc();

      // 1. Current-month revenue rows -> daily + monthly totals.
      final revenueRows = await getLabRevenue(
        hospitalId: hospitalId,
        from: monthStart,
      );

      var dailyRevenue = 0.0;
      var monthlyRevenue = 0.0;
      for (final row in revenueRows) {
        final amount = _toDouble(row['total_amount']);
        monthlyRevenue += amount;

        final collectedAt = _parseDate(row['collected_at']);
        if (collectedAt != null && !collectedAt.toUtc().isBefore(todayStart)) {
          dailyRevenue += amount;
        }
      }

      // 2. Category-wise breakdown from completed order items. The `!inner`
      //    join ensures only items whose parent order is completed count.
      final itemsResponse = await _client
          .from(ApiConstants.diagnosticOrderItemsTable)
          .select(
            'category, price, diagnostic_orders!inner(status, hospital_id)',
          )
          .eq('diagnostic_orders.status', 'completed')
          .eq('diagnostic_orders.hospital_id', hospitalId)
          .order('category', ascending: true);

      final categoryAmount = <String, double>{};
      final categoryCount = <String, int>{};
      for (final item in List<Map<String, dynamic>>.from(itemsResponse)) {
        final category = item['category']?.toString() ?? 'other';
        final amount = _toDouble(item['price']);
        categoryAmount[category] = (categoryAmount[category] ?? 0) + amount;
        categoryCount[category] = (categoryCount[category] ?? 0) + 1;
      }

      // 3. Pending vs completed order counts.
      final ordersResponse = await _client
          .from(ApiConstants.diagnosticOrdersTable)
          .select('status')
          .eq('hospital_id', hospitalId);

      var pendingOrders = 0;
      var completedOrders = 0;
      for (final order in List<Map<String, dynamic>>.from(ordersResponse)) {
        final status = order['status']?.toString() ?? 'pending';
        if (status == 'completed') {
          completedOrders++;
        } else if (status == 'pending' || status == 'in_progress') {
          pendingOrders++;
        }
      }

      return {
        'daily_revenue': dailyRevenue,
        'monthly_revenue': monthlyRevenue,
        'category_breakdown': categoryAmount.entries
            .map(
              (entry) => {
                'category': entry.key,
                'amount': entry.value,
                'count': categoryCount[entry.key] ?? 0,
              },
            )
            .toList(),
        'pending_orders': pendingOrders,
        'completed_orders': completedOrders,
      };
    } catch (e) {
      AppLogger.e('Error fetching lab revenue stats', e);
      return {
        'daily_revenue': 0.0,
        'monthly_revenue': 0.0,
        'category_breakdown': const <Map<String, dynamic>>[],
        'pending_orders': 0,
        'completed_orders': 0,
      };
    }
  }

  /// Returns the public `users` record for a doctor id (for report headers).
  Future<Map<String, dynamic>?> getDoctorById(String doctorId) async {
    if (doctorId.isEmpty) return null;
    return getById(ApiConstants.usersTable, doctorId);
  }

  // ---------------------------------------------------------------------------
  // Free Trial / Subscription Module
  // ---------------------------------------------------------------------------

  /// Returns the effective subscription status for a hospital.
  ///
  /// The effective status is derived from the dates (never trusted blindly
  /// from the stored column):
  /// * `subscription_expiry` in the future  -> `active`
  /// * `trial_end_date` in the future       -> `trial`
  /// * otherwise                            -> `expired`
  ///
  /// The returned map always contains: `status`, `is_trial`, `is_active`,
  /// `is_expired`, `days_left`, `trial_start_date`, `trial_end_date`,
  /// `subscription_expiry`, `subscription_plan`.
  Future<Map<String, dynamic>> getSubscriptionStatus(String hospitalId) async {
    try {
      final hospital = await fetchWithRetry(
        () => _client
            .from(ApiConstants.hospitalsTable)
            .select(
              'id, trial_start_date, trial_end_date, subscription_status, '
              'subscription_plan, subscription_expiry',
            )
            .eq('id', hospitalId)
            .maybeSingle(),
      );

      final now = DateTime.now();
      final trialStart = _parseDate(hospital?['trial_start_date']);
      final trialEnd = _parseDate(hospital?['trial_end_date']);
      final subscriptionExpiry = _parseDate(hospital?['subscription_expiry']);
      final storedStatus = hospital?['subscription_status']
          ?.toString()
          .toLowerCase();

      String effectiveStatus;
      if (subscriptionExpiry != null && subscriptionExpiry.isAfter(now)) {
        effectiveStatus = 'active';
      } else if (trialEnd != null && trialEnd.isAfter(now)) {
        effectiveStatus = 'trial';
      } else {
        effectiveStatus = 'expired';
      }

      // Keep the stored status in sync when it has drifted (e.g. the trial
      // ended while nobody logged in). Best-effort only.
      if (storedStatus != null && storedStatus != effectiveStatus) {
        try {
          await _client
              .from(ApiConstants.hospitalsTable)
              .update({
                'subscription_status': effectiveStatus,
                'updated_at': now.toUtc().toIso8601String(),
              })
              .eq('id', hospitalId);
        } catch (_) {
          // Never fail the status read because of a sync write.
        }
      }

      final relevantEnd = effectiveStatus == 'active'
          ? subscriptionExpiry
          : trialEnd;
      final today = DateTime(now.year, now.month, now.day);
      final endDay = relevantEnd == null
          ? today
          : DateTime(relevantEnd.year, relevantEnd.month, relevantEnd.day);
      final daysLeft = endDay.difference(today).inDays;

      return {
        'hospital_id': hospitalId,
        'status': effectiveStatus,
        'subscription_status': effectiveStatus,
        'subscription_plan': hospital?['subscription_plan']?.toString(),
        'trial_start_date': trialStart?.toIso8601String(),
        'trial_end_date': trialEnd?.toIso8601String(),
        'subscription_expiry': subscriptionExpiry?.toIso8601String(),
        'days_left': daysLeft < 0 ? 0 : daysLeft,
        'is_trial': effectiveStatus == 'trial',
        'is_active': effectiveStatus == 'active',
        'is_expired': effectiveStatus == 'expired',
      };
    } catch (e) {
      AppLogger.e('Error fetching subscription status', e);
      rethrow;
    }
  }

  /// Renews / activates a subscription for [days] days from today (or from
  /// the current expiry when the subscription is still active — extending).
  ///
  /// * Updates `hospitals.subscription_*` columns.
  /// * Records one row in `payments` so the renewal appears in the payment
  ///   history.
  /// * [paymentMethod] is one of `mock`, `stripe`, `upi`, `paytm`.
  /// * [paymentAmount] defaults to the plan's standard price.
  Future<Map<String, dynamic>> updateSubscription(
    String hospitalId,
    String plan,
    int days, {
    String paymentMethod = 'mock',
    double? paymentAmount,
  }) async {
    try {
      final now = DateTime.now();
      final currentStatus = await getSubscriptionStatus(hospitalId);
      final currentExpiry = _parseDate(currentStatus['subscription_expiry']);

      // Extend from the current expiry when still active, otherwise start now.
      final base = (currentExpiry != null && currentExpiry.isAfter(now))
          ? currentExpiry
          : now;
      final newExpiry = base.add(Duration(days: days));
      final amount = paymentAmount ?? _subscriptionPlanPrice(plan);

      final updated = await _client
          .from(ApiConstants.hospitalsTable)
          .update({
            'subscription_status': 'active',
            'subscription_plan': plan.toLowerCase(),
            'subscription_expiry': newExpiry.toUtc().toIso8601String(),
            'updated_at': now.toUtc().toIso8601String(),
          })
          .eq('id', hospitalId)
          .select()
          .single();

      await _recordSubscriptionPayment(
        hospitalId: hospitalId,
        plan: plan,
        amount: amount,
        paymentMethod: paymentMethod,
      );

      return {...await getSubscriptionStatus(hospitalId), 'hospital': updated};
    } catch (e) {
      AppLogger.e('Error updating subscription', e);
      rethrow;
    }
  }

  /// Returns all subscription payments for a hospital, newest first.
  Future<List<Map<String, dynamic>>> getPaymentHistory(
    String hospitalId,
  ) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.paymentsTable)
            .select()
            .eq('hospital_id', hospitalId)
            .order('payment_date', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } on PostgrestException catch (e) {
      if (e.message.toLowerCase().contains('could not find the table')) {
        AppLogger.e('payments table missing — run subscription migration', e);
        return [];
      }
      AppLogger.e('Error fetching payment history', e);
      return [];
    }
  }

  /// Inserts one row into the `payments` table (internal helper).
  Future<void> _recordSubscriptionPayment({
    required String hospitalId,
    required String plan,
    required double amount,
    required String paymentMethod,
  }) async {
    try {
      await _client.from(ApiConstants.paymentsTable).insert({
        'hospital_id': hospitalId,
        'payment_amount': amount,
        'payment_date': DateTime.now().toUtc().toIso8601String(),
        'payment_method': paymentMethod.toLowerCase(),
        'payment_status': 'success',
        'subscription_plan': plan.toLowerCase(),
      });
    } on PostgrestException catch (e) {
      if (e.message.toLowerCase().contains('could not find the table')) {
        AppLogger.e('payments table missing — run subscription migration', e);
        return;
      }
      rethrow;
    }
  }

  /// Standard yearly price for a subscription plan.
  double _subscriptionPlanPrice(String plan) {
    switch (plan.toLowerCase()) {
      case 'basic':
        return 10000;
      case 'standard':
        return 15000;
      case 'premium':
        return 20000;
      default:
        return 15000;
    }
  }

  // ---------------------------------------------------------------------------
  // Offline-First Data Sync
  // ---------------------------------------------------------------------------

  /// Generates a random UUID v4 string (offline ids and local row ids).
  static String generateUuid() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Saves data **locally first**, then tries to sync it to Supabase.
  ///
  /// * [patientData] — full row payload. Defaults to the `patients` table;
  ///   pass [table] for `opd_registrations`, `ipd_admissions` or `billing`.
  /// * A fresh `offline_id` (UUID) and local `id` are generated when missing so
  ///   child rows can reference this record before it reaches the server.
  /// * `sync_status` is stored as `pending`; the sync engine flips it to
  ///   `synced` (or removes the local row on conflict) once it is uploaded.
  Future<Map<String, dynamic>> saveOfflineData(
    Map<String, dynamic> patientData, {
    String table = ApiConstants.patientsTable,
  }) async {
    if (!LocalTables.contains(table)) {
      throw ArgumentError.value(table, 'table', 'Unsupported offline table');
    }

    await _localDb.init();

    final offlineId = generateUuid();
    final now = DateTime.now().toUtc().toIso8601String();

    final payload = Map<String, dynamic>.from(patientData);
    payload['offline_id'] = offlineId;
    payload['sync_status'] = 'pending';
    // A locally generated id lets dependent rows (opd/ipd/billing FKs) be
    // saved before the parent patient row has reached Supabase.
    payload['id'] ??= generateUuid();
    payload['created_at'] ??= now;
    payload['updated_at'] ??= now;

    await _localDb.saveRecord(
      table: table,
      offlineId: offlineId,
      data: payload,
      isSynced: false,
    );

    // Best-effort immediate upload; the 30-second timer picks it up if the
    // network is currently down.
    unawaited(syncPendingData());

    return payload;
  }

  /// True when a usable network connection is available.
  Future<bool> _isOnline() async {
    try {
      final result = await Connectivity().checkConnectivity();
      return result != ConnectivityResult.none;
    } catch (_) {
      // Fail open — a failed connectivity probe shouldn't block a sync that
      // might actually succeed.
      return true;
    }
  }

  /// Uploads every pending local record to Supabase.
  ///
  /// * Inserts rows that don't exist yet (matched by `offline_id`).
  /// * **Conflict handling:** if a row with the same `offline_id` already
  ///   exists on Supabase, the local copy is deleted.
  /// * On success the local record is marked `is_synced = true`.
  ///
  /// Returns the number of records successfully processed. Rows are synced in
  /// parent → child order (`patients` → `opd_registrations` → `ipd_admissions`
  /// → `billing`) so foreign keys resolve.
  Future<int> syncPendingData() async {
    if (_syncInProgress) return 0;
    _syncInProgress = true;
    try {
      await _localDb.init();

      if (!await _isOnline()) return 0;
      if (_client.auth.currentSession == null) return 0;

      final pending = await _localDb.getPendingRecords();
      if (pending.isEmpty) return 0;

      var processed = 0;
      for (final record in pending) {
        try {
          await _syncRecord(record);
          processed++;
        } on PostgrestException catch (e) {
          // Server is reachable but rejected this row (constraint, RLS, …).
          // Keep it pending and move on so one bad row can't block the queue.
          AppLogger.e('Sync rejected ${record.table}/${record.offlineId}', e);
          continue;
        } catch (e) {
          // Network-level failure — stop this pass; the next timer tick
          // (30 seconds later) will retry.
          AppLogger.e('Sync stopped at ${record.table}/${record.offlineId}', e);
          break;
        }
      }
      return processed;
    } finally {
      _syncInProgress = false;
    }
  }

  /// Uploads one pending record (insert or conflict-delete).
  Future<void> _syncRecord(PendingSyncRecord record) async {
    final existing = await _client
        .from(record.table)
        .select('id')
        .eq('offline_id', record.offlineId)
        .maybeSingle();

    if (existing != null) {
      // Conflict: the same offline_id already reached Supabase (e.g. from a
      // previous partial sync) → drop the local copy.
      await _localDb.deleteRecord(
        table: record.table,
        offlineId: record.offlineId,
      );
      return;
    }

    final payload = Map<String, dynamic>.from(record.data)
      ..remove('is_synced')
      ..['offline_id'] = record.offlineId
      ..['sync_status'] = 'synced';

    final response = await _client.from(record.table).insert(payload).select();
    if (response.isEmpty) {
      throw StateError(
        'Insert into ${record.table} returned 0 rows for '
        '${record.offlineId}',
      );
    }

    await _localDb.markSynced(table: record.table, offlineId: record.offlineId);
  }

  /// Cache-first read.
  ///
  /// 1. Reads the local database first.
  /// 2. If local rows exist they are returned **immediately**, while a
  ///    background Supabase fetch refreshes the local cache.
  /// 3. If the local cache is empty, the Supabase fetch runs first and its
  ///    result is stored locally before being returned.
  /// 4. If Supabase is unreachable, the local rows are returned as a fallback.
  Future<List<Map<String, dynamic>>> fetchDataCached({
    required String table,
    Map<String, dynamic>? filters,
    String? select,
    String? orderColumn,
    bool ascending = false,
    int? limit,
  }) async {
    await _localDb.init();

    final local = await _localDb.getRecords(table: table);
    if (local.isNotEmpty) {
      // Show local data now; update the cache when Supabase responds.
      unawaited(
        refreshCachedData(
          table: table,
          filters: filters,
          select: select,
          orderColumn: orderColumn,
          ascending: ascending,
          limit: limit,
        ),
      );
      return local;
    }

    try {
      final remote = await _fetchRemote(
        table: table,
        filters: filters,
        select: select,
        orderColumn: orderColumn,
        ascending: ascending,
        limit: limit,
      );
      await _localDb.replaceRecords(table: table, records: remote);
      return remote;
    } catch (e) {
      AppLogger.e('Error fetching cached data for $table', e);
      return local;
    }
  }

  /// Fetches fresh rows from Supabase and replaces the local cache for
  /// [table]. Errors are swallowed — the previous cache stays intact.
  Future<void> refreshCachedData({
    required String table,
    Map<String, dynamic>? filters,
    String? select,
    String? orderColumn,
    bool ascending = false,
    int? limit,
  }) async {
    try {
      final remote = await _fetchRemote(
        table: table,
        filters: filters,
        select: select,
        orderColumn: orderColumn,
        ascending: ascending,
        limit: limit,
      );
      await _localDb.replaceRecords(table: table, records: remote);
    } catch (e) {
      AppLogger.e('Background cache refresh failed for $table', e);
    }
  }

  Future<List<Map<String, dynamic>>> _fetchRemote({
    required String table,
    Map<String, dynamic>? filters,
    String? select,
    String? orderColumn,
    bool ascending = false,
    int? limit,
  }) async {
    return fetchWithRetry(() async {
      dynamic query = _client.from(table).select(select ?? '*');
      if (filters != null) {
        filters.forEach((key, value) {
          query = query.eq(key, value);
        });
      }
      if (orderColumn != null && orderColumn.isNotEmpty) {
        query = query.order(orderColumn, ascending: ascending);
      }
      if (limit != null) {
        query = query.limit(limit);
      }
      final response = await query;
      return List<Map<String, dynamic>>.from(response);
    });
  }

  // ---------------------------------------------------------------------------
  // Hive TTL Cache — Frequently Used Data
  // (doctors_cache, departments_cache, medicines_cache, patients_cache)
  // ---------------------------------------------------------------------------

  /// Fetches all active doctors from Supabase.
  Future<List<Map<String, dynamic>>> fetchDoctors({String? hospitalId}) async {
    try {
      dynamic query = _client
          .from(ApiConstants.doctorsTable)
          .select()
          .eq('is_active', true);
      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }
      final response = await fetchWithRetry(
        () => query.order('name', ascending: true),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching doctors', e);
      rethrow;
    }
  }

  /// Fetches all departments from Supabase.
  Future<List<Map<String, dynamic>>> fetchDepartments({String? hospitalId}) {
    return getDepartments(hospitalId: hospitalId);
  }

  /// Fetches active medicines (pharmacy master) from Supabase.
  Future<List<Map<String, dynamic>>> fetchMedicines({
    String? hospitalId,
  }) async {
    try {
      dynamic query = _client
          .from(ApiConstants.pharmacyMedicinesTable)
          .select()
          .eq('is_active', true);
      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }
      final response = await fetchWithRetry(
        () => query.order('medicine_name', ascending: true).limit(500),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching medicines', e);
      rethrow;
    }
  }

  /// Fetches the lightweight patient list (basic list columns) from Supabase.
  Future<List<Map<String, dynamic>>> fetchPatientsBasicList({
    String? hospitalId,
    int limit = 100,
  }) async {
    try {
      dynamic query = _client
          .from(ApiConstants.patientsTable)
          .select(
            'id, hospital_id, uhid, first_name, last_name, mobile_number, '
            'gender, age, blood_group, abha_linked, registration_date, '
            'created_at',
          );
      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }
      final response = await fetchWithRetry(
        () => query.order('created_at', ascending: false).limit(limit),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching patients basic list', e);
      rethrow;
    }
  }

  /// Always fetches doctors from Supabase and updates the Hive cache.
  Future<List<Map<String, dynamic>>> fetchDoctorsAndCache({
    String? hospitalId,
  }) async {
    final fresh = await fetchDoctors(hospitalId: hospitalId);
    await _cache.put(CacheKeys.doctors, fresh, hospitalId: hospitalId);
    return fresh;
  }

  /// Always fetches departments from Supabase and updates the Hive cache.
  Future<List<Map<String, dynamic>>> fetchDepartmentsAndCache({
    String? hospitalId,
  }) async {
    final fresh = await fetchDepartments(hospitalId: hospitalId);
    await _cache.put(CacheKeys.departments, fresh, hospitalId: hospitalId);
    return fresh;
  }

  /// Always fetches medicines from Supabase and updates the Hive cache.
  Future<List<Map<String, dynamic>>> fetchMedicinesAndCache({
    String? hospitalId,
  }) async {
    final fresh = await fetchMedicines(hospitalId: hospitalId);
    await _cache.put(CacheKeys.medicines, fresh, hospitalId: hospitalId);
    return fresh;
  }

  /// Always fetches the basic patient list from Supabase and updates Hive.
  Future<List<Map<String, dynamic>>> fetchPatientsAndCache({
    String? hospitalId,
    int limit = 100,
  }) async {
    final fresh = await fetchPatientsBasicList(
      hospitalId: hospitalId,
      limit: limit,
    );
    await _cache.put(CacheKeys.patients, fresh, hospitalId: hospitalId);
    return fresh;
  }

  /// Cache-first readers.
  ///
  /// 1. Valid Hive data (≤ 5 min old) is returned immediately while a
  ///    background Supabase fetch refreshes the cache.
  /// 2. When the cache is empty/expired, Supabase is fetched first and the
  ///    result is stored in Hive before being returned.
  Future<List<Map<String, dynamic>>> getCachedDoctors({String? hospitalId}) {
    return _cacheFirst(
      CacheKeys.doctors,
      () => fetchDoctorsAndCache(hospitalId: hospitalId),
      hospitalId: hospitalId,
    );
  }

  /// Cache-first doctors for one department. Filters the shared
  /// `doctors_cache` list client-side (the whole doctors cache is refreshed in
  /// the background by [getCachedDoctors]).
  Future<List<Map<String, dynamic>>> getCachedDoctorsByDepartment(
    String departmentId, {
    String? hospitalId,
  }) async {
    final doctors = await getCachedDoctors(hospitalId: hospitalId);
    return doctors
        .where((d) => d['department_id']?.toString() == departmentId)
        .toList();
  }

  Future<List<Map<String, dynamic>>> getCachedDepartments({
    String? hospitalId,
  }) {
    return _cacheFirst(
      CacheKeys.departments,
      () => fetchDepartmentsAndCache(hospitalId: hospitalId),
      hospitalId: hospitalId,
    );
  }

  Future<List<Map<String, dynamic>>> getCachedMedicines({String? hospitalId}) {
    return _cacheFirst(
      CacheKeys.medicines,
      () => fetchMedicinesAndCache(hospitalId: hospitalId),
      hospitalId: hospitalId,
    );
  }

  Future<List<Map<String, dynamic>>> getCachedPatients({
    String? hospitalId,
    int limit = 100,
  }) {
    return _cacheFirst(
      CacheKeys.patients,
      () => fetchPatientsAndCache(hospitalId: hospitalId, limit: limit),
      hospitalId: hospitalId,
    );
  }

  Future<List<Map<String, dynamic>>> _cacheFirst(
    String key,
    Future<List<Map<String, dynamic>>> Function() fetchAndCache, {
    String? hospitalId,
  }) async {
    await _cache.init();
    final cached = await _cache.get(key, hospitalId: hospitalId);
    if (cached != null) {
      // Show cached data now; update the cache when Supabase responds.
      unawaited(_refreshCache(key, fetchAndCache));
      return cached;
    }
    return fetchAndCache();
  }

  Future<void> _refreshCache(
    String key,
    Future<List<Map<String, dynamic>>> Function() fetchAndCache,
  ) async {
    try {
      await fetchAndCache();
    } catch (e) {
      AppLogger.e('Background cache refresh failed for $key', e);
    }
  }

  /// Maps a Supabase table name to its frequent-cache key (null when the table
  /// is not part of the 5-minute Hive cache).
  String? _frequentCacheKeyForTable(String table) {
    switch (table) {
      case ApiConstants.doctorsTable:
        return CacheKeys.doctors;
      case ApiConstants.departmentsTable:
        return CacheKeys.departments;
      case ApiConstants.pharmacyMedicinesTable:
        return CacheKeys.medicines;
      case ApiConstants.patientsTable:
        return CacheKeys.patients;
      default:
        return null;
    }
  }

  /// Invalidates the Hive cache entry for [table] after a successful write so
  /// the next screen load fetches fresh data instead of serving stale cache.
  Future<void> _invalidateFrequentCacheForTable(String table) async {
    final key = _frequentCacheKeyForTable(table);
    if (key != null) {
      await _cache.invalidate(key);
    }
  }

  /// Fetches all frequently used data together (doctors, departments,
  /// medicines and the basic patient list) and stores each list in Hive under
  /// its cache key.
  ///
  /// A failed source is logged and **not** cached (the previous valid cache for
  /// that key stays intact, or the key stays empty), so one failed fetch never
  /// blocks or poisons the other three.
  Future<Map<String, List<Map<String, dynamic>>>> fetchAndCacheData({
    String? hospitalId,
  }) async {
    await _cache.init();

    final results = await Future.wait([
      _fetchForCache(() => fetchDoctors(hospitalId: hospitalId)),
      _fetchForCache(() => fetchDepartments(hospitalId: hospitalId)),
      _fetchForCache(() => fetchMedicines(hospitalId: hospitalId)),
      _fetchForCache(() => fetchPatientsBasicList(hospitalId: hospitalId)),
    ]);

    final doctors = results[0] ?? const <Map<String, dynamic>>[];
    final departments = results[1] ?? const <Map<String, dynamic>>[];
    final medicines = results[2] ?? const <Map<String, dynamic>>[];
    final patients = results[3] ?? const <Map<String, dynamic>>[];

    final puts = <Future<void>>[];
    if (results[0] != null) {
      puts.add(_cache.put(CacheKeys.doctors, doctors, hospitalId: hospitalId));
    }
    if (results[1] != null) {
      puts.add(
        _cache.put(CacheKeys.departments, departments, hospitalId: hospitalId),
      );
    }
    if (results[2] != null) {
      puts.add(
        _cache.put(CacheKeys.medicines, medicines, hospitalId: hospitalId),
      );
    }
    if (results[3] != null) {
      puts.add(
        _cache.put(CacheKeys.patients, patients, hospitalId: hospitalId),
      );
    }
    await Future.wait(puts);

    return {
      'doctors': doctors,
      'departments': departments,
      'medicines': medicines,
      'patients': patients,
    };
  }

  /// Returns the fetched list, or null when the fetch failed. Null means
  /// "don't touch the cache for this key".
  Future<List<Map<String, dynamic>>?> _fetchForCache(
    Future<List<Map<String, dynamic>>> Function() fetch,
  ) async {
    try {
      return await fetch();
    } catch (e) {
      AppLogger.e('fetchAndCacheData: one source failed', e);
      return null;
    }
  }

  /// Force-refreshes every frequently used list from Supabase into Hive.
  /// Use this together with `ref.invalidate(...)` on the Refresh button.
  Future<void> refreshFrequentCache({String? hospitalId}) async {
    await fetchAndCacheData(hospitalId: hospitalId);
  }

  /// Deletes one cache key, or every key when [key] is null.
  Future<void> invalidateFrequentCache({String? key}) async {
    await _cache.init();
    if (key == null) {
      await _cache.invalidateAll();
    } else {
      await _cache.invalidate(key);
    }
  }

  // ---------------------------------------------------------------------------
  // Clinical Counseling Documentation
  // ---------------------------------------------------------------------------

  /// Returns all counseling records for [patientId], newest first.
  ///
  /// Missing-table errors are swallowed so screens keep working before the
  /// `counseling_records` migration has been applied.
  Future<List<Map<String, dynamic>>> getCounselingRecords(
    String patientId, {
    String? hospitalId,
  }) async {
    try {
      var query = _client
          .from(ApiConstants.counselingRecordsTable)
          .select('*, users(first_name, last_name)')
          .eq('patient_id', patientId);

      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }

      final response = await fetchWithRetry(
        () => query
            .order('counseling_date', ascending: false)
            .order('created_at', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) {
        AppLogger.e(
          'counseling_records table missing — run counseling migration',
          e,
        );
        return [];
      }
      AppLogger.e('Error fetching counseling records', e);
      return [];
    } catch (e) {
      AppLogger.e('Error fetching counseling records', e);
      return [];
    }
  }

  /// Returns counseling records for one specific visit/admission, newest
  /// first. Pass exactly one of [opdRegistrationId] / [ipdAdmissionId].
  ///
  /// Counseling is visit-specific: OPD sessions stack under their OPD
  /// registration and IPD sessions stack under their admission.
  Future<List<Map<String, dynamic>>> getCounselingRecordsByVisit({
    required String visitType,
    String? opdRegistrationId,
    String? ipdAdmissionId,
    String? hospitalId,
  }) async {
    final visitId = visitType == 'ipd'
        ? (ipdAdmissionId ?? '').trim()
        : (opdRegistrationId ?? '').trim();
    if (visitId.isEmpty) return [];

    final visitColumn = visitType == 'ipd'
        ? 'ipd_admission_id'
        : 'opd_registration_id';

    try {
      var query = _client
          .from(ApiConstants.counselingRecordsTable)
          .select('*, users(first_name, last_name)')
          .eq(visitColumn, visitId);

      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }

      final response = await fetchWithRetry(
        () => query
            .order('counseling_date', ascending: false)
            .order('created_at', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) {
        AppLogger.e(
          'counseling_records table missing — run counseling migration',
          e,
        );
        return [];
      }
      AppLogger.e('Error fetching visit counseling records', e);
      return [];
    } catch (e) {
      AppLogger.e('Error fetching visit counseling records', e);
      return [];
    }
  }

  /// Saves one counseling record.
  ///
  /// Expected keys in [recordData]: `patient_id`, `visit_type` (`opd`/`ipd`),
  /// `counseling_date`, `transcript_text`, `summary_text`, `doctor_id`, and
  /// the visit link — `opd_registration_id` for OPD or `ipd_admission_id` for
  /// IPD. `hospital_id` is added automatically from the tenant when not
  /// present.
  Future<Map<String, dynamic>> saveCounselingRecord(
    Map<String, dynamic> recordData, {
    String? hospitalId,
  }) async {
    final payload = _tenantPayload(
      recordData,
      hospitalId,
      table: ApiConstants.counselingRecordsTable,
    );
    payload['counseling_date'] ??= DateTime.now().toIso8601String().split(
      'T',
    )[0];
    payload['created_at'] ??= DateTime.now().toUtc().toIso8601String();

    try {
      return await fetchWithRetry(
        () => _client
            .from(ApiConstants.counselingRecordsTable)
            .insert(payload)
            .select()
            .single(),
      );
    } catch (e) {
      AppLogger.e('Error saving counseling record', e);
      rethrow;
    }
  }

  /// Returns the latest counseling record for [patientId], or null when none
  /// exists (or the table migration is still pending).
  Future<Map<String, dynamic>?> getLatestCounselingRecord(
    String patientId, {
    String? hospitalId,
  }) async {
    try {
      var query = _client
          .from(ApiConstants.counselingRecordsTable)
          .select()
          .eq('patient_id', patientId);

      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }

      return await fetchWithRetry(
        () => query
            .order('counseling_date', ascending: false)
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle(),
      );
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) {
        AppLogger.e(
          'counseling_records table missing — run counseling migration',
          e,
        );
        return null;
      }
      AppLogger.e('Error fetching latest counseling record', e);
      return null;
    } catch (e) {
      AppLogger.e('Error fetching latest counseling record', e);
      return null;
    }
  }

  /// Returns one counseling record by id, or null when missing / the table
  /// migration is still pending.
  Future<Map<String, dynamic>?> getCounselingRecordById(
    String recordId, {
    String? hospitalId,
  }) async {
    try {
      var query = _client
          .from(ApiConstants.counselingRecordsTable)
          .select('*, users(first_name, last_name)')
          .eq('id', recordId);

      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }

      return await fetchWithRetry(() => query.maybeSingle());
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) {
        AppLogger.e(
          'counseling_records table missing — run counseling migration',
          e,
        );
        return null;
      }
      AppLogger.e('Error fetching counseling record by id', e);
      return null;
    } catch (e) {
      AppLogger.e('Error fetching counseling record by id', e);
      return null;
    }
  }

  /// Updates one counseling record (e.g. duration after a recording).
  Future<Map<String, dynamic>> updateCounselingRecord(
    String recordId,
    Map<String, dynamic> data, {
    String? hospitalId,
  }) async {
    final payload = Map<String, dynamic>.from(data);
    payload['updated_at'] = DateTime.now().toUtc().toIso8601String();
    try {
      return await fetchWithRetry(
        () => _client
            .from(ApiConstants.counselingRecordsTable)
            .update(payload)
            .eq('id', recordId)
            .select()
            .single(),
      );
    } catch (e) {
      AppLogger.e('Error updating counseling record', e);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Counseling Media (video/audio recordings + GPS stamp)
  // ---------------------------------------------------------------------------

  /// Saves one recording row (`video` / `audio`) into `counseling_media`.
  Future<Map<String, dynamic>> saveCounselingMedia(
    Map<String, dynamic> mediaData, {
    String? hospitalId,
  }) async {
    final payload = _tenantPayload(
      mediaData,
      hospitalId,
      table: ApiConstants.counselingMediaTable,
    );
    payload['recorded_at'] ??= DateTime.now().toUtc().toIso8601String();
    payload['created_at'] ??= DateTime.now().toUtc().toIso8601String();
    try {
      return await fetchWithRetry(
        () => _client
            .from(ApiConstants.counselingMediaTable)
            .insert(payload)
            .select()
            .single(),
      );
    } catch (e) {
      AppLogger.e('Error saving counseling media', e);
      rethrow;
    }
  }

  /// Returns media files linked to one counseling record.
  Future<List<Map<String, dynamic>>> getCounselingMediaForRecord(
    String recordId,
  ) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.counselingMediaTable)
            .select()
            .eq('counseling_record_id', recordId)
            .order('created_at', ascending: true),
      );
      return List<Map<String, dynamic>>.from(response);
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) return [];
      AppLogger.e('Error fetching counseling media', e);
      return [];
    } catch (e) {
      AppLogger.e('Error fetching counseling media', e);
      return [];
    }
  }

  /// Returns every media file recorded for a patient, newest first.
  Future<List<Map<String, dynamic>>> getCounselingMediaByPatient(
    String patientId, {
    String? hospitalId,
  }) async {
    try {
      var query = _client
          .from(ApiConstants.counselingMediaTable)
          .select()
          .eq('patient_id', patientId);
      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }
      final response = await fetchWithRetry(
        () => query.order('recorded_at', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) return [];
      AppLogger.e('Error fetching counseling media by patient', e);
      return [];
    } catch (e) {
      AppLogger.e('Error fetching counseling media by patient', e);
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Counseling Consent Management
  // ---------------------------------------------------------------------------

  /// Saves a consent form row into `counseling_consents`.
  Future<Map<String, dynamic>> saveCounselingConsent(
    Map<String, dynamic> consentData, {
    String? hospitalId,
  }) async {
    final payload = _tenantPayload(
      consentData,
      hospitalId,
      table: ApiConstants.counselingConsentsTable,
    );
    payload['consent_date'] ??= DateTime.now().toIso8601String().split('T')[0];
    payload['created_at'] ??= DateTime.now().toUtc().toIso8601String();
    payload['updated_at'] ??= DateTime.now().toUtc().toIso8601String();
    try {
      return await fetchWithRetry(
        () => _client
            .from(ApiConstants.counselingConsentsTable)
            .insert(payload)
            .select()
            .single(),
      );
    } catch (e) {
      AppLogger.e('Error saving counseling consent', e);
      rethrow;
    }
  }

  /// Updates a consent row (used to record signature / status changes).
  Future<Map<String, dynamic>> updateCounselingConsent(
    String consentId,
    Map<String, dynamic> data,
  ) async {
    final payload = Map<String, dynamic>.from(data);
    payload['updated_at'] = DateTime.now().toUtc().toIso8601String();
    try {
      return await fetchWithRetry(
        () => _client
            .from(ApiConstants.counselingConsentsTable)
            .update(payload)
            .eq('id', consentId)
            .select()
            .single(),
      );
    } catch (e) {
      AppLogger.e('Error updating counseling consent', e);
      rethrow;
    }
  }

  /// Latest consent linked to one counseling record.
  Future<Map<String, dynamic>?> getCounselingConsentForRecord(
    String recordId,
  ) async {
    try {
      return await fetchWithRetry(
        () => _client
            .from(ApiConstants.counselingConsentsTable)
            .select()
            .eq('counseling_record_id', recordId)
            .order('consent_version', ascending: false)
            .limit(1)
            .maybeSingle(),
      );
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) return null;
      AppLogger.e('Error fetching counseling consent', e);
      return null;
    } catch (e) {
      AppLogger.e('Error fetching counseling consent', e);
      return null;
    }
  }

  /// Every consent generated for a patient, newest first.
  Future<List<Map<String, dynamic>>> getCounselingConsentsByPatient(
    String patientId, {
    String? hospitalId,
  }) async {
    try {
      var query = _client
          .from(ApiConstants.counselingConsentsTable)
          .select()
          .eq('patient_id', patientId);
      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }
      final response = await fetchWithRetry(
        () => query.order('created_at', ascending: false),
      );
      return List<Map<String, dynamic>>.from(response);
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) return [];
      AppLogger.e('Error fetching counseling consents', e);
      return [];
    } catch (e) {
      AppLogger.e('Error fetching counseling consents', e);
      return [];
    }
  }

  /// Merged session history for the counseling module:
  /// each record carries its `media` list and latest `consent`.
  Future<List<Map<String, dynamic>>> getCounselingSessionHistory(
    String patientId, {
    String? hospitalId,
  }) async {
    final records = await getCounselingRecords(
      patientId,
      hospitalId: hospitalId,
    );
    final media = await getCounselingMediaByPatient(
      patientId,
      hospitalId: hospitalId,
    );
    final consents = await getCounselingConsentsByPatient(
      patientId,
      hospitalId: hospitalId,
    );

    return records.map((record) {
      final recordId = record['id']?.toString() ?? '';
      final recordMedia = media
          .where((m) => m['counseling_record_id']?.toString() == recordId)
          .toList();
      final recordConsents =
          consents
              .where((c) => c['counseling_record_id']?.toString() == recordId)
              .toList()
            ..sort(
              (a, b) => ((b['consent_version'] as int?) ?? 0).compareTo(
                (a['consent_version'] as int?) ?? 0,
              ),
            );
      return <String, dynamic>{
        ...record,
        'media': recordMedia,
        'consent': recordConsents.isEmpty ? null : recordConsents.first,
      };
    }).toList();
  }

  /// Merged session history for one specific visit/admission (OPD or IPD).
  /// Each record carries its `media` list and latest `consent`; the list is
  /// already sorted newest-first by [getCounselingRecordsByVisit].
  Future<List<Map<String, dynamic>>> getCounselingSessionHistoryByVisit({
    required String patientId,
    required String visitType,
    String? opdRegistrationId,
    String? ipdAdmissionId,
    String? hospitalId,
  }) async {
    final records = await getCounselingRecordsByVisit(
      visitType: visitType,
      opdRegistrationId: opdRegistrationId,
      ipdAdmissionId: ipdAdmissionId,
      hospitalId: hospitalId,
    );
    if (records.isEmpty) return [];

    final media = await getCounselingMediaByPatient(
      patientId,
      hospitalId: hospitalId,
    );
    final consents = await getCounselingConsentsByPatient(
      patientId,
      hospitalId: hospitalId,
    );

    return records.map((record) {
      final recordId = record['id']?.toString() ?? '';
      final recordMedia = media
          .where((m) => m['counseling_record_id']?.toString() == recordId)
          .toList();
      final recordConsents =
          consents
              .where((c) => c['counseling_record_id']?.toString() == recordId)
              .toList()
            ..sort(
              (a, b) => ((b['consent_version'] as int?) ?? 0).compareTo(
                (a['consent_version'] as int?) ?? 0,
              ),
            );
      return <String, dynamic>{
        ...record,
        'media': recordMedia,
        'consent': recordConsents.isEmpty ? null : recordConsents.first,
      };
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Notifications & Push Notification Device Tokens
  // ---------------------------------------------------------------------------

  /// True jab PostgREST error "table/resource API ko nahi mili" ho.
  ///
  /// Supabase ka API gateway kabhi-kabhi underlying Postgres error
  /// (`42P01 relation does not exist` / `PGRST205`) ki jagah generic message
  /// `"Failed to retrieve the requested resource"` return karta hai. Isliye
  /// sirf message text par depend nahi karte — `code` + message dono check
  /// karte hain taaki missing-table cases hamesha gracefully handle hon.
  bool _isMissingTableError(PostgrestException e) {
    final message = e.message.toLowerCase();
    return e.code == 'PGRST205' ||
        e.code == '42P01' ||
        message.contains('could not find the table') ||
        message.contains('failed to retrieve the requested resource') ||
        (message.contains('relation') && message.contains('does not exist'));
  }

  /// Returns notifications for [userId], newest first.
  ///
  /// [unreadOnly] sirf unread rows laata hai. Notification migration abhi
  /// apply nahi hui ho toh empty list return hoti hai (app crash nahi hota).
  Future<List<Map<String, dynamic>>> getNotifications(
    String userId, {
    String? hospitalId,
    String? notificationType,
    int limit = 100,
    bool unreadOnly = false,
  }) async {
    try {
      dynamic query = _client
          .from(ApiConstants.notificationsTable)
          .select()
          .eq('user_id', userId);

      if (hospitalId != null && hospitalId.isNotEmpty) {
        query = query.eq('hospital_id', hospitalId);
      }
      if (notificationType != null && notificationType.isNotEmpty) {
        query = query.eq('notification_type', notificationType);
      }
      if (unreadOnly) {
        query = query.eq('is_read', false);
      }

      final response = await fetchWithRetry(
        () => query.order('created_at', ascending: false).limit(limit),
      );
      return List<Map<String, dynamic>>.from(response);
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) {
        AppLogger.e(
          'notifications table missing — run notifications migration',
          e,
        );
        return [];
      }
      AppLogger.e('Error fetching notifications', e);
      return [];
    } catch (e) {
      AppLogger.e('Error fetching notifications', e);
      return [];
    }
  }

  /// Returns the latest notifications for a user (dashboard/badge use).
  ///
  /// [userId] null hone par current logged-in user automatically resolve hota
  /// hai.
  Future<List<Map<String, dynamic>>> getRecentNotifications({
    String? userId,
    String? hospitalId,
    int limit = 10,
  }) async {
    final resolvedUserId = userId ?? await getCurrentUsersTableId();
    if (resolvedUserId == null || resolvedUserId.isEmpty) return [];
    return getNotifications(
      resolvedUserId,
      hospitalId: hospitalId,
      limit: limit,
    );
  }

  /// Unread notification count for [userId] (header badge ke liye).
  Future<int> getUnreadNotificationCount(String userId) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.notificationsTable)
            .select('id')
            .eq('user_id', userId)
            .eq('is_read', false)
            .count(CountOption.exact),
      );
      return response.count;
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) {
        return 0;
      }
      AppLogger.e('Error fetching unread notification count', e);
      return 0;
    } catch (e) {
      AppLogger.e('Error fetching unread notification count', e);
      return 0;
    }
  }

  /// Marks one notification as read (`is_read = true`, `read_at = now`).
  Future<void> markNotificationAsRead(String notificationId) async {
    try {
      await fetchWithRetry(
        () => _client
            .from(ApiConstants.notificationsTable)
            .update({
              'is_read': true,
              'read_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', notificationId),
      );
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) {
        AppLogger.e(
          'notifications table missing — run notifications migration',
          e,
        );
        return;
      }
      AppLogger.e('Error marking notification as read', e);
    }
  }

  /// Marks every notification of a user as read.
  Future<void> markAllNotificationsAsRead(String userId) async {
    try {
      await fetchWithRetry(
        () => _client
            .from(ApiConstants.notificationsTable)
            .update({
              'is_read': true,
              'read_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('user_id', userId)
            .eq('is_read', false),
      );
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) {
        AppLogger.e(
          'notifications table missing — run notifications migration',
          e,
        );
        return;
      }
      AppLogger.e('Error marking all notifications as read', e);
    }
  }

  /// Creates one in-app notification row.
  Future<Map<String, dynamic>> createNotification({
    required String hospitalId,
    String? userId,
    required String title,
    required String message,
    required String notificationType,
    String? linkUrl,
  }) async {
    try {
      final response = await fetchWithRetry(
        () => _client
            .from(ApiConstants.notificationsTable)
            .insert({
              'hospital_id': hospitalId,
              'user_id': userId,
              'title': title,
              'message': message,
              'notification_type': notificationType,
              'is_read': false,
              'link_url': linkUrl,
            })
            .select()
            .single(),
      );
      return response;
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) {
        AppLogger.e(
          'notifications table missing — run notifications migration',
          e,
        );
        return const {};
      }
      AppLogger.e('Error creating notification', e);
      rethrow;
    }
  }

  /// Creates one notification row from a generic data map.
  ///
  /// Expected keys: `hospital_id` (required), `user_id`, `title`, `message`,
  /// `notification_type`, `link_url` (optional).
  Future<Map<String, dynamic>> sendNotification(
    Map<String, dynamic> notificationData,
  ) {
    return createNotification(
      hospitalId: (notificationData['hospital_id'] as String? ?? '').trim(),
      userId: notificationData['user_id'] as String?,
      title: notificationData['title'] as String? ?? 'Notification',
      message: notificationData['message'] as String? ?? '',
      notificationType:
          notificationData['notification_type'] as String? ?? 'info',
      linkUrl: notificationData['link_url'] as String?,
    );
  }

  /// Supabase Edge Function invoke karta hai (e.g. `send-fcm` Firebase Admin
  /// SDK ke liye). Timeout/retry logic ke saath.
  Future<FunctionResponse> invokeEdgeFunction(
    String functionName, {
    Map<String, dynamic>? body,
  }) {
    return fetchWithRetry(
      () => _client.functions.invoke(functionName, body: body),
    );
  }

  /// Returns active staff members of a hospital (optionally filtered by role).
  ///
  /// Roles jaise `doctor`, `nurse`, `receptionist` — in-app notification fan-out
  /// ke liye use hota hai.
  Future<List<Map<String, dynamic>>> getHospitalStaffUsers(
    String hospitalId, {
    List<String>? roles,
  }) async {
    try {
      dynamic query = _client
          .from(ApiConstants.usersTable)
          .select('id, hospital_id, first_name, last_name, role, email, phone')
          .eq('hospital_id', hospitalId)
          .eq('is_active', true);

      if (roles != null && roles.isNotEmpty) {
        query = query.inFilter('role', roles);
      }

      final response = await fetchWithRetry(
        () => query.order('first_name', ascending: true),
      );
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      AppLogger.e('Error fetching hospital staff', e);
      return [];
    }
  }

  /// Upserts a device token into `user_devices` (registration + token update
  /// dono yahin handle hote hain).
  Future<void> saveDeviceToken({
    required String userId,
    required String fcmToken,
    String? hospitalId,
    String? platform,
    String? appVersion,
  }) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();

      final existing = await _client
          .from(ApiConstants.userDevicesTable)
          .select('id')
          .eq('fcm_token', fcmToken)
          .maybeSingle();

      if (existing != null) {
        await _client
            .from(ApiConstants.userDevicesTable)
            .update({
              'user_id': userId,
              'hospital_id': hospitalId,
              'platform': platform,
              'app_version': appVersion,
              'last_seen_at': now,
              'updated_at': now,
            })
            .eq('id', existing['id']);
        return;
      }

      await _client.from(ApiConstants.userDevicesTable).insert({
        'user_id': userId,
        'hospital_id': hospitalId,
        'fcm_token': fcmToken,
        'platform': platform,
        'app_version': appVersion,
        'last_seen_at': now,
      });
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) {
        AppLogger.e(
          'user_devices table missing — run notifications migration',
          e,
        );
        return;
      }
      AppLogger.e('Error saving device token', e);
    }
  }

  /// Deletes a device token row (logout / uninstall par).
  Future<void> removeDeviceToken(String fcmToken) async {
    try {
      await fetchWithRetry(
        () => _client
            .from(ApiConstants.userDevicesTable)
            .delete()
            .eq('fcm_token', fcmToken),
      );
    } on PostgrestException catch (e) {
      if (_isMissingTableError(e)) {
        AppLogger.e(
          'user_devices table missing — run notifications migration',
          e,
        );
        return;
      }
      AppLogger.e('Error removing device token', e);
    }
  }

  // ---------------------------------------------------------------------------
  // Reports Module
  // ---------------------------------------------------------------------------

  /// All generated reports for a hospital, newest first. Rows are enriched
  /// with a `generated_by_name` key (from the `users` table) so the list UI
  /// never has to do N+1 lookups itself.
  Future<List<Map<String, dynamic>>> getReports({
    required String hospitalId,
  }) async {
    try {
      final rows = await _fetchReportRows(
        hospitalId: hospitalId,
        reportId: null,
      );
      await _enrichReportsWithUserNames(rows);
      return rows;
    } catch (e) {
      AppLogger.e('Error fetching reports', e);
      rethrow;
    }
  }

  /// One report by id (may be null when not found). The returned row includes
  /// `generated_by_name` when the joined user lookup succeeds.
  Future<Map<String, dynamic>?> getReportById(String reportId) async {
    try {
      final rows = await _fetchReportRows(reportId: reportId);
      if (rows.isEmpty) return null;
      await _enrichReportsWithUserNames(rows);
      return rows.first;
    } catch (e) {
      AppLogger.e('Error fetching report by id', e);
      rethrow;
    }
  }

  /// Shared PostgREST query for report rows.
  ///
  /// A join on `users(first_name, last_name)` is attempted first (nice
  /// single-query `generated_by` names); when the FK alias isn't configured
  /// it falls back to a plain select. Both paths are tenant-safe.
  Future<List<Map<String, dynamic>>> _fetchReportRows({
    String? hospitalId,
    String? reportId,
  }) async {
    try {
      return await _runReportQuery(
        select: '*, users(first_name, last_name)',
        hospitalId: hospitalId,
        reportId: reportId,
      );
    } on PostgrestException catch (e) {
      // Reports table may not expose the `users` FK alias — retry without join.
      AppLogger.w('Reports join failed, falling back to plain select: $e');
      return _runReportQuery(
        select: '*',
        hospitalId: hospitalId,
        reportId: reportId,
      );
    }
  }

  Future<List<Map<String, dynamic>>> _runReportQuery({
    required String select,
    String? hospitalId,
    String? reportId,
  }) async {
    dynamic query = _client.from(ApiConstants.reportsTable).select(select);
    if (hospitalId != null && hospitalId.isNotEmpty) {
      query = query.eq('hospital_id', hospitalId);
    }
    if (reportId != null && reportId.isNotEmpty) {
      query = query.eq('id', reportId);
    }
    query = query.order('created_at', ascending: false);
    final response = await fetchWithRetry(() => query);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Fills `generated_by_name` on every row. When the joined `users` object is
  /// missing, all distinct `generated_by` ids are resolved with one `inFilter`
  /// query so large lists stay cheap.
  Future<void> _enrichReportsWithUserNames(
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return;

    String fullName(String? first, String? last) =>
        '${first ?? ''} ${last ?? ''}'.trim();

    final unresolvedIds = <String>[];
    for (final row in rows) {
      final joinedUser = row['users'];
      if (joinedUser is Map) {
        final name = fullName(
          joinedUser['first_name']?.toString(),
          joinedUser['last_name']?.toString(),
        );
        if (name.isNotEmpty) {
          row['generated_by_name'] = name;
          continue;
        }
      }
      final id = row['generated_by']?.toString();
      if (id != null && id.isNotEmpty) {
        unresolvedIds.add(id);
      }
    }

    if (unresolvedIds.isEmpty) return;

    try {
      final users = await fetchWithRetry(
        () => _client
            .from(ApiConstants.usersTable)
            .select('id, first_name, last_name')
            .inFilter('id', unresolvedIds.toSet().toList()),
      );
      final nameById = <String, String?>{
        for (final user in users)
          user['id']?.toString() ?? '': fullName(
            user['first_name']?.toString(),
            user['last_name']?.toString(),
          ),
      };
      for (final row in rows) {
        if (row['generated_by_name'] == null) {
          row['generated_by_name'] =
              nameById[row['generated_by']?.toString() ?? ''];
        }
      }
    } catch (e) {
      // User-name enrichment is cosmetic; report list must still render.
      AppLogger.w('Could not enrich report generated_by names: $e');
    }
  }
}
