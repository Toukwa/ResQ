// ResQ GPS tracker (ESP32 + NEO-M8L GPS, optional SIM7600 for mobile data)
//
// Sends its position straight to the Firebase Realtime Database (free Spark plan).
// Uses Wi-Fi when connected, otherwise the SIM card's mobile data (if ENABLE_CELLULAR).
//
// Arduino libraries needed (Library Manager):
//   - TinyGPSPlus        (Mikal Hart)
//   - ArduinoHttpClient  (Arduino)
//   - TinyGSM            (Volodymyr Shymanskyy)  - only when ENABLE_CELLULAR is true

// Set to true once the SIM7600 is wired, powered and has a SIM with mobile data.
#define ENABLE_CELLULAR false

#if ENABLE_CELLULAR
#define TINY_GSM_MODEM_SIM7600
#define TINY_GSM_RX_BUFFER 1024
#include <TinyGsmClient.h>
#endif

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <ArduinoHttpClient.h>
#include <TinyGPSPlus.h>
#include <time.h>

// Wi-Fi name/password, DEVICE_API_KEY and the SIM's APN live in secrets.h (not committed to git).
// Copy secrets.example.h to secrets.h and fill it in.
#include "secrets.h"

// ---------- Firebase ----------
// Each tracker signs in with its own Firebase account, created automatically on first boot:
//   email    = tracker-<mac address>@resq-tracker.app
//   password = DEVICE_API_KEY
// It may only write its own node, trackers/<its uid>. New trackers show up in the
// ResQ admin app as "Unassigned" vehicles; admins then set the plate, type and department.
const char* FIREBASE_API_KEY = "AIzaSyDHBxLSpKSbICYzLekvrysNP7dobVZFK6s";
const char* RTDB_HOST = "resq-db-41ff8-default-rtdb.asia-southeast1.firebasedatabase.app";
const char* AUTH_HOST = "identitytoolkit.googleapis.com";
const char* TOKEN_HOST = "securetoken.googleapis.com";

// ---------- Pins ----------
// NEO-M8L GPS on UART1
constexpr int GPS_RX_PIN = 4; // ESP32 RX <- GPS TX
constexpr int GPS_TX_PIN = 2; // ESP32 TX -> GPS RX (optional)
constexpr uint32_t GPS_BAUD = 9600;

// SIM7600 on UART2. Must be different pins from the GPS.
constexpr int MODEM_RX_PIN = 16;     // ESP32 RX <- SIM7600 TX
constexpr int MODEM_TX_PIN = 17;     // ESP32 TX -> SIM7600 RX
constexpr int MODEM_PWRKEY_PIN = -1; // GPIO wired to the module's PWRKEY, or -1 if it powers on by itself
constexpr uint32_t MODEM_BAUD = 115200;

// ---------- Timing ----------
// Every update is streamed to every open admin map; mobile data also costs load.
constexpr unsigned long WIFI_INTERVAL_MS = 3000;
constexpr unsigned long CELLULAR_INTERVAL_MS = 10000;
constexpr unsigned long WIFI_RETRY_INTERVAL_MS = 10000;
constexpr unsigned long CELLULAR_RETRY_INTERVAL_MS = 30000;
constexpr unsigned long GPS_STATUS_INTERVAL_MS = 2000;           // Serial monitor print interval
constexpr unsigned long TOKEN_LIFETIME_MS = 50UL * 60UL * 1000UL; // Firebase ID tokens last 60 min

TinyGPSPlus gps;
HardwareSerial GPSSerial(1);

// One kept-alive connection for location writes, one for the occasional sign-in.
WiFiClientSecure wifiRtdb;
WiFiClientSecure wifiAuth;

#if ENABLE_CELLULAR
HardwareSerial ModemSerial(2);
TinyGsm modem(ModemSerial);
TinyGsmClientSecure gsmRtdb(modem, 0);
TinyGsmClientSecure gsmAuth(modem, 1);
bool cellularReady = false;
unsigned long lastCellularAttempt = 0;
#endif

unsigned long lastLocationAttempt = 0;
unsigned long lastWifiAttempt = 0;
unsigned long lastGpsStatusPrint = 0;

String idToken;
String refreshToken;
String trackerUid;
unsigned long tokenObtainedAt = 0;

String getHardwareId() {
  String mac = WiFi.macAddress();
  mac.toUpperCase();
  return mac;
}

