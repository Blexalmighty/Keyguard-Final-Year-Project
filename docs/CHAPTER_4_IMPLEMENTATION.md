# CHAPTER FOUR

# SYSTEM IMPLEMENTATION, TESTING AND RESULTS

---

## 4.1 Introduction

This chapter presents the implementation of the design set out in Chapter Three,
the testing carried out on it, and the results obtained. It is organised to be
verifiable rather than merely descriptive: every quantity given — line counts,
test counts, measured ranges — was taken from the source tree or from the
instrument that measured it, and where a figure is an estimate or was not
measured, that is said.

Two sections are included that a conventional implementation chapter would omit.
Section 4.7 documents the faults found during testing and how each was diagnosed,
because in this project the diagnosis was the substantive technical work: two of
the three most serious faults were invisible from the application's side and were
found by arithmetic rather than by instrumentation. Section 4.9 states the
limitations of what was built.

---

## 4.2 Implementation overview

### 4.2.1 Deliverables

| | |
|---|---|
| **FindX** | Android application, Flutter/Dart, version 1.0.0+1, minimum API 26 |
| **FindMe** | ESP32-C3 firmware, Arduino framework |
| **Documentation** | Architecture reference, security model, and this report |

### 4.2.2 Code metrics

**Application — 15,306 lines of Dart across 42 files in `lib/`**

| Layer | Files | Lines | Share |
|---|---|---|---|
| Services | 14 | 7,867 | 51.4 % |
| Screens | 5 | 4,627 | 30.2 % |
| Widgets | 12 | 2,343 | 15.3 % |
| Models | 7 | 807 | 5.3 % |
| Utilities and theme | 4 | ~1,100 | — |

**Tests — 145 automated tests across 11 files**

### 4.2.3 Largest modules

| File | Lines | Responsibility |
|---|---|---|
| `services/ble_service.dart` | 2,924 | Scanning, connection, GATT I/O, ownership state, event log, every push to the keyholder |
| `screens/settings_screen.dart` | 2,074 | All configuration, calibration, background monitoring, device management |
| `theme/app_theme.dart` | 853 | Design tokens, typography, component theming |
| `screens/home_screen.dart` | 805 | Distance, battery, map, primary controls |
| `screens/scan_screen.dart` | 789 | Discovery list, signal bars, vendor identification |
| `services/phone_ringer_service.dart` | 550 | Ringing this phone, tone choice, vibration |
| `services/pairing_service.dart` | 504 | HMAC handshake, nonces, lockout |
| `screens/history_screen.dart` | 489 | Event log presentation |
| `screens/pairing_screen.dart` | 470 | Guided claim flow |
| `widgets/motion.dart` | 355 | Shared animation primitives |
| `services/ble_protocol.dart` | 352 | The wire contract — every UUID and frame |
| `services/background_service.dart` | 344 | Foreground service, boot reconnection |

### 4.2.4 Dependencies

| Package | Version | Purpose |
|---|---|---|
| `flutter_blue_plus` | ^1.35.0 | BLE scanning, GATT |
| `geolocator` | 14.0.2 | Phone position |
| `flutter_foreground_task` | ^11.0.3 | Background execution |
| `flutter_local_notifications` | ^18.0.1 | Notifications |
| `flutter_secure_storage` | ^9.2.2 | Owner id and device key |
| `shared_preferences` | ^2.3.2 | Settings and event log |
| `crypto` | ^3.0.5 | HMAC-SHA256 |
| `provider` | — | State distribution |
| `audioplayers` · `flutter_ringtone_player` · `vibration` | — | Phone ringing |
| `permission_handler` | ^11.3.1 | Runtime permissions |
| `connectivity_plus` · `url_launcher` · `file_picker` · `path_provider` | — | Supporting |

`geolocator` is pinned at exactly **14.0.2**, not a caret range. Version 14.0.3
pulls `package_info_plus`, which requires `win32 ^6`, while `file_picker` 11 pins
`win32 ^5.9` — an unresolvable conflict. The pin is deliberate and is documented
in `pubspec.yaml` so it is not "tidied up" into a range later.

---

## 4.3 Application implementation

### 4.3.1 State management

`BleService` extends `ChangeNotifier` and is provided once at the root of the
widget tree. Screens read it through `Provider` and rebuild on `notifyListeners()`.

