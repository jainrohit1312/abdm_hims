import 'package:abdm_hims/app/providers.dart';
import 'package:abdm_hims/app/sync_lifecycle.dart';
import 'package:abdm_hims/core/utils/logger.dart';
import 'package:abdm_hims/services/database_service.dart';
import 'package:abdm_hims/services/local_db.dart';
import 'package:abdm_hims/services/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockDatabaseService extends Mock implements DatabaseService {}

class _MockLocalDatabase extends Mock implements LocalDatabase {}

class _RecordingSyncEngine extends SyncEngine {
  _RecordingSyncEngine({required super.dbService, required super.localDb});

  final List<String> events = [];

  @override
  void start() {
    events.add('start');
    super.start();
  }

  @override
  void reset() {
    events.add('reset');
    super.reset();
  }
}

AuthState _auth({String? hospitalId, bool authenticated = true}) {
  return AuthState(
    isAuthenticated: authenticated,
    hasCheckedAuth: true,
    userId: authenticated ? 'user-1' : null,
    hospitalId: hospitalId,
  );
}

void main() {
  late _RecordingSyncEngine engine;
  late SyncLifecycleCoordinator coordinator;

  setUpAll(AppLogger.init);

  setUp(() {
    final db = _MockDatabaseService();
    final localDb = _MockLocalDatabase();
    // Report an unreachable server: a started engine publishes "cloud
    // unreachable" without logging, which is irrelevant to lifecycle assertions.
    when(() => db.probeSupabase()).thenAnswer((_) async => false);
    when(() => db.hasNetwork()).thenAnswer((_) async => true);
    engine = _RecordingSyncEngine(dbService: db, localDb: localDb);
    coordinator = SyncLifecycleCoordinator(engine);
  });

  tearDown(() => engine.dispose());

  test('does not start sync while unauthenticated', () {
    coordinator.onAuthStateChanged(const AuthState());
    coordinator.onAuthStateChanged(
      _auth(authenticated: false, hospitalId: 'h1'),
    );

    expect(engine.events, isEmpty);
    expect(coordinator.activeHospitalId, isNull);
  });

  test('does not start sync without a hospital id', () {
    coordinator.onAuthStateChanged(_auth());

    expect(engine.events, isEmpty);
    expect(coordinator.activeHospitalId, isNull);
  });

  test('starts sync once a session and hospital id exist', () {
    coordinator.onAuthStateChanged(_auth(hospitalId: 'h1'));

    expect(engine.events, ['start']);
    expect(coordinator.activeHospitalId, 'h1');

    // Repeated identical notifications must not restart the engine.
    coordinator.onAuthStateChanged(_auth(hospitalId: 'h1'));
    expect(engine.events, ['start']);
  });

  test('login after logout starts sync again without a process restart', () {
    coordinator.onAuthStateChanged(_auth(hospitalId: 'h1'));
    coordinator.onAuthStateChanged(const AuthState());
    coordinator.onAuthStateChanged(_auth(hospitalId: 'h1'));

    expect(engine.events, ['start', 'reset', 'start']);
    expect(coordinator.activeHospitalId, 'h1');
  });

  test('a hospital change resets then starts the engine', () {
    coordinator.onAuthStateChanged(_auth(hospitalId: 'h1'));
    coordinator.onAuthStateChanged(_auth(hospitalId: 'h2'));

    expect(engine.events, ['start', 'reset', 'start']);
    expect(coordinator.activeHospitalId, 'h2');
  });

  test('logout stops sync and returns to neutral health', () {
    coordinator.onAuthStateChanged(_auth(hospitalId: 'h1'));
    coordinator.onAuthStateChanged(const AuthState());

    expect(coordinator.activeHospitalId, isNull);
    expect(engine.status.health, SyncHealth.neutral);
  });
}