String trackerEmail() {
  String mac = getHardwareId();
  mac.replace(":", "");
  mac.toLowerCase();
  return "tracker-" + mac + "@resq-tracker.app";
}

// ---------- Connectivity ----------

// Waits up to 10 s at boot; afterwards the ESP32 keeps reconnecting in the background.
void connectWiFi() {
  Serial.print("[WIFI] Connecting to SSID: ");
  Serial.println(WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 10000) {
    delay(500);
    Serial.print(".");
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("\n[WIFI] Connected! ESP32 IP: ");
    Serial.println(WiFi.localIP());
  } else {
    Serial.println("\n[WIFI] Wi-Fi not available. Will use mobile data if enabled.");
  }
}

bool wifiUp() { return WiFi.status() == WL_CONNECTED; }

#if ENABLE_CELLULAR
void powerOnModem() {
  if (MODEM_PWRKEY_PIN < 0) return;
  pinMode(MODEM_PWRKEY_PIN, OUTPUT);
  digitalWrite(MODEM_PWRKEY_PIN, HIGH);
  delay(500);
  digitalWrite(MODEM_PWRKEY_PIN, LOW); // SIM7600 powers on after a ~500 ms low pulse
  delay(500);
  digitalWrite(MODEM_PWRKEY_PIN, HIGH);
  delay(5000);
}

void connectCellular() {
  Serial.println("[SIM] Starting modem...");
  if (!modem.init() && !modem.restart()) {
    Serial.println("[SIM] Modem not responding. Check wiring, power and MODEM_RX/TX pins.");
    return;
  }
  if (strlen(SIM_PIN) > 0 && modem.getSimStatus() != 3) modem.simUnlock(SIM_PIN);

  Serial.print("[SIM] Waiting for network");
  if (!modem.waitForNetwork(60000L)) {
    Serial.println(" - no signal.");
    return;
  }
  Serial.printf(" - OK (signal %d/31)\n", modem.getSignalQuality());

  if (!modem.gprsConnect(GSM_APN, GSM_USER, GSM_PASS)) {
    Serial.println("[SIM] Mobile data connection failed. Check GSM_APN in secrets.h and that the SIM has load/data.");
    return;
  }
  cellularReady = true;
  Serial.println("[SIM] Mobile data connected.");
}

bool cellularUp() {
  if (cellularReady && !modem.isGprsConnected()) {
    Serial.println("[SIM] Mobile data dropped.");
    cellularReady = false;
  }
  return cellularReady;
}
#endif

bool online() {
#if ENABLE_CELLULAR
  return wifiUp() || cellularUp();
#else
  return wifiUp();
#endif
}

// Prefer Wi-Fi (free, fast); fall back to the SIM.
Client& rtdbClient() {
#if ENABLE_CELLULAR
  if (!wifiUp()) return gsmRtdb;
#endif
  return wifiRtdb;
}

Client& authClient() {
#if ENABLE_CELLULAR
  if (!wifiUp()) return gsmAuth;
#endif
  return wifiAuth;
}

const char* transportName() { return wifiUp() ? "wifi" : "cellular"; }

// ---------- HTTPS ----------

// Sends one HTTPS request and returns the status code; the body goes in `response`.
// keepAlive reuses the TLS connection, which saves a lot of mobile data.
int httpsRequest(Client& client, const char* host, const char* method, const String& path,
                 const char* contentType, const String& body, String& response, bool keepAlive) {
  HttpClient http(client, host, 443);
  http.setHttpResponseTimeout(10000);
  if (keepAlive) http.connectionKeepAlive();

  const int err = http.startRequest(path.c_str(), method, contentType, body.length(),
                                    reinterpret_cast<const byte*>(body.c_str()));
  if (err != 0) {
    http.stop();
    return -1;
  }
  const int code = http.responseStatusCode();
  response = http.responseBody();
  if (!keepAlive || code < 0) http.stop();
  return code;
}

// ---------- Firebase auth ----------

// Minimal JSON string lookup: returns the value of "key":"value", or "" if absent.
String jsonString(const String& body, const char* key) {
  const String needle = String("\"") + key + "\"";
  int k = body.indexOf(needle);
  if (k < 0) return "";
  int start = body.indexOf('"', body.indexOf(':', k + needle.length()) + 1);
  int end = body.indexOf('"', start + 1);
  return (start < 0 || end < 0) ? "" : body.substring(start + 1, end);
}

