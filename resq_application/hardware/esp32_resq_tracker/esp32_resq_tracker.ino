#include <WiFi.h>
#include <HTTPClient.h>
#include <TinyGPSPlus.h>

// ---------- Fill these from vehicle_telemetry_schema.sql ----------
const char* WIFI_SSID = "ZTE_2.4G_6pppJp";
const char* WIFI_PASSWORD = "2v46htjp";
// This must be your computer/server's LAN IP, never localhost/127.0.0.1.
const char* TELEMETRY_URL = "http://192.168.1.9:3000/api/telemetry/vehicle-location";

// Approach 2: Secure Setup (Separate Hardware ID & Secret API Key)
// - Hardware ID: Physical MAC Address (obtained dynamically via WiFi.macAddress())
// - api_key: Unique secret token flashed into microcontroller to prove authenticity.
// Note: plate_no, vehicle_type, and dept_ID are NOT set here; department admins will assign them via the ResQ Admin Web App.
const char* DEVICE_API_KEY = "resq_token_9x8f7e6d5c"; 
const char* SMS_SECRET     = "resq_sms_secret_9x8f7e6d5c";

// NEO-M8L UART pins. Change these to the pins wired on your Type-C ESP32.
constexpr int GPS_RX_PIN = 16; // ESP32 RX <- GPS TX
constexpr int GPS_TX_PIN = 17; // ESP32 TX -> GPS RX (optional)
constexpr uint32_t GPS_BAUD = 9600;

// Enable only after wiring and powering the SIM7600X HAT correctly.
#define ENABLE_SIM7600 false
constexpr int MODEM_RX_PIN = 16; // ESP32 RX <- SIM7600 TX
constexpr int MODEM_TX_PIN = 17; // ESP32 TX -> SIM7600 RX
constexpr uint32_t MODEM_BAUD = 9600;
const char* SMS_DESTINATION = "+639XXXXXXXXX"; // number/chat gateway receiving SMS

constexpr unsigned long LOCATION_INTERVAL_MS = 600; // Transmit telemetry every 600ms
constexpr unsigned long WIFI_RETRY_INTERVAL_MS = 10000;
constexpr unsigned long SMS_FAILOVER_AFTER_MS = 30000;
constexpr unsigned long SMS_INTERVAL_MS = 60000;
constexpr unsigned long GPS_STATUS_INTERVAL_MS = 2000; // Serial monitor print interval

TinyGPSPlus gps;
HardwareSerial GPSSerial(1);
#if ENABLE_SIM7600
HardwareSerial ModemSerial(2);
#endif

unsigned long lastLocationAttempt = 0;
unsigned long lastWifiAttempt = 0;
unsigned long lastSuccessfulUpload = 0;
unsigned long lastSmsSent = 0;
unsigned long lastGpsStatusPrint = 0;

String getHardwareId() {
  String mac = WiFi.macAddress();
  mac.toUpperCase();
  return mac;
}

void connectWiFi() {
  if (WiFi.status() == WL_CONNECTED) return;
  Serial.print("[WIFI] Connecting to SSID: ");
  Serial.println(WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 10000) {
    delay(500);
    Serial.print(".");
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\n[WIFI] Connected! ESP32 IP: ");
    Serial.println(WiFi.localIP());
  } else {
    Serial.println("\n[WIFI] Wi-Fi connection pending. Continuing in background...");
  }
}

bool sendLocationOverWiFi() {
  if (WiFi.status() != WL_CONNECTED) return false;

  const String hardwareId = getHardwareId();
  // Fallback coordinates (0.0, 0.0) if indoor satellite fix is still acquiring
  const double latitude = gps.location.isValid() ? gps.location.lat() : 0.0;
  const double longitude = gps.location.isValid() ? gps.location.lng() : 0.0;
  const double speedKph = gps.speed.isValid() ? gps.speed.kmph() : 0.0;
  const double courseDeg = gps.course.isValid() ? gps.course.deg() : 0.0;
  const double altitudeM = gps.altitude.isValid() ? gps.altitude.meters() : 0.0;
  const unsigned int satellites = gps.satellites.isValid() ? gps.satellites.value() : 0;

  const time_t unixTime = time(nullptr);
  char timestampField[48] = "";
  if (unixTime > 1700000000) {
    snprintf(timestampField, sizeof(timestampField), "\"timestamp\":%lu000,", static_cast<unsigned long>(unixTime));
  }
  char payload[440];
  snprintf(payload, sizeof(payload),
    "{\"hardwareId\":\"%s\",\"deviceKey\":\"%s\",%s\"latitude\":%.7f,\"longitude\":%.7f,\"speedKph\":%.2f,\"courseDeg\":%.2f,\"altitudeM\":%.2f,\"satellites\":%u}",
    hardwareId.c_str(), DEVICE_API_KEY, timestampField,
    latitude, longitude, speedKph, courseDeg, altitudeM, satellites);

  HTTPClient http;
  http.setConnectTimeout(3000);
  http.setTimeout(4000);
  
  if (!http.begin(TELEMETRY_URL)) {
    Serial.println("[HTTP ERROR] Failed to initialize connection to TELEMETRY_URL");
    return false;
  }

  http.addHeader("Content-Type", "application/json");
  http.addHeader("X-Device-Key", DEVICE_API_KEY);
  http.addHeader("X-Hardware-ID", hardwareId.c_str());
  const int responseCode = http.POST(reinterpret_cast<uint8_t*>(payload), strlen(payload));
  http.end();

  if (responseCode >= 200 && responseCode < 300) {
    Serial.printf("[HTTP %d OK] Hardware [%s] Telemetry posted (Lat: %.5f, Lng: %.5f, Sats: %u)\n", 
                  responseCode, hardwareId.c_str(), latitude, longitude, satellites);
    return true;
  } else {
    Serial.printf("[HTTP ERROR %d] Hardware [%s] Could not post to %s\n", 
                  responseCode, hardwareId.c_str(), TELEMETRY_URL);
    return false;
  }
}

