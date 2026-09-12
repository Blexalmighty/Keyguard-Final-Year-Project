/* ===========================================================================
 * KeyGuard — BLE object locator with owner-locked pairing
 * ESP32-C3 Super Mini (AOICRIE) + onboard 0.42" OLED
 *
 * Two-Way BLE-Based Object Proximity Alert System for Personal Item Recovery
 * BAIDOO Blessed Dokun · CSC/2019/021 · Obafemi Awolowo University
 *
 * ---------------------------------------------------------------------------
 * WHY THE SECURITY LIVES HERE AND NOT IN THE APP
 * ---------------------------------------------------------------------------
 * A BLE peripheral accepts whatever connects to it. No amount of Flutter code
 * can stop a stranger with nRF Connect from opening a GATT link, reading this
 * device's GPS history and firing its buzzer. So the requirement — "once paired,
 * nobody else can pair until the owner disconnects" — has to be enforced by this
 * sketch. The app is a client that knows how to answer; this file is the thing
 * that refuses.
 *
 * Three independent layers:
 *
 *   1. LINK ENCRYPTION. Secure Connections with MITM protection and bonding.
 *      A random 6-digit passkey appears on the OLED; the phone's operating
 *      system asks the user to type it. Every characteristic requires an
 *      encrypted link, so an unbonded stranger cannot read or write at all.
 *
 *   2. OWNER BINDING. A 16-byte owner id (from the app) and a 32-byte owner key
 *      (generated here) are stored in NVS. A claim is accepted ONLY while the
 *      physical button is held, which binds the right to claim to physical
 *      possession. The key is transmitted exactly once, at claim time.
 *
 *   3. PER-CONNECTION CHALLENGE-RESPONSE. On every later connection this device
 *      sends a fresh random nonce and gives the phone 10 seconds to return
 *      HMAC-SHA256(ownerKey, nonce || ownerId) truncated to 16 bytes. Wrong or
 *      late means disconnect, and three failures means a 30-second lockout.
 *      Because the nonce is fresh, a captured reply is worthless on replay.
 *
 * And the part that answers the requirement most directly: while the owner is
 * connected this device STOPS ADVERTISING. A second phone cannot see it, so it
 * cannot attempt to pair. That is enforced by the Bluetooth controller, not by
 * application logic.
 *
 * ---------------------------------------------------------------------------
 * WIRING
 * ---------------------------------------------------------------------------
 *   OLED SSD1306 72x40   I2C 0x3C, GPIO 8 (SDA) / GPIO 9 (SCL)  — internal
 *   Red LED              GPIO 4  via 220R to GND
 *   Active buzzer 3V     GPIO 5  — digitalWrite only, NEVER tone()
 *   Push button          GPIO 7  to GND, INPUT_PULLUP (LOW = pressed)
 *   GPS NEO-6M           module TX -> GPIO 20 (ESP RX), module RX -> GPIO 21
 *   Battery sense        GPIO 3  via 100k/100k divider from LiPo +
 *
 * ---------------------------------------------------------------------------
 * ARDUINO IDE SETTINGS  (all of these matter)
 * ---------------------------------------------------------------------------
 *   Board:              ESP32C3 Dev Module
 *   USB CDC On Boot:    ENABLED     <- see note below, this is not optional
 *   Flash Size:         4MB (32Mb)
 *   Partition Scheme:   Default 4MB with spiffs
 *   Upload Speed:       921600
 *
 * USB CDC On Boot must be ENABLED because GPIO 20 and 21 are the ESP32-C3's
 * hardware UART0 pins. With CDC enabled, Serial goes over USB and UART0 is free
 * for the GPS. With it disabled, the serial console and the GPS fight over the
 * same two pins and you get garbage on both.
 *
 * Libraries: U8g2 (by olikraus), TinyGPSPlus. BLE, Preferences, WiFi and
 * mbedTLS ship with the ESP32 core.
 * =========================================================================== */

#include <Wire.h>
#include <U8g2lib.h>

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <BLESecurity.h>

#include <Preferences.h>
#include <TinyGPSPlus.h>
#include <WiFi.h>

#include <esp_random.h>
#include <esp_gap_ble_api.h>
#include <mbedtls/md.h>
#include <mbedtls/base64.h>

/* ===========================================================================
 * SECTION 1 — Pins and hardware constants
 * =========================================================================== */

#define PIN_LED        4
#define PIN_BUZZER     5
#define PIN_BUTTON     7
#define PIN_BATTERY    3
#define PIN_GPS_RX     20   // ESP receives here; wire the GPS module's TX to it
#define PIN_GPS_TX     21   // ESP transmits here; wire the GPS module's RX to it

#define I2C_SDA        8
#define I2C_SCL        9
#define OLED_ADDRESS   0x3C

/* The 0.42" panel is driven by a full SSD1306 controller but only a 72x40 window
 * of its RAM is wired to visible pixels, and different production batches place
 * that window differently. U8g2 ships a constructor built for exactly this panel
 * (U8G2_SSD1306_72X40_ER_F_HW_I2C) with the column offset already baked into its
 * init sequence, so the drawing area is a plain 72x40 with the origin at the top
 * left corner of what you can actually see — no offsets to tune.
 *
 * This is why U8g2 rather than Adafruit_SSD1306: the Adafruit library has no
 * concept of a display window, so it needs a 128x64 buffer plus two magic offset
 * constants that have to be found by trial and error on each panel batch. */
#define OLED_W 72
#define OLED_H 40

/* Battery. Two 100k resistors halve the pack voltage, so the true voltage is
 * twice what the ADC sees. A 402030 LiPo is empty near 3.30 V and full at
 * 4.20 V; the mapping between them is linear, which is not physically accurate
 * for lithium chemistry but is honest enough for a battery pill and avoids
 * pretending to a precision this hardware does not have. */
#define BATTERY_DIVIDER_RATIO 2.0f
#define BATTERY_EMPTY_MV      3300
#define BATTERY_FULL_MV       4200
#define BATTERY_LOW_PERCENT   15

/* ===========================================================================
 * SECTION 2 — BLE protocol
 *
 * Every string below is mirrored in lib/services/ble_protocol.dart. If you
 * change one side you MUST change the other; test/auth_test.dart asserts the
 * numeric parameters so at least those will fail loudly.
 * =========================================================================== */

#define SERVICE_UUID   "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHAR_DATA_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define CHAR_AUTH_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a9"
#define CHAR_PROV_UUID "beb5483e-36e1-4688-b7f5-ea07361b26aa"

/* Advertised name. One name in both ownership states, and short on purpose.
 *
 * A fixed, distinctive name on a static address lets a stranger passively follow
 * the OWNER around — the AirTag stalking problem — so the name carries no
 * per-unit identifier. Claim state used to be encoded in the name itself
 * ("BLE-Keyholder" when unclaimed); it now rides in the scan response as service
 * data instead, for two reasons. It keeps the advertised identity constant, and
 * "BLE-Keyholder" did not fit: 15 bytes of name plus 18 of service UUID plus 3
 * of flags overruns the 31-byte legacy advertising packet, and the ESP32 BLE
 * library drops the overflowing field without saying so. "KeyGuard" is 8
 * characters, which is exactly the budget that remains.
 * Full mitigation needs resolvable private addresses; see docs/SECURITY_MODEL.md */
#define ADV_NAME "KeyGuard"

/* Claim state, advertised as one byte of service data under SERVICE_UUID so the
 * app can tell an unclaimed keyholder from somebody else's before connecting.
 * Mirrored in BleAdvFlags in lib/services/ble_protocol.dart. */
#define ADV_STATE_UNCLAIMED 0x00
#define ADV_STATE_CLAIMED   0x01

