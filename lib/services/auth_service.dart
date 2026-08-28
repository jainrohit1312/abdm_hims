import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../core/constants/api_constants.dart';
import '../core/utils/logger.dart';

/// Raised when the account has been temporarily locked after too many failed
/// login attempts. Carries the lock-expiry timestamp so the UI can show a
/// countdown / lockout message.
class AccountLockedException implements Exception {
  AccountLockedException({required this.email, required this.lockedUntil})
    : remaining = lockedUntil.difference(DateTime.now());

  final String email;
  final DateTime lockedUntil;
  final Duration remaining;

  bool get isActive => lockedUntil.isAfter(DateTime.now());

  String get message {
    final minutes = remaining.inSeconds <= 0
        ? 0
        : (remaining.inSeconds / 60).ceil();
    return 'Account temporarily locked due to too many failed attempts.\n'
        'Try again in $minutes minute${minutes == 1 ? '' : 's'}.\n'
        'बहुत सारे गलत प्रयासों के कारण खाता अस्थायी रूप से लॉक है। '
        '$minutes मिनट बाद पुनः प्रयास करें।';
  }

  @override
  String toString() =>
      'AccountLockedException(email: $email, '
      'lockedUntil: ${lockedUntil.toIso8601String()})';
}

/// Result of [AuthService.checkAccountLocked].
class LoginLockInfo {
  const LoginLockInfo({
    required this.isLocked,
    this.lockedUntil,
    this.remaining = Duration.zero,
  });

  final bool isLocked;
  final DateTime? lockedUntil;
  final Duration remaining;
}

class AuthService {
  AuthService(this._client, {FlutterSecureStorage? secureStorage})
    : _storage = secureStorage ?? AppConfig.secureStorage;

  final SupabaseClient _client;
  final FlutterSecureStorage _storage;

  // ---------------------------------------------------------------------------
  // Security tuning (rate limiting + session timeout)
  // ---------------------------------------------------------------------------

  /// Max failed login attempts allowed before the account is locked.
  static const int maxLoginAttempts = 5;

  /// Lock duration applied after [maxLoginAttempts] failed attempts.
  static const Duration lockoutDuration = Duration(minutes: 15);

  /// Default inactivity timeout for an authenticated session.
  static const Duration defaultSessionTimeout = Duration(minutes: 15);

  /// Timeout applied to remote auth calls (sign-in, user-record lookup) so a
  /// stalled Supabase endpoint fails fast instead of leaving the login button
  /// spinner running forever.
  static const Duration authRequestTimeout = Duration(seconds: 15);

  /// A paused/cold Supabase project often accepts the very next request after
  /// the first one times out. Retry once transparently before surfacing the
  /// timeout to the login screen.
  static const int maxAuthRetries = 2;

  /// Wait between auth retry attempts.
  static const Duration authRetryDelay = Duration(seconds: 2);

  /// How often the background monitor checks for session timeout.
  static const Duration _sessionMonitorInterval = Duration(seconds: 30);

  // Secure storage keys (JWT + rate limiting + session timeout).
  static const String _kAccessToken = 'auth_access_token';
  static const String _kRefreshToken = 'auth_refresh_token';
  static const String _kSessionJson = 'auth_session_json';
  static const String _kUserRecord = 'auth_user_record';
  static const String _kSessionExpiresAt = 'auth_session_expires_at';
  static const String _kSessionTimeoutMinutes = 'auth_session_timeout_minutes';
  static const String _kLastActivityAt = 'auth_last_activity_at';
  static const String _kLoginAttemptsPrefix = 'login_attempts_';
  static const String _kLockoutUntilPrefix = 'lockout_until_';

  Duration _sessionTimeout = defaultSessionTimeout;
  Timer? _sessionTimer;

  /// Invoked when the inactivity session-timeout monitor fires.
  void Function()? onSessionTimeout;

  String _attemptsKey(String email) =>
      '$_kLoginAttemptsPrefix${_normalize(email)}';
  String _lockKey(String email) => '$_kLockoutUntilPrefix${_normalize(email)}';

  String _normalize(String email) => email.trim().toLowerCase();

  // ===========================================================================
  // 1. SECURE TOKEN STORAGE (flutter_secure_storage — SharedPreferences NO)
  // ===========================================================================

