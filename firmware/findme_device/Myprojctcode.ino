#include <Arduino.h>
#include <U8g2lib.h>
#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <esp_system.h>
#include <esp_pm.h>
#include <Preferences.h>

// ================================================================
// BOOT COUNT
// ================================================================
RTC_DATA_ATTR int bootCount = 0;

const char* resetReasonName(esp_reset_reason_t r) {
  switch (r) {
    case ESP_RST_POWERON:  return "POWERON";
    case ESP_RST_SW:       return "SW";
    case ESP_RST_PANIC:    return "PANIC";
    case ESP_RST_TASK_WDT: return "TASK_WDT";
    case ESP_RST_BROWNOUT: return "BROWNOUT";
    default:               return "OTHER";
  }
}

// ================================================================
// PINS
// ================================================================
#define SDA_PIN     5
#define SCL_PIN     6
#define LED_PIN     4
#define BUZZER_PIN  10
#define BUTTON_PIN  7
#define BAT_PIN     1
#define BAT_DIVIDER_RATIO 2.0f

// ================================================================
// BLE
// ================================================================
#define BLE_NAME            "FindMe"
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

// ================================================================
// POWER & ACTIVITY SETTINGS
// ================================================================
#define INACTIVITY_TIMEOUT_MS  600000UL   // 10 minutes → low power
#define FULL_POWER_HOLD_MS     30000UL    // stay full power 30s after activity

// ================================================================
// LOW POWER MODE
// CPU drops to 80MHz, light sleep between BLE events
// BLE stays fully connected — only clock speed reduces
// ================================================================
bool lowPowerActive = false;

void enableLowPower() {
  if (lowPowerActive) return;
  setCpuFrequencyMhz(80);
  esp_pm_config_esp32c3_t pm = {
    .max_freq_mhz       = 80,
    .min_freq_mhz       = 10,
    .light_sleep_enable = true
  };
  esp_pm_configure(&pm);
  lowPowerActive = true;
  Serial.println("[PM] Low power ON — 80MHz, light sleep");
}

void disableLowPower() {
  if (!lowPowerActive) return;
  setCpuFrequencyMhz(160);
  esp_pm_config_esp32c3_t pm = {
    .max_freq_mhz       = 160,
    .min_freq_mhz       = 80,
    .light_sleep_enable = false
  };
  esp_pm_configure(&pm);
  lowPowerActive = false;
  Serial.println("[PM] Full power ON — 160MHz");
}

// ================================================================
// OBJECTS
// ================================================================
U8G2_SSD1306_72X40_ER_F_HW_I2C u8g2(U8G2_R0, U8X8_PIN_NONE);
BLEServer*         pServer         = nullptr;
BLECharacteristic* pCharacteristic = nullptr;
Preferences        prefs;

// ================================================================
// STATE
// ================================================================
bool deviceConnected  = false;
bool alertActive      = false;
bool deviceRegistered = false;
bool buzzerState      = false;
bool distanceAlertOn  = false;  // true when distance limit exceeded

double lastLat = 0.0;
double lastLng = 0.0;
bool   hasValidLocation = false;

String locationName    = "";
bool   hasLocationName = false;

String pairedToken = "";

// Partial command reassembly. A frame longer than the write payload arrives in
// pieces, so pieces are accumulated here until the whole frame is in hand.
//
// Both guards below exist because the earlier version of this had neither and
// the board went permanently deaf. It waited for a comma before processing
// anything that began with "PHONE_LOC:", and nothing ever reset the buffer when
// that comma failed to turn up — so one truncated frame left "PHONE_LOC:7.52"
// sitting in the buffer, the next command was appended to it, the result never
// matched any command, and no command was obeyed again until a reconnect.
String        bleBuffer    = "";
unsigned long bleBufferAt  = 0;      // when the buffer last grew
#define BLE_FRAME_TIMEOUT_MS  150UL  // no newline and nothing new: take it as-is
#define BLE_BUFFER_MAX        512    // hard cap, so a stuck buffer cannot grow

int cachedBatPercent = -1;
int lastRSSI         = -65;
int displayMode      = 0;

// Distance threshold set by app (in metres, -1 = not set)
int distanceThresholdM = -1;

// Activity tracking
unsigned long lastActivityTime = 0;  // millis of last event
unsigned long fullPowerUntil   = 0;  // millis to stay full power

