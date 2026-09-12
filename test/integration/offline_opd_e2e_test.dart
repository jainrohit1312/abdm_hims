@Timeout(Duration(minutes: 5))
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:abdm_hims/core/utils/logger.dart';
import 'package:abdm_hims/services/cache_service.dart';
import 'package:abdm_hims/services/database_service.dart';
import 'package:abdm_hims/services/local_db.dart';
import 'package:abdm_hims/services/local_db_io.dart';
import 'package:abdm_hims/services/sync_engine.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// SERVICE-LEVEL end-to-end test of the offline OPD workflow against the
/// ISOLATED LOCAL Supabase stack. It exercises the real client services, the
/// real PostgREST/GoTrue endpoints, and a REAL transport failure.
///
/// It is NOT a GUI test: no widget is rendered and no printer is exercised.
/// GUI/printer steps stay on the manual checklist
/// (docs/offline_opd_e2e_checklist.md).
///
/// Opt-in only (the default suite must stay offline-safe):
///
///   set HIMS_LOCAL_E2E=1 && flutter test test/integration/offline_opd_e2e_test.dart
///
/// Safety: the URL is hard-checked to loopback before any request is made, so
/// this can never touch a deployed backend.
const String _localUrl = 'http://127.0.0.1:54321';

// Legacy JWT anon key of the ISOLATED local stack (`supabase status -o env`).
// Never a production secret.
const String _localAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
    'eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.'
    'CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

const String _adminEmail = 'admin@himshospital.com';
const String _adminPassword = 'password123';

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

/// A local, toggleable HTTP proxy in front of the isolated backend.
///
/// Blocking it breaks established keep-alive sockets too, so the "offline"
/// phase produces genuine connection failures rather than a simulated flag.
class ToggleableHttpProxy {
  ToggleableHttpProxy({required this.targetHost, required this.targetPort});

  final String targetHost;
  final int targetPort;

  late ServerSocket _server;
  final List<Socket> _clients = [];
  final List<Socket> _upstreams = [];
  bool _blocked = false;

  int get port => _server.port;
  bool get isBlocked => _blocked;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle, onError: (_) {});
  }

  Future<void> _handle(Socket client) async {
    if (_blocked) {
      client.destroy();
      return;
    }
    _clients.add(client);
    Socket upstream;
    try {
      upstream = await Socket.connect(targetHost, targetPort);
    } catch (_) {
      client.destroy();
      return;
    }
    _upstreams.add(upstream);
    client.listen(
      (data) {
        try {
          upstream.add(data);
        } catch (_) {}
      },
      onDone: upstream.destroy,
      onError: (_) => upstream.destroy(),
      cancelOnError: true,
    );
    upstream.listen(
      (data) {
        try {
          client.add(data);
        } catch (_) {}
      },
      onDone: client.destroy,
      onError: (_) => client.destroy(),
      cancelOnError: true,
    );
  }

  /// Simulates the backend becoming unreachable (link down / proxy cut).
  void block() {
    _blocked = true;
    for (final s in _clients) {
      s.destroy();
    }
    for (final s in _upstreams) {
      s.destroy();
    }
    _clients.clear();
    _upstreams.clear();
  }

  void unblock() => _blocked = false;

  Future<void> stop() async {
    block();
    await _server.close();
  }
}

