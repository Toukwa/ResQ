/**
 * register_esp32_device.js
 *
 * Registers the real ESP32 tracker (vehicle_ID = 1) in the gps_device
 * table using the EXACT api_key and sms_secret from the flashed .ino sketch
 * so the server authenticates incoming telemetry.
 *
 * Run once:  node register_esp32_device.js
 */

const mysql = require('mysql2/promise');

const DB_CONFIG = {
  host: 'localhost',
  user: 'root',
  password: '',
  database: 'resq_db',
};

// Must match exactly what is compiled into the ESP32 sketch
const VEHICLE_ID    = 1;
const DEVICE_API_KEY = 'REPLACE_WITH_LONG_WIFI_DEVICE_KEY';
const SMS_SECRET     = 'REPLACE_WITH_LONG_SMS_SECRET';

(async () => {
  let conn;
  try {
    conn = await mysql.createConnection(DB_CONFIG);
    console.log('[✓] Connected to resq_db\n');

    // 1. Ensure telemetry tables exist
    await conn.query(`
      CREATE TABLE IF NOT EXISTS gps_device (
        vehicle_ID  INT NOT NULL,
        api_key     VARCHAR(128) NOT NULL,
        sms_secret  VARCHAR(128) NOT NULL,
        is_active   TINYINT(1) NOT NULL DEFAULT 1,
        created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (vehicle_ID),
        CONSTRAINT fk_gps_device_vehicle
          FOREIGN KEY (vehicle_ID) REFERENCES response_vehicle(vehicle_ID)
          ON DELETE CASCADE,
        UNIQUE KEY uq_gps_device_api_key (api_key)
      ) ENGINE=InnoDB
    `);

    await conn.query(`
      CREATE TABLE IF NOT EXISTS vehicle_location (
        vehicle_ID      INT NOT NULL,
        latitude        DECIMAL(10,7) NOT NULL,
        longitude       DECIMAL(10,7) NOT NULL,
        speed_kph       DECIMAL(6,2) NULL,
        course_deg      DECIMAL(6,2) NULL,
        altitude_m      DECIMAL(8,2) NULL,
        satellites      TINYINT UNSIGNED NULL,
        fix_timestamp   DATETIME NOT NULL,
        received_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        source          ENUM('wifi', 'sms') NOT NULL,
        PRIMARY KEY (vehicle_ID),
        CONSTRAINT fk_vehicle_location_vehicle
          FOREIGN KEY (vehicle_ID) REFERENCES response_vehicle(vehicle_ID)
          ON DELETE CASCADE,
        KEY idx_vehicle_location_received (received_at)
      ) ENGINE=InnoDB
    `);
    console.log('[✓] Telemetry tables ready');

    // 2. Make sure vehicle 1 exists in response_vehicle
    const [existing] = await conn.query(
      'SELECT vehicle_ID, plate_no, dept_ID FROM response_vehicle WHERE vehicle_ID = ?',
      [VEHICLE_ID]
    );

    if (existing.length === 0) {
      await conn.query(`
        INSERT INTO response_vehicle (vehicle_ID, plate_no, vehicle_type, dept_ID, status)
        VALUES (?, NULL, NULL, NULL, 'Available')
      `, [VEHICLE_ID]);
      console.log(`[✓] Created response_vehicle row (ID ${VEHICLE_ID}, default unassigned state)`);
    } else {
      console.log(`[✓] Vehicle ${VEHICLE_ID} already exists: ${existing[0].plate_no}`);
    }

    // 3. Register the device with the EXACT keys from the ESP32 sketch
    await conn.query(`
      INSERT INTO gps_device (vehicle_ID, api_key, sms_secret, is_active)
      VALUES (?, ?, ?, 1)
      ON DUPLICATE KEY UPDATE
        api_key    = VALUES(api_key),
        sms_secret = VALUES(sms_secret),
        is_active  = 1
    `, [VEHICLE_ID, DEVICE_API_KEY, SMS_SECRET]);

    console.log(`[✓] GPS device registered for vehicle ${VEHICLE_ID}`);
    console.log(`    api_key    = "${DEVICE_API_KEY}"`);
    console.log(`    sms_secret = "${SMS_SECRET}"`);

    // 4. Verify the full chain
    const [verify] = await conn.query(`
      SELECT gd.vehicle_ID, gd.api_key, gd.is_active,
             v.plate_no, v.vehicle_type, d.deptName,
             l.latitude, l.longitude, l.fix_timestamp
      FROM gps_device gd
      INNER JOIN response_vehicle v ON v.vehicle_ID = gd.vehicle_ID
      LEFT JOIN department d ON v.dept_ID = d.dept_ID
      LEFT JOIN vehicle_location l ON v.vehicle_ID = l.vehicle_ID
      WHERE gd.vehicle_ID = ?
    `, [VEHICLE_ID]);

    if (verify.length) {
      const r = verify[0];
      console.log('\n══════════════════════════════════════════════');
      console.log('  ESP32 DEVICE REGISTRATION — VERIFIED');
      console.log('══════════════════════════════════════════════');
      console.log(`  Vehicle ID : ${r.vehicle_ID}`);
      console.log(`  Plate      : ${r.plate_no}`);
      console.log(`  Type       : ${r.vehicle_type}`);
      console.log(`  Department : ${r.deptName || 'N/A'}`);
      console.log(`  API Key    : ${r.api_key}`);
      console.log(`  Active     : ${r.is_active ? 'YES' : 'NO'}`);
      console.log(`  Last GPS   : ${r.latitude ? `${r.latitude}, ${r.longitude} @ ${r.fix_timestamp}` : 'Waiting for first fix...'}`);
      console.log('══════════════════════════════════════════════');
      console.log('\n[✓] Your ESP32 can now send telemetry to:');
      console.log('    POST http://<YOUR_IP>:3000/api/telemetry/vehicle-location');
      console.log('    with header  X-Device-Key: ' + DEVICE_API_KEY);
      console.log('\n    Once the ESP32 gets a GPS fix and hits this endpoint,');
      console.log('    the vehicle will appear on your dashboard map.\n');
    }

  } catch (err) {
    console.error('[✗] Error:', err.message);
  } finally {
    if (conn) await conn.end();
  }
})();