// Commands from the phone
#define CMD_FIND_KEY   "FIND_KEY"
#define CMD_STOP       "STOP"
#define CMD_GET_LOC    "GET_LOC"
#define CMD_CLAIM      "CLAIM:"
#define CMD_AUTH       "AUTH:"
#define CMD_UNCLAIM    "UNCLAIM"
#define CMD_WIFI_SET   "WIFI_SET:"
/* ALERT_SET:<token> — pick the buzzer cadence. The phone sends a NAME, never
 * milliseconds, so the numbers below can be retuned without the app agreeing to
 * anything. Tokens must match AlertPattern.wireName in lib/models/alert_pattern.dart */
#define CMD_ALERT_SET  "ALERT_SET:"

// Responses to the phone
#define RSP_READY            "READY"
#define RSP_LOC              "LOC:"
#define RSP_BAT              "BAT:"
#define RSP_FIND_PHONE       "FIND_PHONE|LOC:"
#define RSP_STATUS_UNCLAIMED "STATUS:UNCLAIMED"
#define RSP_AUTH_REQ         "AUTH_REQ:"
#define RSP_AUTH_OK          "AUTH_OK"
#define RSP_AUTH_FAIL        "AUTH_FAIL"
#define RSP_LOCKED           "LOCKED:"
#define RSP_CLAIM_OK         "CLAIM_OK:"
#define RSP_CLAIM_DENIED     "CLAIM_DENIED"
#define RSP_UNCLAIM_OK       "UNCLAIM_OK"
#define RSP_NOT_AUTHED       "ERR_NOT_AUTHED"
#define RSP_WIFI_OK          "WIFI_OK:"
#define RSP_WIFI_FAIL        "WIFI_FAIL:"
/* ALERT:<token> — the cadence this device is ACTUALLY set to. Sent on connect
 * and after every accepted ALERT_SET, so the app's Settings screen shows the
 * device's state rather than what some phone last asked for. Those two diverge
 * as soon as the app is reinstalled, or a second phone is given ownership. */
#define RSP_ALERT            "ALERT:"

#define OWNER_ID_BYTES   16
#define OWNER_KEY_BYTES  32
#define NONCE_BYTES      16
#define HMAC_BYTES       16
#define DESIRED_MTU      247

/* ===========================================================================
 * SECTION 3 — Timing
 * =========================================================================== */

#define AUTH_TIMEOUT_MS       10000UL   // must match BleAuthParams.authTimeout
#define MAX_AUTH_FAILURES     3
#define LOCKOUT_MS            30000UL
#define ALERT_MAX_MS          45000UL   // buzzer gives up rather than draining
#define BATTERY_INTERVAL_MS   30000UL   // per the handout
#define BUTTON_DEBOUNCE_MS    50UL
#define FACTORY_RESET_HOLD_MS 10000UL
#define WIFI_CONNECT_TIMEOUT  15000UL

/* ===========================================================================
 * SECTION 4 — Globals
 * =========================================================================== */

/* Full-buffer ("_F_") mode: the whole 72x40 frame is assembled in RAM and pushed
 * in one go, so partial redraws never flicker. It costs 360 bytes, which is
 * nothing next to the BLE stack. */
U8G2_SSD1306_72X40_ER_F_HW_I2C display(U8G2_R0, U8X8_PIN_NONE);
bool g_displayPresent = false;
TinyGPSPlus gps;
Preferences prefs;

BLEServer*         pServer   = nullptr;
BLECharacteristic* pDataChar = nullptr;
BLECharacteristic* pAuthChar = nullptr;
BLECharacteristic* pProvChar = nullptr;
BLEAdvertising*    pAdvertising = nullptr;

// --- Ownership, persisted in NVS ---
bool    g_claimed = false;
uint8_t g_ownerId[OWNER_ID_BYTES];
uint8_t g_ownerKey[OWNER_KEY_BYTES];

// --- Per-connection session state. Reset on every connect and disconnect. ---
bool     g_deviceConnected = false;
bool     g_sessionAuthed   = false;
uint8_t  g_nonce[NONCE_BYTES];
uint32_t g_authDeadline    = 0;
uint8_t  g_authFailures    = 0;
uint32_t g_lockoutUntil    = 0;

/* Set by the callback and acted on in loop(). Bluedroid callbacks run on the
 * BLE stack's own task; calling disconnect() or touching I2C from inside one can
 * deadlock the stack. Everything slow or reentrant is deferred to loop(). */
volatile bool g_pendingDisconnect = false;
volatile bool g_identityChanged   = false;

// --- Location ---
double  g_lastLat = 0.0;
double  g_lastLng = 0.0;
bool    g_hasFix  = false;

/* --- Alert cadences ---------------------------------------------------------
 *
 * WHY THESE ARE RHYTHMS AND NOT RINGTONES. The buzzer on GPIO 5 is an ACTIVE
 * element: it contains its own oscillator, so it has exactly one pitch and the
 * only thing this code controls is whether current is flowing. digitalWrite HIGH
 * and LOW are the entire instrument. tone() generates a square wave for a
 * PASSIVE buzzer and does nothing useful here — a mistake already recorded in
 * the hardware notes as one that cost debugging time.
 *
 * So an app menu of "Chime / Bell / Marimba" would be three names for one sound.
 * What actually differs, and what actually makes a beep findable, is the rhythm:
 * a long tone is easy to walk towards, a fast triple-beep cuts through
 * conversation, a slow single pip finds keys without announcing it to a lecture
 * hall.
 *
 * This table is the mirror of the AlertPattern enum in
 * lib/models/alert_pattern.dart. The tokens must match its wireName values
 * exactly; the millisecond numbers exist only here, which is the point — retuning
 * a pattern is a firmware change alone.
 */
struct AlertCadence {
  const char* token;    // wire token, matches AlertPattern.wireName
  uint32_t    onMs;     // buzzer driven high, per beep
  uint32_t    gapMs;    // silence BETWEEN beeps of a burst (0 when burst == 1)
  uint8_t     burst;    // beeps per burst; 1 is a plain on/off cycle
  uint32_t    pauseMs;  // silence AFTER a completed burst, before it repeats
  bool        silent;   // LED only — buzzer stays down throughout
};

static const AlertCadence ALERT_CADENCES[] = {
  { "CONT",     60000UL,   0UL, 1,    0UL, false },  // unbroken tone
  { "STEADY",     250UL,   0UL, 1,  250UL, false },  // the default
  { "TRIPLE",      90UL,  80UL, 3,  700UL, false },  // three quick beeps, pause
  { "URGENT",      60UL,   0UL, 1,   60UL, false },  // rapid chirping
  { "DISCREET",    70UL,   0UL, 1, 2000UL, false },  // one pip every two seconds
  { "SILENT",     400UL,   0UL, 1,  400UL, true  },  // LED flashes, buzzer silent
};
static const uint8_t ALERT_CADENCE_COUNT =
    sizeof(ALERT_CADENCES) / sizeof(ALERT_CADENCES[0]);

/* Index into ALERT_CADENCES. Defaults to STEADY, and is loaded from NVS at boot
 * so the choice survives a reboot and applies to the low-battery chirp — which
 * sounds whether or not a phone is anywhere near. */
uint8_t g_cadenceIndex = 1;

// --- Alert (buzzer + LED) ---
bool     g_alertActive  = false;
uint32_t g_alertStarted = 0;
uint32_t g_alertToggled = 0;
bool     g_alertOn      = false;
/* Which beep of the current burst we are on, and whether we are in the long gap
 * that follows a completed burst. Only TRIPLE uses more than one beep, but the
 * state machine is written generally so a future pattern needs no new code. */
uint8_t  g_alertBeep    = 0;
bool     g_alertInPause = false;

// --- Battery ---
int      g_batteryPercent = 0;
uint32_t g_lastBatteryRead = 0;
/* True once the low-battery warning has sounded, so it sounds once per discharge
 * rather than every 30 seconds all the way down. Cleared when the pack recovers
 * above the threshold plus hysteresis. */
bool     g_batteryWarned = false;

// --- Button ---
bool     g_buttonDown      = false;
uint32_t g_buttonDownAt    = 0;
bool     g_resetCountdownShown = false;
int      g_lastCountdownSecond = -1;