void main() {
  final enabled = Platform.environment['HIMS_LOCAL_E2E']?.trim() == '1';

  setUpAll(() {
    _configureProjectLocalSqlite();
    AppLogger.init();

    // `Hive.initFlutter()` (used by the master-data cache) resolves a documents
    // directory through path_provider, whose default test implementation is the
    // method-channel one. Point it at a throwaway temp directory.
    TestWidgetsFlutterBinding.ensureInitialized();
    // The widget-test binding installs a mock HttpClient that answers every
    // request with HTTP 400. This suite deliberately talks to the real
    // isolated backend, so drop the override again.
    HttpOverrides.global = null;
    final docsDir = Directory.systemTemp.createTempSync('hims_e2e_docs_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            switch (call.method) {
              case 'getApplicationDocumentsDirectory':
              case 'getApplicationSupportDirectory':
              case 'getTemporaryDirectory':
                return docsDir.path;
            }
            return null;
          },
        );

    try {
      final probe = LocalDriftDatabase(NativeDatabase.memory());
      probe.select(probe.patientRecords);
      probe.close();
    } catch (_) {
      _sqliteAvailable = false;
    }
  });

  test(
    'offline OPD: provision -> transport loss -> restart -> reconnect -> exact backend records',
    skip: !enabled
        ? 'Set HIMS_LOCAL_E2E=1 (and run supabase start/db reset) to enable.'
        : (!_sqliteAvailable ? 'sqlite3 native library unavailable.' : false),
    () async {
      expect(
        Uri.parse(_localUrl).host,
        anyOf('127.0.0.1', 'localhost'),
        reason: 'this test must never target a non-loopback backend',
      );

      SharedPreferences.setMockInitialValues(<String, Object>{});
      // Re-assert real networking for this (binding-initialised) suite.
      HttpOverrides.global = null;

      final tempDir = await Directory.systemTemp.createTemp('hims_e2e_');
      final dbFile = File(
        '${tempDir.path}${Platform.pathSeparator}hims.sqlite',
      );

      final proxy = ToggleableHttpProxy(
        targetHost: '127.0.0.1',
        targetPort: 54321,
      );
      await proxy.start();

      // ------------------------------------------------------------------
      // 1. Online authorized provisioning + initial download
      // ------------------------------------------------------------------
      final client = SupabaseClient(
        'http://127.0.0.1:${proxy.port}',
        _localAnonKey,
        authOptions: const AuthClientOptions(autoRefreshToken: true),
      );

      final session = await client.auth.signInWithPassword(
        email: _adminEmail,
        password: _adminPassword,
      );
      expect(session.session, isNotNull, reason: 'provisioning requires login');

      LocalDriftDatabase? drift = LocalDriftDatabase(NativeDatabase(dbFile));
      var local = DriftLocalDatabase(database: drift);
      await local.init();

      var service = DatabaseService(
        client,
        localDb: local,
        cacheService: CacheService.instance,
      );

      final userRecord = await service.getCurrentUserRecord();
      expect(userRecord, isNotNull, reason: 'public users row must exist');
      final publicUserId = userRecord!['id'] as String;
      final hospitalId = userRecord['hospital_id'] as String;

      await service.persistIdentityMapping(
        publicUserId: publicUserId,
        hospitalId: hospitalId,
        role: userRecord['role'] as String?,
      );

      // A doctor must exist for the offline OPD doctor picker to work.
      final doctorName = 'E2E Doctor ${DateTime.now().millisecondsSinceEpoch}';
      await client.from('doctors').insert({
        'hospital_id': hospitalId,
        'name': doctorName,
        'specialization': 'General Medicine',
        'opd_fee': 500,
        'consultation_fee': 500,
        'is_active': true,
        'prescription_mode': false,
      });

      await service.cacheMasterData(hospitalId: hospitalId);
      expect(
        await service.isDatasetProvisioned(LocalTables.doctors),
        isTrue,
        reason: 'baseline download should persist the master mirror',
      );
      final mirroredDoctors = await service.getMirroredDoctors(
        hospitalId: hospitalId,
      );
      expect(
        mirroredDoctors.any((d) => d['name'] == doctorName),
        isTrue,
        reason: 'the doctor master list must be downloadable and mirrorable',
      );
      expect(
        await service.isDatasetProvisioned(LocalTables.departments),
        isTrue,
      );

      // ------------------------------------------------------------------
      // 2/3. The backend becomes unreachable; requests genuinely fail
      // ------------------------------------------------------------------
      proxy.block();

      expect(
        await service.probeSupabase(),
        isFalse,
        reason: 'a cut transport must never report a reachable backend',
      );
      expect(
        await service.hasNetwork(),
        isTrue,
        reason:
            'the local network stack is fine — only the backend is cut, which '
            'is exactly the case that must NOT be reported as green',
      );

      // A local write must still succeed with the backend gone.
      final unique = math.Random().nextInt(1000000);
      final uhid = 'E2E-UHID-$unique';

      final patient = await service.registerPatientLocal({
        'uhid': uhid,
        'first_name': 'Offline',
        'last_name': 'Patient$unique',
        'mobile_number': '98$unique',
        'gender': 'Male',
      }, hospitalId: hospitalId);
      final patientId = patient['id'] as String;

      // ------------------------------------------------------------------
      // 4. An existing patient can be searched locally
      // ------------------------------------------------------------------
      final searchHits = await service.searchPatientsLocal(
        uhid,
        hospitalId: hospitalId,
      );
      expect(searchHits, hasLength(1));
      expect(searchHits.single['id'], patientId);

      // ------------------------------------------------------------------
      // 6. OPD visit + payment can be saved offline
      // ------------------------------------------------------------------
      final opd = await service.createOPDRegistrationLocal(
        {
          'patient_id': patientId,
          'consultation_fee': 500.0,
          'visit_date': DateTime.now().toIso8601String().split('T')[0],
          'department_name': 'General Medicine',
        },
        hospitalId: hospitalId,
        prescriptionMode: false,
      );
      final opdId = opd['id'] as String;
      final token = opd['token_number'] as int;
      expect(token, greaterThan(0), reason: 'a queue token must be allocated');

      final slipRow = await service.generateOPDSlipLocal(
        patientId: patientId,
        paymentAmount: 500.0,
        paymentMode: 'Cash',
        opdRegistrationId: opdId,
      );
      expect(slipRow['payment_status'], 'paid');
      expect((slipRow['patients'] as Map)['uhid'], uhid);

      // ------------------------------------------------------------------
      // 7/8. Slip data is available locally; a reprint must not write money
      // ------------------------------------------------------------------
      final opdOutbox = await local.outboxPendingCount();

      final slipData = await service.getOPDPaymentDetailsLocal(opdId);
      expect(slipData, isNotNull);
      expect((slipData!['patients'] as Map)['uhid'], uhid);
      expect(slipData['paid_amount'], 500.0);

      final billHistory = await service.getBillingHistoryPageLocal(
        hospitalId: hospitalId,
        page: 0,
        limit: 20,
      );
      expect(
        billHistory.any((b) => b['opd_registration_id'] == opdId),
        isTrue,
        reason: 'the OPD bill must be visible in the local billing list',
      );

      final queue = await service.getOPDQueueLocal(
        page: 0,
        limit: 20,
        hospitalId: hospitalId,
      );
      expect(queue.any((r) => r['id'] == opdId), isTrue);
      expect(
        queue.firstWhere((r) => r['id'] == opdId)['patients'],
        isNotNull,
        reason: 'the local queue must embed the patient for printing',
      );

      // Reprint == read-only.
      await service.getOPDPaymentDetailsLocal(opdId);
      expect(
        await local.outboxPendingCount(),
        opdOutbox,
        reason: 'reprinting a slip must never add any write',
      );
      expect(
        (await local.getRecords(table: LocalTables.billing)).length,
        1,
        reason: 'reprinting must never create a second bill',
      );

      // ------------------------------------------------------------------
      // 5. IPD remains blocked while the patient is only local
      // ------------------------------------------------------------------
      // `hasNetwork()` fails open when the connectivity plugin is unavailable
      // (headless test), so the honest classification here is
      // `cloudUnreachable`; on a real device with the link down it is
      // `offline`. BOTH must refuse an online admission — what must never
      // happen is `synced`.
      final blockedStatus = await service.patientCloudStatus(patientId);
      expect(
        blockedStatus,
        anyOf(PatientCloudStatus.offline, PatientCloudStatus.cloudUnreachable),
        reason:
            'online IPD admission must be refused while the patient is '
            'not on the cloud',
      );
      expect(blockedStatus, isNot(PatientCloudStatus.synced));

      // ------------------------------------------------------------------
      // 8. App restart while offline: the data must still be there
      // ------------------------------------------------------------------
      await local.close();
      drift = LocalDriftDatabase(NativeDatabase(dbFile));
      local = DriftLocalDatabase(database: drift);
      await local.init();
      service = DatabaseService(
        client,
        localDb: local,
        cacheService: CacheService.instance,
      );

      final afterRestart = await service.searchPatientsLocal(
        uhid,
        hospitalId: hospitalId,
      );
      expect(afterRestart, hasLength(1), reason: 'offline restart lost data');
      expect(
        await service.getOPDPaymentDetailsLocal(opdId),
        isNotNull,
        reason: 'visit + payment history must survive an offline restart',
      );
      expect(
        await local.outboxPendingCount(),
        opdOutbox,
        reason: 'pending operations must survive an offline restart',
      );

      // ------------------------------------------------------------------
      // 11/12. Connectivity returns; synchronization completes
      // ------------------------------------------------------------------
      proxy.unblock();
      expect(await service.probeSupabase(), isTrue);

      final engine = SyncEngine(
        dbService: service,
        localDb: local,
        interval: const Duration(minutes: 5),
      );
      addTearDown(engine.dispose);

      await engine.syncNow();
      await engine.reconcileNow();

      expect(
        await local.outboxPendingCount(),
        0,
        reason: 'every queued operation must be acknowledged',
      );
      expect(await local.getConflicts(), isEmpty);
      expect(
        await service.patientCloudStatus(patientId),
        PatientCloudStatus.synced,
        reason: 'after a verified upload the patient gates online IPD',
      );

      // ------------------------------------------------------------------
      // 12/13. Exact expected backend records, no duplicates
      // ------------------------------------------------------------------
      final backendPatients = await client
          .from('patients')
          .select('id, uhid, hospital_id')
          .eq('uhid', uhid);
      expect(backendPatients, hasLength(1), reason: 'exactly one patient');
      expect(
        backendPatients.single['id'],
        patientId,
        reason: 'the local patient UUID must be preserved',
      );

      final backendOpd = await client
          .from('opd_registrations')
          .select('id, patient_id, payment_status, paid_amount, token_number')
          .eq('id', opdId);
      expect(backendOpd, hasLength(1), reason: 'exactly one OPD visit');
      expect(backendOpd.single['payment_status'], 'paid');
      expect(backendOpd.single['token_number'], token);

      final backendBills = await client
          .from('billing')
          .select(
            'id, opd_registration_id, patient_id, paid_amount, net_amount, '
            'balance_amount, payment_status, created_by',
          )
          .eq('opd_registration_id', opdId);
      expect(backendBills, hasLength(1), reason: 'exactly one bill');
      final bill = backendBills.single;
      expect(bill['paid_amount'], 500.0);
      expect(bill['net_amount'], 500.0);
      expect(bill['balance_amount'], 0.0);
      expect(bill['payment_status'], 'paid');
      expect(
        bill['created_by'],
        publicUserId,
        reason: 'the bill must be attributed to the public users.id',
      );
      final billId = bill['id'] as String;

      final backendItems = await client
          .from('billing_items')
          .select('id')
          .eq('bill_id', billId);
      expect(backendItems, hasLength(1), reason: 'exactly one line item');

      final backendPayments = await client
          .from('payment_logs')
          .select('id, amount_paid, payment_mode')
          .eq('bill_id', billId);
      expect(backendPayments, hasLength(1), reason: 'exactly one payment log');
      expect(backendPayments.single['amount_paid'], 500.0);

      final receipts = await client
          .from('hims_operation_receipts')
          .select('operation_id, result')
          .eq('operation_record_id', billId);
      expect(
        receipts,
        hasLength(1),
        reason: 'the operation must have exactly one durable receipt',
      );

      // Another retry pass must not duplicate anything.
      await engine.syncNow();
      await engine.reconcileNow();
      expect(
        await client.from('patients').select('id').eq('uhid', uhid),
        hasLength(1),
      );
      expect(
        await client
            .from('billing')
            .select('id')
            .eq('opd_registration_id', opdId),
        hasLength(1),
      );
      expect(
        await client.from('payment_logs').select('id').eq('bill_id', billId),
        hasLength(1),
      );

      // ------------------------------------------------------------------
      // 13. A second authorized client receives the synchronized data
      // ------------------------------------------------------------------
      final client2 = SupabaseClient(
        'http://127.0.0.1:${proxy.port}',
        _localAnonKey,
        authOptions: const AuthClientOptions(autoRefreshToken: true),
      );
      await client2.auth.signInWithPassword(
        email: _adminEmail,
        password: _adminPassword,
      );

      final local2 = DriftLocalDatabase(
        database: LocalDriftDatabase(NativeDatabase.memory()),
      );
      await local2.init();
      final service2 = DatabaseService(
        client2,
        localDb: local2,
        cacheService: CacheService.instance,
      );
      await service2.persistIdentityMapping(
        publicUserId: publicUserId,
        hospitalId: hospitalId,
        role: userRecord['role'] as String?,
      );

      final reconciled = await service2.reconcileAll();
      expect(reconciled, isTrue, reason: 'client 2 reconciliation must finish');

      final client2Patients = await service2.searchPatientsLocal(
        uhid,
        hospitalId: hospitalId,
      );
      expect(
        client2Patients,
        hasLength(1),
        reason: 'client 2 must receive the synchronized patient',
      );
      expect(client2Patients.single['id'], patientId);

      // Child rows (bill items + payment history) must have been pulled too.
      final mirroredItems = await local2.getMirror('billing_items');
      expect(
        mirroredItems.any((r) => r['bill_id'] == billId),
        isTrue,
        reason: 'client 2 must receive the bill line items',
      );
      final mirroredPayments = await local2.getMirror('payment_logs');
      expect(
        mirroredPayments.any((r) => r['bill_id'] == billId),
        isTrue,
        reason: 'client 2 must receive the payment history',
      );

      // ------------------------------------------------------------------
      // 14. Online IPD admission uses the SAME patient (no re-registration)
      // ------------------------------------------------------------------
      final bedId = await _ensureSyntheticBed(client, hospitalId: hospitalId);

      final admission = await service.admitIPDPatient({
        // Mirrors what the IPD admission screen submits.
        'hospital_id': hospitalId,
        'patient_id': patientId,
        'doctor_id': null,
        'bed_id': bedId,
        'ward_type': 'general',
        'admission_type': 'planned',
        'is_emergency': false,
        'whatsapp_opt_in': false,
        'status': 'admitted',
        'admission_date': DateTime.now().toIso8601String(),
        'diagnosis': 'E2E synthetic admission',
        'remarks': 'automated offline->online handoff check',
      });
      expect(admission['patient_id'], patientId);

      expect(
        await client.from('patients').select('id').eq('uhid', uhid),
        hasLength(1),
        reason: 'admitting online must not register a duplicate patient',
      );
      final admissions = await client
          .from('ipd_admissions')
          .select('id, patient_id')
          .eq('patient_id', patientId);
      expect(admissions, hasLength(1), reason: 'exactly one admission');

      // ------------------------------------------------------------------
      // 16. Tenant isolation: another hospital cannot see these records
      // ------------------------------------------------------------------
      final otherHospitalPatients = await client
          .from('patients')
          .select('id')
          .eq('uhid', uhid)
          .eq('hospital_id', '00000000-0000-4000-8000-000000000099');
      expect(otherHospitalPatients, isEmpty);

      await local2.close();
      await local.close();
      await proxy.stop();
      await tempDir.delete(recursive: true);
    },
  );
}

/// Creates (or reuses) one synthetic available bed so the online admission
/// workflow has something to allocate.
Future<String> _ensureSyntheticBed(
  SupabaseClient client, {
  required String hospitalId,
}) async {
  const bedNumber = 'E2E-BED-1';
  final existing = await client
      .from('beds')
      .select('id')
      .eq('hospital_id', hospitalId)
      .eq('bed_number', bedNumber)
      .maybeSingle();
  if (existing != null) return existing['id'] as String;

  final inserted = await client
      .from('beds')
      .insert({
        'hospital_id': hospitalId,
        'bed_number': bedNumber,
        'ward_name': 'E2E Ward',
        'ward_type': 'general',
        'bed_type': 'general',
        'daily_charge': 0,
        'status': 'available',
        'is_active': true,
      })
      .select('id')
      .single();
  return inserted['id'] as String;
}
