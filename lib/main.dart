import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:provider/provider.dart';
import 'services/background_service.dart';
import 'services/ble_service.dart';
import 'services/network_info_service.dart';
import 'services/notification_service.dart';
import 'services/owner_identity.dart';
import 'services/pairing_service.dart';
import 'services/phone_location_service.dart';
import 'services/phone_ringer_service.dart';
import 'screens/home_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/history_screen.dart';
import 'screens/settings_screen.dart';
import 'theme/app_theme.dart';
import 'widgets/phone_ringing_banner.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  /* Memory budget, for phones with 3 GB of RAM or less.
   *
   * Flutter's default image cache is 1000 images or 100 MB of decoded bitmaps,
   * sized for a flagship. On a 3 GB device 100 MB is a serious fraction of what
   * the whole app is allowed, and it is spent on decoded pixels the app does not
   * need: this UI is icons, text and painted shapes, with no photographs and no
   * network imagery anywhere in it. Twenty images and 16 MB is generous for what
   * is actually drawn.
   *
   * This matters more than it looks, because the app now holds a foreground
   * service open. Android ranks what to kill under pressure by how much a
   * process is holding, so a smaller resident footprint is the same thing as a
   * longer life in the background — the cache cap and "do not close when
   * minimised" are the same problem seen from two ends.
   *
   * Note what this is NOT: `android:largeHeap="true"`. That asks for a bigger
   * heap rather than using less of it, makes garbage collection pauses longer,
   * and on a 3 GB phone gets the app killed sooner, not later.
   */
  PaintingBinding.instance.imageCache
    ..maximumSize = 20
    ..maximumSizeBytes = 16 << 20; // 16 MB

  // Opens the channel the foreground service's isolate uses to talk back to
  // this one. Must happen before `runApp`, and must happen even when background
  // running is switched off — without it the Stop button on the ongoing
  // notification has nowhere to deliver its press. A no-op off Android.
  if (BackgroundService.isSupported) {
    FlutterForegroundTask.initCommunicationPort();
  }
  runApp(const FindXProviders(child: FindXApp()));
}

/// The app's dependency graph, as one widget.
///
/// This exists so tests build the *same* tree the app does. It was previously
/// inlined in `main()`, and the moment a second provider was added every widget
/// test broke with `ProviderNotFoundException` — the tests were quietly
/// maintaining their own copy of the graph. Anything that needs the real service
/// wiring should wrap itself in this.
class FindXProviders extends StatelessWidget {
  const FindXProviders({super.key, required this.child});

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

        // Not a ChangeNotifier either. The phone's receiver is polled on demand
        // by BleService rather than streamed to the UI: a continuous position
        // stream would hold the GPS on all day for the sake of a screen that
        // only needs a position at the moment the link changes.
        Provider<PhoneLocationService>(create: (_) => PhoneLocationService()),

        // Reads the phone's IP address for the last-known-location card. Not a
        // ChangeNotifier for the same reason: it is polled on attach and on
        // connectivity changes, not streamed.
        Provider<NetworkInfoService>(create: (_) => NetworkInfoService()),

        // `ChangeNotifierProxyProvider` only so `update` can inject the ringer,
        // the notifier, the phone's location and its network address. The
        // BleService instance itself is created once and never replaced.
        ChangeNotifierProxyProvider4<PhoneRingerService, NotificationService,
            PhoneLocationService, NetworkInfoService, BleService>(
          create: (_) => BleService(),
          update: (_, ringer, notifications, location, network, ble) => ble!
            ..attachRinger(ringer)
            ..attachNotifications(notifications)
            ..attachPhoneLocation(location)
            ..attachNetworkInfo(network),
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

class FindXApp extends StatelessWidget {
  const FindXApp({super.key});

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
        title: 'FindX',
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

class _MainNavigationState extends State<MainNavigation>
    with WidgetsBindingObserver {
  int _currentIndex = 0;

  /// Which tabs have ever been opened.
  ///
  /// The IndexedStack below builds a child for every tab, and it built all four
  /// on first paint — including the Settings tree, which is the largest screen
  /// in the app by a wide margin, on a launch where the owner only ever looks at
  /// Home. A tab enters this set the first time it is selected and stays, so it
  /// is built once and then kept alive exactly as before: the saving is on the
  /// screens that have not been visited, not on switching between the ones that
  /// have.
  ///
  /// Home is in from the start because it is what the app opens on.
  final Set<int> _visited = {0};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    /* Give back the decoded images when the owner leaves the app.
     *
     * The app deliberately stays running behind a foreground service, so
     * nothing here is freed for us. Its cached bitmaps are pure waste while no
     * pixel of it is on screen, and holding them is what makes the process an
     * attractive target when a 3 GB phone needs memory back. Dropping them
     * costs one decode on the way back in.
     *
     * `clearLiveImages()` is deliberately NOT called: those belong to widgets
     * still mounted, and evicting them causes a visible flash on resume. */
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      PaintingBinding.instance.imageCache.clear();
    }
    super.didChangeAppLifecycleState(state);
  }

  static const List<Widget> _screens = [
    HomeScreen(),
    ScanScreen(),
    HistoryScreen(),
    SettingsScreen(),
  ];

  void _select(int index) {
    setState(() {
      _currentIndex = index;
      _visited.add(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);

    return Scaffold(
      body: Column(
        children: [
          // Above the IndexedStack so it is visible on every tab: the
          // keyholder's button can be pressed while the user is on any tab, so
          // the way to silence the phone has to be reachable from any tab.
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
                  children: [
                    for (var i = 0; i < _screens.length; i++)
                      // A zero-size box for a tab never opened. IndexedStack
                      // lays out every child, so this has to be something —
                      // but an empty box is a few bytes against a whole screen.
                      if (_visited.contains(i))
                        _screens[i]
                      else
                        const SizedBox.shrink(),
                  ],
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
                onDestinationSelected: _select,
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
                    icon: Icon(Icons.shield_outlined),
                    selectedIcon: Icon(Icons.shield_rounded),
                    label: 'Security',
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