#if ENABLE_SIM7600
bool modemCommand(const char* command, const char* expected, unsigned long timeoutMs = 3000) {
  while (ModemSerial.available()) ModemSerial.read();
  ModemSerial.println(command);
  String response;
  const unsigned long started = millis();
  while (millis() - started < timeoutMs) {
    while (ModemSerial.available()) response += static_cast<char>(ModemSerial.read());
    if (response.indexOf(expected) >= 0) return true;
    delay(10);
  }
  Serial.printf("[MODEM] Command failed: %s\n", command);
  return false;
}

bool sendSmsFailover() {
  const String hardwareId = getHardwareId();
  char sms[280];
  snprintf(sms, sizeof(sms), "RESQ1,%s,%lu,%.7f,%.7f,%.2f,%.2f,%.2f,%u,%s",
    hardwareId.c_str(), static_cast<unsigned long>(time(nullptr)),
    gps.location.isValid() ? gps.location.lat() : 0.0,
    gps.location.isValid() ? gps.location.lng() : 0.0,
    gps.speed.isValid() ? gps.speed.kmph() : 0.0,
    gps.course.isValid() ? gps.course.deg() : 0.0,
    gps.altitude.isValid() ? gps.altitude.meters() : 0.0,
    gps.satellites.isValid() ? gps.satellites.value() : 0, SMS_SECRET);

  if (!modemCommand("AT", "OK") || !modemCommand("AT+CMGF=1", "OK")) return false;
  ModemSerial.print("AT+CMGS=\"");
  ModemSerial.print(SMS_DESTINATION);
  ModemSerial.println("\"");
  delay(250);
  ModemSerial.print(sms);
  ModemSerial.write(26); // Ctrl+Z submits the SMS
  return modemCommand("", "+CMGS", 15000);
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
  GPSSerial.begin(GPS_BAUD, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);
#if ENABLE_SIM7600
  ModemSerial.begin(MODEM_BAUD, SERIAL_8N1, MODEM_RX_PIN, MODEM_TX_PIN);
#endif
  connectWiFi();
  configTime(0, 0, "pool.ntp.org", "time.nist.gov");
  Serial.println("=================================================");
  Serial.printf(" ResQ Hardware Tracker Started (MAC: %s)\n", getHardwareId().c_str());
  Serial.println(" Hardware identity telemetry active ");
  Serial.println("=================================================");
}

void loop() {
  while (GPSSerial.available()) gps.encode(GPSSerial.read());

  const unsigned long now = millis();

  // Print GPS Status Indicators every 2 seconds
  if (now - lastGpsStatusPrint >= GPS_STATUS_INTERVAL_MS) {
    lastGpsStatusPrint = now;
    printGpsIndicator();
  }

  if (WiFi.status() != WL_CONNECTED && now - lastWifiAttempt >= WIFI_RETRY_INTERVAL_MS) {
    lastWifiAttempt = now;
    connectWiFi();
  }

  // Send telemetry every 600ms as long as Wi-Fi is connected
  if (WiFi.status() == WL_CONNECTED && now - lastLocationAttempt >= LOCATION_INTERVAL_MS) {
    lastLocationAttempt = now;
    if (sendLocationOverWiFi()) lastSuccessfulUpload = now;
  }

#if ENABLE_SIM7600
  if (now - lastSuccessfulUpload >= SMS_FAILOVER_AFTER_MS && now - lastSmsSent >= SMS_INTERVAL_MS) {
    if (sendSmsFailover()) lastSmsSent = now;
  }
#endif
}