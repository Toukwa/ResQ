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
// Code dialed every 6 h to read the SIM's remaining load/data (shown in Fleet Management).
// Defaults to *123# (TNT / Smart). Uncomment to use a different one.
// #define SIM_BALANCE_USSD "*123#"
// Menu options pressed after SIM_BALANCE_USSD to reach the data balance (TNT: 10 then 1).
// #define SIM_DATA_MENU "10,1"
// Or a code that replies with the remaining mobile DATA directly (skips the menu).
// #define SIM_DATA_USSD "*123#"