One instance, for the reason given in §3.4.2: the Bluetooth adapter is a single
physical resource, and two objects holding handles to it produce failures that
are very hard to attribute — scans that silently stop returning results,
connections dropped by an unrelated part of the application, notifications
delivered to a listener nobody is watching.

### 4.3.2 Scanning and the visibility filter

A raw BLE scan in a populated area returns dozens of radios: headphones,
televisions, other phones, beacons in shops. Presenting that list unfiltered
makes the application look broken.

Devices are shown when they match the service UUID, or when their advertised name
is one of the known keyholder names. Four names are recognised:

| Name | Reason it is recognised |
|---|---|
| `FindMe` | Current |
| `KeyGuard` | Pre-rename firmware. A board already flashed with it is still the owner's board. |
| `Find Me` | The spaced spelling, which shipped briefly. One character from the current name — but BLE matches names byte for byte, so a board flashed in that window is invisible to an application that only knows `FindMe`. |
| `BLE-Keyholder` | Pre-single-name firmware, unclaimed state |

Carrying three obsolete strings costs nothing. Dropping them would leave working
hardware unrecognised until it was reflashed, and "the app stopped seeing my
device" is a worse outcome than one extra constant. Nothing infers ownership from
any of them.

### 4.3.3 Scan-list stability

A naive implementation rebuilds the discovery list on every advertisement, which
arrives several times a second. Rows then reorder under the user's finger and
taps land on the wrong device.

`scan_list_diff.dart` (41 lines, 97 lines of tests) computes a minimal update:
discovery order is preserved, a device that stops advertising is kept briefly
before removal, and signal strength updates in place without a reorder. Small,
and the difference between a usable list and an unusable one.

### 4.3.4 Distance estimation

`ProximityModel` (142 lines) implements §3.8.1. Readings with `rssi >= 0` or
`rssi < -127` are rejected as platform sentinels rather than measurements.

Beyond 30 m the estimate is suppressed and the interface says "far" rather than
printing a number. A figure of "47 m" from an RSSI of −96 dBm carries no
information, and showing it would invite the owner to trust it.

### 4.3.5 Position handling

`PhoneLocationService` (337 lines) wraps `geolocator`. The permission ladder is
implemented in the order the platform requires:

1. Foreground location (`ACCESS_FINE_LOCATION`) — a normal dialog.
2. **Only then**, and only when background monitoring is being switched on,
   background location (`ACCESS_BACKGROUND_LOCATION`).

On Android 11 and above the second is **not a dialog**. The system will not
present one, so the application has to send the owner to `openAppSettings()`
with an explanation of which option to select. Requesting the two together on
Android 10 causes the system to deny both — an implementation detail that is
easy to get wrong and silent when wrong.

Positions are pushed to the keyholder on every new fix, on every reconnection,
and on a two-minute timer while connected. Two minutes was chosen as the point
where a stale position becomes misleading rather than merely old; shorter
intervals cost battery on both devices for a number that has not changed.

### 4.3.6 Reverse geocoding

`GeocodingService` (196 lines) queries Nominatim over HTTPS, with results cached
by coordinate so that a stationary phone makes one request rather than one every
two minutes. A descriptive `User-Agent` is sent, as the service's usage policy
requires.

Name resolution is strictly best-effort. A failure, a timeout or no internet at
all produces coordinates only — less readable, equally correct — and nothing in
the alerting path depends on it.

### 4.3.7 Map rendering

Raster tiles are drawn by a `CustomPainter` (`map_painter.dart`, 212 lines;
`map_tiles.dart`, 283 lines), in two stacked layers: aerial imagery from Esri's
World Imagery service over OpenStreetMap street cartography, at zoom 18. The
ordering is the design — aerial coverage at building zoom is not universal, and
where an imagery tile is missing its request fails and the street map underneath
shows through, so the card degrades to a street map rather than to a hole.

A full mapping SDK was not adopted, and the reason is not only APK weight.
Google's Maps SDK requires a Cloud API key with a billing account attached and
renders a blank grey square without one; using Google's tile endpoints directly
instead of the SDK breaches their terms of service. Neither cost is acceptable
for a screen whose job is to show one marker, so the two open sources above are
used and the picture is a raster rather than a live map.

Tapping the map opens the position in the device's installed maps application,
which is where a user wants to be for routing in any case.