bool storeTokens(const String& response, const char* idKey, const char* refreshKey, const char* uidKey) {
  idToken = jsonString(response, idKey);
  refreshToken = jsonString(response, refreshKey);
  trackerUid = jsonString(response, uidKey);
  tokenObtainedAt = millis();
  return idToken.length() > 0 && trackerUid.length() > 0;
}

// Signs in with this tracker's Firebase account, creating it on first boot.
bool firebaseSignIn() {
  const String body = String("{\"email\":\"") + trackerEmail() + "\",\"password\":\"" + DEVICE_API_KEY +
                      "\",\"returnSecureToken\":true}";
  String response;

  int code = httpsRequest(authClient(), AUTH_HOST, "POST",
                          String("/v1/accounts:signInWithPassword?key=") + FIREBASE_API_KEY,
                          "application/json", body, response, false);
  if (code == 200) return storeTokens(response, "idToken", "refreshToken", "localId");

  if (response.indexOf("INVALID_LOGIN_CREDENTIALS") >= 0 || response.indexOf("EMAIL_NOT_FOUND") >= 0) {
    Serial.println("[FIREBASE] No account for this tracker yet - registering it...");
    code = httpsRequest(authClient(), AUTH_HOST, "POST", String("/v1/accounts:signUp?key=") + FIREBASE_API_KEY,
                        "application/json", body, response, false);
    if (code == 200) {
      Serial.println("[FIREBASE] Tracker registered. It will appear as an Unassigned vehicle in the admin app.");
      return storeTokens(response, "idToken", "refreshToken", "localId");
    }
  }
  Serial.printf("[FIREBASE ERROR %d] Sign-in failed: %s\n", code, response.c_str());
  return false;
}

bool firebaseRefreshToken() {
  String response;
  const int code = httpsRequest(authClient(), TOKEN_HOST, "POST", String("/v1/token?key=") + FIREBASE_API_KEY,
                                "application/x-www-form-urlencoded",
                                "grant_type=refresh_token&refresh_token=" + refreshToken, response, false);
  if (code == 200) return storeTokens(response, "id_token", "refresh_token", "user_id");
  return firebaseSignIn();
}

bool ensureSignedIn() {
  if (idToken.length() == 0) return firebaseSignIn();
  if (millis() - tokenObtainedAt >= TOKEN_LIFETIME_MS) return firebaseRefreshToken();
  return true;
}

// ---------- Location ----------

// UTC time as ISO-8601, from NTP (Wi-Fi) if synced, otherwise from the GPS clock.
String isoTimestamp() {
  const time_t now = time(nullptr);
  char buf[32];
  if (now > 1700000000) {
    struct tm t;
    gmtime_r(&now, &t);
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &t);
    return buf;
  }
  if (gps.date.isValid() && gps.time.isValid() && gps.date.year() > 2020) {
    snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02dZ", gps.date.year(), gps.date.month(),
             gps.date.day(), gps.time.hour(), gps.time.minute(), gps.time.second());
    return buf;
  }
  return "";
}

