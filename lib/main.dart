import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:compact_sales_monitoring/services/firebase_service.dart';
import 'package:compact_sales_monitoring/providers/auth_provider.dart';
import 'package:compact_sales_monitoring/providers/activation_provider.dart';
import 'package:compact_sales_monitoring/providers/company_branding_provider.dart';
import 'package:compact_sales_monitoring/providers/route_provider.dart';
import 'package:compact_sales_monitoring/models/company_branding_model.dart';
import 'package:compact_sales_monitoring/app_router.dart';
import 'package:compact_sales_monitoring/screens/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FirebaseService.initializeApp();
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ActivationProvider>().initialize();
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
    _transitionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<ActivationProvider, AuthProvider>(
      builder: (context, activationProvider, authProvider, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _tryStartTransition();
        });

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
      },
    );
  }
}