### 4.3.8 Phone ringing

`PhoneRingerService` (550 lines) plays the selected tone and vibrates when
`FIND_PHONE|LOC:` arrives.

**There is no timeout.** The ringing continues until the owner stops it in the
application. This was an explicit requirement and it is correct: a phone that
gives up after ten seconds is no help to somebody still lifting cushions. An
acknowledgement is sent back to the keyholder so its screen can confirm the
phone is ringing — without it the owner cannot tell whether the press was
registered at all.

### 4.3.9 Background execution

`BackgroundService` (344 lines) configures a foreground service with:

| Setting | Value | Reason |
|---|---|---|
| `foregroundServiceType` | `connectedDevice` | From Android 15, `dataSync` is capped at ≈6 h per 24. A key finder that quietly gives up after six hours is worse than one that never claimed to watch. The application genuinely interacts with a connected Bluetooth device, so the accurate type is also the uncapped one. |
| `stopWithTask` | `false` | Swiping the app out of Recents must not stop monitoring. |
| `autoRunOnBoot` | `true` | Restart after a reboot. |
| `autoRunOnMyPackageReplaced` | `true` | An app update must not silently stop monitoring. |
| `allowWakeLock` | `false` | The radio wakes the CPU for each connection event; a wake lock would cost battery for nothing. |
| `eventAction` | `repeat(15 min)` | Wakes the service isolate to re-check the link after a reboot. The handler returns immediately when the platform reports it was started by the application, so the callback costs nothing at all in the ordinary case. |
| Channel importance | `LOW` | A status line, not an alert. An owner who mutes "FindX is running" must not thereby mute "your keys are moving away". |

The notification carries a **Stop** button. An ongoing notification cannot be
swiped away, so without the button the only exit would be the system settings —
and the requirement was that monitoring stops when the owner stops it. The button
runs in the service's isolate, which can reach neither the settings store nor the
live `BleService`, so it sends a token down the port opened in `main()`; the main
isolate turns that token into the thing the owner meant — preference off, switch
off, no service on next launch.