// --- Wi-Fi (credentials arrive over BLE; see SECTION 11) ---
String g_wifiSsid;
String g_wifiPass;

/* ===========================================================================
 * SECTION 5 — Display
 *
 * Keep all panel-specific code in this section. Everything else in the sketch
 * talks to the screen only through showOnOLED() and showPasskey().
 * =========================================================================== */

/* The two fonts used, and why:
 *
 *   FONT_SMALL  u8g2_font_6x10_tf   6 px advance -> exactly 12 characters across
 *                                   the 72 px panel. Keep messages to 12 chars.
 *   FONT_BIG    u8g2_font_10x20_tf  10 px advance -> a 6-digit passkey is 60 px,
 *                                   leaving a 6 px margin either side.
 *
 * The big font exists only for the passkey. The previous version drew it with a
 * 2x-scaled 6x8 font, which made six digits exactly 72 px — the full panel width
 * with no margin at all, and it clipped the "PAIR CODE" label to "PAIR C". */
#define FONT_SMALL u8g2_font_6x10_tf
#define FONT_BIG   u8g2_font_10x20_tf

void initDisplay() {
  /* This Wire.begin() looks redundant next to display.begin() and is not. The
   * two-argument U8g2 constructor leaves the I2C pins as U8X8_PIN_NONE, so
   * u8g2's own init calls Wire.begin() with no arguments and picks up the board
   * variant's defaults — which on the C3 Super Mini are GPIO 8 and 9, the pins
   * the onboard panel is wired to. Naming them here means the probe below runs
   * on the right bus, and means a reader can see which pins are in play. */
  Wire.begin(I2C_SDA, I2C_SCL);

  /* Probe before initialising. u8g2's begin() returns success even with no panel
   * attached — it writes an init sequence and never reads back — so without this
   * the log would claim a display that is not there. */
  Wire.beginTransmission(OLED_ADDRESS);
  if (Wire.endTransmission() != 0) {
    // Not fatal: the locator still works, it just cannot show a passkey, so
    // bonding would have to be confirmed from a device that can display one.
    Serial.println("OLED not found at 0x3C");
    return;
  }

  display.setBusClock(400000);
  display.begin();
  display.setFont(FONT_SMALL);
  display.clearBuffer();
  display.sendBuffer();
  g_displayPresent = true;
}

/* Up to three centred lines. Written as overloads rather than with default
 * arguments on purpose: the Arduino IDE auto-generates a prototype for every
 * function in a .ino, and when the definition carries default values the
 * generated prototype carries them too — which C++ rejects as "default argument
 * given for parameter 2". Overloads sidestep that entirely. */
void showOnOLED(const String& line1, const String& line2, const String& line3) {
  if (!g_displayPresent) return;

  const String lines[3] = {line1, line2, line3};
  const int count = (line3.length() ? 3 : (line2.length() ? 2 : 1));

  // 11 px per line: 9 px of glyph plus 2 px of air. Three lines is 33 px, which
  // leaves 7 px to distribute above and below inside the 40 px panel.
  const int lineH = 11;
  const int top   = (OLED_H - count * lineH) / 2;

  display.clearBuffer();
  display.setFont(FONT_SMALL);
  for (int i = 0; i < count; i++) {
    const char* s = lines[i].c_str();
    int x = (OLED_W - (int)display.getStrWidth(s)) / 2;
    if (x < 0) x = 0;  // over-long line: clip at the left edge, do not wrap
    // getStrWidth is measured, not assumed, so a proportional font would still
    // centre correctly if these #defines are ever changed.
    display.drawStr(x, top + 8 + i * lineH, s);
  }
  display.sendBuffer();
}

void showOnOLED(const String& line1) { showOnOLED(line1, "", ""); }

void showOnOLED(const String& line1, const String& line2) {
  showOnOLED(line1, line2, "");
}

/* The pairing passkey: a small label above, the digits as large as the panel
 * allows. Separate from showOnOLED() because it is the one screen where being
 * readable across a desk matters more than fitting the house style — the owner
 * has to copy these six digits into Android's system dialog. */
void showPasskey(const String& digits) {
  if (!g_displayPresent) return;

  display.clearBuffer();

  display.setFont(FONT_SMALL);
  const char* label = "PAIR CODE";
  int lx = (OLED_W - (int)display.getStrWidth(label)) / 2;
  if (lx < 0) lx = 0;
  display.drawStr(lx, 10, label);

  display.setFont(FONT_BIG);
  const char* d = digits.c_str();
  int dx = (OLED_W - (int)display.getStrWidth(d)) / 2;
  if (dx < 0) dx = 0;
  display.drawStr(dx, 34, d);

  display.sendBuffer();
}

/* The idle screen. Deliberately states ownership: someone holding an unclaimed
 * device should be able to tell at a glance that it is up for grabs. */
void showIdleScreen() {
  if (!g_claimed) {
    showOnOLED("UNCLAIMED", "PRESS BTN", "TO PAIR");
    return;
  }
  if (g_deviceConnected && g_sessionAuthed) {
    showOnOLED("OWNER", "CONNECTED", String(g_batteryPercent) + "%");
    return;
  }
  showOnOLED("KEYGUARD", "LOCKED", String(g_batteryPercent) + "%");
}

void showLastLocation() {
  if (!g_hasFix) {
    showOnOLED("LAST SEEN", "NO GPS FIX");
    return;
  }
  // Six decimals is about 0.1 m — more than the NEO-6M delivers, but it keeps
  // the two lines the same width, which reads better on 72 px.
  showOnOLED("LAST SEEN",
             String(g_lastLat, 4),
             String(g_lastLng, 4));
}

/* ===========================================================================
 * SECTION 6 — Small helpers
 * =========================================================================== */

void toHex(const uint8_t* bytes, size_t length, char* out) {
  static const char* digits = "0123456789abcdef";
  for (size_t i = 0; i < length; i++) {
    out[i * 2]     = digits[bytes[i] >> 4];
    out[i * 2 + 1] = digits[bytes[i] & 0x0F];
  }
  out[length * 2] = '\0';
}

