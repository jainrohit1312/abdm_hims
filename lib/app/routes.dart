import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../presentation/screens/auth/login_screen.dart';
import '../presentation/screens/dashboard/dashboard_screen.dart';
import '../presentation/screens/patients/patient_list_screen.dart';
import '../presentation/screens/patients/patient_registration_screen.dart';
import '../presentation/screens/patients/patient_profile_screen.dart';
import '../presentation/screens/opd/opd_registration_screen.dart';
import '../presentation/screens/opd/opd_queue_screen.dart';
import '../presentation/screens/opd/opd_consultation_screen.dart';
import '../presentation/screens/ipd/ipd_admission_screen.dart';
import '../presentation/screens/ipd/ipd_ward_screen.dart';
import '../presentation/screens/ipd/ipd_patient_screen.dart';
import '../presentation/screens/ipd/ipd_discharge_screen.dart';
import '../presentation/screens/abha/abha_verify_screen.dart';
import '../presentation/screens/abha/abha_create_screen.dart';
import '../presentation/screens/billing/billing_screen.dart';
import '../presentation/screens/settings/settings_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/login',
    routes: [
      // Handle a browser opening `/` without globally redirecting deep links.
      GoRoute(path: '/', redirect: (context, state) => '/login'),
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/dashboard',
        name: 'dashboard',
        builder: (context, state) => const DashboardScreen(),
      ),
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
            path: ':id',
            name: 'patient-profile',
            builder: (context, state) {
              final id = state.pathParameters['id']!;
              return PatientProfileScreen(patientId: id);
            },
          ),
        ],
      ),
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
        ],
      ),
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
            path: 'wards',
            name: 'ipd-wards',
            builder: (context, state) => const IPDWardScreen(),
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
        ],
      ),
      GoRoute(
        path: '/abha',
        name: 'abha',
        builder: (context, state) => const ABHAVerifyScreen(),
        routes: [
          GoRoute(
            path: 'verify',
            name: 'abha-verify',
            builder: (context, state) => const ABHAVerifyScreen(),
          ),
          GoRoute(
            path: 'create',
            name: 'abha-create',
            builder: (context, state) => const ABHACreateScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/billing',
        name: 'billing',
        builder: (context, state) => const BillingScreen(),
      ),
      GoRoute(
        path: '/settings',
        name: 'settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      for (final module in const {
        '/lab': 'Laboratory',
        '/pharmacy': 'Pharmacy',
        '/reports': 'Reports',
      }.entries)
        GoRoute(
          path: module.key,
          builder: (context, state) =>
              _ModuleComingSoonScreen(moduleName: module.value),
        ),
    ],
    errorBuilder: (context, state) => Scaffold(
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
  );
});

class _ModuleComingSoonScreen extends StatelessWidget {
  const _ModuleComingSoonScreen({required this.moduleName});

  final String moduleName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(moduleName)),
      body: Center(child: Text('$moduleName module is coming soon.')),
    );
  }
}
 