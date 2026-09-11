import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ble_service.dart';
import '../theme/app_theme.dart';
import '../widgets/motion.dart';

/// Configure the Wi-Fi network the keyholder joins as a *station*.
///
/// This screen does not decide how the phone talks to the keyholder — that is
/// always Bluetooth, and a second radio doesn't change it. It tells the device
/// which existing network to join so it can report its position to the cloud on
/// its own, which is the only thing Wi-Fi buys an object locator. The screen
/// says so up front rather than letting the button imply otherwise, because the
/// most common misunderstanding in this whole system is exactly that this widens
/// the phone-to-keyholder link. It doesn't.
///
/// Credentials are written as `WIFI_SET:<ssid b64>:<password b64>` over BLE to
/// the encrypted, owner-only provisioning characteristic. The firmware replies
/// with `WIFI_OK:<ip>` or `WIFI_FAIL:<reason>` on the auth stream; how long that
/// takes depends on the point in the connection, so the screen shows a live
/// "connecting…" state rather than a false "done".
class WifiSetupScreen extends StatefulWidget {
  const WifiSetupScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const WifiSetupScreen()),
    );
  }

  @override
  State<WifiSetupScreen> createState() => _WifiSetupScreenState();
}

class _WifiSetupScreenState extends State<WifiSetupScreen> {
  final TextEditingController _ssid = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final GlobalKey<FormState> _form = GlobalKey<FormState>();

  bool _obscure = true;
  bool _sending = false;
  String? _status;

  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // Pre-fill the password field? No. A password field that auto-fills with
    // something the owner cannot see is a password field that lets them send
    // credentials they did not mean to. The SSID is left usable from previous
    // attempts, but the password always starts blank.
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ssid.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _send(BleService bleService) async {
    if (_sending) return;
    if (!_form.currentState!.validate()) return;

    setState(() {
      _sending = true;
      _status = null;
    });

    // Capture the reply before the write so a fast WIFI_OK that lands between
    // now and the first poll is not missed.
    bleService.armWifiResultCapture();

    final ok = await bleService.setupWifi(
      ssid: _ssid.text.trim(),
      password: _password.text,
    );

    if (!ok) {
      if (mounted) {
        setState(() {
          _sending = false;
          _status = bleService.lastError.isEmpty
              ? 'Could not send the network details.'
              : bleService.lastError;
        });
      }
      return;
    }

    // The device acknowledges on its own schedule. Poll briefly rather than
    // hanging the button: after ~15s the credentials are assumed to have had
    // their say, and anything later is a retry, not a first failure.
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 300), (timer) {
      final result = bleService.wifiSetupResult;
      if (result == null && timer.tick < 50) return;
      timer.cancel();
      if (mounted) {
        setState(() {
          _sending = false;
          _status = result ?? 'The keyholder did not answer. This usually means '
              'the credentials were wrong or the network was out of reach. '
              'Check and try again.';
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final bleService = context.watch<BleService>();

    return Scaffold(
      appBar: AppBar(title: const Text('Set up keyholder Wi-Fi')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...staggered([
                    _Intro(),
                    Form(
                      key: _form,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: AppDecorations.card(p),
                        child: Column(
                          children: [
                            TextFormField(
                              controller: _ssid,
                              enabled: !_sending,
                              maxLength: 32,
                              decoration: const InputDecoration(
                                labelText: 'Network name (SSID)',
                                prefixIcon: Icon(Icons.wifi_rounded),
                              ),
                              validator: (v) =>
                                  (v == null || v.trim().isEmpty)
                                      ? 'Enter the network name'
                                      : null,
                            ),
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: _password,
                              enabled: !_sending,
                              obscureText: _obscure,
                              maxLength: 64,
                              decoration: InputDecoration(
                                labelText: 'Password',
                                prefixIcon: const Icon(Icons.lock_rounded),
                                suffixIcon: IconButton(
                                  icon: Icon(_obscure
                                      ? Icons.visibility_off_rounded
                                      : Icons.visibility_rounded),
                                  onPressed: () =>
                                      setState(() => _obscure = !_obscure),
                                ),
                              ),
                              validator: (v) =>
                                  (v == null || v.isEmpty)
                                      ? 'Enter the password'
                                      : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_status != null) _StatusCard(message: _status!),
                    const SizedBox(height: 8),
                    SizedBox(
                      child: OutlinedButton.icon(
                        onPressed:
                            _sending ? null : () => _send(bleService),
                        icon: _sending
                            ? SizedBox(
                                width: 17,
                                height: 17,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2, color: p.muted),
                              )
                            : const Icon(Icons.cloud_upload_rounded),
                        label: Text(
                          _sending ? 'Sending…' : 'Save network on keyholder',
                        ),
                      ),
                    ),
                  ], step: AppMotion.stagger)
                      .expand((w) => [w, const SizedBox(height: 16)]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: p.surfaceAlt,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: p.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 15, color: p.muted),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              'The keyholder joins your home or campus network as a device so it '
              'can report its position to the cloud when you are not nearby. The '
              'phone still talks to it over Bluetooth; this does not extend the '
              'phone-to-keyholder range, it extends how far its last location '
              'can reach you.',
              style: AppTypography.bodyMd(color: p.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    // _wifiSetupResult is "Joined <ip>" on success and a plain-sentence
    // description on failure, so the leading word is the discriminator.
    final isOk = message.startsWith('Joined');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isOk ? p.successSoft : p.dangerSoft,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isOk ? Icons.check_circle_rounded : Icons.error_outline_rounded,
            size: 15,
            color: isOk ? p.success : p.danger,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: AppTypography.bodyMd(
                  color: isOk ? p.success : p.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
