# KeyGuard firmware — ESP32-C3 Super Mini

Sketch: [`keyguard_esp32c3/keyguard_esp32c3.ino`](keyguard_esp32c3/keyguard_esp32c3.ino)

This is where the ownership lock is actually enforced. The Flutter app is a
client that knows how to answer the keyholder's challenge; it cannot stop anyone
from connecting. Only this sketch can.

---

## 1. Wiring

| Component | Pin | Notes |
|---|---|---|
| OLED SSD1306 72×40 | GPIO 8 (SDA), GPIO 9 (SCL) | Onboard, already wired. I²C address `0x3C` |
| Red LED | GPIO 4 | Through a 220 Ω resistor to GND |
| Active buzzer (3 V) | GPIO 5 | **Active**, so `digitalWrite` only — see §5 |
| Push button | GPIO 7 | Other leg to GND. `INPUT_PULLUP`, so LOW = pressed |
| GPS NEO-6M TX | GPIO 20 | Module's **TX** → ESP's **RX** |
| GPS NEO-6M RX | GPIO 21 | Module's **RX** → ESP's **TX** |
| GPS VCC | 3.3 V | Not 5 V |
| Battery sense | GPIO 3 | Via two 100 kΩ resistors as a divider from LiPo + |
| Power | 5 V pin | From TP4056 OUT+, LiPo 402030 3.7 V 700 mAh |

The TP4056's `CHRG` and `STDBY` pads are not connected to a GPIO on this build,
so **the firmware cannot detect charging** and does not claim to. The app's
battery pill shows charge level only. Wire either pad to a spare input if you
want a charging indicator.

---

## 2. Arduino IDE settings

Board Manager URL: `https://espressif.github.io/arduino-esp32/package_esp32_index.json`

| Setting | Value |
|---|---|
| Board | **ESP32C3 Dev Module** |
| USB CDC On Boot | **Enabled** ← not optional, see below |
| Flash Size | 4MB (32Mb) |
| Partition Scheme | Default 4MB with spiffs |
| Upload Speed | 921600 |

**Why USB CDC On Boot must be Enabled.** GPIO 20 and 21 are the ESP32-C3's
hardware UART0 pins. With CDC enabled, `Serial` is routed over USB and UART0 is
free for `Serial1` to use for the GPS. With it disabled, the serial monitor and
the GPS module fight over the same two pins and you get corrupted NMEA plus
unreadable debug output. If the GPS never gets a fix and the monitor prints
garbage, check this setting first.

### Libraries

Install from Library Manager:

- **U8g2** by oliver (olikraus) — the display driver
- **TinyGPSPlus** by Mikal Hart

`BLEDevice`, `Preferences`, `WiFi` and mbedTLS ship with the ESP32 core — do not
install separate versions.

---

## 3. The display

The 0.42" panel is driven by a full SSD1306 controller, but only a 72×40 window
of its RAM is wired to visible pixels — and different production batches place
that window differently.

The sketch uses U8g2's panel-specific constructor, which has the offset baked
into its initialisation sequence:

```cpp
U8G2_SSD1306_72X40_ER_F_HW_I2C display(U8G2_R0, U8X8_PIN_NONE);
```

So the drawing area is a plain 72×40 with `(0, 0)` at the top left of what you
can actually see, and **there are no offsets to tune**. This is the reason for
U8g2 over Adafruit_SSD1306: the Adafruit library has no concept of a display
window, so it needs a 128×64 buffer plus two magic offset constants that have to
be found by trial and error on each batch.

Two things to know when editing screen text:

- At `u8g2_font_6x10_tf` a character is 6 px wide, so **12 characters fit per
  line** and three lines fit vertically. Longer strings are clipped at the left
  edge rather than wrapped.
- `initDisplay()` probes address `0x3C` with `Wire` before calling
  `display.begin()`. U8g2's `begin()` reports success even with no panel attached
  — it writes an init sequence and never reads back — so without the probe the
  serial log would claim a display that is not there. If the probe fails you get
  `OLED not found at 0x3C` and `g_displayPresent` stays false; every screen call
  then returns immediately and the locator carries on working without a screen.

All panel-specific code is confined to **Section 5** of the sketch
(`initDisplay()`, `showOnOLED()`, `showPasskey()`). Nothing outside it touches
the display object.

---

## 4. First boot and claiming

1. Flash. The OLED shows `UNCLAIMED / PRESS BTN / TO PAIR` and the device
   advertises as `BLE-Keyholder`.
2. Open the app, go to **Scan**, tap **Pair** on the keyholder.
3. Tap **Pair** in the passkey sheet. A six-digit code appears on the OLED;
   Android asks for it in its own system dialog. Type it there — not into the
   app. No mobile OS lets an application supply a BLE passkey, and that
   restriction is what stops malware pairing with your keyholder behind your
   back.