  /// Persists the active JWT session into secure storage.
  ///
  /// Supabase ka apna session bhi [SecureLocalStorage] (secure storage) mein
  /// rehta hai; yahan explicit keys isliye rakhi gayi hain taaki AuthService
  /// ko refresh/restore ke liye seedha access mile. Saath hi full session JSON
  /// bhi save hota hai taaki app restart/browser refresh par bina network ke
  /// session restore ho sake.
  Future<void> _persistSession(Session? session) async {
    if (session == null) {
      await clearStoredSession();
      return;
    }
    await Future.wait([
      _storage.write(key: _kAccessToken, value: session.accessToken),
      _storage.write(key: _kSessionJson, value: jsonEncode(session.toJson())),
    ]);
    final refreshToken = session.refreshToken;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await _storage.write(key: _kRefreshToken, value: refreshToken);
    }
    final expiresAt = session.expiresAt;
    if (expiresAt != null) {
      await _storage.write(
        key: _kSessionExpiresAt,
        value: expiresAt.toString(),
      );
    }
  }

  /// Returns the raw JWT access token stored in secure storage (if any).
  Future<String?> getStoredAccessToken() => _storage.read(key: _kAccessToken);

  /// Returns the refresh token stored in secure storage (if any).
  Future<String?> getStoredRefreshToken() => _storage.read(key: _kRefreshToken);

  /// Deletes the JWT tokens from secure storage. Called on logout and when the
  /// server confirms a stored token is invalid/revoked. A transient network
  /// failure must NOT call this — the stored session has to survive restarts.
  Future<void> clearStoredSession() async {
    await Future.wait([
      _storage.delete(key: _kAccessToken),
      _storage.delete(key: _kRefreshToken),
      _storage.delete(key: _kSessionJson),
      _storage.delete(key: _kSessionExpiresAt),
      _storage.delete(key: _kUserRecord),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Public user-record cache (offline session restore)
  // ---------------------------------------------------------------------------

  /// Caches the public `users` record (`id`, `auth_id`, `role`, `hospital_id`)
  /// so the hospital context can be restored even when the first restore
  /// happens offline (Supabase project paused / no connectivity).
  Future<void> cacheUserRecord(Map<String, dynamic> record) async {
    try {
      await _storage.write(key: _kUserRecord, value: jsonEncode(record));
    } catch (e) {
      AppLogger.w('Could not cache user record: $e');
    }
  }

  /// Returns the cached public `users` record (if any).
  Future<Map<String, dynamic>?> getCachedUserRecord() async {
    try {
      final raw = await _storage.read(key: _kUserRecord);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (e) {
      AppLogger.w('Could not read cached user record: $e');
      return null;
    }
  }

  /// Restores the Supabase session from secure storage when the in-memory
  /// session is missing. Returns true when a session could be restored.
  ///
  /// Restoration is offline-first: the full session JSON is replayed into the
  /// Supabase client with `setInitialSession` (no network), so an app restart
  /// or browser refresh never depends on the network being available.
  Future<bool> restoreSessionFromSecureStorage() async {
    try {
      final current = _client.auth.currentSession;
      if (current != null) {
        // In-memory session already available — make sure secure storage is
        // in sync and continue.
        await _persistSession(current);
        await _touchLastActivity();
        return true;
      }

      // Primary path: replay the full session JSON we persisted at login time.
      // This works offline and does not need the Supabase project to be awake.
      final sessionJson = await _storage.read(key: _kSessionJson);
      if (sessionJson != null && sessionJson.isNotEmpty) {
        try {
          await _client.auth.setInitialSession(sessionJson);
          if (_client.auth.currentSession != null) return true;
        } catch (e) {
          AppLogger.w('Could not restore session from stored JSON: $e');
        }
      }

      // Legacy fallback for installs that only have the explicit tokens.
      final refreshToken = await getStoredRefreshToken();
      if (refreshToken == null || refreshToken.isEmpty) return false;

      final response = await _client.auth.setSession(refreshToken);
      if (response.session != null) return true;
      return false;
    } on AuthRetryableFetchException catch (e) {
      // Temporary network failure — keep the stored session for a later retry.
      AppLogger.w('Session restore hit a temporary network problem: $e');
      return false;
    } on AuthException catch (e) {
      // Server-confirmed invalid/revoked token. The session is truly dead and
      // the stored copy must be removed so the next launch starts clean.
      AppLogger.e('Stored session is invalid or revoked', e);
      await clearStoredSession();
      return false;
    } catch (e) {
      AppLogger.e('Could not restore session from secure storage', e);
      return false;
    }
  }

  /// Returns a fresh (non-expired) session, restoring from secure storage and
  /// refreshing the token when necessary.
  ///
  /// IMPORTANT (persistent login): a temporary refresh failure (offline,
  /// Supabase paused, timeout) does NOT log the user out. The stored session is
  /// kept and the expired in-memory session is returned so the Supabase client
  /// can auto-refresh it in the background as soon as connectivity returns.
  /// Only a server-confirmed invalid/revoked token clears the session here.
  Future<Session?> ensureFreshSession() async {
    var session = _client.auth.currentSession;

    if (session == null) {
      await restoreSessionFromSecureStorage();
      session = _client.auth.currentSession;
    }

    if (session != null && session.isExpired) {
      try {
        final response = await refreshSession();
        session = response.session ?? session;
      } on AuthRetryableFetchException catch (e) {
        AppLogger.w(
          'Session refresh failed during restore (network). '
          'Keeping stored session — the client will auto-refresh later. $e',
        );
        session = _client.auth.currentSession ?? session;
      } on AuthException catch (e) {
        AppLogger.e(
          'Session refresh failed with an auth error during restore',
          e,
        );
        await clearStoredSession();
        try {
          await _client.auth.signOut(scope: SignOutScope.local);
        } catch (_) {
          // Local sign-out is best-effort; storage cleanup already happened.
        }
        return null;
      } catch (e) {
        AppLogger.w(
          'Session refresh failed during restore. Keeping stored session. $e',
        );
        session = _client.auth.currentSession ?? session;
      }
    }

    if (session != null) {
      await _persistSession(session);
      await _touchLastActivity();
    }
    return session;
  }

  // ===========================================================================
  // 2. SESSION TIMEOUT
  // ---------------------------------------------------------------------------
  // NOTE: Persistent-login requirement ke tahat inactivity auto-logout DISABLED
  // hai — sirf deliberate logout hi session khatam karta hai. Neeche ke methods
  // API compatibility ke liye rakhe gaye hain; AuthNotifier inhe start nahi
  // karta. Inhe dobara enable karna ho toh AuthNotifier.bootstrap/login mein
  // `startSessionTimeoutMonitor` call add karein.
  // ===========================================================================

  /// Sets the inactivity session timeout and resets the last-activity clock.
  ///
  /// Jab bhi login hota hai (ya session restore hota hai) ye call karna chahiye.
  Future<void> setSessionTimeout({Duration? timeout}) async {
    _sessionTimeout = timeout ?? defaultSessionTimeout;
    await _storage.write(
      key: _kSessionTimeoutMinutes,
      value: _sessionTimeout.inMinutes.toString(),
    );
    await _touchLastActivity();
  }

  /// Returns the currently configured session timeout duration.
  Future<Duration> getSessionTimeout() async {
    final raw = await _storage.read(key: _kSessionTimeoutMinutes);
    final minutes = int.tryParse(raw ?? '');
    if (minutes != null && minutes > 0) {
      return Duration(minutes: minutes);
    }
    return _sessionTimeout;
  }

  /// Resets the inactivity clock. Har important user interaction par call
  /// karein (ya login/restore par — jo AuthService khud handle karta hai).
  Future<void> touchSession() => _touchLastActivity();

  Future<void> _touchLastActivity() async {
    await _storage.write(
      key: _kLastActivityAt,
      value: DateTime.now().toUtc().toIso8601String(),
    );
  }

  /// True when the user has been inactive longer than the allowed timeout.
  /// On timeout the stored session is cleared (client-side sign out).
  Future<bool> checkSessionTimeout() async {
    final session = _client.auth.currentSession;
    if (session == null) return false;

    final raw = await _storage.read(key: _kLastActivityAt);
    if (raw == null || raw.isEmpty) {
      await _touchLastActivity();
      return false;
    }

    final lastActivity = DateTime.tryParse(raw);
    if (lastActivity == null) {
      await _touchLastActivity();
      return false;
    }

    final timeout = await getSessionTimeout();
    if (DateTime.now().difference(lastActivity) < timeout) return false;

    // Timed out: local sign-out + token cleanup (network-free, safe offline).
    stopSessionTimeoutMonitor();
    try {
      await _client.auth.signOut(scope: SignOutScope.local);
    } catch (e) {
      AppLogger.e('Local sign-out failed during session timeout', e);
    }
    await clearStoredSession();
    return true;
  }

  /// Starts the periodic inactivity monitor. [onTimeout] fires once when the
  /// session has timed out (AuthNotifier isko /login redirect ke liye use
  /// karta hai).
  void startSessionTimeoutMonitor({void Function()? onTimeout}) {
    if (onTimeout != null) onSessionTimeout = onTimeout;
    _sessionTimer ??= Timer.periodic(_sessionMonitorInterval, (_) async {
      final timedOut = await checkSessionTimeout();
      if (timedOut) {
        onSessionTimeout?.call();
      }
    });
  }

  /// Stops the periodic inactivity monitor (logout ke waqt call hota hai).
  void stopSessionTimeoutMonitor() {
    _sessionTimer?.cancel();
    _sessionTimer = null;
  }

  /// Releases the monitor timer. Provider dispose ke saath use karein.
  void dispose() => stopSessionTimeoutMonitor();

  // ===========================================================================
  // 3. LOGIN RATE LIMITING & LOCKOUT
  // ===========================================================================

  /// Returns the number of failed login attempts recorded for [email].
  Future<int> getFailedLoginAttempts(String email) async {
    final raw = await _storage.read(key: _attemptsKey(email));
    return int.tryParse(raw ?? '') ?? 0;
  }

  /// Registers one failed attempt. Returns the lock-expiry timestamp when the
  /// account just became locked, otherwise null.
  Future<DateTime?> registerFailedLogin(String email) async {
    final attempts = await getFailedLoginAttempts(email) + 1;
    await _storage.write(key: _attemptsKey(email), value: attempts.toString());

    if (attempts >= maxLoginAttempts) {
      final lockedUntil = DateTime.now().add(lockoutDuration);
      await _storage.write(
        key: _lockKey(email),
        value: lockedUntil.toUtc().toIso8601String(),
      );
      return lockedUntil;
    }
    return null;
  }

  /// Resets the failed-attempt counter and clears any lockout for [email].
  Future<void> resetLoginAttempts(String email) async {
    await Future.wait([
      _storage.delete(key: _attemptsKey(email)),
      _storage.delete(key: _lockKey(email)),
    ]);
  }

  /// Checks whether [email] is currently locked out.
  ///
  /// Returns a [LoginLockInfo] with `isLocked = true` and the remaining lock
  /// duration when locked, otherwise `isLocked = false`.
  Future<LoginLockInfo> checkAccountLocked(String email) async {
    final raw = await _storage.read(key: _lockKey(email));
    if (raw == null || raw.isEmpty) {
      return const LoginLockInfo(isLocked: false);
    }

    final lockedUntil = DateTime.tryParse(raw);
    if (lockedUntil == null) {
      await resetLoginAttempts(email);
      return const LoginLockInfo(isLocked: false);
    }

    final now = DateTime.now();
    if (lockedUntil.isAfter(now)) {
      return LoginLockInfo(
        isLocked: true,
        lockedUntil: lockedUntil,
        remaining: lockedUntil.difference(now),
      );
    }

    // Lock expired — clear it and start a fresh attempt window.
    await resetLoginAttempts(email);
    return const LoginLockInfo(isLocked: false);
  }

  // ===========================================================================
  // 4. AUTH OPERATIONS
  // ===========================================================================

  Future<Session?> getCurrentSession() async {
    try {
      return _client.auth.currentSession;
    } catch (e) {
      AppLogger.e('Error getting current session', e);
      return null;
    }
  }

  Future<User?> getCurrentUser() async {
    try {
      return _client.auth.currentUser;
    } catch (e) {
      AppLogger.e('Error getting current user', e);
      return null;
    }
  }

  /// Returns the current auth user's ID (from Supabase Auth), or null.
  String? get currentUserId => _client.auth.currentUser?.id;

  /// Returns the hospital_id of the currently authenticated user from the
  /// public `users` table, or null when there is no session / no linked
  /// record yet. Callers should treat a null result as "not assigned to a
  /// hospital" and surface an error instead of querying tenant data.
  Future<String?> fetchCurrentHospitalId() async {
    try {
      final authId = _client.auth.currentUser?.id;
      if (authId == null) return null;

      final record = await _client
          .from(ApiConstants.usersTable)
          .select('hospital_id')
          .eq('auth_id', authId)
          .maybeSingle();
      return record?['hospital_id'] as String?;
    } catch (e) {
      AppLogger.e('Error fetching current hospital id', e);
      return null;
    }
  }

  /// Runs an auth-related remote call with [authRequestTimeout] and retries it
  /// once when it times out. Supabase free-tier projects frequently pause when
  /// idle — the first request after a pause can time out while the project
  /// wakes up, and the immediate retry then succeeds.
  Future<T> _withAuthRetry<T>(String step, Future<T> Function() action) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await action().timeout(authRequestTimeout);
      } on TimeoutException {
        if (attempt >= maxAuthRetries) rethrow;
        AppLogger.w(
          '$step timed out (attempt $attempt/$maxAuthRetries). '
          'Retrying in ${authRetryDelay.inSeconds}s...',
        );
        await Future.delayed(authRetryDelay);
      }
    }
  }

  Future<AuthResponse> signIn(String email, String password) async {
    try {
      final response = await _withAuthRetry(
        'Supabase sign-in',
        () => _client.auth.signInWithPassword(email: email, password: password),
      );
      await _persistSession(response.session);
      await _touchLastActivity();
      return response;
    } catch (e) {
      AppLogger.e('Error signing in', e);
      rethrow;
    }
  }

  /// Signs in and immediately fetches the user's public record from the
  /// `users` table. Returns the user record (containing `hospital_id`,
  /// `role`, etc.), or throws on failure.
  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      await _withAuthRetry(
        'Supabase sign-in',
        () => _client.auth.signInWithPassword(email: email, password: password),
      );

      final authId = _client.auth.currentUser?.id;
      if (authId == null) {
        throw Exception('Authentication succeeded but no user ID found.');
      }

      final userRecord = await _withAuthRetry(
        'User record lookup',
        () => _client
            .from(ApiConstants.usersTable)
            .select(
              'id, auth_id, email, role, hospital_id, first_name, last_name, is_active',
            )
            .eq('auth_id', authId)
            .maybeSingle(),
      );

      if (userRecord == null) {
        throw Exception(
          'User authenticated but no matching record found in the users table. '
          'Please contact your administrator.',
        );
      }

      // Defensive check: the record MUST carry a non-null hospital_id for
      // every downstream screen (dashboard, OPD, IPD) to function.
      final hospitalId = userRecord['hospital_id'] as String?;
      if (hospitalId == null || hospitalId.isEmpty) {
        AppLogger.e('login() succeeded but hospital_id is null/empty.', null);
        throw Exception(
          'Your account is not assigned to any hospital. '
          'Please contact your administrator.',
        );
      }

      await _persistSession(_client.auth.currentSession);
      await _touchLastActivity();
      return userRecord;
    } catch (e) {
      AppLogger.e('Error during login', e);
      rethrow;
    }
  }

  /// Rate-limited login flow used by the LoginScreen/AuthNotifier.
  ///
  /// 1. Locked account? -> [AccountLockedException] with remaining time.
  /// 2. Credentials valid? -> reset attempt counter, persist JWT in secure
  ///    storage and start the session-timeout clock.
  /// 3. Credentials invalid? -> increment counter; after [maxLoginAttempts]
  ///    failures the account is locked for [lockoutDuration].
  Future<Map<String, dynamic>> loginWithRateLimit({
    required String email,
    required String password,
  }) async {
    final normalized = _normalize(email);

    final lock = await checkAccountLocked(normalized);
    if (lock.isLocked) {
      throw AccountLockedException(
        email: normalized,
        lockedUntil: lock.lockedUntil!,
      );
    }

    try {
      final userRecord = await login(email, password);

      // Successful login — clear the failed-attempt counter and any lockout,
      // then (re)start the session timeout clock.
      await resetLoginAttempts(normalized);
      await setSessionTimeout();
      return userRecord;
    } catch (e) {
      // Supabase/network failures are NOT credential failures. Counting them
      // against the lockout counter would lock users out during an outage.
      if (e is TimeoutException) {
        rethrow;
      }
      final lockedUntil = await registerFailedLogin(normalized);
      if (lockedUntil != null) {
        throw AccountLockedException(
          email: normalized,
          lockedUntil: lockedUntil,
        );
      }
      rethrow;
    }
  }

  Future<void> signOut() async {
    stopSessionTimeoutMonitor();
    try {
      await _client.auth.signOut();
    } catch (e) {
      AppLogger.e('Error signing out', e);
      rethrow;
    } finally {
      // Requirement: logout karte hi token secure storage se delete ho jaye.
      await clearStoredSession();
    }
  }

  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _client.auth.resetPasswordForEmail(email);
    } catch (e) {
      AppLogger.e('Error sending password reset email', e);
      rethrow;
    }
  }

  Future<AuthResponse> signUp(
    String email,
    String password,
    Map<String, dynamic> userData,
  ) async {
    try {
      final response = await _client.auth.signUp(
        email: email,
        password: password,
        data: userData,
      );
      await _persistSession(response.session);
      await _touchLastActivity();
      return response;
    } catch (e) {
      AppLogger.e('Error signing up', e);
      rethrow;
    }
  }

  /// Registers a new hospital together with its first admin user.
  ///
  /// Preferred path: calls the hospital-registration Edge Function (deployed
  /// as `hyper-function` in the Supabase dashboard), which uses the
  /// service-role key to create the auth user with `email_confirm: true`.
  /// No confirmation/welcome email is sent, so Supabase's email rate limit is
  /// never hit. If the function isn't deployed yet, it falls back to the
  /// client-side `signUp` flow (which requires "Confirm email" to be OFF).
  ///
  /// Expected keys in [data]:
  ///   hospital_name, address, city, state, pincode, phone, email,
  ///   registration_number, logo_url (all optional except hospital_name),
  ///   admin_first_name, admin_last_name, admin_email, admin_password,
  ///   admin_role ('super_admin' or 'admin').
  ///
  /// Returns `{ 'hospital': {...}, 'user': {...}, 'auth_user_id': ... }`.
  Future<Map<String, dynamic>> registerHospital(
    Map<String, dynamic> data,
  ) async {
    final adminEmail = (data['admin_email'] as String? ?? '').trim();
    final adminPassword = data['admin_password'] as String? ?? '';
    if (adminEmail.isEmpty || adminPassword.isEmpty) {
      throw ArgumentError('Admin email and password are required.');
    }

    try {
      // NOTE: This name must match the Edge Function name in the Supabase
      // dashboard. Currently deployed as `hyper-function`.
      final response = await _client.functions.invoke(
        'hyper-function',
        body: data,
      );

      final payload = response.data;
      if (payload is Map<String, dynamic> && payload['error'] != null) {
        throw Exception(payload['error'].toString());
      }
      if (payload is! Map<String, dynamic> || payload['success'] != true) {
        throw Exception(
          'Unexpected response from the register-hospital function.',
        );
      }

      // The function creates the auth identity with the service-role key but
      // does not sign this device in — establish the admin session locally.
      await _client.auth.signInWithPassword(
        email: adminEmail,
        password: adminPassword,
      );
      await _persistSession(_client.auth.currentSession);
      await _touchLastActivity();

      return {
        'hospital': {'id': payload['hospital_id']},
        'user': {'id': payload['user_id']},
        'auth_user_id': payload['auth_user_id'],
      };
    } on FunctionException catch (e) {
      final details = e.details?.toString() ?? '';

      // Function not deployed yet -> fall back to the client-side flow.
      if (e.status == 404 || details.toLowerCase().contains('could not find')) {
        AppLogger.e('register-hospital function unavailable, falling back', e);
        return _registerHospitalClientSide(data);
      }

      // Deployed function returned a business error -> surface a clean message.
      final message = _extractFunctionErrorMessage(e.details);
      if (message != null && message.isNotEmpty) {
        throw Exception(message);
      }
      rethrow;
    }
  }

  /// Pulls `error` / `message` out of an Edge Function error payload.
  String? _extractFunctionErrorMessage(dynamic details) {
    if (details is Map) {
      final error = details['error'] ?? details['message'];
      return error?.toString();
    }
    if (details is String) {
      try {
        final decoded = jsonDecode(details);
        if (decoded is Map) {
          final error = decoded['error'] ?? decoded['message'];
          return error?.toString();
        }
      } catch (_) {
        // Not JSON — fall through to the raw string.
      }
      return details;
    }
    return null;
  }

  /// Client-side fallback used when the `register-hospital` Edge Function has
  /// not been deployed yet. Requires "Confirm email" to be OFF in the
  /// Supabase dashboard, otherwise Supabase sends a confirmation email on
  /// every signup and may hit `over_email_send_rate_limit`.
  Future<Map<String, dynamic>> _registerHospitalClientSide(
    Map<String, dynamic> data,
  ) async {
    final adminEmail = (data['admin_email'] as String? ?? '').trim();
    final adminPassword = data['admin_password'] as String? ?? '';
    final adminFirstName = (data['admin_first_name'] as String? ?? '').trim();
    final adminLastName = (data['admin_last_name'] as String? ?? '').trim();
    final adminRole = (data['admin_role'] as String? ?? 'admin').trim();

    // Capture the existing session (if any) so it can be restored if the
    // registration fails after signUp replaces it.
    final previousSession = _client.auth.currentSession;

    // 1. Create the auth identity for the hospital admin.
    final authResponse = await _client.auth.signUp(
      email: adminEmail,
      password: adminPassword,
      data: {
        'role': adminRole,
        'first_name': adminFirstName,
        'last_name': adminLastName,
      },
    );

    final authUserId = authResponse.user?.id ?? authResponse.session?.user.id;
    if (authUserId == null) {
      await _restoreSessionAfterSignUp(previousSession);
      throw Exception(
        'Admin account could not be created. Check that email confirmation '
        'is disabled for self-registration.',
      );
    }

    // The initial schema requires a unique `code` per hospital. The UI does
    // not ask for it, so generate one when it isn't supplied explicitly.
    final requestedCode = (data['hospital_code'] as String? ?? '').trim();
    final hospitalCode = requestedCode.isNotEmpty
        ? requestedCode
        : 'HOSP${DateTime.now().millisecondsSinceEpoch}';

    Map<String, dynamic>? hospital;
    try {
      // 2. Create the hospital row.
      hospital = await _client
          .from(ApiConstants.hospitalsTable)
          .insert({
            'name': data['hospital_name'],
            'code': hospitalCode,
            'address': data['address'],
            'city': data['city'],
            'state': data['state'],
            'pincode': data['pincode'],
            'phone': data['phone'],
            'email': data['email'],
            'registration_number': data['registration_number'],
            'logo_url': data['logo_url'],
            'is_active': true,
          })
          .select()
          .single();

      // 3. Link the admin to the hospital in public.users.
      final user = await _client
          .from(ApiConstants.usersTable)
          .insert({
            'auth_id': authUserId,
            'hospital_id': hospital['id'],
            'first_name': adminFirstName,
            'last_name': adminLastName.isEmpty ? null : adminLastName,
            'email': adminEmail,
            'role': adminRole,
            'is_active': true,
          })
          .select()
          .single();

      await _persistSession(_client.auth.currentSession);
      await _touchLastActivity();

      return {'hospital': hospital, 'user': user, 'auth_user_id': authUserId};
    } catch (e) {
      // Best-effort cleanup so a half-registered hospital doesn't linger.
      if (hospital != null) {
        try {
          await _client
              .from(ApiConstants.hospitalsTable)
              .delete()
              .eq('id', hospital['id']);
        } catch (_) {
          // Ignore cleanup errors; the original error is rethrown below.
        }
      }
      await _restoreSessionAfterSignUp(previousSession);
      AppLogger.e('Error registering hospital', e);
      rethrow;
    }
  }

  /// Restores the session that existed before a client-side `signUp` call.
  ///
  /// When [previousSession] is null the newly created auth session is signed
  /// out instead (failed registration should not leave a stray session).
  Future<void> _restoreSessionAfterSignUp(Session? previousSession) async {
    try {
      if (previousSession != null) {
        final refreshToken = previousSession.refreshToken;
        if (refreshToken != null && refreshToken.isNotEmpty) {
          await _client.auth.setSession(refreshToken);
          await _persistSession(_client.auth.currentSession);
        }
      } else {
        await _client.auth.signOut();
        await clearStoredSession();
      }
    } catch (_) {
      // Best effort only — the original error is more important.
    }
  }

  Future<void> updatePassword(String newPassword) async {
    try {
      await _client.auth.updateUser(UserAttributes(password: newPassword));
    } catch (e) {
      AppLogger.e('Error updating password', e);
      rethrow;
    }
  }

  Future<AuthResponse> refreshSession() async {
    try {
      final response = await _withAuthRetry(
        'Supabase session refresh',
        () => _client.auth.refreshSession(),
      );
      await _persistSession(response.session);
      await _touchLastActivity();
      return response;
    } catch (e) {
      AppLogger.e('Error refreshing session', e);
      rethrow;
    }
  }
}
