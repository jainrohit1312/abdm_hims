import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;
  bool _rememberMe = false;

  Timer? _lockoutTicker;
  Timer? _emailDebounce;

  /// Lock expiry discovered via [AuthService.checkAccountLocked] when the
  /// user types an email that is already locked (e.g. app restarted during a
  /// lockout window).
  DateTime? _preExistingLockUntil;

  @override
  void initState() {
    super.initState();
    // Har second UI refresh karo taaki lockout countdown live dikhe.
    _lockoutTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final authLocked = ref.read(authStateProvider).accountLockedUntil;
      if (authLocked != null || _preExistingLockUntil != null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _lockoutTicker?.cancel();
    _emailDebounce?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onEmailChanged(String value) {
    _emailDebounce?.cancel();
    _emailDebounce = Timer(const Duration(milliseconds: 400), () async {
      final info = await ref
          .read(authServiceProvider)
          .checkAccountLocked(value.trim());
      if (!mounted) return;
      setState(() {
        _preExistingLockUntil = info.isLocked ? info.lockedUntil : null;
      });
    });
  }

  String _formatRemaining(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    final messenger = ScaffoldMessenger.of(context);
    final email = _emailController.text.trim();

    // UI-level lockout guard — bina network call ke turant feedback.
    final lock = await ref.read(authServiceProvider).checkAccountLocked(email);
    if (lock.isLocked) {
      setState(() => _preExistingLockUntil = lock.lockedUntil);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Account locked. Try again in '
            '${_formatRemaining(lock.remaining)}.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final success = await ref
        .read(authStateProvider.notifier)
        .login(email, _passwordController.text.trim());

    if (!success || !mounted) return;

    // Successful login — lockout state clear karo.
    setState(() => _preExistingLockUntil = null);

    // Critical check: every downstream screen (dashboard, OPD, IPD) depends
    // on authState.hospitalId. If it's missing, stay on the login screen
    // and surface the problem instead of navigating to a broken dashboard.
    final authState = ref.read(authStateProvider);
    final hospitalId = authState.hospitalId;
    print('✅ [LoginScreen] authState.hospitalId after login: $hospitalId');

    if (hospitalId == null || hospitalId.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Your account is not assigned to any hospital. '
            'Please contact the administrator.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Subscription gate: an expired trial is not allowed inside the app.
    // The user is taken straight to /subscription to renew.
    final subscriptionExpired = ref.read(authStateProvider).subscriptionExpired;
    if (subscriptionExpired) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Subscription Expired. Please renew to continue.'),
          backgroundColor: Colors.red,
        ),
      );
      if (mounted) {
        context.go('/subscription');
      }
      return;
    }

    if (mounted) {
      context.go('/dashboard');
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final theme = Theme.of(context);

    // Effective lock expiry: authState (failed attempts from AuthNotifier)
    // ya pre-existing lockout (email type karne par secure storage se).
    final DateTime? lockedUntil =
        authState.accountLockedUntil ?? _preExistingLockUntil;
    final now = DateTime.now();
    final isLocked = lockedUntil != null && lockedUntil.isAfter(now);
    final remaining = isLocked ? lockedUntil.difference(now) : Duration.zero;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.local_hospital,
                        size: 56,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Welcome Back',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Sign in to continue',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),

                      // ---------------------------------------------------------
                      // Lockout banner — account 15 min ke liye locked hai.
                      // ---------------------------------------------------------
                      if (isLocked) ...[
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: theme.colorScheme.error,
                              width: 1.5,
                            ),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.lock_clock,
                                    color: theme.colorScheme.error,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      'Account Locked',
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: theme
                                                .colorScheme
                                                .onErrorContainer,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Too many failed login attempts. '
                                'Try again in ${_formatRemaining(remaining)}.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: theme.colorScheme.onErrorContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'बहुत सारे गलत लॉगिन प्रयास। '
                                'कृपया ${_formatRemaining(remaining)} बाद पुनः प्रयास करें।',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: theme.colorScheme.onErrorContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        enabled: !isLocked,
                        onChanged: _onEmailChanged,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.email_outlined),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter your email';
                          }
                          if (!value.contains('@')) {
                            return 'Please enter a valid email';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        enabled: !isLocked,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outlined),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                            onPressed: () {
                              setState(
                                () => _obscurePassword = !_obscurePassword,
                              );
                            },
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter your password';
                          }
                          if (value.length < 6) {
                            return 'Password must be at least 6 characters';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Checkbox(
                            value: _rememberMe,
                            onChanged: isLocked
                                ? null
                                : (value) {
                                    setState(
                                      () => _rememberMe = value ?? false,
                                    );
                                  },
                          ),
                          const Text('Remember me'),
                          const Spacer(),
                          TextButton(
                            onPressed: isLocked
                                ? null
                                : () {
                                    // Forgot password flow
                                    showDialog(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: const Text('Reset Password'),
                                        content: const Text(
                                          'Enter your email to receive a password reset link.',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context),
                                            child: const Text('Cancel'),
                                          ),
                                          TextButton(
                                            onPressed: () {
                                              // Send reset email
                                              Navigator.pop(context);
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                    'Password reset link sent!',
                                                  ),
                                                ),
                                              );
                                            },
                                            child: const Text('Send'),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                            child: const Text('Forgot Password?'),
                          ),
                        ],
                      ),
                      if (authState.error != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            authState.error!,
                            style: TextStyle(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                            textAlign: TextAlign.start,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: (authState.isLoading || isLocked)
                            ? null
                            : _handleLogin,
                        child: authState.isLoading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Sign In'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => context.push('/register'),
                        icon: const Icon(Icons.local_hospital_outlined, size: 18),
                        label: const Text('New Registration'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