int  buttonState    = HIGH;
int  lastButtonState = HIGH;

unsigned long lastDebounce     = 0;
unsigned long lastDisplayCycle = 0;
unsigned long lastBuzzerToggle = 0;
unsigned long lastBatRead      = 0;
unsigned long lastBatReport    = 0;
unsigned long lastLowBatBuzz   = 0;
unsigned long lastLedBlink     = 0;
bool          ledBlinkState    = false;
int           ledBlinkCount    = 0;

const unsigned long debounceDelay        = 50;
const unsigned long displayCycleInterval = 5000;
const unsigned long buzzerOnTime         = 300;
const unsigned long buzzerOffTime        = 200;
const unsigned long batReadInterval      = 30000;
const unsigned long lowBatBuzzInterval   = 10000;

// ================================================================
// FORWARD DECLARATIONS
// ================================================================
void showCentred(String line1, String line2 = "", String line3 = "");
void showOnOLED(String line1,  String line2 = "", String line3 = "");
void updateDisplay();
void startAlert();
void stopAlert();
void broadcastViaBLE(String payload);
void processBLECommand(String value);
void drainBleBuffer();
bool bleFrameIsComplete(const String& s);
void flushStaleBleBuffer();

// ================================================================
// ACTIVITY TRACKING
// Call this whenever something meaningful happens
// Resets inactivity timer and ensures full power for 30 seconds
// ================================================================
void registerActivity() {
  lastActivityTime = millis();
  fullPowerUntil   = millis() + FULL_POWER_HOLD_MS;

  // Wake to full power if currently in low power mode
  if (lowPowerActive) {
    disableLowPower();
    Serial.println("[PM] Activity detected — waking to full power");
  }
}

// ================================================================
// PERSISTENT STORAGE
// ================================================================
void loadPairedToken() {
  prefs.begin("findme", true);
  pairedToken          = prefs.getString("token",   "");
  distanceThresholdM   = prefs.getInt("dist_thresh", -1);
  prefs.end();
  deviceRegistered = (pairedToken.length() > 0);
  Serial.println("[PAIR] " +
    (deviceRegistered ? String("registered") : String("none")));
  if (distanceThresholdM > 0) {
    Serial.println("[DIST] Threshold: " +
      String(distanceThresholdM) + "m");
  }
}

void savePairedToken(String token) {
  prefs.begin("findme", false);
  prefs.putString("token", token);
  prefs.end();
  pairedToken      = token;
  deviceRegistered = true;
}

void clearPairedToken() {
  prefs.begin("findme", false);
  prefs.remove("token");
  prefs.end();
  pairedToken      = "";
  deviceRegistered = false;
}

void saveDistanceThreshold(int metres) {
  prefs.begin("findme", false);
  prefs.putInt("dist_thresh", metres);
  prefs.end();
  distanceThresholdM = metres;
  Serial.println("[DIST] Threshold saved: " + String(metres) + "m");
}

void saveLocation(double lat, double lng) {
  prefs.begin("findme", false);
  prefs.putDouble("lat",  lat);
  prefs.putDouble("lng",  lng);
  prefs.putBool("hasloc", true);
  prefs.end();
}

void saveLocationName(String name) {
  prefs.begin("findme", false);
  prefs.putString("locname", name);
  prefs.putBool("hasname",   true);
  prefs.end();
}

void loadLastLocation() {
  prefs.begin("findme", true);
  lastLat          = prefs.getDouble("lat",    0.0);
  lastLng          = prefs.getDouble("lng",    0.0);
  hasValidLocation = prefs.getBool("hasloc",   false);
  locationName     = prefs.getString("locname","");
  hasLocationName  = prefs.getBool("hasname",  false)
                     && locationName.length() > 0;
  prefs.end();
  if (hasValidLocation) {
    Serial.print("[LOC] Restored: ");
    Serial.print(lastLat, 6);
    Serial.print(", ");
    Serial.println(lastLng, 6);
  }
}

// ================================================================
// BATTERY
// ================================================================
void diagnoseBattery() {
  Serial.println("=== BATTERY ===");
  for (int i = 0; i < 5; i++) {
    uint32_t mv = analogReadMilliVolts(BAT_PIN);
    float batV  = (mv / 1000.0f) * BAT_DIVIDER_RATIO;
    Serial.print("  mv="); Serial.print(mv);
    Serial.print("  batV="); Serial.print(batV, 3);
    Serial.println("V");
    delay(80);
  }
  Serial.println("  Expected full LiPo: ~4.2V");
  Serial.println("===============");
}

