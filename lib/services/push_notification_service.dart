import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../core/utils/logger.dart';
import 'database_service.dart';

/// Notification ke types jo HIMS support karta hai.
enum NotificationType {
  opdVisit('opd_visit', 'OPD Visit'),
  ipdAdmission('ipd_admission', 'IPD Admission'),
  voucher('voucher', 'Voucher'),
  labReport('lab_report', 'Lab Report'),
  billing('billing', 'Billing'),
  complianceReminder('compliance_reminder', 'Compliance Reminder');

  const NotificationType(this.value, this.label);

  /// Value jo `notifications.notification_type` column mein store hoti hai.
  final String value;

  /// Human readable label.
  final String label;

  static NotificationType? fromValue(String? value) {
    for (final type in NotificationType.values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

/// Hospital staff roles jinko push notifications jaani chahiye.
class NotificationTargetRoles {
  NotificationTargetRoles._();

  /// Doctor, Nurse aur Receptionist — spec ke mutabik target users.
  static const List<String> staff = ['doctor', 'nurse', 'receptionist'];

  /// Hospital ke Super Admin aur Admin — voucher creation alerts ke liye.
  static const List<String> admins = ['super_admin', 'admin'];
}

/// Notification message templates (spec ke exact messages).
class NotificationMessages {
  NotificationMessages._();

  static String opdVisit(String patientName) =>
      'New OPD Visit for Patient $patientName';

  static String ipdAdmission(String patientName) =>
      'New IPD Admission for Patient $patientName';

  static String billing(String patientName) =>
      'New Bill Generated for Patient $patientName';

  static String voucher(String voucherNumber) =>
      'Voucher $voucherNumber has been punched';

  static String labReport(String patientName) =>
      'Lab Report Ready for Patient $patientName';

  static String complianceReminder(String documentName) =>
      'Compliance Reminder: $documentName is due for renewal';
}

/// Push Notification Service (Firebase Cloud Messaging).
///
/// Responsibilities:
/// * FCM permission + device token registration.
/// * Device token update (onTokenRefresh) — `user_devices` table mein upsert.
/// * Hospital-wise topic subscription (`hospital_{hospitalId}`) taaki sirf
///   us hospital ke staff ko notification mile.
/// * In-app `notifications` rows create karna (OPD Visit, IPD Admission,
///   Billing, Lab Report).
///
/// NOTE: FCM payload ki actual delivery aapke backend/Edge Function se hoti
/// hai (topic par publish). Ye service device-side registration, subscription
/// aur in-app notification rows handle karti hai.
class PushNotificationService {
  PushNotificationService({required this.dbService});

  final DatabaseService dbService;

  FirebaseMessaging? _messaging;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _openAppSubscription;

  String? _fcmToken;
  String? _currentUserId;
  String? _currentHospitalId;
  String? _hospitalTopic;
  bool _initialized = false;

  /// Current FCM device token (null jab FCM configured nahi hai).
  String? get fcmToken => _fcmToken;

  bool get isInitialized => _initialized;

  /// Foreground message receive hone par call hota hai (providers ise
  /// notification list refresh karne ke liye wire karte hain).
  void Function(RemoteMessage message)? onForegroundMessage;

  /// User jab notification tap kare (foreground/background/terminated).
  void Function(Map<String, dynamic> data)? onNotificationTap;

  /// FCM setup + token registration + topic subscription.
  ///
  /// Firebase configure na hone par (google-services.json /
  /// GoogleService-Info.plist / firebase_options.dart missing) service
  /// silently disable ho jati hai — app ka baaki flow chalta rehta hai.
  Future<void> initialize({
    required String userId,
    required String hospitalId,
  }) async {
    if (_initialized) return;
    _currentUserId = userId;
    _currentHospitalId = hospitalId;

    try {
      await _ensureFirebaseInitialized();
      _messaging = FirebaseMessaging.instance;

      await _requestPermission();
      await registerDeviceToken();
      await subscribeToHospitalTopic(hospitalId);

      _tokenRefreshSubscription = _messaging!.onTokenRefresh.listen((token) {
        _fcmToken = token;
        updateDeviceToken(token);
      });

      // Foreground messages — app open hone par bhi notification data mile.
      _foregroundSubscription = FirebaseMessaging.onMessage.listen((message) {
        AppLogger.i(
          'Foreground FCM: ${message.notification?.title} | ${message.data}',
        );
        onForegroundMessage?.call(message);
      });

      // Notification tap (app background se open).
      _openAppSubscription = FirebaseMessaging.onMessageOpenedApp.listen((
        message,
      ) {
        onNotificationTap?.call(message.data);
      });

      // Terminated state se tap karke app open karne par.
      final initialMessage = await _messaging!.getInitialMessage();
      if (initialMessage != null) {
        onNotificationTap?.call(initialMessage.data);
      }

      _initialized = true;
      AppLogger.i(
        'PushNotificationService initialized. Topic: $_hospitalTopic',
      );
    } catch (e, stackTrace) {
      AppLogger.e(
        'PushNotificationService init failed — FCM disabled for this build',
        e,
        stackTrace,
      );
    }
  }

  Future<void> _ensureFirebaseInitialized() async {
    // NOTE: web par `Firebase.apps.isEmpty` check khud hi
    // `core/not-initialized` throw kar deta hai, isliye seedha initialize
    // karte hain. Agar pehle se initialized hai to `duplicate-app` milta hai
    // jise ignore kar dete hain.
    try {
      await Firebase.initializeApp(options: AppConfig.firebaseOptions);
    } on FirebaseException catch (e) {
      if (e.code != 'duplicate-app') rethrow;
    }
  }

  Future<void> _requestPermission() async {
    final settings = await _messaging!.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    AppLogger.i(
      'FCM authorization status: ${settings.authorizationStatus.name}',
    );
  }

  /// Returns the current device token and stores it in `user_devices`.
  Future<String?> registerDeviceToken() async {
    if (_messaging == null) return null;
    final token = await _messaging!.getToken();
    if (token == null || token.isEmpty) return null;
    _fcmToken = token;
    await updateDeviceToken(token);
    return token;
  }

  /// Device token ko `user_devices` table mein upsert karta hai (token update
  /// logic — onTokenRefresh aur login dono isi ko call karte hain).
  Future<void> updateDeviceToken(String token) async {
    final userId = _currentUserId;
    if (userId == null || token.isEmpty) return;

    _fcmToken = token;
    await dbService.saveDeviceToken(
      userId: userId,
      fcmToken: token,
      hospitalId: _currentHospitalId,
      platform: defaultTargetPlatform.name,
    );
    AppLogger.i('Device token saved for user $userId');
  }

  /// `hospital_{hospitalId}` topic subscribe karo — sirf us hospital ke staff
  /// devices ko FCM message milega.
  Future<void> subscribeToHospitalTopic(String hospitalId) async {
    if (_messaging == null) return;
    final topic = _hospitalTopicName(hospitalId);
    await _messaging!.subscribeToTopic(topic);
    _hospitalTopic = topic;
    AppLogger.i('Subscribed to FCM topic: $topic');
  }

  /// Hospital topic se unsubscribe (logout / hospital switch par).
  Future<void> unsubscribeFromHospitalTopic(String hospitalId) async {
    if (_messaging == null) return;
    await _messaging!.unsubscribeFromTopic(_hospitalTopicName(hospitalId));
    AppLogger.i(
      'Unsubscribed from FCM topic: ${_hospitalTopicName(hospitalId)}',
    );
  }

  /// FCM topic name builder. NOTE: agar aap ye format badalte hain to Edge
  /// Function / server-side publish bhi update karna hoga.
  String _hospitalTopicName(String hospitalId) => 'hospital_$hospitalId';

  // ---------------------------------------------------------------------------
  // In-app notifications (notifications table)
  // ---------------------------------------------------------------------------

  /// Ek user ke liye notification row create karta hai.
  Future<void> notifyUser({
    required String hospitalId,
    required String userId,
    required NotificationType type,
    required String title,
    required String message,
    String? linkUrl,
  }) async {
    await dbService.createNotification(
      hospitalId: hospitalId,
      userId: userId,
      title: title,
      message: message,
      notificationType: type.value,
      linkUrl: linkUrl,
    );
  }

  /// Hospital ke saare active Doctor/Nurse/Receptionist ke liye notification
  /// row create karta hai. Returns kitne users ko notify kiya gaya.
  ///
  /// Actual push delivery ke liye server side par `hospital_{hospitalId}`
  /// topic par FCM message publish karein; yahan DB rows persist hoti hain.
  Future<int> notifyHospitalStaff({
    required String hospitalId,
    required NotificationType type,
    required String title,
    required String message,
    String? linkUrl,
    List<String> roles = NotificationTargetRoles.staff,
  }) async {
    final staff = await dbService.getHospitalStaffUsers(
      hospitalId,
      roles: roles,
    );

    var created = 0;
    for (final user in staff) {
      final userId = user['id']?.toString();
      if (userId == null || userId.isEmpty) continue;

      await dbService.createNotification(
        hospitalId: hospitalId,
        userId: userId,
        title: title,
        message: message,
        notificationType: type.value,
        linkUrl: linkUrl,
      );
      created++;
    }
    return created;
  }

  // ---------------------------------------------------------------------------
  // Send Notification (in-app rows + FCM push via send-fcm Edge Function)
  // ---------------------------------------------------------------------------

  /// [userType] ke hisaab se hospital staff ko notification bhejta hai.
  ///
  /// * `userType` = `all` / `staff` / `doctor` / `nurse` / `receptionist`
  ///   (koi bhi ek role pass karne par sirf us role ke active users target
  ///   hote hain).
  /// * Har target user ke liye `notifications` table mein row create hoti hai.
  /// * Actual push delivery `hospital_{hospitalId}` FCM topic par
  ///   `send-fcm` Supabase Edge Function ke through hoti hai (Firebase Admin
  ///   SDK server-side use hota hai — private key client par kabhi nahi
  ///   aati).
  ///
  /// Returns kitne users ko in-app notify kiya gaya (push delivery ka result
  /// Edge Function ke response mein hota hai).
  Future<int> sendNotification({
    required String hospitalId,
    required String userType,
    required String message,
    String title = 'MediFlux Notification',
    NotificationType type = NotificationType.opdVisit,
    String? linkUrl,
  }) async {
    final roles = _rolesForUserType(userType);
    final staff = await dbService.getHospitalStaffUsers(
      hospitalId,
      roles: roles,
    );

    var created = 0;
    for (final user in staff) {
      final userId = user['id']?.toString();
      if (userId == null || userId.isEmpty) continue;

      await dbService.sendNotification({
        'hospital_id': hospitalId,
        'user_id': userId,
        'title': title,
        'message': message,
        'notification_type': type.value,
        'link_url': linkUrl,
      });
      created++;
    }

    // FCM push — hospital topic par, Edge Function Firebase Admin SDK use
    // karke bhejta hai. In-app rows ban chuke hain; agar function deploy
    // nahi hai toh sirf in-app notification milega (app crash nahi hogi).
    await _deliverPushViaEdgeFunction(
      hospitalId: hospitalId,
      title: title,
      message: message,
      notificationType: type.value,
      linkUrl: linkUrl,
      targetRoles: roles,
    );

    return created;
  }

  /// [userType] ko `users.role` filter list mein convert karta hai.
  List<String>? _rolesForUserType(String userType) {
    switch (userType.trim().toLowerCase()) {
      case 'all':
      case 'staff':
      case '':
        return NotificationTargetRoles.staff;
      default:
        return [userType.trim().toLowerCase()];
    }
  }

  /// `send-fcm` Supabase Edge Function invoke karta hai jo Firebase Admin SDK
  /// (`firebase-admin` npm package) se `hospital_{hospitalId}` topic par
  /// `messaging().send()` call karti hai.
  Future<void> _deliverPushViaEdgeFunction({
    required String hospitalId,
    required String title,
    required String message,
    required String notificationType,
    String? linkUrl,
    List<String>? targetRoles,
  }) async {
    try {
      final response = await dbService.invokeEdgeFunction(
        'send-fcm',
        body: {
          'hospital_id': hospitalId,
          'topic': _hospitalTopicName(hospitalId),
          'title': title,
          'message': message,
          'notification_type': notificationType,
          'link_url': linkUrl,
          'target_roles': targetRoles ?? const <String>[],
        },
      );
      AppLogger.i('send-fcm Edge Function response: ${response.data}');
    } catch (e, stackTrace) {
      AppLogger.e(
        'send-fcm Edge Function call failed — in-app notification still saved',
        e,
        stackTrace,
      );
    }
  }

  // -- Ready-made templates ---------------------------------------------------

  /// "New OPD Visit for Patient [Name]" — Doctor/Nurse/Receptionist ke liye.
  Future<int> notifyOpdVisit({
    required String hospitalId,
    required String patientName,
    String? linkUrl,
  }) {
    return notifyHospitalStaff(
      hospitalId: hospitalId,
      type: NotificationType.opdVisit,
      title: 'New OPD Visit',
      message: NotificationMessages.opdVisit(patientName),
      linkUrl: linkUrl,
    );
  }

  /// "New IPD Admission for Patient [Name]" — Doctor/Nurse/Receptionist.
  Future<int> notifyIpdAdmission({
    required String hospitalId,
    required String patientName,
    String? linkUrl,
  }) {
    return notifyHospitalStaff(
      hospitalId: hospitalId,
      type: NotificationType.ipdAdmission,
      title: 'New IPD Admission',
      message: NotificationMessages.ipdAdmission(patientName),
      linkUrl: linkUrl,
    );
  }

  /// Billing notification — Doctor/Nurse/Receptionist.
  Future<int> notifyBilling({
    required String hospitalId,
    required String patientName,
    String? linkUrl,
  }) {
    return notifyHospitalStaff(
      hospitalId: hospitalId,
      type: NotificationType.billing,
      title: 'New Bill Generated',
      message: NotificationMessages.billing(patientName),
      linkUrl: linkUrl,
    );
  }

  /// Lab report ready notification — Doctor/Nurse/Receptionist.
  Future<int> notifyLabReport({
    required String hospitalId,
    required String patientName,
    String? linkUrl,
  }) {
    return notifyHospitalStaff(
      hospitalId: hospitalId,
      type: NotificationType.labReport,
      title: 'Lab Report Ready',
      message: NotificationMessages.labReport(patientName),
      linkUrl: linkUrl,
    );
  }

  /// Voucher created notification — Super Admin/Admin ko bhejte hain taaki
  /// unhe pata chale ki hospital mein naya voucher punch hua hai.
  Future<int> notifyVoucher({
    required String hospitalId,
    required String voucherNumber,
    String? linkUrl,
  }) {
    return notifyHospitalStaff(
      hospitalId: hospitalId,
      type: NotificationType.voucher,
      title: 'New Voucher',
      message: NotificationMessages.voucher(voucherNumber),
      linkUrl: linkUrl,
      roles: NotificationTargetRoles.admins,
    );
  }

  /// Compliance renewal reminder — Super Admin/Admin ko bhejte hain taaki
  /// license/contract expiry se pehle action liya ja sake.
  Future<int> notifyComplianceReminder({
    required String hospitalId,
    required String documentName,
    String? linkUrl,
  }) {
    return notifyHospitalStaff(
      hospitalId: hospitalId,
      type: NotificationType.complianceReminder,
      title: 'Compliance Renewal Reminder',
      message: NotificationMessages.complianceReminder(documentName),
      linkUrl: linkUrl,
      roles: NotificationTargetRoles.admins,
    );
  }

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

  /// Token row remove karo, topic se unsubscribe karo aur stream listeners
  /// cancel karo. Logout ke waqt call karein.
  Future<void> stop() async {
    try {
      if (_messaging != null && _hospitalTopic != null) {
        await _messaging!.unsubscribeFromTopic(_hospitalTopic!);
        _hospitalTopic = null;
      }
    } catch (e) {
      AppLogger.e('Could not unsubscribe from FCM topic', e);
    }

    try {
      final token = _fcmToken;
      if (token != null && token.isNotEmpty) {
        await dbService.removeDeviceToken(token);
      }
    } catch (e) {
      AppLogger.e('Could not remove device token', e);
    }

    await _tokenRefreshSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    await _openAppSubscription?.cancel();

    _tokenRefreshSubscription = null;
    _foregroundSubscription = null;
    _openAppSubscription = null;
    _messaging = null;
    _fcmToken = null;
    _currentUserId = null;
    _currentHospitalId = null;
    _initialized = false;
  }
}