int hexValue(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

/* Strict: returns false on any non-hex character or a wrong length, rather than
 * decoding what it can. A partially decoded key would authenticate today and
 * fail mysteriously later. */
bool fromHex(const String& hex, uint8_t* out, size_t expectedBytes) {
  if (hex.length() != expectedBytes * 2) return false;
  for (size_t i = 0; i < expectedBytes; i++) {
    const int hi = hexValue(hex[i * 2]);
    const int lo = hexValue(hex[i * 2 + 1]);
    if (hi < 0 || lo < 0) return false;
    out[i] = (uint8_t)((hi << 4) | lo);
  }
  return true;
}

void hmacSha256(const uint8_t* key, size_t keyLen,
                const uint8_t* msg, size_t msgLen,
                uint8_t out[32]) {
  mbedtls_md_context_t ctx;
  const mbedtls_md_info_t* info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  mbedtls_md_init(&ctx);
  mbedtls_md_setup(&ctx, info, 1);          // 1 = HMAC mode
  mbedtls_md_hmac_starts(&ctx, key, keyLen);
  mbedtls_md_hmac_update(&ctx, msg, msgLen);
  mbedtls_md_hmac_finish(&ctx, out);
  mbedtls_md_free(&ctx);
}

/* Compares without leaking, through timing, how many leading bytes matched.
 *
 * memcmp() returns as soon as it finds a difference. An attacker who can time
 * this device's reply can use that to find a valid MAC one byte at a time —
 * 16 x 256 guesses instead of 2^128. Accumulating every byte with XOR takes the
 * same time whatever the input. Mirrors PairingService.constantTimeEquals. */
bool constantTimeEquals(const uint8_t* a, const uint8_t* b, size_t length) {
  uint8_t diff = 0;
  for (size_t i = 0; i < length; i++) diff |= (uint8_t)(a[i] ^ b[i]);
  return diff == 0;
}

void notifyData(const String& payload) {
  if (!pDataChar || !g_deviceConnected) return;
  pDataChar->setValue((uint8_t*)payload.c_str(), payload.length());
  pDataChar->notify();
}

void notifyAuth(const String& payload) {
  if (!pAuthChar || !g_deviceConnected) return;
  pAuthChar->setValue((uint8_t*)payload.c_str(), payload.length());
  pAuthChar->notify();
}

bool buttonHeldNow() {
  // INPUT_PULLUP with the switch to ground, so LOW means pressed.
  return digitalRead(PIN_BUTTON) == LOW;
}

/* A short chirp used to mark security events audibly. Blocking, but only ever
 * called from loop() and only for a few tens of milliseconds.
 *
 * Overloads rather than default arguments, for the reason given on showOnOLED. */
void chirp(int times, int onMs, int offMs) {
  for (int i = 0; i < times; i++) {
    digitalWrite(PIN_BUZZER, HIGH);
    digitalWrite(PIN_LED, HIGH);
    delay(onMs);
    digitalWrite(PIN_BUZZER, LOW);
    digitalWrite(PIN_LED, LOW);
    if (i < times - 1) delay(offMs);
  }
}

void chirp(int times) { chirp(times, 80, 60); }

void chirp(int times, int onMs) { chirp(times, onMs, 60); }

/* ===========================================================================
 * SECTION 7 — Ownership storage (NVS)
 * =========================================================================== */

void loadOwnership() {
  prefs.begin("keyguard", false);
  g_claimed = prefs.getBool("claimed", false);

  if (g_claimed) {
    const size_t idLen  = prefs.getBytes("owner_id", g_ownerId, OWNER_ID_BYTES);
    const size_t keyLen = prefs.getBytes("owner_key", g_ownerKey, OWNER_KEY_BYTES);

    // A half-written claim (power loss mid-write) would otherwise leave a device
    // that is locked but cannot authenticate anybody — bricked. Treat it as
    // unclaimed and let the owner claim again.
    if (idLen != OWNER_ID_BYTES || keyLen != OWNER_KEY_BYTES) {
      Serial.println("NVS ownership record incomplete; reverting to unclaimed");
      g_claimed = false;
      prefs.putBool("claimed", false);
    }
  }

  g_wifiSsid = prefs.getString("wifi_ssid", "");
  g_wifiPass = prefs.getString("wifi_pass", "");

  Serial.printf("Ownership: %s\n", g_claimed ? "CLAIMED" : "unclaimed");
}

/* Removes every stored BLE bond.
 *
 * Necessary on release: if this device forgot its owner but kept the bond, the
 * next connection from that phone would be encrypted with a key the phone still
 * has and the two sides would disagree about who is paired. Better that both
 * sides start clean. */
void clearAllBonds() {
  const int count = esp_ble_get_bond_device_num();
  if (count <= 0) return;

  esp_ble_bond_dev_t* list =
      (esp_ble_bond_dev_t*)malloc(sizeof(esp_ble_bond_dev_t) * count);
  if (!list) return;

  int n = count;
  if (esp_ble_get_bond_device_list(&n, list) == ESP_OK) {
    for (int i = 0; i < n; i++) esp_ble_remove_bond_device(list[i].bd_addr);
    Serial.printf("Removed %d BLE bond(s)\n", n);
  }
  free(list);
}

void releaseOwnership() {
  g_claimed = false;
  g_sessionAuthed = false;
  memset(g_ownerId, 0, OWNER_ID_BYTES);
  memset(g_ownerKey, 0, OWNER_KEY_BYTES);

  prefs.putBool("claimed", false);
  prefs.remove("owner_id");
  prefs.remove("owner_key");

  clearAllBonds();
  g_identityChanged = true;
}

/* ===========================================================================
 * SECTION 8 — The ownership handshake
 * =========================================================================== */

void sendChallenge() {
  // esp_fill_random() draws from the hardware RNG. The Arduino random() family
  // is a PRNG seeded predictably and must never be used here: a guessable nonce
  // makes the whole challenge-response pointless.
  esp_fill_random(g_nonce, NONCE_BYTES);

  char hex[NONCE_BYTES * 2 + 1];
  toHex(g_nonce, NONCE_BYTES, hex);

  g_authDeadline = millis() + AUTH_TIMEOUT_MS;
  notifyAuth(String(RSP_AUTH_REQ) + hex);
  Serial.println("Challenge sent");
}

void rejectConnection(const char* reason) {
  Serial.printf("Rejecting connection: %s\n", reason);

  g_authFailures++;
  notifyAuth(RSP_AUTH_FAIL);

  if (g_authFailures >= MAX_AUTH_FAILURES) {
    g_lockoutUntil = millis() + LOCKOUT_MS;
    notifyAuth(String(RSP_LOCKED) + String(LOCKOUT_MS / 1000));
    Serial.println("Lockout engaged");
  }

  // Deferred: disconnecting from inside a stack callback can deadlock.
  g_pendingDisconnect = true;
}

/* Handles `CLAIM:<ownerId hex>`.
 *
 * The button check is the heart of it. Without it, anyone within radio range
 * could claim an unclaimed keyholder sitting on a desk. With it, claiming
 * requires holding the device — the same standard as a car key. */
void handleClaim(const String& payload) {
  if (g_claimed) {
    // Already owned. Say denied rather than explaining who owns it: that would
    // leak the owner id to a stranger.
    notifyAuth(RSP_CLAIM_DENIED);
    showOnOLED("CLAIM", "REFUSED", "ALREADY OWNED");
    chirp(2);
    return;
  }

  if (!buttonHeldNow()) {
    notifyAuth(RSP_CLAIM_DENIED);
    showOnOLED("HOLD BUTTON", "THEN CLAIM");
    Serial.println("Claim refused: button not held");
    return;
  }

  uint8_t candidateId[OWNER_ID_BYTES];
  if (!fromHex(payload, candidateId, OWNER_ID_BYTES)) {
    notifyAuth(RSP_CLAIM_DENIED);
    Serial.println("Claim refused: malformed owner id");
    return;
  }

  // The key is generated HERE, not by the phone. The device is the authority on
  // its own ownership, and the hardware RNG on this chip is better than anything
  // a Dart VM can offer.
  uint8_t newKey[OWNER_KEY_BYTES];
  esp_fill_random(newKey, OWNER_KEY_BYTES);

  memcpy(g_ownerId, candidateId, OWNER_ID_BYTES);
  memcpy(g_ownerKey, newKey, OWNER_KEY_BYTES);

  prefs.putBytes("owner_id", g_ownerId, OWNER_ID_BYTES);
  prefs.putBytes("owner_key", g_ownerKey, OWNER_KEY_BYTES);
  prefs.putBool("claimed", true);
  g_claimed = true;
  g_sessionAuthed = true;
  g_authFailures = 0;

  // Sent exactly once, ever. After this the key never leaves the device again;
  // every later connection only proves knowledge of it.
  char keyHex[OWNER_KEY_BYTES * 2 + 1];
  toHex(g_ownerKey, OWNER_KEY_BYTES, keyHex);
  notifyAuth(String(RSP_CLAIM_OK) + keyHex);

  showOnOLED("PAIRED", "OWNER SET");
  chirp(1, 200);
  Serial.println("Claimed");

  g_identityChanged = true;
}

/* Handles `AUTH:<ownerId hex>:<hmac hex>`. */
void handleAuth(const String& payload) {
  if (!g_claimed) {
    // Nothing to authenticate against. Tell the phone the truth so it offers to
    // claim instead of retrying forever.
    notifyAuth(RSP_STATUS_UNCLAIMED);
    return;
  }
  if (g_sessionAuthed) return;  // already in; ignore duplicates

  const int separator = payload.indexOf(':');
  if (separator < 0) {
    rejectConnection("malformed AUTH frame");
    return;
  }

  const String idHex  = payload.substring(0, separator);
  const String macHex = payload.substring(separator + 1);

  uint8_t claimedId[OWNER_ID_BYTES];
  uint8_t claimedMac[HMAC_BYTES];
  if (!fromHex(idHex, claimedId, OWNER_ID_BYTES) ||
      !fromHex(macHex, claimedMac, HMAC_BYTES)) {
    rejectConnection("malformed AUTH fields");
    return;
  }

  /* Compare the id in constant time too. It is not secret, but branching on it
   * early would let an attacker discover the stored owner id by timing, and a
   * known owner id is the first half of a forgery attempt. */
  if (!constantTimeEquals(claimedId, g_ownerId, OWNER_ID_BYTES)) {
    rejectConnection("owner id mismatch");
    showOnOLED("INTRUDER", "BLOCKED");
    chirp(3);
    return;
  }

  /* HMAC-SHA256(ownerKey, nonce || ownerId). The nonce is what makes this
   * replay-proof; the ownerId is inside the MAC as well as beside it on the
   * wire so a captured frame cannot have a different id substituted into it. */
  uint8_t message[NONCE_BYTES + OWNER_ID_BYTES];
  memcpy(message, g_nonce, NONCE_BYTES);
  memcpy(message + NONCE_BYTES, g_ownerId, OWNER_ID_BYTES);

  uint8_t expected[32];
  hmacSha256(g_ownerKey, OWNER_KEY_BYTES, message, sizeof(message), expected);

  if (!constantTimeEquals(claimedMac, expected, HMAC_BYTES)) {
    rejectConnection("HMAC mismatch");
    showOnOLED("INTRUDER", "BLOCKED");
    chirp(3);
    return;
  }

  /* Burn the nonce. Without this, a reply captured earlier in THIS connection
   * could be replayed within the same connection — a narrow window, but the fix
   * costs one line. */
  memset(g_nonce, 0, NONCE_BYTES);

  g_sessionAuthed = true;
  g_authFailures = 0;
  notifyAuth(RSP_AUTH_OK);

  showOnOLED("OWNER", "CONNECTED");
  Serial.println("Owner authenticated");

  // The app asks for a position on connect, but sending it unprompted here
  // means the map has something real the moment the handshake completes.
  if (g_hasFix) {
    notifyData(String(RSP_LOC) + String(g_lastLat, 6) + "," + String(g_lastLng, 6));
  }
  notifyData(String(RSP_BAT) + String(g_batteryPercent));
  // Which cadence this device is set to. Sent here rather than at connect time
  // because on a claimed device nothing before AUTH_OK is worth saying.
  notifyCadence();
}

void handleUnclaim() {
  if (!g_sessionAuthed) {
    notifyAuth(RSP_NOT_AUTHED);
    return;
  }
  notifyAuth(RSP_UNCLAIM_OK);
  releaseOwnership();
  showOnOLED("RELEASED", "UNCLAIMED");
  chirp(2, 150);
  Serial.println("Ownership released by owner");
}

/* ===========================================================================
 * SECTION 9 — Alert (the "find my keys" buzzer)
 * =========================================================================== */

const AlertCadence& currentCadence() {
  // Defensive: an NVS value written by a firmware build with more patterns than
  // this one would otherwise index off the end of the table.
  if (g_cadenceIndex >= ALERT_CADENCE_COUNT) g_cadenceIndex = 1;
  return ALERT_CADENCES[g_cadenceIndex];
}

/* Tells the phone which cadence is in force. Called on connect and after every
 * accepted ALERT_SET, because the device — not the app — is the authority here:
 * the value lives in this chip's NVS. */
void notifyCadence() {
  notifyData(String(RSP_ALERT) + currentCadence().token);
}

/* Look a token up in the table. Returns -1 for anything unrecognised, and the
 * caller ignores the command rather than guessing — silently applying the wrong
 * rhythm would be worse than doing nothing. */
int8_t cadenceIndexForToken(const String& token) {
  for (uint8_t i = 0; i < ALERT_CADENCE_COUNT; i++) {
    if (token.equalsIgnoreCase(ALERT_CADENCES[i].token)) return (int8_t)i;
  }
  return -1;
}

void loadCadence() {
  // prefs.begin() has already been called by loadOwnership().
  const uint8_t stored = prefs.getUChar("cadence", 1);
  g_cadenceIndex = (stored < ALERT_CADENCE_COUNT) ? stored : 1;
  Serial.printf("Alert cadence: %s\n", currentCadence().token);
}

/* Applies a new cadence and persists it.
 *
 * Restarts the alert if one is sounding, so a change made while the buzzer is
 * going is heard immediately — which is exactly what happens when the app's
 * preview button is used twice in a row.
 */
void setCadence(uint8_t index) {
  if (index >= ALERT_CADENCE_COUNT) return;

  const bool changed = (index != g_cadenceIndex);
  g_cadenceIndex = index;
  if (changed) prefs.putUChar("cadence", index);

  if (g_alertActive) {
    // Reset the beep state machine but keep the original start time, so choosing
    // a pattern repeatedly cannot extend the ALERT_MAX_MS budget indefinitely.
    g_alertToggled = 0;
    g_alertBeep    = 0;
    g_alertInPause = false;
    g_alertOn      = false;
    digitalWrite(PIN_BUZZER, LOW);
    digitalWrite(PIN_LED, LOW);
  }

  Serial.printf("Alert cadence set to %s\n", currentCadence().token);
  notifyCadence();
}

void startAlert() {
  g_alertActive  = true;
  g_alertStarted = millis();
  g_alertToggled = 0;
  g_alertBeep    = 0;
  g_alertInPause = false;
  g_alertOn      = false;
  showOnOLED("PINGED", "BY PHONE");
}

void stopAlert() {
  g_alertActive = false;
  digitalWrite(PIN_BUZZER, LOW);
  digitalWrite(PIN_LED, LOW);
  showLastLocation();
}

/* Non-blocking so the BLE stack keeps running and a STOP command can land while
 * the buzzer is sounding. A delay()-based beep loop would make the device
 * unresponsive for exactly as long as it was making noise.
 *
 * The state machine walks: beep, short gap, beep, short gap, ... for `burst`
 * beeps, then one long `offMs` gap, then repeats. For the common burst == 1 case
 * that collapses to plain on/off, which is what the old single-interval version
 * did — this is a generalisation of it, not a replacement of the timing.
 */
void serviceAlert() {
  if (!g_alertActive) return;

  const AlertCadence& c = currentCadence();
  const uint32_t now = millis();

  // Give up eventually. A buzzer left running would flatten a 700 mAh cell.
  if (now - g_alertStarted > ALERT_MAX_MS) {
    stopAlert();
    return;
  }

  // A continuous tone has no off phase at all. Special-cased rather than run
  // through the toggler with a zero interval, which would thrash the GPIO on
  // every pass through loop().
  if (c.pauseMs == 0 && c.gapMs == 0) {
    if (!g_alertOn) {
      g_alertOn = true;
      digitalWrite(PIN_BUZZER, c.silent ? LOW : HIGH);
      digitalWrite(PIN_LED, HIGH);
    }
    return;
  }

  /* How long the current phase lasts. Three phases, not two: an on-beep, the
   * short gap between beeps of a burst, and the long pause after the burst
   * completes. Keeping gapMs and pauseMs separate is what makes TRIPLE sound like
   * three beeps and a rest rather than six evenly spaced ones. */
  const uint32_t interval =
      g_alertOn ? c.onMs : (g_alertInPause ? c.pauseMs : c.gapMs);

  if (now - g_alertToggled < interval) return;
  g_alertToggled = now;

  if (g_alertOn) {
    // A beep just finished.
    g_alertOn = false;
    digitalWrite(PIN_BUZZER, LOW);
    digitalWrite(PIN_LED, LOW);
    g_alertBeep++;
    g_alertInPause = (g_alertBeep >= c.burst);
    if (g_alertInPause) g_alertBeep = 0;
  } else {
    // A gap or pause just finished: start the next beep.
    g_alertOn = true;
    g_alertInPause = false;
    /* SILENT drives the LED and nothing else. Not the same as switching the
     * alert off — the red LED on GPIO 4 still flashes, so the keyholder is
     * findable in a dark bag or a quiet room where a buzzer would be rude. */
    digitalWrite(PIN_BUZZER, c.silent ? LOW : HIGH);
    digitalWrite(PIN_LED, HIGH);
  }
}

/* ===========================================================================
 * SECTION 10 — BLE callbacks
 * =========================================================================== */

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    g_deviceConnected = true;
    g_sessionAuthed   = false;

    /* THE ANSWER TO "nobody else should be able to pair while I am connected".
     *
     * Advertising stops the instant anybody connects, so a second phone cannot
     * discover this device at all — there is nothing to tap. This is enforced by
     * the Bluetooth controller; no application-level check can be bypassed
     * because there is no application-level check involved. */
    if (pAdvertising) pAdvertising->stop();

    Serial.println("Connected");

    if (millis() < g_lockoutUntil) {
      const uint32_t left = (g_lockoutUntil - millis() + 999) / 1000;
      notifyAuth(String(RSP_LOCKED) + String(left));
      g_pendingDisconnect = true;
      return;
    }

    if (g_claimed) {
      sendChallenge();
    } else {
      // Honest and useful: an unclaimed device says so, and the app offers to
      // claim rather than waiting for a challenge that will never come.
      notifyAuth(RSP_STATUS_UNCLAIMED);
      notifyData(RSP_READY);
      notifyCadence();
    }
  }

  void onDisconnect(BLEServer* server) override {
    g_deviceConnected = false;
    g_sessionAuthed   = false;
    g_authDeadline    = 0;
    memset(g_nonce, 0, NONCE_BYTES);

    Serial.println("Disconnected");

    /* Advertise again — but still claimed. This is the second half of the
     * requirement: the device becomes visible once the owner leaves, yet a
     * stranger who connects now gets a challenge they cannot answer. It is
     * never "open" again unless ownership is explicitly released.
     *
     * Restarting from inside this callback is the documented pattern for the
     * Bluedroid wrapper, and it must be skipped during a lockout. */
    if (millis() >= g_lockoutUntil && pAdvertising) {
      pAdvertising->start();
    }
  }
};

