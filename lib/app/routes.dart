import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../presentation/screens/auth/login_screen.dart';
import '../presentation/screens/auth/hospital_registration_screen.dart';
import '../presentation/screens/dashboard/dashboard_screen.dart';
import '../presentation/screens/patients/patient_list_screen.dart';
import '../presentation/screens/patients/patient_registration_screen.dart';
import '../presentation/screens/patients/patient_profile_screen.dart';
import '../presentation/screens/patients/patient_combined_search_screen.dart';
import '../presentation/screens/opd/opd_registration_screen.dart';
import '../presentation/screens/opd/opd_queue_screen.dart';
import '../presentation/screens/opd/opd_consultation_screen.dart';
import '../presentation/screens/opd/opd_slip_print.dart';
import '../presentation/screens/doctor/doctor_prescription_screen.dart';
import '../presentation/screens/ipd/ipd_admission_screen.dart';
import '../presentation/screens/ipd/ipd_ward_screen.dart';
import '../presentation/screens/ipd/ipd_patient_screen.dart';
import '../presentation/screens/ipd/ipd_patient_queue_screen.dart';
import '../presentation/screens/ipd/ipd_discharge_screen.dart';
import '../presentation/screens/ipd/ipd_ward_transfer_screen.dart';
import '../presentation/screens/ipd/ipd_billing_screen.dart';
import '../presentation/screens/counseling/counseling_screen.dart';
import '../presentation/screens/counseling/counseling_session_history_screen.dart';
import '../presentation/screens/counseling/counseling_playback_screen.dart';
import '../presentation/screens/abha/abha_verify_screen.dart';
import '../presentation/screens/abha/abha_create_screen.dart';
import '../presentation/screens/billing/billing_screen.dart';
import '../presentation/screens/billing/bill_edit_screen.dart';
import '../presentation/screens/billing/bill_create_screen.dart';
import '../presentation/screens/settings/settings_screen.dart';
import '../presentation/screens/users/user_management_screen.dart';
import '../presentation/screens/notifications/notifications_screen.dart';
import '../presentation/screens/diagnostics/diagnostic_tests_master_screen.dart';
import '../presentation/screens/diagnostics/diagnostic_order_screen.dart';
import '../presentation/screens/diagnostics/diagnostic_result_screen.dart';
import '../presentation/screens/diagnostics/lab_revenue_dashboard.dart';
import '../presentation/screens/voucher/voucher_entry_screen.dart';
import '../presentation/screens/voucher/voucher_list_screen.dart';
import '../presentation/screens/voucher/voucher_settings_screen.dart';
import '../presentation/screens/compliance/compliance_dashboard_screen.dart';
import '../presentation/screens/compliance/compliance_record_form_screen.dart';
import '../presentation/screens/compliance/compliance_record_detail_screen.dart';
import '../presentation/screens/compliance/compliance_documents_screen.dart';
import '../presentation/screens/compliance/compliance_document_viewer_screen.dart';
import '../presentation/screens/compliance/compliance_reminder_history_screen.dart';
import '../presentation/screens/compliance/compliance_audit_log_screen.dart';
import '../presentation/screens/whatsapp/whatsapp_analytics_screen.dart';
import '../presentation/screens/whatsapp/whatsapp_campaigns_screen.dart';
import '../presentation/screens/whatsapp/whatsapp_opt_out_screen.dart';
import '../presentation/screens/whatsapp/whatsapp_settings_screen.dart';
import '../presentation/screens/whatsapp/whatsapp_templates_screen.dart';
import '../presentation/screens/subscription/subscription_status_screen.dart';
import '../presentation/screens/reports/reports_screen.dart';
import '../presentation/screens/reports/reports_detail_screen.dart';
import '../presentation/widgets/app_header.dart';
import '../presentation/widgets/smart_navigation.dart';
import 'providers.dart';