`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is requested at runtime. Stock Android
honours a foreground service; Xiaomi, Oppo, Vivo and Huawei run additional
battery managers that will kill even a foreground service unless the application
is exempted. On those handsets this request is the difference between the feature
working and not.

### 4.3.10 Boot reconnection

The implementation of §3.8.4, in the task handler isolate. Three points of
implementation detail determined whether it worked:

**`TaskStarter`** is the discriminator. The platform reports whether the service
was started by the application (`developer`) or by the system (`system`). Only
the second case performs any Bluetooth work.

**`DartPluginRegistrant.ensureInitialized()`** is mandatory. The isolate is
spawned by the Flutter engine, not by the application, so the plugin registrant
has not run; without this call every plugin invocation throws
`MissingPluginException`.

**`autoConnect: true` with `mtu: null`.** The two go together — `flutter_blue_plus`
asserts if an MTU is requested alongside `autoConnect`, because an MTU exchange
cannot be scheduled for a connection that has not happened yet. The real MTU is
raised by `BleService` once the application is open.

The handler also waits up to 30 seconds for the Bluetooth adapter to come up. The
adapter is enabled some seconds after the rest of the phone, so reading its state
once at boot returns `off` and the reconnection never happens; waiting for the
transition is the difference between reconnecting at boot and reconnecting never.

The persisted `user_disconnected` flag is checked first. A deliberate
disconnection therefore survives a reboot, which is what makes the rule coherent.

### 4.3.11 Keys read directly in the boot path

The boot handler reads `'user_disconnected'` and `'last_device_id'` as raw string
keys, because `SettingsStore` is not constructed in that isolate. These two
string literals are consequently duplicated between `settings_store.dart` and
`background_service.dart`, and **renaming either key in one place silently breaks
boot reconnection** — it would fail quietly, at a moment with no user interface
to report it. The duplication is noted in comments at both sites.

---

## 4.4 Firmware implementation

### 4.4.1 Structure

| Section | Function |
|---|---|
| Configuration | Pin definitions, timing constants, BLE UUIDs — mirrored from `ble_protocol.dart` |
| Globals | Connection state, alert state, buffers, cached battery reading |
| Display | `U8g2` full-buffer rendering, four pages |
| Battery | ADC read, averaging, percentage mapping with hysteresis |
| Alert | Cadence table, non-blocking stepper |
| BLE callbacks | `onConnect`, `onDisconnect`, `onWrite` |
| Reassembly | Buffer, newline split, completeness test, stale flush |
| Dispatch | `processBLECommand()` |
| Ownership | Claim, challenge, verify, lockout, unclaim |
| Power | Light-sleep entry and exit |
| NVS | `Preferences`, namespace `findme` |

### 4.4.2 Non-blocking alert

The cadence stepper is driven from `loop()` against `millis()`. `delay()` is not
used anywhere in the alert path: a blocking delay inside a sounding alert would
make the device unable to receive `STOP` while it was sounding, which is the one
moment `STOP` matters.

### 4.4.3 Battery measurement

```c
analogReadResolution(12);
analogSetPinAttenuation(BAT_PIN, ADC_11db);
// readBatteryVoltage(): average several analogReadMilliVolts(), × 2.0
```

`analogReadMilliVolts()` applies the chip's factory calibration internally;
converting a raw count by hand carries several percent of chip-to-chip error that
this removes for free. Several readings are averaged, because a single ADC sample
on this part is noisy by a few millivolts.

The reading is cached and refreshed on a timer rather than sampled on demand, so
that a notification cannot be delayed by an ADC conversion.

### 4.4.4 Display implementation

`U8G2_SSD1306_72X40_ER_F_HW_I2C` — the `_F_` is full-buffer mode. The frame is
composed in RAM and transferred in one operation, which removes the tearing that
page mode produces when the display is updated while an alert is stepping. The
cost is about 360 bytes of RAM.

Text is truncated to twelve characters on the location line. Wrapping was tried
and rejected: a wrapped place name pushes the battery indicator off a 40-pixel
screen.

### 4.4.5 Low-power implementation

```c
setCpuFrequencyMhz(80);
esp_pm_configure(&pm_config);   // light_sleep_enable = true
```

| Constant | Value |
|---|---|
| `INACTIVITY_TIMEOUT_MS` | 600 000 (10 min) before resting |
| `FULL_POWER_HOLD_MS` | 30 000 (30 s) full-power hold after any activity |

Entering low power notifies `LOW_POWER:on`, and the OLED shows `LP`. Surfacing
this rather than hiding it was deliberate: resting is the *normal* state of a key
finder that has been in a pocket for ten minutes, and an owner who can see the
device chose to rest reads a longer battery life, where an owner who sees nothing
reads a device that has gone quiet on them.

### 4.4.6 Two sketches

| Sketch | Role |
|---|---|
| `firmware/findme_device/Myprojctcode.ino` | **The flashed firmware.** No GPS, two-entry cadence table, single-characteristic `AUTH:` dialect, light-sleep power management. |
| `firmware/keyguard_esp32c3/keyguard_esp32c3.ino` | Reference sketch for a GPS-equipped variant with the two-characteristic ownership protocol. Also a **test fixture** — `test/alert_pattern_test.dart` reads it from disk, so it cannot be deleted. |

---

## 4.5 Testing

### 4.5.1 Strategy

| Level | Method |
|---|---|
| Unit | 145 automated tests, `flutter_test`, run in a plain Dart VM |
| Static analysis | `flutter analyze` on every change |
| Integration | Application against real hardware |
| Field | Real use: pockets, buildings, reboots, swipe-aways, out-of-range |
| Cross-boundary | One test parses the firmware source and compares it with the application's constants |

### 4.5.2 Automated test suite — 145 tests

| File | Lines | What it covers |
|---|---|---|
| `auth_test.dart` | 367 | HMAC derivation, nonce handling, lockout behaviour, the 31-byte advertisement budget |
| `widget_test.dart` | 208 | Application boot, `EventModel` serialisation round-trips, retention windows |
| `phone_location_test.dart` | 199 | Permission ladder ordering, fix plausibility rejection |
| `alert_pattern_test.dart` | 173 | Cadence tokens **parsed from the firmware on disk** |
| `distance_test.dart` | 336 | Path-loss model, sentinel-RSSI rejection, 30 m ceiling |
| `scan_list_visibility_test.dart` | 169 | Which radios are presented as keyholders |
| `phone_alert_tone_test.dart` | 108 | Tone selection and persistence |
| `scan_list_diff_test.dart` | 97 | List stability under rapid advertisement updates |
| `coordinates_test.dart` | 95 | Formatting, hemispheres, the no-fix case |
| `background_service_test.dart` | 54 | Platform gating; every method a no-op off Android |
| `error_banner_test.dart` | 45 | Error surfacing |

### 4.5.3 The cross-boundary test

`alert_pattern_test.dart` is the most valuable test in the suite and the least
conventional. It opens the firmware source file, parses the cadence table with a
five-group regular expression, and asserts that the tokens match the
application's `AlertPattern` definitions.

It is the only mechanism in the project that can detect the two sides of the wire
contract drifting apart — a class of fault no amount of Dart-only testing would
find, because both sides are individually self-consistent while disagreeing with
each other.

It is also, deliberately, brittle: adding a field to the firmware struct breaks
the test. That is the test doing its job. A change to the shared contract should
require a decision, not pass silently.

### 4.5.4 Results

```
$ flutter analyze
No issues found!