float readBatteryVoltage() {
  for (int i = 0; i < 10; i++) {
    analogReadMilliVolts(BAT_PIN); delay(3);
  }
  uint32_t sumMv = 0;
  for (int i = 0; i < 32; i++) {
    sumMv += analogReadMilliVolts(BAT_PIN); delay(3);
  }
  float adcV = (sumMv / 32.0f) / 1000.0f;
  return adcV * BAT_DIVIDER_RATIO;
}

int batteryPercentage() {
  float v = readBatteryVoltage();
  Serial.print("[BAT] "); Serial.print(v, 3); Serial.println("V");
  if (v < 2.50f || v > 4.50f) return -1;
  if (v >= 4.20f) return 100;
  if (v <= 3.00f) return 0;
  int newPct = constrain(
    (int)(((v - 3.00f) / 1.20f) * 100.0f), 0, 100);
  if (cachedBatPercent >= 0 &&
      abs(newPct - cachedBatPercent) <= 3) return cachedBatPercent;
  return newPct;
}

void updateBatteryCache() {
  if (millis() - lastBatRead > batReadInterval) {
    lastBatRead      = millis();
    cachedBatPercent = batteryPercentage();
    Serial.println("[BAT] " +
      (cachedBatPercent >= 0
        ? String(cachedBatPercent) + "%"
        : String("N/A")));
  }
}

// ================================================================
// RSSI → estimated distance in metres
// ================================================================
String rssiToDistance(int rssi) {
  if (rssi >= -55) return "Very close";
  if (rssi >= -65) return "~1-3m";
  if (rssi >= -75) return "~3-7m";
  if (rssi >= -85) return "~7-15m";
  return ">15m";
}

// Rough RSSI → metres for threshold comparison
int rssiToMetres(int rssi) {
  if (rssi >= -55) return 2;
  if (rssi >= -65) return 3;
  if (rssi >= -75) return 7;
  if (rssi >= -85) return 15;
  return 30;
}

// ================================================================
// OLED — centred splash
// ================================================================
void showCentred(String line1, String line2, String line3) {
  u8g2.clearBuffer();
  u8g2.setFont(u8g2_font_ncenB08_tr);
  auto cx = [](const String& s) -> int {
    return max(0, (72 - (int)s.length() * 6) / 2);
  };
  if      (line1 != "" && line2 == "")
    u8g2.drawStr(cx(line1), 24, line1.c_str());
  else if (line2 != "" && line3 == "") {
    u8g2.drawStr(cx(line1), 16, line1.c_str());
    u8g2.drawStr(cx(line2), 32, line2.c_str());
  } else {
    if (line1 != "") u8g2.drawStr(cx(line1), 12, line1.c_str());
    if (line2 != "") u8g2.drawStr(cx(line2), 25, line2.c_str());
    if (line3 != "") u8g2.drawStr(cx(line3), 38, line3.c_str());
  }
  u8g2.sendBuffer();
}

// ================================================================
// OLED — battery top right, content centred and below battery row
// ================================================================
void showOnOLED(String line1, String line2, String line3) {
  int bat = cachedBatPercent;
  u8g2.clearBuffer();

  // Battery top right
  u8g2.setFont(u8g2_font_5x7_tr);
  if (bat >= 0) {
    String batStr = String(bat) + "%";
    int textW = (int)batStr.length() * 5;
    int textX = 72 - textW;
    u8g2.drawStr(textX, 7, batStr.c_str());
    int iconX = textX - 12;
    u8g2.drawFrame(iconX,    1, 9, 6);
    u8g2.drawBox(iconX + 9, 3, 2, 2);
    int fw = map(bat, 0, 100, 0, 7);
    if (fw > 0) u8g2.drawBox(iconX + 1, 2, fw, 4);
    // Low power indicator top left
    if (lowPowerActive) u8g2.drawStr(0, 7, "LP");
  } else {
    u8g2.drawStr(60, 7, "?%");
    if (lowPowerActive) u8g2.drawStr(0, 7, "LP");
  }

  // Content lines — pushed down below battery row
  u8g2.setFont(u8g2_font_ncenB08_tr);
  auto cx = [](const String& s) -> int {
    return max(0, (72 - (int)s.length() * 6) / 2);
  };
  if (line1 != "") u8g2.drawStr(cx(line1), 18,
    line1.substring(0, 12).c_str());
  if (line2 != "") u8g2.drawStr(cx(line2), 29,
    line2.substring(0, 12).c_str());
  if (line3 != "") u8g2.drawStr(cx(line3), 40,
    line3.substring(0, 12).c_str());
  u8g2.sendBuffer();
}