// -----------------------------------------------------------------------------
// Web routing (Vercel deployment): hash mode
// -----------------------------------------------------------------------------
// Flutter web's DEFAULT URL strategy is hash-based:
//
//   https://<your-app>.vercel.app/#/login
//   https://<your-app>.vercel.app/#/patients/register
//
// The `#` fragment is never sent to the server, so Vercel only ever has to
// serve the static `/index.html` — no server-side route entries are needed for
// the GoRouter paths below. Do NOT call `usePathUrlStrategy()` /
// `setUrlStrategy(PathUrlStrategy())` anywhere in this project: that would
// switch the app to path-style URLs and every route would need a rewrite rule.
//
// `vercel.json` still ships a catch-all rewrite to `/index.html` as a safety
// net, so any path-style URL that reaches Vercel (for example a manually typed
// `/dashboard`) also lands in the app and GoRouter resolves it normally.
// -----------------------------------------------------------------------------
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/login',
    redirect: (context, state) {
      final path = state.uri.path;
      final auth = ref.read(authStateProvider);

      // Bootstrap abhi chal raha hai — abhi redirect mat karo, warna restored
      // session se pehle hi galat route lock ho jayega.
      if (!auth.hasCheckedAuth) return null;

      // The subscription screen is the only place an expired hospital may go.
      if (path == '/subscription') {
        if (!auth.isAuthenticated) return '/login';
        return null;
      }

      if (auth.isAuthenticated) {
        // Logged-in users ko public auth pages par nahi rehna chahiye —
        // persistent session restore hone par seedha dashboard (ya renewal)
        // kholo.
        if (path == '/' || path == '/login' || path == '/register') {
          return auth.subscriptionExpired ? '/subscription' : '/dashboard';
        }

        // Expired subscription => every module bounces to /subscription until
        // the hospital renews.
        if (auth.subscriptionExpired) return '/subscription';
      } else {
        // Authentication Security: unauthenticated users ko sirf /login,
        // /register aur /subscription accessible hain.
        if (path != '/login' &&
            path != '/register' &&
            path != '/subscription') {
          return '/login';
        }
      }
      return null;
    },
    routes: [
      // Handle a browser opening `/` without globally redirecting deep links.
      GoRoute(path: '/', redirect: (context, state) => '/login'),
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/register',
        name: 'register',
        builder: (context, state) => const HospitalRegistrationScreen(),
      ),

      // Subscription status + renewal screen. Kept OUTSIDE the authenticated
      // shell so an expired hospital can still open it and renew.
      GoRoute(
        path: '/subscription',
        name: 'subscription',
        builder: (context, state) => const SubscriptionStatusScreen(),
      ),

      // ---------------------------------------------------------------------
      // Authenticated app shell: keeps the global desktop-style top
      // navigation bar mounted on every module route below.
      // ---------------------------------------------------------------------
      ShellRoute(
        builder: (context, state, child) =>
            AppNavigationShell(currentPath: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/dashboard',
            name: 'dashboard',
            builder: (context, state) => const DashboardScreen(),
          ),

          // Patients module: list, registration and profile (nested routes).
          GoRoute(
            path: '/patients',
            name: 'patients',
            builder: (context, state) => const PatientListScreen(),
            routes: [
              GoRoute(
                path: 'register',
                name: 'patient-register',
                builder: (context, state) => const PatientRegistrationScreen(),
              ),
              GoRoute(
                path: 'search',
                name: 'patient-combined-search',
                builder: (context, state) =>
                    const PatientCombinedSearchScreen(),
              ),
              GoRoute(
                path: ':id',
                name: 'patient-profile',
                builder: (context, state) {
                  final id = state.pathParameters['id']!;
                  return PatientProfileScreen(patientId: id);
                },
              ),
            ],
          ),

          // OPD module. The global nav links to `/opd/queue`; the bare
          // `/opd` route is kept for deep-link/backwards compatibility.
          GoRoute(
            path: '/opd',
            name: 'opd',
            builder: (context, state) {
              final patientId = state.uri.queryParameters['patientId'];
              final uhid = state.uri.queryParameters['uhid'];
              final patientName = state.uri.queryParameters['patientName'];
              return OPDRegistrationScreen(
                patientId: patientId,
                uhid: uhid,
                patientName: patientName,
              );
            },
            routes: [
              GoRoute(
                path: 'register',
                name: 'opd-register',
                builder: (context, state) {
                  final patientId = state.uri.queryParameters['patientId'];
                  final uhid = state.uri.queryParameters['uhid'];
                  final patientName = state.uri.queryParameters['patientName'];
                  return OPDRegistrationScreen(
                    patientId: patientId,
                    uhid: uhid,
                    patientName: patientName,
                  );
                },
              ),
              GoRoute(
                path: 'queue',
                name: 'opd-queue',
                builder: (context, state) => const OPDQueueScreen(),
              ),
              GoRoute(
                path: 'consultation/:id',
                name: 'opd-consultation',
                builder: (context, state) {
                  final id = state.pathParameters['id']!;
                  return OPDConsultationScreen(registrationId: id);
                },
              ),
              GoRoute(
                path: 'slip/:id',
                name: 'opd-slip',
                builder: (context, state) {
                  final id = state.pathParameters['id']!;
                  final doctorName = state.uri.queryParameters['doctorName'];
                  return OPDSlipPrintScreen(
                    opdRegistrationId: id,
                    doctorName: doctorName,
                  );
                },
              ),
            ],
          ),

          // Doctor module (e-prescription). Patients can be linked from an
          // OPD registration or an IPD admission via query parameters.
          GoRoute(
            path: '/doctor',
            name: 'doctor',
            builder: (context, state) => const DoctorPrescriptionScreen(),
            routes: [
              GoRoute(
                path: 'prescription',
                name: 'doctor-prescription',
                builder: (context, state) {
                  return DoctorPrescriptionScreen(
                    patientId: state.uri.queryParameters['patientId'],
                    opdRegistrationId:
                        state.uri.queryParameters['opdRegistrationId'],
                    ipdAdmissionId: state.uri.queryParameters['ipdAdmissionId'],
                    patientName: state.uri.queryParameters['patientName'],
                    uhid: state.uri.queryParameters['uhid'],
                  );
                },
              ),
            ],
          ),

          // IPD module. The global nav links to `/ipd/queue` (IPD Patient
          // Queue); `/ipd/wards` remains the secondary Ward Management view.
          GoRoute(
            path: '/ipd',
            name: 'ipd',
            builder: (context, state) => const IPDAdmissionScreen(),
            routes: [
              GoRoute(
                path: 'admit',
                name: 'ipd-admit',
                builder: (context, state) {
                  final patientId = state.uri.queryParameters['patientId'];
                  return IPDAdmissionScreen(patientId: patientId);
                },
              ),
              GoRoute(
                path: 'queue',
                name: 'ipd-queue',
                builder: (context, state) => const IPDPatientQueueScreen(),
              ),
              GoRoute(
                path: 'wards',
                name: 'ipd-wards',
                builder: (context, state) => const IPDWardScreen(),
              ),
              // Backwards-compatible route: older bookmarks / deep links to
              // `/ipd/patients` now land on the IPD Patient Queue.
              GoRoute(
                path: 'patients',
                name: 'ipd-patients',
                redirect: (context, state) => '/ipd/queue',
              ),
              GoRoute(
                path: 'patient/:id',
                name: 'ipd-patient',
                builder: (context, state) {
                  final id = state.pathParameters['id']!;
                  return IPDPatientScreen(admissionId: id);
                },
              ),
              GoRoute(
                path: 'discharge/:id',
                name: 'ipd-discharge',
                builder: (context, state) {
                  final id = state.pathParameters['id']!;
                  return IPDDischargeScreen(admissionId: id);
                },
              ),
              GoRoute(
                path: 'transfer',
                name: 'ipd-transfer',
                builder: (context, state) {
                  final admissionId = state.uri.queryParameters['admissionId'];
                  return IPDWardTransferScreen(admissionId: admissionId);
                },
              ),
              GoRoute(
                path: 'billing',
                name: 'ipd-billing',
                builder: (context, state) {
                  final admissionId = state.uri.queryParameters['admissionId'];
                  return IPDBillingScreen(admissionId: admissionId);
                },
              ),
            ],
          ),

          // Clinical Counseling Documentation. Visit-specific — opened only
          // from the OPD consultation / IPD patient dashboard with the visit
          // context passed via query parameters.
          GoRoute(
            path: '/counseling',
            name: 'counseling',
            builder: (context, state) {
              return CounselingScreen(
                patientId: state.uri.queryParameters['patientId'] ?? '',
                patientName: state.uri.queryParameters['patientName'] ?? '',
                uhid: state.uri.queryParameters['uhid'] ?? '',
                patientComplaint: state.uri.queryParameters['complaint'] ?? '',
                visitType: state.uri.queryParameters['visitType'] ?? 'opd',
                opdRegistrationId:
                    state.uri.queryParameters['opdRegistrationId'],
                ipdAdmissionId: state.uri.queryParameters['ipdAdmissionId'],
              );
            },
            routes: [
              GoRoute(
                path: 'history',
                name: 'counseling-history',
                builder: (context, state) {
                  return CounselingSessionHistoryScreen(
                    patientId: state.uri.queryParameters['patientId'] ?? '',
                    patientName: state.uri.queryParameters['patientName'] ?? '',
                    visitType: state.uri.queryParameters['visitType'] ?? 'opd',
                    visitId: state.uri.queryParameters['visitId'] ?? '',
                  );
                },
              ),
              GoRoute(
                path: 'playback/:id',
                name: 'counseling-playback',
                builder: (context, state) {
                  return CounselingPlaybackScreen(
                    recordId: state.pathParameters['id']!,
                    patientName: state.uri.queryParameters['patientName'] ?? '',
                  );
                },
              ),
            ],
          ),

          // ABHA / ABDM module (M1 + M2 + M3). Kept inside the shell so the
          // global header stays visible. `initialTab` routes open the hub
          // directly on the Care Context / Consent / Records tabs.
          GoRoute(
            path: '/abha',
            name: 'abha',
            builder: (context, state) => ABHAVerifyScreen(
              patientId: state.uri.queryParameters['patientId'],
            ),
            routes: [
              GoRoute(
                path: 'verify',
                name: 'abha-verify',
                builder: (context, state) => ABHAVerifyScreen(
                  patientId: state.uri.queryParameters['patientId'],
                ),
              ),
              GoRoute(
                path: 'create',
                name: 'abha-create',
                builder: (context, state) => const ABHACreateScreen(),
              ),
              GoRoute(
                path: 'care-contexts',
                name: 'abha-care-contexts',
                builder: (context, state) => ABHAVerifyScreen(
                  initialTab: 1,
                  patientId: state.uri.queryParameters['patientId'],
                ),
              ),
              GoRoute(
                path: 'consent',
                name: 'abha-consent',
                builder: (context, state) => ABHAVerifyScreen(
                  initialTab: 2,
                  patientId: state.uri.queryParameters['patientId'],
                ),
              ),
              GoRoute(
                path: 'records',
                name: 'abha-records',
                builder: (context, state) => ABHAVerifyScreen(
                  initialTab: 3,
                  patientId: state.uri.queryParameters['patientId'],
                ),
              ),
            ],
          ),

          GoRoute(
            path: '/billing',
            name: 'billing',
            builder: (context, state) => const BillingScreen(),
            routes: [
              GoRoute(
                path: 'new',
                name: 'billing-new',
                builder: (context, state) => const BillCreateScreen(),
              ),
              GoRoute(
                path: 'edit/:billId',
                name: 'billing-edit',
                builder: (context, state) {
                  final billId = state.pathParameters['billId']!;
                  return BillEditScreen(billId: billId);
                },
              ),
            ],
          ),
          GoRoute(
            path: '/settings',
            name: 'settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/users',
            name: 'users',
            builder: (context, state) => const UserManagementScreen(),
          ),
          GoRoute(
            path: '/notifications',
            name: 'notifications',
            builder: (context, state) => const NotificationsScreen(),
          ),

          // Voucher / Expense module.
          GoRoute(
            path: '/vouchers',
            name: 'vouchers',
            builder: (context, state) => const VoucherListScreen(),
            routes: [
              GoRoute(
                path: 'new',
                name: 'voucher-new',
                builder: (context, state) => const VoucherEntryScreen(),
              ),
              GoRoute(
                path: 'settings',
                name: 'voucher-settings',
                builder: (context, state) => const VoucherSettingsScreen(),
              ),
            ],
          ),

          // Compliance & Renewal Reminder module (separate from Voucher/Expense).
          GoRoute(
            path: '/compliance',
            name: 'compliance',
            builder: (context, state) => const ComplianceDashboardScreen(),
            routes: [
              GoRoute(
                path: 'new',
                name: 'compliance-new',
                builder: (context, state) => const ComplianceRecordFormScreen(),
              ),
              GoRoute(
                path: 'documents',
                name: 'compliance-documents',
                builder: (context, state) => const ComplianceDocumentsScreen(),
              ),
              GoRoute(
                path: 'reminders',
                name: 'compliance-reminders',
                builder: (context, state) =>
                    const ComplianceReminderHistoryScreen(),
              ),
              GoRoute(
                path: 'audit-logs',
                name: 'compliance-audit-logs',
                builder: (context, state) => const ComplianceAuditLogScreen(),
              ),
              GoRoute(
                path: 'record/:id',
                name: 'compliance-record',
                builder: (context, state) {
                  final id = state.pathParameters['id']!;
                  return ComplianceRecordDetailScreen(recordId: id);
                },
                routes: [
                  GoRoute(
                    path: 'edit',
                    name: 'compliance-record-edit',
                    builder: (context, state) {
                      final id = state.pathParameters['id']!;
                      return ComplianceRecordFormScreen(recordId: id);
                    },
                  ),
                ],
              ),
              GoRoute(
                path: 'document/:id/view',
                name: 'compliance-document-view',
                builder: (context, state) {
                  final id = state.pathParameters['id']!;
                  return ComplianceDocumentViewerScreen(documentId: id);
                },
              ),
            ],
          ),

          // Unified Lab / Diagnostics module (Pathology + Radiology +
          // Cardiology + Other). `/lab` is kept as a redirect for backwards
          // compatibility with the dashboard card and older bookmarks.
          GoRoute(path: '/lab', redirect: (context, state) => '/diagnostics'),
          GoRoute(
            path: '/diagnostics',
            name: 'diagnostics',
            builder: (context, state) => const DiagnosticOrderScreen(),
            routes: [
              GoRoute(
                path: 'order',
                name: 'diagnostics-order',
                builder: (context, state) => DiagnosticOrderScreen(
                  patientId: state.uri.queryParameters['patientId'],
                  patientName: state.uri.queryParameters['patientName'],
                  uhid: state.uri.queryParameters['uhid'],
                ),
              ),
              // Test master lives under Settings > Masters, but keeps its own
              // route so deep links and the settings tile can open it.
              GoRoute(
                path: 'tests',
                name: 'diagnostics-tests',
                builder: (context, state) =>
                    const DiagnosticTestsMasterScreen(),
              ),
              GoRoute(
                path: 'results',
                name: 'diagnostics-results',
                builder: (context, state) => const DiagnosticResultScreen(),
              ),
              GoRoute(
                path: 'revenue',
                name: 'diagnostics-revenue',
                builder: (context, state) => const LabRevenueDashboard(),
              ),
            ],
          ),

          // WhatsApp Marketing module (Meta WhatsApp Cloud API).
          GoRoute(
            path: '/whatsapp',
            name: 'whatsapp',
            builder: (context, state) => const WhatsappAnalyticsScreen(),
            routes: [
              GoRoute(
                path: 'campaigns',
                name: 'whatsapp-campaigns',
                builder: (context, state) => const WhatsappCampaignsScreen(),
              ),
              GoRoute(
                path: 'templates',
                name: 'whatsapp-templates',
                builder: (context, state) => const WhatsappTemplatesScreen(),
              ),
              GoRoute(
                path: 'settings',
                name: 'whatsapp-settings',
                builder: (context, state) => const WhatsappSettingsScreen(),
              ),
              GoRoute(
                path: 'opt-outs',
                name: 'whatsapp-opt-outs',
                builder: (context, state) => const WhatsappOptOutScreen(),
              ),
            ],
          ),

          // Reports module: generated reports list + detail view.
          GoRoute(
            path: '/reports',
            name: 'reports',
            builder: (context, state) => const ReportsScreen(),
            routes: [
              GoRoute(
                path: ':id',
                name: 'report-detail',
                builder: (context, state) {
                  final id = state.pathParameters['id']!;
                  return ReportsDetailScreen(reportId: id);
                },
              ),
            ],
          ),

          // Modules that are not implemented yet still live inside the shell
          // so the global header remains available.
          for (final module in const {'/pharmacy': 'Pharmacy'}.entries)
            GoRoute(
              path: module.key,
              builder: (context, state) =>
                  _ModuleComingSoonScreen(moduleName: module.value),
            ),
        ],
      ),
    ],
    errorBuilder: (context, state) => AppNavigationShell(
      currentPath: state.uri.path,
      child: Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                'Page not found',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text('The requested page could not be found'),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => context.go('/dashboard'),
                child: const Text('Go to Dashboard'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
});

class _ModuleComingSoonScreen extends StatelessWidget {
  const _ModuleComingSoonScreen({required this.moduleName});

  final String moduleName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SmartAppBar(title: Text(moduleName)),
      body: Center(child: Text('$moduleName module is coming soon.')),
    );
  }
}
