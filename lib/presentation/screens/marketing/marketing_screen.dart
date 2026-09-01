import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../widgets/smart_navigation.dart';
import 'marketing_areas_tab.dart';
import 'marketing_dashboard_tab.dart';
import 'marketing_referrals_tab.dart';
import 'marketing_visits_tab.dart';
import 'referral_doctors_tab.dart';

/// ---------------------------------------------------------------------------
/// PRO / Marketing root screen (`/marketing`).
///
/// UI composition only: the screen lays out the five module tabs and delegates
/// every data/calculation concern to providers + pure services. It never
/// performs a Supabase query or geofence/analytics calculation itself.
///
/// Domain note: Referral Doctors here are a COMPLETELY SEPARATE domain from
/// hospital doctors. They live only inside this module.
/// ---------------------------------------------------------------------------
class MarketingScreen extends ConsumerStatefulWidget {
  const MarketingScreen({super.key});

  @override
  ConsumerState<MarketingScreen> createState() => _MarketingScreenState();
}

class _MarketingScreenState extends ConsumerState<MarketingScreen> {
  @override
  Widget build(BuildContext context) {
    final hospitalId = ref.watch(authStateProvider).hospitalId;

    if (hospitalId == null || hospitalId.isEmpty) {
      return Scaffold(
        appBar: SmartAppBar(title: const Text('PRO / Marketing')),
        body: const Center(
          child: Text('Hospital not assigned to this user.'),
        ),
      );
    }

    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: SmartAppBar(
          title: const Text('PRO / Marketing'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Dashboard'),
              Tab(text: 'Referral Doctors'),
              Tab(text: 'Visits'),
              Tab(text: 'Referrals'),
              Tab(text: 'Areas'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            MarketingDashboardTab(hospitalId: hospitalId),
            ReferralDoctorsTab(hospitalId: hospitalId),
            MarketingVisitsTab(hospitalId: hospitalId),
            MarketingReferralsTab(hospitalId: hospitalId),
            MarketingAreasTab(hospitalId: hospitalId),
          ],
        ),
      ),
    );
  }
}
