import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:compact_sales_monitoring/services/firebase_service.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/providers/activation_provider.dart';
import 'package:compact_sales_monitoring/providers/company_branding_provider.dart';
import 'package:compact_sales_monitoring/providers/route_provider.dart';
import 'package:compact_sales_monitoring/providers/version_provider.dart';
import 'package:compact_sales_monitoring/models/company_branding_model.dart';
import 'package:compact_sales_monitoring/app_router.dart';
import 'package:compact_sales_monitoring/screens/splash_screen.dart';
import 'package:compact_sales_monitoring/services/background_location_service.dart';

/// Selectively clears corrupted background tracking keys left by older app
/// versions (e.g. v2.1.4, v2.1.5). Only removes background service state —
/// activation codes and Firebase Auth tokens are never touched.
Future<void> _runV216Migration() async {
  const migrationKey = 'has_migrated_v216';

  // Keys used ONLY by the background location service — safe to wipe.
  const backgroundTrackingKeys = [
    'active_route_id',
    'last_checkpoint_time',
    'last_checkpoint_lat',
    'last_checkpoint_lon',
  ];

  final prefs = await SharedPreferences.getInstance();

  // Already migrated on a previous launch — skip.
  if (prefs.getBool(migrationKey) == true) return;

  debugPrint('[Migration] Running v2.1.6 migration: clearing stale background tracking state...');

  // Delete ONLY background tracking keys.
  // Keys like is_activated, activation_code, and Firebase Auth tokens
  // are stored separately and are NOT affected.
  for (final key in backgroundTrackingKeys) {
    await prefs.remove(key);
    debugPrint('[Migration] Removed key: $key');
  }

  // Mark migration as complete so it never runs again.
  await prefs.setBool(migrationKey, true);
  debugPrint('[Migration] v2.1.6 migration complete.');
}

/// Clears stale batch checkpoint data left by broken v2.1.7/v2.1.8 builds.
/// Those builds had a race condition that could leave corrupt or unprocessed
/// checkpoint data in the batch queue, causing silent upload failures.
/// This migration wipes the batch so v2.1.9 starts with a clean slate.
Future<void> _runV219Migration() async {
  const migrationKey = 'has_migrated_v219';
  const batchKey = 'batched_checkpoints_v2';

  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(migrationKey) == true) return;

  debugPrint('[Migration] Running v2.1.9 migration: clearing stale batch checkpoint data...');
  await prefs.remove(batchKey);
  await prefs.setInt('batch_pending_count', 0);
  await prefs.remove('last_flush_time');

  await prefs.setBool(migrationKey, true);
  debugPrint('[Migration] v2.1.9 migration complete.');
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FirebaseService.initializeApp();

  // Step 1: Run one-time migrations to clear stale state from older versions.
  // These preserve login, activation, and Firebase Auth data.
  await _runV216Migration();
  await _runV219Migration();

  // Step 2: Initialize the background service with a safety net.
  // If the native plugin has corrupted state that causes an immediate crash
  // (e.g. ForegroundServiceStartNotAllowedException on Android 12+), we
  // catch the error so the app can still launch normally. The service will
  // re-initialize correctly the next time the salesman begins a call.
  try {
    await BackgroundLocationService.initializeService();
  } catch (e, stack) {
    debugPrint('[BackgroundService] Initialization failed (non-fatal): $e');
    debugPrint('[BackgroundService] Stack: $stack');
  }

  final initialBranding = await CompanyBrandingProvider.loadLastCachedBranding();
  runApp(MainApp(initialBranding: initialBranding));
}

class MainApp extends StatelessWidget {
  final CompanyBranding? initialBranding;

  const MainApp({
    super.key,
    this.initialBranding,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ActivationProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => RouteProvider()),
        ChangeNotifierProvider(create: (_) => VersionProvider()),
        ChangeNotifierProxyProvider<AuthProvider, CompanyBrandingProvider>(
          create: (_) => CompanyBrandingProvider(
            initialBranding: initialBranding,
          ),
          update: (_, authProvider, brandingProvider) {
            final provider = brandingProvider ?? CompanyBrandingProvider();
            provider.updateFromUser(authProvider.currentUser);
            return provider;
          },
        ),
      ],
      child: MaterialApp(
        title: 'Sales Agile Monitoring',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFB7ADF8),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFFFBFBFF),
          cardColor: Colors.white,
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF8F83F0), width: 1.5),
            ),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFFEEEAFE),
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            foregroundColor: Color(0xFF2F2A57),
            titleTextStyle: TextStyle(
              color: Color(0xFF2F2A57),
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
            iconTheme: IconThemeData(color: Color(0xFF2F2A57)),
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE6E1FD),
              foregroundColor: const Color(0xFF3D356B),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE6E1FD),
              foregroundColor: const Color(0xFF3D356B),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF7B68EE),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFF1A1A2E),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF2A2A4E),
            foregroundColor: Colors.white,
          ),
        ),
        themeMode: ThemeMode.light,
        home: const MainAppHome(),
      ),
    );
  }
}

class MainAppHome extends StatefulWidget {
  const MainAppHome({super.key});

  @override
  State<MainAppHome> createState() => _MainAppHomeState();
}

class _MainAppHomeState extends State<MainAppHome>
    with SingleTickerProviderStateMixin {
  bool _showSplash = true;
  bool _splashContentFinished = false;
  bool _transitionStarted = false;
  late AnimationController _transitionController;

  late final ActivationProvider _activationProvider;
  late final AuthProvider _authProvider;

  @override
  void initState() {
    super.initState();
    _transitionController = AnimationController(
      duration: const Duration(milliseconds: 1400),
      vsync: this,
    );

    _transitionController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() {
          _showSplash = false;
        });
      }
    });

    _activationProvider = context.read<ActivationProvider>();
    _authProvider = context.read<AuthProvider>();

    _activationProvider.addListener(_tryStartTransition);
    _authProvider.addListener(_tryStartTransition);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activationProvider.initialize();
      context.read<VersionProvider>().checkVersion();
    });
  }

  void _completeSplash() {
    _splashContentFinished = true;
    _tryStartTransition();
  }

  void _tryStartTransition() {
    if (_transitionStarted || !_splashContentFinished) return;

    final activationProvider = context.read<ActivationProvider>();
    final authProvider = context.read<AuthProvider>();

    final canExitSplash =
        !activationProvider.isChecking &&
        (!authProvider.isInitializing || authProvider.requiresLaunchRetry);

    if (!canExitSplash) return;

    _transitionStarted = true;
    _transitionController.forward(from: 0);
  }

  @override
  void dispose() {
    _activationProvider.removeListener(_tryStartTransition);
    _authProvider.removeListener(_tryStartTransition);
    _transitionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _transitionController,
      builder: (context, _) {
        // t: 0 → 1 over 1400ms
        final t = _transitionController.value;
        // Smooth ease-out curve
        final easeT = Curves.easeOutQuart.transform(t);

        // Height to slide (approximately screen height)
        final slideDistance = MediaQuery.sizeOf(context).height;

        return Stack(
          fit: StackFit.expand,
          children: [
            // ── App Router (destination) slides UP from bottom ──
            Transform.translate(
              offset: Offset(0, slideDistance * (1 - easeT)),
              child: const AppRouter(),
            ),

            // ── Splash slides UP and exits ──
            if (_showSplash)
              Transform.translate(
                offset: Offset(0, -slideDistance * easeT),
                child: SplashScreen(
                  onComplete: _completeSplash,
                ),
              ),
          ],
        );
      },
    );
  }
}