/* Renders the pairing passkey on the OLED.
 *
 * This is Passkey Entry: the device displays, the phone's operating system
 * prompts. The phone app never sees this number, and that is the point — if an
 * app could read or supply it, malware could bond with your keyholder without
 * you ever looking at its screen. */
class SecurityCallbacks : public BLESecurityCallbacks {
  void onPassKeyNotify(uint32_t passKey) override {
    char digits[7];
    snprintf(digits, sizeof(digits), "%06u", (unsigned)(passKey % 1000000));
    // Size 2 gives 12 px per character: six digits is exactly 72 px, the full
    // width of the panel. Any larger and they would not fit.
    showPasskey(String(digits));
    Serial.printf("Passkey: %s\n", digits);
  }

  uint32_t onPassKeyRequest() override {
    // Never called with ESP_IO_CAP_OUT: this device displays, it does not ask.
    return 0;
  }

  bool onSecurityRequest() override { return true; }

  bool onConfirmPIN(uint32_t) override { return true; }

  void onAuthenticationComplete(esp_ble_auth_cmpl_t desc) override {
    if (desc.success) {
      Serial.println("Bonded (link encrypted)");
      showIdleScreen();
    } else {
      // Wrong code or the user cancelled. Say so on the device: a silent failure
      // here looks identical to a broken display.
      Serial.printf("Bonding failed, reason 0x%x\n", desc.fail_reason);
      showOnOLED("PAIRING", "FAILED");
      chirp(2);
    }
  }
};