bool sendLocation() {
  if (!online() || !ensureSignedIn()) return false;

  const String hardwareId = getHardwareId();
  const bool hasFix = gps.location.isValid();
  char payload[420];

  if (hasFix) {
    // A real fix: publish the position (the app treats trackers silent for 10 min as Offline)
    snprintf(payload, sizeof(payload),
      "{\"hardwareId\":\"%s\",\"hasFix\":true,\"latitude\":%.7f,\"longitude\":%.7f,\"speed_kph\":%.2f,"
      "\"course_deg\":%.2f,\"altitude_m\":%.2f,\"satellites\":%u,\"fix_timestamp\":\"%s\","
      "\"source\":\"%s\",\"received_at\":{\".sv\":\"timestamp\"}}",
      hardwareId.c_str(), gps.location.lat(), gps.location.lng(),
      gps.speed.isValid() ? gps.speed.kmph() : 0.0,
      gps.course.isValid() ? gps.course.deg() : 0.0,
      gps.altitude.isValid() ? gps.altitude.meters() : 0.0,
      gps.satellites.isValid() ? gps.satellites.value() : 0,
      isoTimestamp().c_str(), transportName());
  } else {
    // No satellites yet: only report that the tracker is alive, keep the last known position
    snprintf(payload, sizeof(payload),
      "{\"hardwareId\":\"%s\",\"hasFix\":false,\"satellites\":%u,\"source\":\"%s\",\"received_at\":{\".sv\":\"timestamp\"}}",
      hardwareId.c_str(), gps.satellites.isValid() ? gps.satellites.value() : 0, transportName());
  }

  String response;
  const int code = httpsRequest(rtdbClient(), RTDB_HOST, "PATCH",
                                "/trackers/" + trackerUid + ".json?auth=" + idToken + "&print=silent",
                                "application/json", String(payload), response, true);

  if (code == 200 || code == 204) {
    if (hasFix) {
      Serial.printf("[FIREBASE OK via %s] %s at %.5f, %.5f (%u sats)\n", transportName(), hardwareId.c_str(),
                    gps.location.lat(), gps.location.lng(), gps.satellites.value());
    }
    return true;
  }
  if (code == 401) idToken = ""; // token expired or revoked: sign in again next time
  Serial.printf("[FIREBASE ERROR %d via %s] Could not write location\n", code, transportName());
  return false;
}

// Function to print continuous status indicators to Serial Monitor
void printGpsIndicator() {
  if (gps.location.isValid()) {
    Serial.printf("[GPS FIX - MAC %s] Lat: %.7f | Lng: %.7f | Sats: %u | Alt: %.1fm | Speed: %.1f km/h | Age: %lums\n",
                  getHardwareId().c_str(),
                  gps.location.lat(),
                  gps.location.lng(),
                  gps.satellites.isValid() ? gps.satellites.value() : 0,
                  gps.altitude.isValid() ? gps.altitude.meters() : 0.0,
                  gps.speed.isValid() ? gps.speed.kmph() : 0.0,
                  gps.location.age());
  } else {
    Serial.printf("[GPS ACQUIRING - MAC %s] Searching for satellites... (Sats visible: %u, Sentences parsed: %lu)\n",
                  getHardwareId().c_str(),
                  gps.satellites.isValid() ? gps.satellites.value() : 0,
                  gps.charsProcessed());
  }
}

void setup() {
  Serial.begin(115200);
  GPSSerial.begin(GPS_BAUD, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);

  wifiRtdb.setInsecure(); // no CA bundle on the board; traffic is still encrypted
  wifiAuth.setInsecure();

  connectWiFi();
  configTime(0, 0, "pool.ntp.org", "time.nist.gov");

#if ENABLE_CELLULAR
  ModemSerial.begin(MODEM_BAUD, SERIAL_8N1, MODEM_RX_PIN, MODEM_TX_PIN);
  powerOnModem();
  if (!wifiUp()) connectCellular();
  lastCellularAttempt = millis();
#endif

  Serial.println("=================================================");
  Serial.printf(" ResQ Hardware Tracker Started (MAC: %s)\n", getHardwareId().c_str());
  Serial.printf(" Firebase account: %s\n", trackerEmail().c_str());
  Serial.printf(" Mobile data: %s\n", ENABLE_CELLULAR ? "enabled (backup when Wi-Fi is down)" : "disabled");
  Serial.println("=================================================");
}

void loop() {
  while (GPSSerial.available()) gps.encode(GPSSerial.read());

  const unsigned long now = millis();

  if (now - lastGpsStatusPrint >= GPS_STATUS_INTERVAL_MS) {
    lastGpsStatusPrint = now;
    printGpsIndicator();
  }

  // Non-blocking nudge; the loop must keep running to read the GPS and use the SIM.
  if (!wifiUp() && now - lastWifiAttempt >= WIFI_RETRY_INTERVAL_MS) {
    lastWifiAttempt = now;
    WiFi.reconnect();
  }

#if ENABLE_CELLULAR
  if (!wifiUp() && !cellularUp() && now - lastCellularAttempt >= CELLULAR_RETRY_INTERVAL_MS) {
    lastCellularAttempt = now;
    connectCellular();
  }
#endif

  const unsigned long interval = wifiUp() ? WIFI_INTERVAL_MS : CELLULAR_INTERVAL_MS;
  if (online() && now - lastLocationAttempt >= interval) {
    lastLocationAttempt = now;
    sendLocation();
  }
}