$ flutter test
All tests passed!   145 tests
```

One diagnostic line is printed during `widget_test.dart`:

```
NotificationService: init failed: LateInitializationError: Field '_instance' has not been initialised.
```

This is expected and is not a failure. The test harness has no platform channel,
so the native notification plugin cannot initialise. `NotificationService`
catches it and continues, which is the correct behaviour for a service whose
absence should not prevent the application from running — and the test asserts
that the application boots anyway.

### 4.5.5 Field test results

| Test | Result |
|---|---|
| Discovery, keyholder 2 m away | Appears in under 2 s |
| Connection and authentication | Under 3 s from tap to authenticated |
| Claim with the button held | Succeeds |
| Claim without the button held | Refused, as designed |
| Claim from a second phone while claimed | Refused |
| `FIND_KEY` → buzzer | Sounds in well under 1 s |
| `STOP` → silence | Immediate, including while sounding |
| Button press → phone rings | Rings; continues until stopped in the app |
| Position pushed to the keyholder | Appears on the OLED **after the MTU fix of §4.7.1** |
| Place name on the OLED | Appears a few seconds after the coordinates, when online |
| Maximum allowance breach | Buzzer sounds; notification posted; event logged |
| App minimised | Monitoring continues |
| App swiped from Recents | Monitoring continues; alarm still rings |
| Phone rebooted | Reconnects without the app being opened |
| Deliberate disconnect, then reboot | Does **not** reconnect — correct |
| Deliberate disconnect, then reconnect in app, then reboot | Reconnects — correct |
| Out of range, then back | Reconnects automatically |
| Idle 10 minutes | `LP` on the OLED; connection retained |
| Airplane mode | Coordinates only, no place name; all alerting unaffected |

### 4.5.6 Measured range

| Environment | Reliable connection | Distance estimate |
|---|---|---|
| Open air, line of sight | ≈ 25 – 30 m | Within a few metres to ≈ 10 m |
| Indoors, one wall | ≈ 10 – 15 m | Usable as a relative indicator |
| Indoors, two or more walls | ≈ 5 – 8 m | Unreliable as a number |
| Keyholder in a trouser pocket | Reduced by roughly half | Pessimistic — the body attenuates |

The estimate is good for *relative* judgement — warmer, colder — which is what
finding an object in a room actually requires. It is not a survey instrument, and
the interface says so.

### 4.5.7 Power measurements

| State | Current (indicative) |
|---|---|
| Full power, connected, idle | tens of milliamps |
| Low power (80 MHz, light sleep), connected | a few milliamps |
| Alert sounding | tens of milliamps plus the buzzer |

The ratio between the first two rows is what justifies the low-power mode, and
it is the reason the mode keeps the BLE connection rather than entering deep
sleep. Deep sleep would reduce the current further and drop the link — and a key
finder that must be woken before it can be found is not a key finder.

These figures are indicative, measured with a bench supply rather than a
calibrated coulomb counter. A proper battery-life figure would require a long-run
measurement that was not performed.

---

## 4.6 Results

### 4.6.1 Requirements achieved

| ID | Requirement | Status |
|---|---|---|
| FR-1 | Discover and display keyholders | **Met** |
| FR-2 | Connect and maintain | **Met** |
| FR-3 | Estimate distance | **Met**, as an estimate |
| FR-4 | Sound and silence the keyholder | **Met** |
| FR-5 | Ring the phone until stopped in the app | **Met** |
| FR-6 | Maximum allowance and proximity threshold, separately | **Met** |
| FR-7 | Push the phone's position to the keyholder | **Met** — see §4.7.1 |
| FR-8 | Push the place name | **Met** when online |
| FR-9 | Map, and open externally | **Met** |
| FR-10 | Battery level | **Met** |
| FR-11 | Event log with place and day | **Met** |
| FR-12 | One owner per keyholder | **Met** |
| FR-13 | Background, swipe-away, reboot | **Met** |
| FR-14 | Auto-reconnect, except after a deliberate disconnect | **Met** |
| FR-15 | Alert cadence affects the buzzer | **Met**, two patterns |
| FR-16 | Nickname held on the phone only | **Met** |
| FR-17 | Rest without dropping the connection | **Met** |

| ID | Non-functional | Status |
|---|---|---|
| NFR-1 | 3 GB phone | **Met** — single service instance, bounded log, no second isolate |
| NFR-2 | Survive memory pressure | **Met** |
| NFR-3 | Multi-day battery | **Partly verified** — the low-power mode works; no long-run measurement was taken |
| NFR-4 | No account, no server | **Met** |
| NFR-5 | Not usable for stalking | **Met**, with the limits in §4.9 |
| NFR-6 | Readable at 72 × 40 | **Met** |
| NFR-7 | Degrade without internet | **Met** |
| NFR-8 | Maintainable protocol | **Met** — one contract file plus a cross-boundary test |

| ID | Privacy | Status |
|---|---|---|
| PR-1 | No per-unit identifier advertised | **Met** |
| PR-2 | Nicknames never transmitted | **Met** |
| PR-3 | Ownership not transferable over the air | **Met** |
| PR-4 | No foreign credential on the device | **Met** — Wi-Fi provisioning removed |
| PR-5 | No movement history leaves the phone | **Met** — cloud reporting removed |

### 4.6.2 Code quality

| Measure | Result |
|---|---|
| `flutter analyze` | No issues |
| Automated tests | 145, all passing |
| Dependency cycles | None — the graph is acyclic and one-directional |
| Domain layer plugin dependencies | None, which is what makes it testable |

### 4.6.3 Cleanup performed

A dead-code pass removed:

- The entire Wi-Fi provisioning subsystem, both sides, including the third GATT
  characteristic.
- 29 unreachable members across the service layer.
- Three Wi-Fi permissions from the manifest (`NEARBY_WIFI_DEVICES`,
  `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`).

The permissions matter more than the line count. A permission an application no
longer exercises is not free: it is printed on the store listing and in the system
permission screen, and "this key finder wants to see the networks around you" is
a question an owner should not have to answer for a feature that does not exist.

---

## 4.7 Faults found during testing

This section is included because the diagnosis was the substantive technical work
of the project. Two of the three faults below were invisible from the
application's side, which is why each had survived several earlier attempts to fix
it.

### 4.7.1 The position frame that could not be delivered

**Symptom.** The keyholder's location page displayed no fix, indefinitely, while
the application held a valid GPS position and reported having sent it. Reported
three separate times.

**What was ruled out.** The application's push path was inspected and was
correct: `_adoptPhoneFix` pushed on every new fix, and `_pushBestEffort` permitted
the write on a single-characteristic board. The firmware's `PHONE_LOC:` handler was
also correct. Both ends were right, which is why three earlier attempts on the
application side had not moved the symptom.

**Diagnosis — arithmetic, not instrumentation.**

```
ATT MTU, default                   23 bytes
  less the 3-byte ATT header
  = usable write payload           20 bytes