/* Commands. Every one of these requires an authenticated session on a claimed
 * device — which is what makes a raw nRF Connect write of FIND_KEY do nothing. */
class DataCharCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    String command = characteristic->getValue().c_str();
    command.trim();
    if (!command.length()) return;

    Serial.printf("Data write: %s\n", command.c_str());

    if (g_claimed && !g_sessionAuthed) {
      notifyData(RSP_NOT_AUTHED);
      Serial.println("Command refused: session not authenticated");
      return;
    }

    if (command == CMD_FIND_KEY) {
      startAlert();
    } else if (command == CMD_STOP) {
      stopAlert();
    } else if (command == CMD_GET_LOC) {
      if (g_hasFix) {
        notifyData(String(RSP_LOC) + String(g_lastLat, 6) + "," +
                   String(g_lastLng, 6));
      } else {
        // No fabricated coordinates. The app renders "No GPS fix" for this.
        notifyData(String(RSP_LOC) + "0.000000,0.000000");
      }
      notifyData(String(RSP_BAT) + String(g_batteryPercent));
    } else if (command.startsWith(CMD_ALERT_SET)) {
      const String token = command.substring(strlen(CMD_ALERT_SET));
      const int8_t index = cadenceIndexForToken(token);
      if (index < 0) {
        /* An unknown token means the phone is running a newer build than this
         * firmware. Re-stating what is actually in force is more useful than an
         * error: the app corrects its own display from this notification. */
        Serial.printf("Unknown alert token: %s\n", token.c_str());
        notifyCadence();
      } else {
        setCadence((uint8_t)index);
      }
    }
  }
};

class AuthCharCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    String frame = characteristic->getValue().c_str();
    frame.trim();
    if (!frame.length()) return;

    if (frame.startsWith(CMD_CLAIM)) {
      handleClaim(frame.substring(strlen(CMD_CLAIM)));
    } else if (frame.startsWith(CMD_AUTH)) {
      handleAuth(frame.substring(strlen(CMD_AUTH)));
    } else if (frame == CMD_UNCLAIM) {
      handleUnclaim();
    } else {
      Serial.println("Unrecognised auth frame");
    }
  }
};

/* ===========================================================================
 * SECTION 11 — Wi-Fi provisioning
 *
 * Credentials arrive over the encrypted BLE link as
 * `WIFI_SET:<ssid base64>:<password base64>`. Base64 because a colon in a
 * password would otherwise split the frame in the wrong place — and passwords
 * containing colons are common.
 *
 * The phone never joins this device's Wi-Fi and this device never runs an access
 * point. It joins the user's existing network as a station, which is what it
 * needs for the Firebase upload path.
 * =========================================================================== */

String base64Decode(const String& encoded) {
  size_t outLen = 0;
  const size_t bufferSize = encoded.length() + 1;
  uint8_t* buffer = (uint8_t*)malloc(bufferSize);
  if (!buffer) return "";

  const int rc = mbedtls_base64_decode(buffer, bufferSize, &outLen,
                                       (const uint8_t*)encoded.c_str(),
                                       encoded.length());
  String result;
  if (rc == 0) {
    buffer[outLen] = '\0';
    result = String((char*)buffer);
  }
  free(buffer);
  return result;
}