// ================================================================
// DISPLAY
// ================================================================
void updateDisplay() {
  switch (displayMode) {
    case 0:
      if (deviceConnected) {
        showOnOLED("FindMe", rssiToDistance(lastRSSI));
      } else {
        showCentred("Looking for", "device...");
      }
      break;
    case 1:
      if (hasLocationName) {
        String name = locationName;
        if (name.length() > 12) name = name.substring(0, 12);
        showOnOLED("Location", name);
      } else if (hasValidLocation) {
        showOnOLED("Phone GPS",
                   String(lastLat, 4),
                   String(lastLng, 4));
      } else if (deviceConnected) {
        showCentred("Waiting for", "location...");
      } else {
        showCentred("Connect app", "for GPS");
      }
      break;
  }
}

// ================================================================
// BLE BROADCAST
// ================================================================
void broadcastViaBLE(String payload) {
  if (!deviceConnected || pCharacteristic == nullptr) return;
  pCharacteristic->setValue(payload.c_str());
  pCharacteristic->notify();
  Serial.println("[BLE] >> " + payload);
}

// ================================================================
// ALERT — device rings
// Always wakes to full power first
// ================================================================
void startAlert() {
  registerActivity();  // wake to full power
  alertActive      = true;
  lastBuzzerToggle = millis();
  buzzerState      = true;
  digitalWrite(BUZZER_PIN, HIGH);
  digitalWrite(LED_PIN,    HIGH);
  Serial.println("[ALERT] Started");
}

void stopAlert() {
  alertActive      = false;
  distanceAlertOn  = false;
  buzzerState      = false;
  digitalWrite(BUZZER_PIN, LOW);
  digitalWrite(LED_PIN,    LOW);
  Serial.println("[ALERT] Stopped");
}

// ================================================================
// DISTANCE ALERT
// Called when app reports distance exceeded threshold
// Rings device AND tells phone to ring
// ================================================================
void triggerDistanceAlert() {
  if (distanceAlertOn) return;  // already alerting
  distanceAlertOn = true;

  Serial.println("[DIST] Threshold exceeded — mutual alert");
  registerActivity();

  // Ring the device
  startAlert();

  // Tell phone to ring too
  broadcastViaBLE("FIND_PHONE|DIST_ALERT");

  // Show on OLED
  showCentred("Too far!", "Both ringing");
}

// ================================================================
// LOW BATTERY
// ================================================================
void handleLowBattery() {
  if (cachedBatPercent < 0 || cachedBatPercent >= 20) {
    ledBlinkCount = 0; return;
  }
  if (alertActive) return;

  unsigned long now = millis();
  if (ledBlinkCount == 0 &&
      now - lastLowBatBuzz > lowBatBuzzInterval) {
    lastLowBatBuzz = now;
    ledBlinkCount  = 4;
    lastLedBlink   = now;
    ledBlinkState  = false;
  }
  if (ledBlinkCount > 0 && now - lastLedBlink > 120) {
    lastLedBlink  = now; ledBlinkCount--;
    ledBlinkState = !ledBlinkState;
    digitalWrite(LED_PIN, ledBlinkState ? HIGH : LOW);
  }
  if (ledBlinkCount == 0) digitalWrite(LED_PIN, LOW);
}