"PHONE_LOC:7.521834,4.526901"      27 bytes
```

The frame was seven bytes longer than the maximum a single write could carry. It
could never arrive whole. No error was raised anywhere, because from the
application's point of view the write succeeded.

**Fix.** `BLEDevice::setMTU(247)` in firmware `setup()`, before anything connects.
The value matches `BleAuthParams.desiredMtu`, so the application's own request is
granted rather than clamped. **Both sides must raise it** — raising only the
client achieves nothing, since the negotiated value is the smaller of the two.

### 4.7.2 The reassembly buffer that jammed permanently

Found while fixing §4.7.1, and more serious than it.

**The original code** appended each write to a buffer and held anything beginning
with `PHONE_LOC:` until a comma appeared. It never reset when the comma failed to
arrive.

**Consequence.** One truncated position frame left `PHONE_LOC:7.52` in the buffer
for ever. The next command was appended to that fragment, the result matched no
known command, and the keyholder obeyed **nothing further until it was
reconnected**. The MTU fault made the position undeliverable; this fault made
*everything* undeliverable afterwards — `FIND_KEY`, `STOP`, `SET_DIST:` and
`LOCATION_NAME:` all stopped working after the first position push. That matches
the observed behaviour of a device that intermittently "stops responding" until
reconnected.

**Fix.** Four rules, each addressing a specific failure:

| Rule | Prevents |
|---|---|
| Append each write **untrimmed**; trim only the finished frame | `LOCATION_NAME:Amphitheatre, OAU` becoming `…Amphitheatre,OAU` when the split lands on the space |
| Split on newline when present | Ambiguity about where a frame ends |
| Otherwise judge the buffer complete, **except** `PHONE_LOC:` without a comma | Frames waiting for data that will never come |
| Flush a buffer unchanged for 150 ms; discard beyond 512 bytes | A single malformed write making the board permanently deaf |

**A correction made during implementation.** The first version of the
completeness test also returned "incomplete" for `LOCATION_NAME:`, forcing it to
wait out the 150 ms timeout. That created a worse fault than the one it
prevented: `LOCATION_NAME:X` followed within 150 ms by `SET_DIST:50` would be
joined, and the place name stored as `XSET_DIST:50`. The test was rewritten to
obey immediately for everything except `PHONE_LOC:` — the one frame whose
truncation is *detectable*, because a coordinate pair must contain a comma.

The trade-off is recorded in the source: a split place name is cosmetic, since
the display truncates to twelve characters in any case, whereas a *corrupted*
place name is persisted to NVS and survives.

### 4.7.3 The claim state that was never learned

**Symptom.** On the hardware actually built, every data write was withheld.

**Cause.** The application withholds data commands from a session it cannot
confirm is authenticated — correct behaviour, since the owner's position is not
something to hand to an unidentified peer. The built hardware implements the
single-characteristic dialect and announces its state in plain words
(`AUTH:registered`, `AUTH:ok`) rather than with `AUTH_REQ:` and `AUTH_OK`. The
application did not recognise those strings, so it never left the "unknown"
ownership state, so it never permitted a write.

**Fix.** Recognise the single-characteristic dialect, and treat a board with **no
ownership characteristic at all** as usable. That third case is the one that
matters: there is no handshake to complete on such a link, so waiting for one to
succeed means waiting for ever.

### 4.7.4 Other faults found and fixed

| Fault | Cause | Fix |
|---|---|---|
| Keyholder appeared in scan lists with no name | Advertised name exceeded the 31-byte advertisement budget, so the library moved it to the scan response | Name shortened to `FindMe`; an automated test now holds the eight-character ceiling |
| Alert cadence setting had no audible effect | The application stored the choice but never pushed it | `ALERT_SET:` added, with the device echoing the cadence it is actually using |
| Buzzer produced a thin rattle | `tone()` used on an active, self-oscillating element | `digitalWrite` only |
| Application killed when minimised | No foreground service | Foreground service of type `connectedDevice` |
| Monitoring stopped on swipe-away | `stopWithTask` defaulted to `true` | Set to `false` |
| Monitoring stopped after a reboot | No boot receiver, and nothing to reconnect with | `autoRunOnBoot` plus the headless reconnection of §4.3.10 |
| Hunting resumed after a deliberate disconnect | The flag was set *after* `disconnect()`, so the connection-state listener ran first | Flag set before the radio is touched, and persisted |
| Battery percentage flickered while the buzzer sounded | Terminal voltage sags under load | ±3 % hysteresis against the cached value |
| Build failed on `flutter pub get` | `geolocator` 14.0.3 → `package_info_plus` → `win32 ^6`, against `file_picker` 11 → `win32 ^5.9` | `geolocator` pinned at exactly 14.0.2, with the reason recorded |

---

## 4.8 User interface

Five screens.

| Screen | Content |
|---|---|
| **Home** | Estimated distance with a signal indicator, battery, position card with place name, map preview, and the primary Find/Stop control |
| **Scan** | Discovered keyholders with signal bars; vendor identification for nameless radios |
| **Pairing** | Guided claim, including the instruction to hold the physical button |
| **History** | Event log, with the day and the place name |
| **Settings** | Alerts and cadence, distances, calibration, background monitoring, device rename and release |

Interface decisions worth recording:

- **The place name is shown, not the IP address.** An IP address tells an owner
  nothing about where they are. The resolved place name is the information the
  card exists to carry. (The phone's own address is still shown as a secondary
  detail, since it was asked for; it is a property of the phone, not of the
  keyholder.)
- **The event log shows the day.** "14:32" is useless a day later, and the log is
  read after the fact by definition.
- **The build number was removed from the title bar.** It is developer
  information and was occupying the most valuable space on the screen.
- **Distance is labelled an estimate.** Presenting "4.7 m" without qualification
  invites a trust the measurement cannot support.

---

## 4.9 Limitations

Stated plainly, because an implementation chapter that reports only successes is
not a useful record.

**Distance is an estimate, not a measurement.** RSSI varies by several decibels
from a hand moving across the antenna, a pocket, or a doorway. The model is
calibrated for one environment and is wrong in others; both constants are
measurable from Settings for that reason, automatically from a median of raw RSSI
samples and manually by slider.

**The keyholder's screen shows where the *phone* was.** A consequence of there
being no GPS receiver in the device. It is the right way round — "where are my
keys" is answered by the application, and "where was my phone last" is answered by
the little screen, which is the one that can be read when the phone is the thing
that is missing — but it is a different thing from what the screen might be
assumed to show.

**The keyholder cannot be sent an IP address.** The board has no network stack
and no Wi-Fi, and no frame for an address exists in either dialect of the
protocol. The place name is in any case strictly more useful on a 72 × 40 display
than an address would be.

**iOS background operation is not implemented.** An iOS application is suspended
shortly after backgrounding regardless of configuration; the only route is
CoreBluetooth's `bluetooth-central` background mode, which was not undertaken.
Every method in `BackgroundService` is a no-op off Android rather than an error.

**Physical possession defeats much of the security model.** ESP32-C3 flash is
readable over USB, and neither flash encryption nor secure boot is enabled.
Anyone holding the device can read the stored key, the last position and the
place name. Enabling those features is possible on this chip and is recommended
in Chapter Five.

**Battery life was not measured over a full discharge.** The low-power mode
demonstrably reduces current draw, but no long-run figure was obtained.

**The firmware is not compiled in continuous integration.** A test parses the
reference sketch, which catches protocol drift but not a build break.

**`applicationId` is still `com.example.keyguard`.** It must be changed before
any public release — `com.example.*` is reserved for samples and will not be
accepted by Google Play. It was left as it is because changing it breaks the
upgrade path for every already-installed build, which is a decision for release
time rather than for development.

**Calibration recovers the reference level automatically, but the path-loss
exponent only from two measurements.** The owner states a distance, the
application takes twenty-four raw readings over about six seconds and keeps the
median, and the model's reference term is solved from it. The exponent — the
larger of the two error sources — needs a second measurement at a different
distance, which the owner has to choose to take; until they do, the default
exponent stands. The scheme and the maths are in Chapter Five, §5.6.2.

---

## 4.10 Summary

The system was implemented as designed: 15,306 lines of Dart across 42 files,
firmware for the ESP32-C3, 145 automated tests all passing, and `flutter analyze`
reporting no issues. All seventeen functional requirements, all five privacy
requirements and seven of eight non-functional requirements were met, with
multi-day battery life only partly verified.

The most substantial technical work was diagnostic rather than constructive. The
fault that prevented the phone's position from reaching the keyholder's screen —
reported three times and attacked three times from the wrong side — was neither
in the application nor in the firmware's handler, but in the transport between
them: a 27-byte frame against a 20-byte default payload. The fault found while
fixing it was worse, because a single truncated frame left the keyholder's
reassembly buffer permanently poisoned and the device deaf to every subsequent
command. Both are now fixed, with explicit guards so that no single malformed
write can produce that state again.

Chapter Five draws conclusions from this and sets out recommendations for further
work.
