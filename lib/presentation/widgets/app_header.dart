import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import 'smart_navigation.dart';

/// Height of the header content. The system status-bar inset is added on top
/// of this value by the [Scaffold] when [AppHeader] is used as its `appBar`.
const double kAppHeaderHeight = 56;

/// Width below which the horizontal desktop header collapses into a compact
/// bar with a hamburger button that opens [AppNavDrawer].
const double kAppHeaderDesktopBreakpoint = 900;

/// Global navigation shell mounted by the `ShellRoute` in `lib/app/routes.dart`.
///
/// It keeps the top navigation bar (and, on small screens, the navigation
/// drawer) alive on every authenticated route while the routed child is
/// swapped underneath it.
class AppNavigationShell extends ConsumerStatefulWidget {
  const AppNavigationShell({
    required this.currentPath,
    required this.child,
    super.key,
  });

  /// Full route path of the current location (e.g. `/patients/register`),
  /// taken from `GoRouterState.uri.path`.
  final String currentPath;

  /// The page rendered by the currently matched sub-route.
  final Widget child;

  @override
  ConsumerState<AppNavigationShell> createState() => _AppNavigationShellState();
}

class _AppNavigationShellState extends ConsumerState<AppNavigationShell> {
  @override
  void initState() {
    super.initState();
    // Riverpod forbids provider mutation during the build/lifecycle phase, so
    // the initial mirror is scheduled after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _mirrorCurrentTab());
  }

  @override
  void didUpdateWidget(AppNavigationShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPath != widget.currentPath) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _mirrorCurrentTab());
    }
  }

  /// Mirrors the active location into [currentTabProvider] for widgets that
  /// want to watch the active module without a [BuildContext].
  void _mirrorCurrentTab() {
    if (!mounted) return;
    final notifier = ref.read(currentTabProvider.notifier);
    if (notifier.state != widget.currentPath) {
      notifier.state = widget.currentPath;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Hard gate: when the hospital's trial/subscription has expired, no module
    // inside the shell may be used. The user can only open /subscription
    // (which lives outside the shell) to renew.
    final authState = ref.watch(authStateProvider);
    if (authState.subscriptionExpired) {
      return Scaffold(
        appBar: AppHeader(currentPath: widget.currentPath),
        drawer: AppNavDrawer(currentPath: widget.currentPath),
        body: _SubscriptionExpiredView(
          onRenew: () => context.go('/subscription'),
        ),
      );
    }

    return Scaffold(
      appBar: AppHeader(currentPath: widget.currentPath),
      drawer: AppNavDrawer(currentPath: widget.currentPath),
      body: widget.child,
    );
  }
}

/// Full-screen "Subscription Expired" blocker shown inside the app shell.
class _SubscriptionExpiredView extends StatelessWidget {
  const _SubscriptionExpiredView({required this.onRenew});

