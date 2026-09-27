# ResQ ESP32 tracker deployment

The tracker maps to one `response_vehicle` record through `VEHICLE_ID`. It does **not** send a department ID. The API finds the department from `response_vehicle.dept_ID`, so a tracker cannot claim another department by changing a payload field.

1. Run [`vehicle_telemetry_schema.sql`](../../lib/server/vehicle_telemetry_schema.sql) in MySQL. Change the sample `vehicle_ID = 1` and both credentials first.
2. In `esp32_resq_tracker.ino`, fill `WIFI_SSID`, `WIFI_PASSWORD`, the server computer's LAN IP in `TELEMETRY_URL`, `VEHICLE_ID`, and the two secrets.
3. In Arduino IDE, install **TinyGPSPlus** from Library Manager, select your ESP32 board and upload the sketch.
4. Wire GPS TX to `GPS_RX_PIN`, GPS RX to `GPS_TX_PIN` only if configuration commands are needed, and share GND. The NEO-M8L normally uses 9600 baud.
5. The Superadmin map updates on the `vehicleLocationUpdated` socket event, with a five-second polling fallback.

## SMS / chat fallback

After the SIM7600X is installed, set `ENABLE_SIM7600` to `true`, configure its UART pins and `SMS_DESTINATION`, and ensure the HAT has suitable independent power. The device sends a compact text such as:

`RESQ1,1,1760000000,13.1390000,123.7330000,24.50,185.20,10.00,9,secret`

Your SMS-to-chat provider or webhook should POST the exact incoming text as `{ "message": "..." }` to `POST /api/telemetry/sms-location`. That endpoint verifies the SMS secret, parses the position, and updates the same map record with source `sms`.

The current implementation intentionally uses local Wi-Fi only. It treats an unreachable ResQ server (not merely lack of public internet) as the failover condition. SMS starts after 30 seconds of failed uploads and is rate-limited to one message per minute.
