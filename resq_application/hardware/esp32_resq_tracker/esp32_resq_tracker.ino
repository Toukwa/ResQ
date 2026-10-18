// ResQ GPS tracker (ESP32 + NEO-M8L GPS, optional SIM7600 for mobile data)
//
// Sends its position straight to the Firebase Realtime Database (free Spark plan).
// Uses Wi-Fi when connected, otherwise the SIM card's mobile data (if ENABLE_CELLULAR).
//
// Arduino libraries needed (Library Manager):
//   - TinyGPSPlus        (Mikal Hart)
//   - ArduinoHttpClient  (Arduino)
//   - TinyGSM            (Volodymyr Shymanskyy)  - only when ENABLE_CELLULAR is true
//   - GovoroxSSLClient   (Govorox)               - only when ENABLE_CELLULAR is true

// Set to true once the SIM7600 is wired, powered and has a SIM with mobile data.
#define ENABLE_CELLULAR true
// Set to false to use mobile data only (Wi-Fi stays off).
#define ENABLE_WIFI false
// Shown at boot so you can confirm the right file was uploaded.
#define SKETCH_VERSION "v10-sim-data"

#if ENABLE_CELLULAR
#define TINY_GSM_MODEM_SIM7600
#define TINY_GSM_RX_BUFFER 1024
#include <TinyGsmClient.h>
#include <SSLClient.h> // TinyGSM has no TLS for the SIM7600, so the ESP32 does it
#endif

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <ArduinoHttpClient.h>
#include <TinyGPSPlus.h>
#include <time.h>

// Wi-Fi name/password, DEVICE_API_KEY and the SIM's APN live in secrets.h (not committed to git).
// Copy secrets.example.h to secrets.h and fill it in.
#include "secrets.h"
// Balance code dialed to read the SIM's remaining load/data. TNT and Smart use *123#.
// Set SIM_BALANCE_USSD in secrets.h if your SIM uses a different code.
#ifndef SIM_BALANCE_USSD
#define SIM_BALANCE_USSD "*123#"
#endif
// Code that answers directly with the remaining mobile DATA (shown in the app).
// Left empty, the tracker presses SIM_DATA_MENU in the SIM_BALANCE_USSD menu instead.
#ifndef SIM_DATA_USSD
#define SIM_DATA_USSD ""
#endif
// Options pressed in the SIM_BALANCE_USSD menu to reach the data balance, in order.
// TNT: *123# > 10) Waishacks > 1) Balance.
#ifndef SIM_DATA_MENU
#define SIM_DATA_MENU "10,1"
#endif

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
constexpr int GPS_TX_PIN = 2; // ESP32 TX -> GPS RX (needed for the 5 Hz setup below)
constexpr uint32_t GPS_BAUD = 9600;

// SIM7600 on UART2. Must be different pins from the GPS.
constexpr int MODEM_RX_PIN = 16;     // ESP32 RX <- SIM7600 TX
constexpr int MODEM_TX_PIN = 17;     // ESP32 TX -> SIM7600 RX
constexpr int MODEM_PWRKEY_PIN = 18; // GPIO wired to the module's PWRKEY, or -1 if it powers on by itself
constexpr uint32_t MODEM_BAUD = 115200;