  final VoidCallback onRenew;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.block, size: 72, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              'Subscription Expired',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.error,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Your free trial has ended.\nRenew a plan to continue using MediFlux Hospital Software.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onRenew,
              icon: const Icon(Icons.lock_open),
              label: const Text('Renew Subscription'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Desktop-style top navigation bar used as the global header.
///
/// On wide screens it renders the brand plus a horizontal row of module links;
/// on narrow screens it collapses to a hamburger button that opens
/// [AppNavDrawer]. The active module is derived from [currentPath].
class AppHeader extends ConsumerWidget implements PreferredSizeWidget {
  const AppHeader({required this.currentPath, super.key});

  /// Full route path of the current location.
  final String currentPath;

  @override
  Size get preferredSize => const Size.fromHeight(kAppHeaderHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final topPadding = MediaQuery.paddingOf(context).top;

    return Material(
      color: colorScheme.surface,
      elevation: 2,
      shadowColor: colorScheme.shadow,
      child: Padding(
        padding: EdgeInsets.only(top: topPadding),
        child: SizedBox(
          height: kAppHeaderHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isDesktop =
                  constraints.maxWidth >= kAppHeaderDesktopBreakpoint;
              return isDesktop
                  ? _buildDesktopBar(context, colorScheme, ref)
                  : _buildCompactBar(context, colorScheme, ref);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopBar(
    BuildContext context,
    ColorScheme colorScheme,
    WidgetRef ref,
  ) {
    final publicUserId = ref.watch(currentPublicUserIdProvider).value;
    final unreadCount = publicUserId == null || publicUserId.isEmpty
        ? 0
        : ref.watch(unreadNotificationCountProvider(publicUserId)).value ?? 0;
    final isRootPage = isRootModulePath(currentPath);

    return Row(
      children: [
        const SizedBox(width: 16),
        const _Brand(height: 38),
        const SizedBox(width: 4),
        // Smart Navbar: Home icon is always visible and gets high-priority
        // styling on root module pages.
        IconButton(
          tooltip: 'Go to Dashboard',
          onPressed: () => context.go('/dashboard'),
          icon: Icon(
            Icons.home,
            color: isRootPage
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
          style: isRootPage
              ? IconButton.styleFrom(
                  backgroundColor: colorScheme.primaryContainer,
                )
              : null,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final destination in _navDestinations) ...[
                  _NavButton(
                    destination: destination,
                    active: _isActive(currentPath, destination),
                    colorScheme: colorScheme,
                  ),
                  const SizedBox(width: 4),
                ],
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: 'Notifications',
          onPressed: () => context.go('/notifications'),
          icon: Badge(
            isLabelVisible: unreadCount > 0,
            label: Text('$unreadCount'),
            child: const Icon(Icons.notifications_outlined),
          ),
        ),
        IconButton(
          tooltip: 'Logout',
          onPressed: () => _confirmLogout(context, ref),
          icon: const Icon(Icons.logout),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildCompactBar(
    BuildContext context,
    ColorScheme colorScheme,
    WidgetRef ref,
  ) {
    final isRootPage = isRootModulePath(currentPath);
    return Row(
      children: [
        IconButton(
          tooltip: 'Open navigation menu',
          onPressed: () => Scaffold.of(context).openDrawer(),
          icon: const Icon(Icons.menu),
        ),
        const _Brand(height: 32),
        const Spacer(),
        // Smart Navbar: highlighted Home icon on root pages.
        IconButton(
          tooltip: 'Go to Dashboard',
          onPressed: () => context.go('/dashboard'),
          icon: Icon(
            Icons.home,
            color: isRootPage
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
        ),
        IconButton(
          tooltip: 'Logout',
          onPressed: () => _confirmLogout(context, ref),
          icon: const Icon(Icons.logout),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// Brand block shown on the left of the header. Tapping it navigates to the
/// dashboard so there is always a quick way back to `/dashboard`.
class _Brand extends StatelessWidget {
  const _Brand({this.height = 36});

  /// Height of the MediFlux logo lockup in logical pixels. The width follows
  /// the PNG's intrinsic aspect ratio (500 x 136) via [BoxFit.contain].
  final double height;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.go('/dashboard'),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Image.asset(
          'assets/branding/mediflux_header_logo_light.png',
          height: height,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          alignment: Alignment.centerLeft,
        ),
      ),
    );
  }
}

/// One clickable module entry in the horizontal desktop navigation row.
class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.destination,
    required this.active,
    required this.colorScheme,
  });

  final _NavDestination destination;
  final bool active;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final foreground = active
        ? colorScheme.primary
        : colorScheme.onSurfaceVariant;
    final theme = Theme.of(context);

    return InkWell(
      onTap: () => context.go(destination.route),
      borderRadius: BorderRadius.circular(8),
      hoverColor: colorScheme.primary.withValues(alpha: 0.06),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? colorScheme.primaryContainer.withValues(alpha: 0.45)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border(
            bottom: BorderSide(
              color: active ? colorScheme.primary : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(destination.icon, size: 18, color: foreground),
            const SizedBox(width: 6),
            Text(
              destination.label,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Navigation drawer used on compact screens (hamburger menu).
class AppNavDrawer extends ConsumerWidget {
  const AppNavDrawer({required this.currentPath, super.key});

  /// Full route path of the current location.
  final String currentPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    return Drawer(
      width: 300,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Image.asset(
                'assets/branding/mediflux_header_logo_light.png',
                height: 44,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                alignment: Alignment.centerLeft,
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: 8),
            for (final destination in _navDestinations)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    destination.icon,
                    size: 20,
                    color: _isActive(currentPath, destination)
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                  title: Text(
                    destination.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: _isActive(currentPath, destination)
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                  selected: _isActive(currentPath, destination),
                  selectedTileColor: colorScheme.primaryContainer.withValues(
                    alpha: 0.35,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    context.go(destination.route);
                  },
                ),
              ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: ListTile(
                dense: true,
                leading: Icon(Icons.logout, size: 20, color: colorScheme.error),
                title: Text(
                  'Logout',
                  style: TextStyle(color: colorScheme.error, fontSize: 14),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _confirmLogout(context, ref);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The modules rendered in the global header, in display order.
class _NavDestination {
  const _NavDestination({
    required this.label,
    required this.route,
    required this.icon,
    this.exactMatch = false,
    this.excludeRoutes = const [],
  });

  final String label;
  final String route;
  final IconData icon;

  /// When true, this destination is only highlighted when the current path
  /// equals [route] exactly (used for secondary screens such as Ward
  /// Management that share a module root with the primary IPD screen).
  final bool exactMatch;

  /// Routes that must NOT be highlighted by this destination, even though they
  /// share the same module root (used by IPD Patient Queue to leave
  /// `/ipd/wards` for the Ward Management entry).
  final List<String> excludeRoutes;
}

const List<_NavDestination> _navDestinations = [
  _NavDestination(
    label: 'Dashboard',
    route: '/dashboard',
    icon: Icons.dashboard_outlined,
  ),
  _NavDestination(
    label: 'Patients',
    route: '/patients',
    icon: Icons.people_outline,
  ),
  _NavDestination(
    label: 'Employees',
    route: '/employees',
    icon: Icons.badge_outlined,
  ),
  _NavDestination(
    label: 'Billing',
    route: '/billing',
    icon: Icons.receipt_long_outlined,
  ),
  _NavDestination(
    label: 'Voucher/Expense',
    route: '/vouchers',
    icon: Icons.account_balance_wallet_outlined,
  ),
  _NavDestination(
    label: 'Compliance',
    route: '/compliance',
    icon: Icons.verified_user_outlined,
  ),
  _NavDestination(
    label: 'OPD',
    route: '/opd/queue',
    icon: Icons.medical_services_outlined,
  ),
  _NavDestination(
    label: 'IPD Patient Queue',
    route: '/ipd/queue',
    icon: Icons.medical_information_outlined,
    excludeRoutes: ['/ipd/wards'],
  ),
  _NavDestination(
    label: 'Ward Management',
    route: '/ipd/wards',
    icon: Icons.local_hotel_outlined,
    exactMatch: true,
  ),
  _NavDestination(
    label: 'Diagnostics',
    route: '/diagnostics',
    icon: Icons.biotech_outlined,
  ),
  _NavDestination(
    label: 'Reports',
    route: '/reports',
    icon: Icons.analytics_outlined,
  ),
  _NavDestination(
    label: 'WhatsApp',
    route: '/whatsapp',
    icon: Icons.chat_outlined,
  ),
  _NavDestination(
    label: 'Settings',
    route: '/settings',
    icon: Icons.settings_outlined,
  ),
];

/// Normalizes a route path to its top-level module segment.
///
/// `/patients/register` -> `/patients`, `/opd/queue` -> `/opd`.
String _rootSegment(String path) {
  final segments = path
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.isEmpty) return '/';
  return '/${segments.first}';
}

/// Whether [currentPath] belongs to the module identified by [destination].
bool _isActive(String currentPath, _NavDestination destination) {
  if (destination.exactMatch) {
    return currentPath == destination.route;
  }
  if (_rootSegment(currentPath) != _rootSegment(destination.route)) {
    return false;
  }
  for (final excluded in destination.excludeRoutes) {
    if (currentPath == excluded || currentPath.startsWith('$excluded/')) {
      return false;
    }
  }
  return true;
}

/// Shared logout confirmation dialog. Clears the Supabase session through
/// [authStateProvider] and returns the user to the login screen.
Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Logout'),
      content: const Text('Are you sure you want to logout?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Logout', style: TextStyle(color: Colors.red)),
        ),
      ],
    ),
  );

  if (confirmed != true || !context.mounted) return;

  // FCM: device token remove + hospital topic unsubscribe before logout.
  await ref.read(pushNotificationServiceProvider).stop();
  await ref.read(authStateProvider.notifier).logout();
  if (context.mounted) context.go('/login');
}