// ================================================================
// PROCESS BLE COMMAND
// ================================================================
void processBLECommand(String value) {
  value.trim();
  if (value.length() == 0) return;
  Serial.println("[BLE] CMD: " + value);

  // Any command counts as activity
  registerActivity();

  if (value.startsWith("PAIR:")) {
    if (!deviceRegistered) {
      savePairedToken(value.substring(5));
      broadcastViaBLE("PAIR:ok");
      showCentred("Paired!", "Registered");
    } else {
      broadcastViaBLE("PAIR:already");
    }
    delay(1200); updateDisplay(); return;
  }

  if (value.startsWith("AUTH:")) {
    String token = value.substring(5);
    if (!deviceRegistered) {
      broadcastViaBLE("AUTH:ok_unpaired");
    } else if (token == pairedToken) {
      broadcastViaBLE("AUTH:ok");
      Serial.println("[AUTH] OK");
    } else {
      broadcastViaBLE("AUTH:denied");
      showCentred("SECURITY", "Bad token");
      delay(2000);
      if (pServer != nullptr)
        pServer->disconnect(pServer->getConnId());
      updateDisplay();
    }
    return;
  }

  // Phone GPS coordinates
  if (value.startsWith("PHONE_LOC:")) {
    String coords = value.substring(10); coords.trim();
    int comma = coords.indexOf(',');
    if (comma > 0) {
      String latStr = coords.substring(0, comma);
      String lngStr = coords.substring(comma + 1);
      latStr.trim(); lngStr.trim();
      double newLat = latStr.toDouble();
      double newLng = lngStr.toDouble();
      Serial.print("[LOC] lat="); Serial.print(newLat, 6);
      Serial.print(" lng="); Serial.println(newLng, 6);
      if (newLat >= -90.0  && newLat <= 90.0 &&
          newLng >= -180.0 && newLng <= 180.0 &&
          !(newLat == 0.0 && newLng == 0.0)) {
        lastLat = newLat; lastLng = newLng;
        hasValidLocation = true;
        saveLocation(lastLat, lastLng);
        broadcastViaBLE("LOC:ok");
        displayMode = 1; updateDisplay();
      } else { broadcastViaBLE("LOC:invalid"); }
    } else { broadcastViaBLE("LOC:invalid"); }
    return;
  }

  // Place name from app
  if (value.startsWith("LOCATION_NAME:")) {
    String name = value.substring(14); name.trim();
    if (name.length() > 0) {
      locationName    = name;
      hasLocationName = true;
      saveLocationName(name);
      broadcastViaBLE("NAME:ok");
      displayMode = 1; updateDisplay();
    } else { broadcastViaBLE("NAME:invalid"); }
    return;
  }

  // ── App sets distance threshold ──
  // Format: SET_DIST:50   (50 metres)
  // Format: SET_DIST:0    (disable threshold)
  if (value.startsWith("SET_DIST:")) {
    int metres = value.substring(9).toInt();
    if (metres >= 0) {
      saveDistanceThreshold(metres);
      broadcastViaBLE("DIST_SET:ok:" + String(metres));
      if (metres > 0) {
        showCentred("Alert range", String(metres) + "m set");
      } else {
        showCentred("Distance", "alert off");
      }
      delay(1500); updateDisplay();
    }
    return;
  }

  // ── App reports distance exceeded ──
  // App sends this when its own GPS calculation
  // shows device is beyond the threshold
  // Format: DIST_EXCEEDED:85  (current distance in metres)
  if (value.startsWith("DIST_EXCEEDED:")) {
    int dist = value.substring(14).toInt();
    Serial.println("[DIST] Exceeded: " + String(dist) + "m");
    triggerDistanceAlert();
    return;
  }

  // ── App confirms phone is ringing ──
  if (value == "FIND_PHONE_ACK") {
    showCentred("Phone", "ringing...");
    delay(1000); updateDisplay(); return;
  }

  // ── Phone pings device ──
  if (value == "FIND_KEY") {
    Serial.println("[ALERT] FIND_KEY");
    startAlert();
    showCentred("Ringing...");
    return;
  }

  // ── Stop all alerts ──
  if (value == "STOP") {
    stopAlert();
    showCentred("Stopped");
    delay(800); updateDisplay(); return;
  }

  if (value == "GET_BAT") {
    int bat = cachedBatPercent >= 0 ? cachedBatPercent : 0;
    broadcastViaBLE("BAT:" + String(bat)); return;
  }

  if (value == "GET_LOC") {
    broadcastViaBLE(hasValidLocation
      ? "LOC:" + String(lastLat, 6) + "," + String(lastLng, 6)
      : "LOC:none");
    return;
  }

  if (value == "GET_DIST_THRESH") {
    broadcastViaBLE("DIST_THRESH:" + String(distanceThresholdM));
    return;
  }

  // Manual low power toggle from app
  if (value == "LOW_POWER:ON") {
    enableLowPower();
    broadcastViaBLE("LOW_POWER:ok:on");
    showCentred("Low power", "mode ON");
    delay(1000); updateDisplay(); return;
  }

  if (value == "LOW_POWER:OFF") {
    disableLowPower();
    broadcastViaBLE("LOW_POWER:ok:off");
    showCentred("Full power", "mode ON");
    delay(1000); updateDisplay(); return;
  }

  if (value == "UNPAIR") {
    clearPairedToken();
    broadcastViaBLE("UNPAIRED:ok");
    showCentred("Unpaired", "Re-pair OK");
    delay(2000); updateDisplay(); return;
  }

  if (value == "TEST_BUZZ") {
    for (int i = 0; i < 3; i++) {
      digitalWrite(BUZZER_PIN, HIGH); delay(200);
      digitalWrite(BUZZER_PIN, LOW);  delay(200);
    }
    broadcastViaBLE("TEST_BUZZ:ok"); return;
  }

  Serial.println("[BLE] Unknown: " + value);
}