4. **Press and hold the button on the device**, then tap **Claim this
   keyholder** while still holding it.
5. The OLED shows `PAIRED / OWNER SET`. The device now advertises as the generic
   name `KeyGuard` and is bound to that phone.

The button hold in step 4 is the point of the whole design: it binds the right
to claim to physical possession, so nobody can claim your keyholder from across
the room while it sits on a desk.

---

## 5. The buzzer

It is an **active** 9×4.2 mm SMD buzzer with its own internal oscillator. Drive
it with `digitalWrite(PIN_BUZZER, HIGH)` / `LOW`.

Do **not** use `tone()` or `noTone()`. Those generate a square wave for a
*passive* element; on an active buzzer they either do nothing useful or produce a
weak warble, and on the C3 `tone()` also occupies an LEDC timer for no benefit.

---

## 6. Ownership: releasing and resetting

Two paths, deliberately different in strength.

**Soft release** — Settings → Release Ownership in the app, while connected and
authenticated. Sends `UNCLAIM`, which clears the NVS record *and* wipes the BLE
bond list via `esp_ble_remove_bond_device()`. Both sides start clean.

**Hard factory reset** — hold the device's button for 10 seconds. The OLED counts
down from 5 and releasing early cancels it. Clears ownership and stored Wi-Fi
credentials.

The hard reset exists so a keyholder is never bricked by a lost or wiped phone.
It requires physical possession of the device — and if someone is holding your
keys, they already have your keys.

---

## 7. Serial output

At 115200 baud over USB. Useful lines:

```
Ownership: CLAIMED          NVS record loaded at boot
Passkey: 418902             the code currently on the OLED
Bonded (link encrypted)     Layer 1 complete
Challenge sent              Layer 3 nonce sent, 10 s clock running
Owner authenticated         Layer 3 passed, session unlocked
Rejecting connection: HMAC mismatch     a stranger was refused
Lockout engaged             3 failures, refusing connections for 30 s
```

The owner key is never printed. If you add debug output while working on the
handshake, print the nonce if you must but never the key — a serial log is not a
secret store.

---

## 8. Protocol

The `#define`s in **§2 of the sketch** mirror
[`lib/services/ble_protocol.dart`](../lib/services/ble_protocol.dart) exactly.
Change one side and you must change the other.

`test/auth_test.dart` asserts the four numeric parameters (`ownerIdBytes` 16,
`ownerKeyBytes` 32, `nonceBytes` 16, `hmacBytes` 16) and the truncation length,
so `flutter test` will fail loudly if the Dart side drifts. It cannot see the
firmware, so the reverse direction is on you.

The one ordering detail that will waste an afternoon if you get it wrong:

```
hmac = HMAC-SHA256(owner_key, nonce ‖ owner_id)   truncated to the first 16 bytes
```

Nonce first, owner id second. Swap them and every authentication fails while
looking exactly like a key-storage bug. There is a test named for this
(`nonce and ownerId are not interchangeable`) for that reason.

---

## 9. Upload recovery

If uploads start failing with `A fatal error occurred: Failed to connect`:

1. Hold **BOOT**, tap **RST**, release **BOOT** — this forces download mode.
2. Upload. It should now succeed regardless of what the running sketch was doing.
3. If the port disappears entirely after a bad flash, the USB CDC peripheral is
   held by the crashed sketch; the BOOT/RST sequence above still works because it
   bypasses the application.

Dropping Upload Speed to 115200 helps on long or unshielded cables.

---

## 10. Known limitations

- **BLE address is static.** Advertising the neutral name `KeyGuard` once claimed
  removes the obvious identifier, but a fixed MAC still lets a determined
  observer follow the *owner*. Full mitigation needs resolvable private
  addresses. See `docs/SECURITY_MODEL.md`.
- **Firebase is not wired up yet** (Phase 4). `WIFI_SET:` provisioning works and
  the station joins the network; the upload calls are marked `TODO (Phase 4)` in
  `handleWifiSet()` and `serviceButton()`.
- **Wi-Fi and BLE share one radio** on the C3. Coexistence roughly doubles
  average current draw, which on a 700 mAh cell is the difference between about
  8 hours and about 3–4 hours. Keep Wi-Fi off unless there is something to
  upload.
- **Passkey display size.** Resolved, but worth knowing why it is the way it is.
  Six digits in `u8g2_font_10x20_tf` are 60 px on a 72 px panel, so there is a
  6 px margin either side and the `PAIR CODE` label sits above it in the small
  font. The earlier version scaled the small font 2× instead, which made six
  digits exactly 72 px — the full width, no margin — and clipped the label to
  `PAIR C`. If the digits still prove hard to read, the fallback is a fixed
  passkey stored in NVS at claim time: that is a change to
  `SecurityCallbacks::onPassKeyNotify()` plus one `security->setStaticPIN()` call.
