// Copy this file to secrets.h and fill in your values.
#pragma once

const char* WIFI_SSID = "your-wifi-name";
const char* WIFI_PASSWORD = "your-wifi-password";

// Password of this tracker's Firebase account (at least 6 characters).
const char* DEVICE_API_KEY = "choose-a-long-random-secret";

// ---- SIM card (only used when ENABLE_CELLULAR is true) ----
// Your network's mobile-data APN. Common ones in the Philippines:
//   Globe / TM: "internet.globe.com.ph"   Smart / TNT: "internet"   DITO: "internet.dito.ph"
const char* GSM_APN = "internet.globe.com.ph";
const char* GSM_USER = "";
const char* GSM_PASS = "";
const char* SIM_PIN = ""; // leave empty if the SIM has no PIN lock