// ================================================================
// BLE SERVER CALLBACKS
// ================================================================
class MyServerCallbacks : public BLEServerCallbacks {

  void onConnect(BLEServer* pSrv) {
    deviceConnected = true;
    lastRSSI        = -65;
    bleBuffer       = "";
    Serial.println("[BLE] Connected");
    registerActivity();  // connection = activity

    for (int i = 0; i < 2; i++) {
      digitalWrite(LED_PIN, HIGH); delay(120);
      digitalWrite(LED_PIN, LOW);  delay(120);
    }

    int bat = cachedBatPercent >= 0 ? cachedBatPercent : 0;
    broadcastViaBLE("BAT:" + String(bat));
    broadcastViaBLE(deviceRegistered
                      ? "AUTH:registered"
                      : "AUTH:unpaired");
    broadcastViaBLE(lowPowerActive
                      ? "LOW_POWER:on"
                      : "LOW_POWER:off");
    if (distanceThresholdM > 0) {
      broadcastViaBLE("DIST_THRESH:" +
        String(distanceThresholdM));
    }

    displayMode = 0;
    updateDisplay();
  }

  void onDisconnect(BLEServer* pSrv) {
    deviceConnected = false;
    lastRSSI        = -100;
    bleBuffer       = "";
    Serial.println("[BLE] Disconnected");
    // Disconnection is NOT activity — let inactivity timer run

    if (alertActive) stopAlert();

    showCentred("Looking for", "device...");
    delay(600);
    BLEDevice::startAdvertising();
    displayMode = 0;
    updateDisplay();
  }
};

// ================================================================
// BLE CHARACTERISTIC CALLBACKS
// ================================================================
class MyCharacteristicCallbacks : public BLECharacteristicCallbacks {

  void onWrite(BLECharacteristic* pChar) {
    String chunk = pChar->getValue();
    if (chunk.length() == 0) return;

    Serial.println("[BLE] << '" + chunk + "'");

    // Appended untrimmed, on purpose. Trimming each piece before joining eats
    // the space at a split point, which turns "LOCATION_NAME:Amphitheatre, OAU"
    // into "...Amphitheatre,OAU" when the break lands there. Whitespace is
    // trimmed once, from the finished frame.
    bleBuffer += chunk;
    bleBufferAt = millis();

    if (bleBuffer.length() > BLE_BUFFER_MAX) {
      Serial.println("[BLE] buffer overrun — discarded");
      bleBuffer = "";
      return;
    }

    drainBleBuffer();
  }
};

// Pull every complete frame out of the reassembly buffer.
//
// The app sends one frame per write and does not terminate them, so in the
// normal case the buffer holds exactly one frame and is consumed immediately.
// A newline is honoured if one is present, which keeps the door open for a
// sender that batches frames, and `flushStaleBleBuffer()` in loop() handles the
// case where a frame genuinely arrived in pieces: once the pieces stop coming,
// whatever is in the buffer is the frame.
void drainBleBuffer() {
  int nl;
  while ((nl = bleBuffer.indexOf('\n')) >= 0) {
    String frame = bleBuffer.substring(0, nl);
    bleBuffer.remove(0, nl + 1);
    frame.trim();
    if (frame.length() > 0) processBLECommand(frame);
  }

  // No newline. If what is in hand is already a complete command, obey it now
  // rather than waiting out the timeout — that keeps the common case instant.
  if (bleBuffer.length() > 0 && bleFrameIsComplete(bleBuffer)) {
    String frame = bleBuffer;
    bleBuffer = "";
    frame.trim();
    if (frame.length() > 0) processBLECommand(frame);
  }
}

