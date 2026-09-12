import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/ble_service.dart';
import 'services/notification_service.dart';
import 'services/owner_identity.dart';
import 'services/pairing_service.dart';
import 'services/phone_ringer_service.dart';
import 'screens/home_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/history_screen.dart';
import 'screens/settings_screen.dart';
import 'theme/app_theme.dart';
import 'widgets/demo_mode_banner.dart';
import 'widgets/phone_ringing_banner.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KeyGuardProviders(child: KeyGuardApp()));
}

/// The app's dependency graph, as one widget.
///
/// This exists so tests build the *same* tree the app does. It was previously
/// inlined in `main()`, and the moment a second provider was added every widget
/// test broke with `ProviderNotFoundException` — the tests were quietly
/// maintaining their own copy of the graph. Anything that needs the real service
/// wiring should wrap itself in this.
class KeyGuardProviders extends StatelessWidget {
  const KeyGuardProviders({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Before BleService, because BleService is handed this instance rather
        // than building its own: the ringer holds the one AudioPlayer and the one
        // vibration handle, and two of either would fight over stopping.
        ChangeNotifierProvider(create: (_) => PhoneRingerService()),

        // Not a ChangeNotifier — nothing in the UI rebuilds when a notification
        // is posted, because the whole point of it is to reach the owner when
        // the UI is not on screen. `init()` is fired here rather than awaited in
        // `main()` so a slow platform channel cannot delay first paint; the
        // service treats "not ready yet" as a no-op.
        Provider<NotificationService>(
          create: (_) => NotificationService()..init(),
        ),

        // `ChangeNotifierProxyProvider` only so `update` can inject the ringer
        // and the notifier. The BleService instance itself is created once and
        // never replaced.
        ChangeNotifierProxyProvider2<PhoneRingerService, NotificationService,
            BleService>(
          create: (_) => BleService(),
          update: (_, ringer, notifications, ble) => ble!
            ..attachRinger(ringer)
            ..attachNotifications(notifications),
        ),

        // One instance for the whole app: it caches the owner id so the pairing
        // handshake does not have to await secure storage inside the
        // keyholder's 10-second challenge window.
        Provider<OwnerIdentity>(create: (_) => OwnerIdentity()),

        // Depends on both, so it comes last. `ChangeNotifierProxyProvider`
        // rather than a plain provider because it must be disposed with the app,
        // and because it needs the already-constructed BleService rather than
        // building its own — two BleService instances would fight over the radio.
        ChangeNotifierProxyProvider2<BleService, OwnerIdentity, PairingService>(
          create: (context) => PairingService(
            bleService: context.read<BleService>(),
            identity: context.read<OwnerIdentity>(),
          ),
          // Neither dependency is ever replaced, so there is nothing to update.
          update: (_, _, _, pairing) => pairing!,
        ),
      ],
      child: child,
    );
  }
}

class KeyGuardApp extends StatelessWidget {
  const KeyGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    // `Selector`, not `watch<BleService>()`.
    //
    // This widget reads exactly one bool, but watching the whole service made it
    // a listener of all 60-odd `notifyListeners()` calls in it — including the
    // RSSI poll every two seconds and every batch of scan results, which arrive
    // several times a second while hunting. Each one rebuilt `MaterialApp`, and
    // therefore `MainNavigation` and all four screens in its IndexedStack, to
    // produce an identical frame.
    //
    // Selector rebuilds only when the selected value actually changes, so the
    // theme still flips instantly while a scan no longer drives the whole app.
    return Selector<BleService, bool>(
      selector: (_, service) => service.darkModeEnabled,
      builder: (context, darkMode, _) => MaterialApp(
        title: 'KeyGuard BLE',
        debugShowCheckedModeBanner: false,
        // Both themes are built from AppPalette, so a screen never has to ask
        // which one is active. The inline `ColorScheme.fromSeed` pair that used to
        // live here generated its own surface ramp, which is why dark mode came
        // out with tones nothing in the design system knew about.
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
        // Not `Duration.zero`: MaterialApp cross-fades between light and dark over
        // this window, and because AppPalette is a lerp-able ThemeExtension every
        // custom surface fades with it rather than snapping a frame later.
        themeAnimationDuration: AppMotion.slow,
        themeAnimationCurve: AppMotion.standard,
        home: const MainNavigation(),
      ),
    );
  }
}

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    HomeScreen(),
    ScanScreen(),
    HistoryScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);

    return Scaffold(
      body: Column(
        children: [
          // Above the IndexedStack so it is visible on every tab. See
          // widgets/demo_mode_banner.dart for why it cannot be dismissed.
          const DemoModeBanner(),

          // Same reasoning, different urgency: the keyholder's button can be
          // pressed while the user is on any tab, so the way to silence the
          // phone has to be reachable from any tab.
          const PhoneRingingBanner(),
          Expanded(
            // IndexedStack keeps all four screens alive, so scroll position and
            // in-flight animations survive tab switches. The cross-fade is
            // applied around it rather than to a rebuilt subtree, which is why
            // switching tabs does not restart each screen's entrance animation.
            child: AnimatedSwitcher(
              duration: AppMotion.fast,
              switchInCurve: AppMotion.enter,
              switchOutCurve: AppMotion.exit,
              layoutBuilder: (current, previous) => Stack(
                children: [...previous, ?current],
              ),
              child: KeyedSubtree(
                key: ValueKey<int>(_currentIndex),
                child: IndexedStack(
                  index: _currentIndex,
                  children: _screens,
                ),
              ),
            ),
          ),
        ],
      ),
      // Everything this used to set by hand — background colour, height, label
      // behaviour, indicator, icon and label colours — now comes from
      // `navigationBarTheme` in AppTheme, so it is correct in both brightnesses
      // without a `isDark ? … : …` here.
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.border)),
        ),
        child: SafeArea(
          // `Align` with an explicit `heightFactor`, NOT `Center`.
          //
          // Scaffold hands its bottom bar loose constraints — maxHeight is the
          // whole screen — and `Center` takes every pixel it is offered. That
          // gave the nav bar the full screen height, parked it in the vertical
          // middle, and left the body with zero height: four blank tabs with a
          // floating tab strip. `heightFactor: 1.0` sizes the height to the
          // child while still stretching the width, which is all the centring
          // was ever for.
          child: Align(
            alignment: Alignment.bottomCenter,
            heightFactor: 1.0,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: NavigationBar(
                selectedIndex: _currentIndex,
                onDestinationSelected: (i) =>
                    setState(() => _currentIndex = i),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home_rounded),
                    label: 'Home',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.radar_outlined),
                    selectedIcon: Icon(Icons.radar_rounded),
                    label: 'Scan',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.history_outlined),
                    selectedIcon: Icon(Icons.history_rounded),
                    label: 'History',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings_rounded),
                    label: 'Settings',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}