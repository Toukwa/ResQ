# ResQ ESP32 tracker

ESP32 + NEO-M8L GPS, with an optional SIM7600 for mobile data. The tracker writes its position straight to the Firebase Realtime Database. It uses Wi-Fi when connected and falls back to the SIM's mobile data when `ENABLE_CELLULAR` is on.

## Setup

1. Copy `secrets.example.h` to `secrets.h` and fill in `WIFI_SSID`, `WIFI_PASSWORD` and `DEVICE_API_KEY` (at least 6 characters). `secrets.h` is not committed.
2. In Arduino IDE, install **TinyGPSPlus** and **ArduinoHttpClient** from Library Manager, select your ESP32 board and upload.
3. Wire GPS TX to `GPS_RX_PIN` (4) and share GND. GPS RX to `GPS_TX_PIN` (2) is optional. The NEO-M8L uses 9600 baud.
4. On first boot the tracker creates its own Firebase account (`tracker-<mac>@resq-tracker.app`, password = `DEVICE_API_KEY`). It then appears in the admin app as an **Unassigned** vehicle. Set its plate, type and department there.

## Enabling the SIM card

Once the SIM7600 is wired, has its own suitable power supply, and holds a SIM with load/data:

1. Install **TinyGSM** from Library Manager.
2. In `esp32_resq_tracker.ino`, set `#define ENABLE_CELLULAR true`.
3. In `secrets.h`, set `GSM_APN` for your network:
   - Globe / TM: `internet.globe.com.ph`
   - Smart / TNT: `internet`
   - DITO: `internet.dito.ph`

   Set `SIM_PIN` only if the SIM is PIN-locked.
4. Check the modem pins in the sketch match your wiring: `MODEM_RX_PIN` (16, from SIM7600 TX), `MODEM_TX_PIN` (17, to SIM7600 RX). Set `MODEM_PWRKEY_PIN` to the GPIO wired to PWRKEY, or leave it at `-1` if the module powers on by itself.
5. Re-upload and open Serial Monitor (115200). You should see `[SIM] Mobile data connected.`

Updates are sent every 3 s on Wi-Fi and every 10 s on mobile data to save load.

## Troubleshooting

- `[SIM] Modem not responding`: check wiring, power and the RX/TX pins (they may be swapped).
- `[SIM] Mobile data connection failed`: check `GSM_APN` and that the SIM has load/data.