void handleWifiSet(const String& payload) {
  const int separator = payload.indexOf(':');
  if (separator < 0) {
    notifyAuth(String(RSP_WIFI_FAIL) + "BAD_FORMAT");
    return;
  }

  const String ssid = base64Decode(payload.substring(0, separator));
  const String pass = base64Decode(payload.substring(separator + 1));

  if (!ssid.length()) {
    notifyAuth(String(RSP_WIFI_FAIL) + "BAD_SSID");
    return;
  }

  showOnOLED("WIFI", "CONNECTING");
  Serial.printf("Joining SSID: %s\n", ssid.c_str());

  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid.c_str(), pass.c_str());

  const uint32_t startedAt = millis();
  while (WiFi.status() != WL_CONNECTED &&
         millis() - startedAt < WIFI_CONNECT_TIMEOUT) {
    delay(250);
  }

  if (WiFi.status() != WL_CONNECTED) {
    // Do NOT persist credentials that did not work: on the next boot the device
    // would retry them forever, and BLE-only operation would look like a fault.
    WiFi.disconnect(true);
    notifyAuth(String(RSP_WIFI_FAIL) + "NO_CONNECT");
    showOnOLED("WIFI", "FAILED");
    return;
  }

  g_wifiSsid = ssid;
  g_wifiPass = pass;
  prefs.putString("wifi_ssid", ssid);
  prefs.putString("wifi_pass", pass);

  const String ip = WiFi.localIP().toString();
  notifyAuth(String(RSP_WIFI_OK) + ip);
  showOnOLED("WIFI OK", ip.substring(ip.lastIndexOf('.') + 1));
  Serial.printf("Wi-Fi connected: %s\n", ip.c_str());

  /* TODO (Phase 4) — Firebase. With the station up, publish to
   *   /keyholder/<deviceId>/last_location
   *   /keyholder/<deviceId>/events
   *   /keyholder/<deviceId>/disconnect_location
   *   /keyholder/<deviceId>/button_event
   * using Firebase_ESP_Client, authenticated with email/password. The paths are
   * per-device rather than the handout's global /keyholder because two units
   * would otherwise overwrite each other's location. Rules must require auth —
   * an open database publishes the owner's movements to anyone with the URL,
   * which would undo the point of this file. See docs/SECURITY_MODEL.md
   *
   * Note on power: Wi-Fi and BLE share one radio on the C3 and coexistence
   * roughly doubles average current. On a 150 mAh cell, keep Wi-Fi off unless
   * there is something to upload. */
}

class ProvCharCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    String frame = characteristic->getValue().c_str();
    frame.trim();

    // Provisioning is owner-only. Otherwise a stranger could point the device at
    // a network they control and intercept everything it uploads.
    if (!g_sessionAuthed) {
      notifyAuth(RSP_NOT_AUTHED);
      Serial.println("Provisioning refused: not authenticated");
      return;
    }

    if (frame.startsWith(CMD_WIFI_SET)) {
      handleWifiSet(frame.substring(strlen(CMD_WIFI_SET)));
    }
  }
};

/* ===========================================================================
 * SECTION 12 — BLE setup
 * =========================================================================== */

void applyAdvertisedIdentity() {
  /* The GAP name is updated in place rather than by rebooting, so a claim does
   * not tear down the connection the app is still using. */
  esp_ble_gap_set_device_name(ADV_NAME);

  /* Advertising packet, 31 bytes to the byte: 3 flags + 18 service UUID + 10
   * name. There is no room for a thirty-second, and BLEAdvertisementData::addData
   * discards any field that would overflow without reporting it — so anything
   * added here silently costs one of the three below. */
  BLEAdvertisementData advertisementData;
  advertisementData.setFlags(0x06);  // LE General Discoverable, BR/EDR unsupported
  // The service UUID must be in the advertisement: the app scans with a service
  // filter so it can find keyholders without inspecting every radio in the room.
  advertisementData.setCompleteServices(BLEUUID(SERVICE_UUID));
  advertisementData.setName(ADV_NAME);
  pAdvertising->setAdvertisementData(advertisementData);

  /* Claim state goes in the scan response — its own separate 31 bytes — because
   * the advertisement above has none left. The app needs this before connecting:
   * an unclaimed keyholder is offered for pairing, somebody else's is not. One
   * byte under the 128-bit service UUID costs 19 of the 31; the name is repeated
   * in the remaining 10 so that a scanner reading only this packet still has it. */
  char state = g_claimed ? ADV_STATE_CLAIMED : ADV_STATE_UNCLAIMED;
  BLEAdvertisementData scanResponseData;
  scanResponseData.setServiceData(BLEUUID(SERVICE_UUID), String(&state, 1));
  scanResponseData.setName(ADV_NAME);
  pAdvertising->setScanResponseData(scanResponseData);
}

void setupBle() {
  BLEDevice::init(ADV_NAME);

  /* CLAIM_OK: plus 64 hex characters is 73 bytes. The default 23-byte ATT MTU
   * carries 20, so the owner key would arrive silently truncated and the
   * resulting failures would look like a crypto bug. Both sides ask for 247. */
  BLEDevice::setMTU(DESIRED_MTU);

  // --- Layer 1: link security ---
  BLEDevice::setEncryptionLevel(ESP_BLE_SEC_ENCRYPT_MITM);
  BLEDevice::setSecurityCallbacks(new SecurityCallbacks());

  BLESecurity* security = new BLESecurity();
  // Secure Connections + MITM protection + bonding. MITM is what upgrades this
  // from "encrypted against a passive listener" to "authenticated".
  security->setAuthenticationMode(ESP_LE_AUTH_REQ_SC_MITM_BOND);
  // Display only: this device shows a passkey, the phone types it.
  security->setCapability(ESP_IO_CAP_OUT);
  security->setInitEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService* service = pServer->createService(SERVICE_UUID);

  pDataChar = service->createCharacteristic(
      CHAR_DATA_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE |
          BLECharacteristic::PROPERTY_NOTIFY);
  pDataChar->addDescriptor(new BLE2902());
  pDataChar->setCallbacks(new DataCharCallbacks());

  pAuthChar = service->createCharacteristic(
      CHAR_AUTH_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_NOTIFY);
  pAuthChar->addDescriptor(new BLE2902());
  pAuthChar->setCallbacks(new AuthCharCallbacks());

  pProvChar = service->createCharacteristic(
      CHAR_PROV_UUID, BLECharacteristic::PROPERTY_WRITE);
  pProvChar->setCallbacks(new ProvCharCallbacks());

  /* Every characteristic demands an encrypted, MITM-protected link. An unbonded
   * stranger cannot read or write any of them — the stack refuses before a
   * single byte reaches the code above. Accessing one triggers pairing, which is
   * why the phone sees its passkey prompt at the moment it tries to claim. */
  const esp_gatt_perm_t securePermissions =
      ESP_GATT_PERM_READ_ENC_MITM | ESP_GATT_PERM_WRITE_ENC_MITM;
  pDataChar->setAccessPermissions(securePermissions);
  pAuthChar->setAccessPermissions(securePermissions);
  pProvChar->setAccessPermissions(securePermissions);

  service->start();

  pAdvertising = BLEDevice::getAdvertising();
  /* No addServiceUUID() here: applyAdvertisedIdentity() supplies both packets
   * verbatim, and a UUID registered this way would only be re-encoded into
   * whichever packet the library felt like using. setScanResponse must precede
   * it — it invalidates the cached payload. */
  pAdvertising->setScanResponse(true);
  applyAdvertisedIdentity();
  pAdvertising->start();

  Serial.println("BLE advertising");
}

/* ===========================================================================
 * SECTION 13 — Sensors
 * =========================================================================== */

