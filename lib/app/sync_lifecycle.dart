import '../services/sync_engine.dart';
import 'providers.dart';

/// Drives a [SyncEngine]'s start / restart / reset from the authenticated
/// session so the engine the dashboard watches is always the running one.
///
/// Extracted from `AppBootstrapGate` so the lifecycle rules are unit-testable:
/// * start as soon as an authenticated session AND a valid hospital id exist;
/// * restart (reset + start) when the hospital changes;
/// * reset on logout / missing hospital — and start again on the next login
///   without a process restart.
class SyncLifecycleCoordinator {
  SyncLifecycleCoordinator(this._engine);

  final SyncEngine _engine;

  String? _activeHospitalId;

  /// Hospital id the engine is currently running for (null = stopped).
  String? get activeHospitalId => _activeHospitalId;

  void onAuthStateChanged(AuthState state) {
    final hospitalId = state.hasHospitalId ? state.hospitalId : null;

    if (state.isAuthenticated && hospitalId != null) {
      if (_activeHospitalId == hospitalId) return;
      if (_activeHospitalId != null) {
        // Hospital changed while logged in — drop the old scope's health.
        _engine.reset();
      }
      _activeHospitalId = hospitalId;
      _engine.start();
      return;
    }

    if (_activeHospitalId != null) {
      _activeHospitalId = null;
      _engine.reset();
    }
  }
}