// ---------- Timing ----------
// Every update is streamed to every open admin map; mobile data also costs load.
constexpr unsigned long WIFI_INTERVAL_MS = 1000;
constexpr unsigned long CELLULAR_INTERVAL_MS = 3000;
constexpr unsigned long HEARTBEAT_INTERVAL_MS = 30000;          // Write even without a new fix so the app keeps it Online
constexpr uint16_t GPS_RATE_MS = 200;                            // 5 position fixes per second
constexpr unsigned long WIFI_RETRY_INTERVAL_MS = 10000;
constexpr unsigned long CELLULAR_RETRY_INTERVAL_MS = 30000;
// Route history: a point is recorded on the board (online or not) when the vehicle turns
// or has moved far enough, so the drawn route follows the road's bends instead of cutting
// corners. Points wait in a buffer and are uploaded in batches, so a signal loss leaves
// no hole in the route: everything recorded offline goes up once the signal is back.
constexpr unsigned long HISTORY_MAX_INTERVAL_MS = 30000;        // A point at least this often (also when parked)
constexpr unsigned long HISTORY_MIN_INTERVAL_MS = 2000;         // Never more often than this
constexpr double HISTORY_TURN_DEG = 20.0;                       // A turn this sharp records a point...
constexpr double HISTORY_TURN_MIN_M = 15.0;                     // ...once it has moved this far
constexpr double HISTORY_STRAIGHT_M = 150.0;                    // On a straight road, a point every 150 m
constexpr unsigned long HISTORY_FLUSH_MS = 10000;               // Upload buffered points this often while online
constexpr int HISTORY_BATCH = 25;                               // Points per upload
constexpr int HISTORY_BUFFER = 720;                             // ~6 h of driving offline (17 KB of RAM)
constexpr unsigned long GPS_STATUS_INTERVAL_MS = 2000;           // Serial monitor print interval
constexpr unsigned long BALANCE_INTERVAL_MS = 6UL * 60UL * 60UL * 1000UL; // SIM balance check every 6 h
constexpr unsigned long BALANCE_FIRST_DELAY_MS = 60000;             // First check 1 min after boot
constexpr unsigned long TOKEN_LIFETIME_MS = 50UL * 60UL * 1000UL; // Firebase ID tokens last 60 min

TinyGPSPlus gps;
HardwareSerial GPSSerial(1);

// One kept-alive connection for location writes, one for the occasional sign-in.
WiFiClientSecure wifiRtdb;
WiFiClientSecure wifiAuth;

#if ENABLE_CELLULAR
HardwareSerial ModemSerial(2);
TinyGsm modem(ModemSerial);
TinyGsmClient gsmRtdbBase(modem, 0);
TinyGsmClient gsmAuthBase(modem, 1);
SSLClient gsmRtdb(&gsmRtdbBase);
SSLClient gsmAuth(&gsmAuthBase);
bool cellularReady = false;
unsigned long lastCellularAttempt = 0;
unsigned long lastBalanceCheck = 0;
bool balanceChecked = false;
#endif

unsigned long lastLocationAttempt = 0;
unsigned long lastLocationSent = 0;
unsigned long lastHistoryPoint = 0;
unsigned long lastHistoryFlush = 0;

// ---------- Route history buffer ----------
struct HistoryPoint {
  double lat;
  double lng;
  float speedKph;
  uint64_t tsMs; // UTC milliseconds, from the GPS clock (works without signal)
};
HistoryPoint history[HISTORY_BUFFER];
int historyStart = 0; // oldest point
int historyCount = 0;
double lastPointLat = 0, lastPointLng = 0, lastPointCourse = -1;
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

// ---------- GPS setup ----------

// Sends one u-blox UBX command (adds the header and checksum).
void sendUbx(uint8_t cls, uint8_t id, const uint8_t* payload, uint16_t len) {
  uint8_t ckA = 0, ckB = 0;
  const uint8_t head[] = {cls, id, (uint8_t)(len & 0xFF), (uint8_t)(len >> 8)};
  GPSSerial.write(0xB5);
  GPSSerial.write(0x62);
  for (uint8_t b : head) { GPSSerial.write(b); ckA += b; ckB += ckA; }
  for (uint16_t i = 0; i < len; i++) { GPSSerial.write(payload[i]); ckA += payload[i]; ckB += ckA; }
  GPSSerial.write(ckA);
  GPSSerial.write(ckB);
  delay(50);
}

