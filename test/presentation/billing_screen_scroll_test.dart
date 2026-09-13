import 'package:abdm_hims/app/providers.dart';
import 'package:abdm_hims/app/theme.dart';
import 'package:abdm_hims/presentation/screens/billing/billing_screen.dart';
import 'package:abdm_hims/services/auth_service.dart';
import 'package:abdm_hims/services/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockDatabaseService extends Mock implements DatabaseService {}

/// Never used: the fake notifier only carries the signed-in hospital state.
/// Mocking it keeps a real [SupabaseClient] (and its GoTrue auto-refresh timer)
/// out of the test.
class _MockAuthService extends Mock implements AuthService {}

/// Signed-in hospital without any network/plugin call.
class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(super.authService, super.dbService) {
    state = const AuthState(
      isAuthenticated: true,
      hasCheckedAuth: true,
      userId: 'test-user',
      userRole: 'admin',
      hospitalId: 'hospital-1',
    );
  }
}

/// One unified-bill row exactly as the billing list reads it.
Map<String, dynamic> _bill(int index) => {
  'id': 'bill-$index',
  'source_type': 'opd',
  'opd_registration_id': 'opd-$index',
  'bill_number': 'OPD-$index',
  'patient_name': 'Patient $index',
  'uhid': 'UHID-$index',
  'bill_date': '2026-09-13',
  'total_amount': 500 + index,
  'paid_amount': 500 + index,
  'balance_amount': 0,
  'payment_status': 'paid',
};

void main() {
  testWidgets(
    'BillingScreen keeps rendering while the list is scrolled and its '
    '"Transaction History" tiles are expanded (PageStorageKey regression)',
    (tester) async {
      final db = _MockDatabaseService();
      // 30 rows == billingPageSize, so the list also exercises "load more".
      final bills = [for (var i = 0; i < 30; i++) _bill(i)];

      when(
        () => db.getBillingHistoryPageLocal(
          hospitalId: any(named: 'hospitalId'),
          sourceType: any(named: 'sourceType'),
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((invocation) async {
        final page = invocation.namedArguments[#page] as int;
        return page == 0 ? bills : <Map<String, dynamic>>[];
      });
      when(() => db.getPaymentLogs(any())).thenAnswer(
        (_) async => <Map<String, dynamic>>[],
      );

      tester.view.physicalSize = const Size(420, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseServiceProvider.overrideWithValue(db),
            authStateProvider.overrideWith(
              (ref) => _FakeAuthNotifier(_MockAuthService(), db),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: const BillingScreen(),
          ),
        ),
      );

      // Fixed pumps: a loading spinner would never settle.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // The list must show real bills, not an empty/error state.
      expect(tester.takeException(), isNull);
      expect(find.text('No bills found.'), findsNothing);
      expect(find.text('Patient 0'), findsOneWidget);

      // Expand a Transaction History tile, then scroll: before the fix this
      // combination threw `type 'double' is not a subtype of type 'bool?' in
      // type cast` (a blank grey error box in a release build).
      await tester.tap(find.text('Transaction History').first);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(tester.takeException(), isNull);

      for (var step = 0; step < 12; step++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester.takeException(),
          isNull,
          reason: 'exception while scrolling (step $step)',
        );
      }

      // Scrolling back up rebuilds the tiles that were expanded earlier.
      for (var step = 0; step < 12; step++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester.takeException(),
          isNull,
          reason: 'exception while scrolling back (step $step)',
        );
      }

      expect(find.byType(Card), findsWidgets);
    },
  );
}
