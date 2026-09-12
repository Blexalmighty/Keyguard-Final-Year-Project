import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:keyguard/theme/app_theme.dart';
import 'package:keyguard/widgets/motion.dart';

/// Reproduces the blank-device-card report: the scan list rebuilds every time a
/// BLE advertisement lands, and the entrance animation has to survive that.
///
/// The harness mirrors `ScanScreen.build` exactly in the way that matters —
/// a `Column` holding four *unkeyed* `FadeSlideIn`s (radar, status, chips,
/// results header) followed by `staggered()` device cards that carry a
/// `ValueKey(device.id)`, with an unkeyed `FadeSlideIn` empty state standing in
/// their place while the list is empty.
class _ScanHarness extends StatefulWidget {
  const _ScanHarness({required this.controller});

  final _ScanController controller;

  @override
  State<_ScanHarness> createState() => _ScanHarnessState();
}

class _ScanController extends ChangeNotifier {
  List<String> devices = const [];

  void setDevices(List<String> next) {
    devices = next;
    notifyListeners();
  }

  /// A fresh advertisement batch: same devices, new object identity, re-sorted
  /// exactly as `filteredScannedDevices` re-sorts by RSSI.
  void churn() {
    devices = devices.reversed.toList();
    notifyListeners();
  }
}

class _ScanHarnessState extends State<_ScanHarness> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  void _onChange() => setState(() {});

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devices = widget.controller.devices;

    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              const FadeSlideIn(child: Text('radar')),
              const SizedBox(height: 18),
              const FadeSlideIn(
                delay: AppMotion.stagger,
                child: Text('status'),
              ),
              const SizedBox(height: 20),
              FadeSlideIn(
                delay: AppMotion.stagger * 2,
                child: Text('chips'),
              ),
              const SizedBox(height: 18),
              FadeSlideIn(
                delay: AppMotion.stagger * 3,
                child: Text('header'),
              ),
              const SizedBox(height: 12),
              if (devices.isEmpty)
                FadeSlideIn(
                  delay: AppMotion.stagger * 4,
                  child: Text('empty'),
                )
              else
                ...staggered([
                  for (final id in devices)
                    Padding(
                      key: ValueKey<String>(id),
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(id),
                    ),
                ]),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// The opacity actually being painted for the card showing [label].
double _opacityOf(WidgetTester tester, String label) {
  final opacity = tester.widget<Opacity>(
    find
        .ancestor(of: find.text(label), matching: find.byType(Opacity))
        .first,
  );
  return opacity.opacity;
}

void main() {
  testWidgets('device card becomes visible when it appears in an empty list',
      (tester) async {
    final controller = _ScanController();
    await tester.pumpWidget(_ScanHarness(controller: controller));
    await tester.pumpAndSettle();

    controller.setDevices(['AA:BB:CC:DD:EE:FF']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(_opacityOf(tester, 'AA:BB:CC:DD:EE:FF'), 1.0);
  });

  testWidgets('device card reaches full opacity while the scan keeps churning',
      (tester) async {
    final controller = _ScanController();
    await tester.pumpWidget(_ScanHarness(controller: controller));
    await tester.pumpAndSettle();

    controller.setDevices(['KEYHOLDER', 'HEADPHONES']);

    // A busy channel delivers a fresh accumulated result set several times a
    // second, and every one of them rebuilds the list.
    for (var i = 0; i < 20; i++) {
      controller.churn();
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(_opacityOf(tester, 'KEYHOLDER'), 1.0,
        reason: 'card stayed transparent under scan churn');
    expect(_opacityOf(tester, 'HEADPHONES'), 1.0,
        reason: 'card stayed transparent under scan churn');
  });

  testWidgets('a card that arrives mid-scan still becomes visible',
      (tester) async {
    final controller = _ScanController();
    await tester.pumpWidget(_ScanHarness(controller: controller));
    controller.setDevices(['KEYHOLDER']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Second device shows up once the list is already settled and churning.
    controller.setDevices(['KEYHOLDER', 'LATECOMER']);
    for (var i = 0; i < 20; i++) {
      controller.churn();
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(_opacityOf(tester, 'LATECOMER'), 1.0);
    expect(_opacityOf(tester, 'KEYHOLDER'), 1.0);
  });
}