// The NEO-M8L sends 1 fix per second by default. Turn off the sentences we don't use
// (so 9600 baud has room) and raise it to 5 fixes per second.
void configureGps() {
  const uint8_t unused[] = {0x01, 0x02, 0x03, 0x05}; // GLL, GSA, GSV, VTG
  for (uint8_t msg : unused) {
    const uint8_t off[] = {0xF0, msg, 0};
    sendUbx(0x06, 0x01, off, sizeof(off));
  }
  const uint8_t rate[] = {(uint8_t)(GPS_RATE_MS & 0xFF), (uint8_t)(GPS_RATE_MS >> 8), 1, 0, 1, 0};
  sendUbx(0x06, 0x08, rate, sizeof(rate));
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

bool wifiUp() { return ENABLE_WIFI && WiFi.status() == WL_CONNECTED; }

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
  // The SIM7600 needs ~15-20 s after power-on before it answers AT commands.
  if (!modem.testAT(30000) || (!modem.init() && !modem.restart())) {
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
  Serial.printf("[SIM] IP: %s\n", modem.localIP().toString().c_str());
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
    // -1 = could not connect (DNS/TCP/TLS), -2 = server error, -3 = timed out
    Serial.printf("[HTTPS] %s via %s failed, startRequest error %d\n", host, transportName(), err);
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

// UTC milliseconds since 1970 from the GPS clock (or NTP once synced), or 0 if unknown.
uint64_t epochMs() {
  const time_t now = time(nullptr);
  if (now > 1700000000) return (uint64_t)now * 1000ULL;
  if (!gps.date.isValid() || !gps.time.isValid() || gps.date.year() < 2021) return 0;
  // Days since 1970-01-01 for the GPS date (civil-from-days, no timezone involved)
  int y = gps.date.year(), m = gps.date.month(), d = gps.date.day();
  y -= m <= 2;
  const int era = y / 400;
  const unsigned yoe = (unsigned)(y - era * 400);
  const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  const int64_t days = (int64_t)era * 146097 + (int64_t)doe - 719468;
  return (uint64_t)(days * 86400LL + gps.time.hour() * 3600LL + gps.time.minute() * 60LL + gps.time.second()) * 1000ULL +
         gps.time.centisecond() * 10ULL;
}

// Keeps the buffer from overflowing on a very long outage: drops every other point of the
// older half, so the whole outage stays covered (just less detailed) instead of losing its start.
void thinHistory() {
  const int half = historyCount / 2;
  int kept = 0;
  for (int i = 0; i < half; i++) {
    if (i % 2 == 0) history[(historyStart + kept++) % HISTORY_BUFFER] = history[(historyStart + i) % HISTORY_BUFFER];
  }
  for (int i = half; i < historyCount; i++) history[(historyStart + kept++) % HISTORY_BUFFER] = history[(historyStart + i) % HISTORY_BUFFER];
  Serial.printf("[HISTORY] Buffer full - thinned %d old points to %d\n", half, (half + 1) / 2);
  historyCount = kept;
}

// Records the current fix in the buffer when the vehicle has turned or moved far enough.
void recordHistoryPoint() {
  if (!gps.location.isValid() || gps.location.age() > 2000) return;
  const unsigned long now = millis();
  const bool first = lastHistoryPoint == 0;
  if (!first && now - lastHistoryPoint < HISTORY_MIN_INTERVAL_MS) return;

  const double lat = gps.location.lat(), lng = gps.location.lng();
  const double moved = first ? 0 : TinyGPSPlus::distanceBetween(lastPointLat, lastPointLng, lat, lng);
  const double course = gps.course.isValid() ? gps.course.deg() : -1;
  double turn = 0;
  if (course >= 0 && lastPointCourse >= 0) {
    turn = fabs(course - lastPointCourse);
    if (turn > 180) turn = 360 - turn;
  }
  const bool due = first || now - lastHistoryPoint >= HISTORY_MAX_INTERVAL_MS ||
                   moved >= HISTORY_STRAIGHT_M || (turn >= HISTORY_TURN_DEG && moved >= HISTORY_TURN_MIN_M);
  if (!due) return;

  const uint64_t ts = epochMs();
  if (ts == 0) return; // no clock yet: the point couldn't be placed in time
  if (historyCount == HISTORY_BUFFER) thinHistory();
  history[(historyStart + historyCount) % HISTORY_BUFFER] = {lat, lng, gps.speed.isValid() ? (float)gps.speed.kmph() : 0.0f, ts};
  historyCount++;
  lastHistoryPoint = now;
  lastPointLat = lat;
  lastPointLng = lng;
  if (course >= 0 && (moved >= HISTORY_TURN_MIN_M || first)) lastPointCourse = course;
}

// Uploads up to HISTORY_BATCH buffered points to tracker_history/<uid> in one request.
// Each point's key comes from its time, so re-sending a batch after a lost reply is harmless.
bool flushHistory() {
  if (historyCount == 0) return true;
  if (!online() || !ensureSignedIn()) return false;
  const int n = historyCount < HISTORY_BATCH ? historyCount : HISTORY_BATCH;
  String body = "{";
  char item[160];
  for (int i = 0; i < n; i++) {
    const HistoryPoint& p = history[(historyStart + i) % HISTORY_BUFFER];
    snprintf(item, sizeof(item), "%s\"t%llu\":{\"latitude\":%.7f,\"longitude\":%.7f,\"speed_kph\":%.2f,\"ts\":%llu}",
             i == 0 ? "" : ",", (unsigned long long)p.tsMs, p.lat, p.lng, p.speedKph, (unsigned long long)p.tsMs);
    body += item;
  }
  body += "}";

  String response;
  const int code = httpsRequest(rtdbClient(), RTDB_HOST, "PATCH",
                                "/tracker_history/" + trackerUid + ".json?auth=" + idToken + "&print=silent",
                                "application/json", body, response, true);
  if (code == 200 || code == 204) {
    historyStart = (historyStart + n) % HISTORY_BUFFER;
    historyCount -= n;
    Serial.printf("[HISTORY] Uploaded %d point(s), %d still buffered\n", n, historyCount);
    return true;
  }
  if (code == 401) idToken = "";
  Serial.printf("[FIREBASE ERROR %d via %s] Could not upload history (%d buffered)\n", code, transportName(), historyCount);
  return false;
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

#if ENABLE_CELLULAR
// Puts text inside a JSON string: escapes quotes and backslashes, turns line breaks into spaces.
String jsonEscape(const String& in) {
  String out;
  for (unsigned i = 0; i < in.length() && out.length() < 300; i++) {
    const char c = in[i];
    if (c == '"' || c == '\\') { out += '\\'; out += c; }
    else if (c == '\n' || c == '\r' || c == '\t') out += ' ';
    else if ((uint8_t)c >= 0x20) out += c;
  }
  out.trim();
  return out;
}

// The SIM's own phone number (AT+CNUM), or "" when the network didn't store it on the SIM.
String readSimNumber() {
  String reply;
  modem.sendAT("+CNUM");
  if (modem.waitResponse(3000L, reply) != 1) return "";
  // +CNUM: "","+639171234567",145
  const int k = reply.indexOf("+CNUM:");
  if (k < 0) return "";
  const int start = reply.indexOf("\",\"", k);
  const int end = start < 0 ? -1 : reply.indexOf('"', start + 3);
  return end < 0 ? "" : jsonEscape(reply.substring(start + 3, end));
}

// Presses the SIM_DATA_MENU options one by one in the open USSD menu and returns
// the last screen (the data balance), or "" if the network stopped answering.
String followDataMenu() {
  String path = SIM_DATA_MENU;
  String reply;
  while (path.length() > 0) {
    const int comma = path.indexOf(',');
    String option = comma < 0 ? path : path.substring(0, comma);
    path = comma < 0 ? "" : path.substring(comma + 1);
    option.trim();
    Serial.printf("[SIM] Menu: pressing %s\n", option.c_str());
    reply = modem.sendUSSD(option);
    if (reply.length() == 0) return "";
  }
  return reply;
}

// Dials the balance code and saves the network's reply to trackers/<uid>/sim_balance,
// so the app's Fleet Management can show how much load/data the SIM has left.
void checkSimBalance() {
  Serial.printf("[SIM] Checking balance with %s...\n", SIM_BALANCE_USSD);
  const String reply = modem.sendUSSD(SIM_BALANCE_USSD);
  if (reply.length() == 0) {
    Serial.println("[SIM] No balance reply from the network. Will try again later.");
    return;
  }
  Serial.printf("[SIM] Balance: %s\n", reply.c_str());
  String data;
  if (strlen(SIM_DATA_USSD) > 0) {
    // A separate data code: close the balance menu first, then dial it.
    modem.sendAT("+CUSD=2");
    modem.waitResponse(2000L);
    data = modem.sendUSSD(SIM_DATA_USSD);
  } else {
    // TNT/Smart: the data balance sits inside the *123# menu.
    data = followDataMenu();
  }
  modem.sendAT("+CUSD=2"); // end the USSD session
  modem.waitResponse(2000L);
  Serial.printf("[SIM] Data: %s\n", data.length() ? data.c_str() : "(not found)");
  const String number = readSimNumber();
  Serial.printf("[SIM] Number: %s\n", number.length() ? number.c_str() : "(not stored on the SIM)");
  if (!online() || !ensureSignedIn()) return;

  String body = String("{\"hardwareId\":\"") + getHardwareId() + "\",\"sim_balance\":\"" + jsonEscape(reply) +
                "\",\"sim_balance_at\":{\".sv\":\"timestamp\"}";
  if (number.length()) body += ",\"sim_number\":\"" + number + "\"";
  if (data.length()) body += ",\"sim_data\":\"" + jsonEscape(data) + "\"";
  body += "}";
  String response;
  const int code = httpsRequest(rtdbClient(), RTDB_HOST, "PATCH",
                                "/trackers/" + trackerUid + ".json?auth=" + idToken + "&print=silent",
                                "application/json", body, response, true);
  if (code == 401) idToken = "";
  if (code != 200 && code != 204) Serial.printf("[FIREBASE ERROR %d] Could not save SIM balance\n", code);
}
#endif

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
  GPSSerial.setRxBufferSize(2048); // keeps fixes while an upload blocks the loop
  GPSSerial.begin(GPS_BAUD, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);
  configureGps();

  wifiRtdb.setInsecure(); // no CA bundle on the board; traffic is still encrypted
  wifiAuth.setInsecure();
#if ENABLE_CELLULAR
  gsmRtdb.setInsecure();
  gsmAuth.setInsecure();
#endif

  if (ENABLE_WIFI) connectWiFi();
  else WiFi.mode(WIFI_STA); // radio on but never connects; keeps WiFi.macAddress() (the tracker ID) valid
  configTime(0, 0, "pool.ntp.org", "time.nist.gov");

#if ENABLE_CELLULAR
  ModemSerial.begin(MODEM_BAUD, SERIAL_8N1, MODEM_RX_PIN, MODEM_TX_PIN);
  powerOnModem();
  if (!wifiUp()) connectCellular();
  lastCellularAttempt = millis();
#endif

  Serial.println("=================================================");
  Serial.printf(" ResQ Hardware Tracker %s Started (MAC: %s)\n", SKETCH_VERSION, getHardwareId().c_str());
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
  if (ENABLE_WIFI && !wifiUp() && now - lastWifiAttempt >= WIFI_RETRY_INTERVAL_MS) {
    lastWifiAttempt = now;
    WiFi.reconnect();
  }

#if ENABLE_CELLULAR
  if (!wifiUp() && !cellularUp() && now - lastCellularAttempt >= CELLULAR_RETRY_INTERVAL_MS) {
    lastCellularAttempt = now;
    connectCellular();
  }

  // SIM balance: once a minute after boot, then every 6 hours. Only on mobile data.
  if (cellularUp() && (balanceChecked ? now - lastBalanceCheck >= BALANCE_INTERVAL_MS : now >= BALANCE_FIRST_DELAY_MS)) {
    lastBalanceCheck = now;
    balanceChecked = true;
    checkSimBalance();
  }
#endif

  recordHistoryPoint(); // on the board, whether or not there is signal

  // Buffered route points go up every few seconds; a backlog after an outage drains batch by batch
  if (online() && historyCount > 0 &&
      (now - lastHistoryFlush >= HISTORY_FLUSH_MS || historyCount > HISTORY_BATCH)) {
    lastHistoryFlush = now;
    flushHistory();
  }

  const unsigned long interval = wifiUp() ? WIFI_INTERVAL_MS : CELLULAR_INTERVAL_MS;
  // Send when there is a new fix, or a heartbeat so the app doesn't mark it Offline.
  if (online() && now - lastLocationAttempt >= interval &&
      (gps.location.isUpdated() || now - lastLocationSent >= HEARTBEAT_INTERVAL_MS)) {
    lastLocationAttempt = now;
    if (sendLocation()) lastLocationSent = now;
  }
}