void readBattery() {
  // analogReadMilliVolts applies the chip's factory ADC calibration, which
  // matters here: the raw analogRead value on a C3 is noticeably non-linear.
  const uint32_t dividerMv = analogReadMilliVolts(PIN_BATTERY);
  const uint32_t packMv = (uint32_t)(dividerMv * BATTERY_DIVIDER_RATIO);

  int percent = (int)(((long)packMv - BATTERY_EMPTY_MV) * 100L /
                      (BATTERY_FULL_MV - BATTERY_EMPTY_MV));
  if (percent < 0) percent = 0;
  if (percent > 100) percent = 100;

  g_batteryPercent = percent;
  notifyData(String(RSP_BAT) + String(percent));

  Serial.printf("Battery: %lu mV -> %d%%\n", (unsigned long)packMv, percent);

  if (percent <= BATTERY_LOW_PERCENT && !g_alertActive) {
    showOnOLED("LOW BATTERY", String(percent) + "%");

    /* Audible warning, using the owner's chosen cadence — which is the reason the
     * choice is stored on this device rather than only in the app: this fires
     * with no phone connected, and after a reinstall.
     *
     * Once per crossing, not once per reading. The battery is sampled every 30 s,
     * and a device that beeped every 30 s from 15% down to flat would be
     * intolerable and would itself waste the remaining charge. It re-arms only
     * after the pack recovers above the threshold, i.e. after a charge. */
    if (!g_batteryWarned) {
      g_batteryWarned = true;
      const AlertCadence& c = currentCadence();
      if (!c.silent) chirp(c.burst, (int)min(c.onMs, 200UL));
      Serial.println("Low battery warning sounded");
    }
  } else if (percent > BATTERY_LOW_PERCENT + 5) {
    // +5 of hysteresis: an ADC reading that jitters across the threshold must not
    // re-arm the warning and produce a chirp every other sample.
    g_batteryWarned = false;
  }

  /* Charging is deliberately not reported. The TP4056's CHRG and STDBY pads are
   * not wired to a GPIO on this build, so the firmware genuinely cannot tell —
   * and the app's battery pill defaults isCharging to false for the same reason.
   * Wire either pad to a spare input if you want that indicator. */
}

void serviceGps() {
  while (Serial1.available()) {
    if (!gps.encode(Serial1.read())) continue;
    if (!gps.location.isValid()) continue;

    g_lastLat = gps.location.lat();
    g_lastLng = gps.location.lng();
    g_hasFix  = true;

    // Only to an authenticated owner. Streaming coordinates to whoever happens
    // to be connected would hand a stranger exactly what they want.
    if (g_deviceConnected && g_sessionAuthed && gps.location.isUpdated()) {
      notifyData(String(RSP_LOC) + String(g_lastLat, 6) + "," +
                 String(g_lastLng, 6));
    }
  }
}

/* ===========================================================================
 * SECTION 14 — Button
 *
 * Three jobs on one pin: a short press pings the phone, holding it authorises a
 * claim (checked in handleClaim), and holding for ten seconds factory-resets.
 * =========================================================================== */

void factoryReset() {
  Serial.println("Factory reset");
  releaseOwnership();

  prefs.remove("wifi_ssid");
  prefs.remove("wifi_pass");
  g_wifiSsid = "";
  g_wifiPass = "";

  showOnOLED("FACTORY", "RESET", "UNCLAIMED");
  chirp(3, 150);

  if (g_deviceConnected) g_pendingDisconnect = true;
}

void serviceButton() {
  const bool down = buttonHeldNow();
  const uint32_t now = millis();

  if (down && !g_buttonDown) {
    g_buttonDown = true;
    g_buttonDownAt = now;
    g_resetCountdownShown = false;
    g_lastCountdownSecond = -1;
    return;
  }

  if (down && g_buttonDown) {
    const uint32_t held = now - g_buttonDownAt;

    /* A visible countdown for the last five seconds. A silent ten-second hold is
     * indistinguishable from a dead button, and a factory reset that happens
     * without warning is worse still. */
    if (held > FACTORY_RESET_HOLD_MS - 5000) {
      const int remaining = (int)((FACTORY_RESET_HOLD_MS - held + 999) / 1000);
      if (remaining != g_lastCountdownSecond && remaining > 0) {
        g_lastCountdownSecond = remaining;
        showOnOLED("RESET IN", String(remaining), "RELEASE=STOP");
        g_resetCountdownShown = true;
      }
    }

    if (held >= FACTORY_RESET_HOLD_MS) {
      factoryReset();
      // Wait for release so one long hold cannot trigger a second reset.
      while (buttonHeldNow()) delay(50);
      g_buttonDown = false;
    }
    return;
  }

  if (!down && g_buttonDown) {
    const uint32_t held = now - g_buttonDownAt;
    g_buttonDown = false;

    if (held < BUTTON_DEBOUNCE_MS) return;  // contact bounce, not a press

    if (g_resetCountdownShown) {
      // They let go during the countdown. Confirm nothing happened.
      showOnOLED("RESET", "CANCELLED");
      delay(600);
      showIdleScreen();
      return;
    }

    // Short press: ping the phone.
    if (g_deviceConnected && g_sessionAuthed) {
      const String coords = g_hasFix
          ? String(g_lastLat, 6) + "," + String(g_lastLng, 6)
          : "0.000000,0.000000";
      notifyData(String(RSP_FIND_PHONE) + coords);
      showOnOLED("PINGING", "PHONE");
      chirp(1, 120);
    } else if (g_deviceConnected) {
      // Connected but unverified: do not hand a stranger the coordinates.
      showOnOLED("NOT PAIRED", "TO OWNER");
      chirp(2);
    } else {
      // TODO (Phase 4): with Wi-Fi up, push /keyholder/<id>/button_event here so
      // a press still reaches the owner when BLE is out of range.
      showLastLocation();
      chirp(1, 120);
    }
  }
}

/* ===========================================================================
 * SECTION 15 — setup / loop
 * =========================================================================== */

void setup() {
  Serial.begin(115200);
  delay(300);  // let USB CDC come up so the first prints are not lost
  Serial.println("\nKeyGuard starting");

  pinMode(PIN_LED, OUTPUT);
  pinMode(PIN_BUZZER, OUTPUT);
  pinMode(PIN_BUTTON, INPUT_PULLUP);
  digitalWrite(PIN_LED, LOW);
  digitalWrite(PIN_BUZZER, LOW);

  initDisplay();
  showOnOLED("KEYGUARD", "STARTING");

  // GPIO 20/21 are UART0's default pins; this only works with USB CDC On Boot
  // enabled, which moves the console to USB. See the header comment.
  Serial1.begin(9600, SERIAL_8N1, PIN_GPS_RX, PIN_GPS_TX);

  loadOwnership();
  loadCadence();   // must follow loadOwnership(), which opens the NVS namespace
  setupBle();

  readBattery();
  g_lastBatteryRead = millis();

  showIdleScreen();
  Serial.println("Ready");
}

void loop() {
  const uint32_t now = millis();

  /* Deferred disconnect. Calling pServer->disconnect() from inside a stack
   * callback can deadlock Bluedroid, so callbacks set a flag and the work
   * happens here, on the Arduino task. */
  if (g_pendingDisconnect) {
    g_pendingDisconnect = false;
    if (pServer) {
      // Small pause so the AUTH_FAIL or LOCKED notification actually leaves the
      // radio before the link is torn down. Without it the phone sees only a
      // dropped connection and cannot explain why.
      delay(120);
      pServer->disconnect(pServer->getConnId());
    }
  }

  // Advertised name follows ownership; applied outside the callback for the same
  // reason as above.
  if (g_identityChanged) {
    g_identityChanged = false;
    applyAdvertisedIdentity();
  }

  /* Challenge timeout. A phone that connects and then says nothing is either
   * broken or probing, and either way it must not hold the link open — while it
   * is connected this device is not advertising, so an idle intruder would be a
   * denial of service against the real owner. */
  if (g_deviceConnected && g_claimed && !g_sessionAuthed && g_authDeadline &&
      now > g_authDeadline) {
    g_authDeadline = 0;
    Serial.println("Challenge timed out");
    showOnOLED("INTRUDER", "BLOCKED", "NO REPLY");
    chirp(3);
    rejectConnection("auth timeout");
  }

  // Lockout expiry: start advertising again once the penalty is served.
  if (g_lockoutUntil && now >= g_lockoutUntil) {
    g_lockoutUntil = 0;
    g_authFailures = 0;
    if (!g_deviceConnected && pAdvertising) pAdvertising->start();
    showIdleScreen();
    Serial.println("Lockout cleared");
  }

  if (now - g_lastBatteryRead >= BATTERY_INTERVAL_MS) {
    g_lastBatteryRead = now;
    readBattery();
  }

  serviceGps();
  serviceButton();
  serviceAlert();

  delay(10);  // yields to the BLE and Wi-Fi tasks
}