// Does this look like a whole command rather than the front of one?
//
// The bias is deliberately towards "yes, obey it now". One write carries one
// frame in this protocol, and with the MTU raised to 247 every frame defined
// here fits in a single write — so holding a frame back to see whether more
// arrives is not caution, it is an invitation to glue the next command onto the
// end of this one. A place name that got split would then be stored as
// "AmphitheatreSET_DIST:50".
//
// Only PHONE_LOC: is held back, because it is the one frame whose truncation
// can be detected for certain: no comma means the coordinates are not all here
// yet. A place name cannot be checked that way — any text is a valid name — so
// it is accepted as it stands. The screen truncates names to 12 characters
// anyway, so the worst case of accepting a split name is cosmetic, whereas the
// worst case of waiting is a corrupted one.
bool bleFrameIsComplete(const String& s) {
  if (s.startsWith("PHONE_LOC:")) return s.substring(10).indexOf(',') > 0;
  return true;
}

// Process a frame that stopped arriving mid-way.
//
// Called from loop(). Only a truncated PHONE_LOC: can reach here, and only on a
// stack that could not carry 27 bytes in one write. It is processed rather than
// discarded so the app gets its `LOC:invalid` answer, and the buffer is cleared
// either way — a frame that never completes must never outlive its own arrival.
void flushStaleBleBuffer() {
  if (bleBuffer.length() == 0) return;
  if (millis() - bleBufferAt < BLE_FRAME_TIMEOUT_MS) return;

  String frame = bleBuffer;
  bleBuffer = "";
  frame.trim();
  if (frame.length() > 0) {
    Serial.println("[BLE] flush '" + frame + "'");
    processBLECommand(frame);
  }
}

// ================================================================
// SETUP
// ================================================================
void setup() {
  Serial.begin(115200);
  delay(500);

  bootCount++;
  Serial.println("\n[BOOT] FindMe v1.2  boot#" +
    String(bootCount) + "  " +
    String(resetReasonName(esp_reset_reason())));

  analogReadResolution(12);
  analogSetPinAttenuation(BAT_PIN, ADC_11db);

  pinMode(LED_PIN,    OUTPUT); digitalWrite(LED_PIN,    LOW);
  pinMode(BUZZER_PIN, OUTPUT); digitalWrite(BUZZER_PIN, LOW);
  pinMode(BUTTON_PIN, INPUT_PULLUP);

  Wire.begin(SDA_PIN, SCL_PIN);
  u8g2.begin();

  showCentred("Starting"); delay(1000);
  showCentred("FindMe");   delay(1200);

  for (int i = 0; i < 3; i++) {
    digitalWrite(LED_PIN, HIGH); delay(100);
    digitalWrite(LED_PIN, LOW);  delay(100);
  }

  showCentred("FindMe", "Testing...");
  digitalWrite(BUZZER_PIN, HIGH); delay(150);
  digitalWrite(BUZZER_PIN, LOW);
  delay(400);

  diagnoseBattery();
  cachedBatPercent = batteryPercentage();
  lastBatRead      = millis();
  Serial.println("[BAT] Initial: " +
    (cachedBatPercent >= 0
      ? String(cachedBatPercent) + "%"
      : String("N/A")));

  loadPairedToken();
  loadLastLocation();

  // Start activity timer — full power on boot
  lastActivityTime = millis();
  fullPowerUntil   = millis() + FULL_POWER_HOLD_MS;

  BLEDevice::init(BLE_NAME);

  // Raise the local ATT MTU before anything connects.
  //
  // This line is why the phone's GPS reaches the screen. Without it the server
  // keeps the 23-byte default, which leaves 20 bytes of payload in a single
  // GATT write — and "PHONE_LOC:7.521834,4.526901" is 27. The frame therefore
  // could never arrive whole, arrived in pieces instead, and the reassembly
  // below used to jam on the first piece and stop processing commands at all.
  // The location page sat on "Waiting for location..." while the app had a
  // perfectly good fix and believed it had sent it.
  //
  // 247 matches BleAuthParams.desiredMtu in lib/services/ble_protocol.dart, so
  // the app's own MTU request is granted rather than clamped. Both sides must
  // agree; raising only the client does nothing.
  BLEDevice::setMTU(247);

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);
  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ  |
    BLECharacteristic::PROPERTY_WRITE |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharacteristic->addDescriptor(new BLE2902());
  pCharacteristic->setCallbacks(new MyCharacteristicCallbacks());
  pCharacteristic->setValue("READY");
  pService->start();

  BLEAdvertising* pAdv = BLEDevice::getAdvertising();
  pAdv->setScanResponse(true);
  pAdv->setMinPreferred(0x06);
  pAdv->setMaxPreferred(0x12);

  BLEAdvertisementData advData;
  advData.setFlags(0x06);
  advData.setCompleteServices(BLEUUID(SERVICE_UUID));
  advData.setName(BLE_NAME);
  pAdv->setAdvertisementData(advData);

  BLEAdvertisementData scanResp;
  scanResp.setName(BLE_NAME);
  pAdv->setScanResponseData(scanResp);

  BLEDevice::startAdvertising();
  Serial.println("[BLE] Advertising: " + String(BLE_NAME));
  Serial.println("[PM] Inactivity timeout: 10 minutes");
  Serial.println("[SYSTEM] FindMe ready");

  showCentred("FindMe"); delay(800);

  lastDisplayCycle = millis();
  lastBatRead      = millis();
  lastLowBatBuzz   = millis();
  updateDisplay();
}

