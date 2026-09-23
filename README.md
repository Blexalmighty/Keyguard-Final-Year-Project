# FindX

A two-way BLE proximity alert system for personal item recovery.

**FindX** is the Flutter app. **FindMe** is the ESP32-C3 keyholder it talks to —
the small board you clip to your keys, with a buzzer, a button and a 72×40 OLED.

The two halves answer opposite questions:

- *Where are my keys?* — the app rings the keyholder and shows the last position
  its own GPS recorded.
- *Where is my phone?* — the button on the keyholder rings the phone, and the
  keyholder's screen shows the last position the phone pushed to it.

Everything travels over Bluetooth Low Energy. There is no cloud service, no
account, and no network setup: the log lives on the phone, and a keyholder that
has been claimed refuses commands from any other phone until its owner releases
it.

## Layout

| Path | What is in it |
| --- | --- |
| `lib/` | The Flutter app. `lib/services/ble_protocol.dart` is the wire contract. |
| `firmware/keyguard_esp32c3/` | The Arduino sketch for the keyholder. |
| `firmware/README.md` | Pin map, flashing, and what each screen means. |
| `docs/SECURITY_MODEL.md` | The ownership lock and its limits. |
| `test/` | Unit and widget tests — `flutter test`. |

## Running it

```bash
flutter pub get
flutter run
```

The Dart package is still named `keyguard`, which is why every import reads
`package:keyguard/...`. That name is not user-visible and renaming it would
touch every file in `lib/` for no benefit.

## Getting started with Flutter

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)