// ================================================================
// LOOP
// ================================================================
void loop() {

  updateBatteryCache();

  // A frame that arrived in pieces and then stopped. See flushStaleBleBuffer().
  flushStaleBleBuffer();

  unsigned long now = millis();

  // ── POWER MANAGEMENT ──
  if (!alertActive) {
    if (!lowPowerActive && now > fullPowerUntil) {
      // Full power window expired — check inactivity
      if (now - lastActivityTime >= INACTIVITY_TIMEOUT_MS) {
        Serial.println("[PM] 10min inactivity — entering low power");
        showCentred("Low power", "mode");
        delay(1000);
        enableLowPower();
        updateDisplay();
      }
    }
  }

  // ── ALERT buzzer ──
  if (alertActive) {
    if (buzzerState && now - lastBuzzerToggle >= buzzerOnTime) {
      buzzerState = false; lastBuzzerToggle = now;
      digitalWrite(BUZZER_PIN, LOW); digitalWrite(LED_PIN, LOW);
    } else if (!buzzerState &&
               now - lastBuzzerToggle >= buzzerOffTime) {
      buzzerState = true; lastBuzzerToggle = now;
      digitalWrite(BUZZER_PIN, HIGH); digitalWrite(LED_PIN, HIGH);
    }
  }

  handleLowBattery();

  // ── BUTTON — ping phone ──
  int reading = digitalRead(BUTTON_PIN);
  if (reading != lastButtonState) lastDebounce = millis();

  if ((millis() - lastDebounce) > debounceDelay) {
    if (reading != buttonState) {
      buttonState = reading;
      if (buttonState == LOW) {
        Serial.println("[BTN] Pressed");
        registerActivity();  // button = activity

        if (deviceConnected) {
          String loc = hasValidLocation
            ? String(lastLat, 6) + "," + String(lastLng, 6)
            : "0,0";
          broadcastViaBLE("FIND_PHONE|LOC:" + loc);
          showCentred("Pinging", "phone...");
        } else {
          showCentred("No BLE", "Connect app");
        }

        if (!alertActive) {
          for (int i = 0; i < 2; i++) {
            digitalWrite(LED_PIN,    HIGH);
            digitalWrite(BUZZER_PIN, HIGH); delay(180);
            digitalWrite(BUZZER_PIN, LOW);
            digitalWrite(LED_PIN,    LOW);  delay(130);
          }
        }

        delay(200);
        updateDisplay();
      }
    }
  }
  lastButtonState = reading;

  // ── Display cycle every 5 seconds ──
  if (!alertActive &&
      millis() - lastDisplayCycle > displayCycleInterval) {
    lastDisplayCycle = millis();
    displayMode = (displayMode + 1) % 2;
    updateDisplay();
  }

  // ── Battery report every 30 seconds ──
  if (deviceConnected && millis() - lastBatReport > 30000) {
    lastBatReport = millis();
    int bat = cachedBatPercent >= 0 ? cachedBatPercent : 0;
    broadcastViaBLE("BAT:" + String(bat));
  }

  delay(10);
}