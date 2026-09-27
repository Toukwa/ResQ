/**
 * insert_esp32_test_data.js
 * 
 * Inserts ESP32 vehicle tracker test data into resq_db so the
 * dashboard/map can display a live vehicle pin without needing
 * the physical ESP32 hardware.
 * 
 * Run once:  node insert_esp32_test_data.js
 */

const mysql = require('mysql2/promise');

const DB_CONFIG = {
  host: 'localhost',
  user: 'root',
  password: '',
  database: 'resq_db',
};

// ---- Test data matching the ESP32 sketch defaults ----
const API_KEY  = 'resq-esp32-test-key-abc123def456';
const SMS_KEY  = 'resq-esp32-sms-secret-xyz789';

// Iriga City coordinates (near the city center)
const TEST_VEHICLES = [
  {
    vehicle_ID: 1,
    plate_no:   'BFP-001',
    vehicle_type: 'Fire Truck',
    dept_ID:    null, // will be resolved to BFP department
    dept_name:  'BFP',
    latitude:   13.4228,
    longitude:  123.4130,
    speed_kph:  35.50,
    course_deg: 90.00,
    altitude_m: 52.00,
    satellites: 8,
  },
  {
    vehicle_ID: 2,
    plate_no:   'PNP-001',
    vehicle_type: 'Patrol Car',
    dept_ID:    null,
    dept_name:  'PNP',
    latitude:   13.4195,
    longitude:  123.4155,
    speed_kph:  0,
    course_deg: 0,
    altitude_m: 48.00,
    satellites: 10,
  },
  {
    vehicle_ID: 3,
    plate_no:   'CDRRMO-001',
    vehicle_type: 'Ambulance',
    dept_ID:    null,
    dept_name:  'CDRRMO',
    latitude:   13.4250,
    longitude:  123.4100,
    speed_kph:  55.20,
    course_deg: 180.00,
    altitude_m: 50.00,
    satellites: 7,
  },
];

(async () => {
  let conn;
  try {
    conn = await mysql.createConnection(DB_CONFIG);
    console.log('[✓] Connected to resq_db\n');

    // ──────────────────────────────────────────
    // 1. Ensure the gps_device & vehicle_location tables exist
    // ──────────────────────────────────────────
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
    console.log('[✓] gps_device table ready');

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
    console.log('[✓] vehicle_location table ready\n');

    // ──────────────────────────────────────────
    // 2. Look up existing departments
    // ──────────────────────────────────────────
    const [departments] = await conn.query('SELECT dept_ID, deptName FROM department');
    const deptMap = {};
    for (const d of departments) {
      deptMap[d.deptName.toUpperCase()] = d.dept_ID;
    }
    console.log('[i] Departments found:', Object.keys(deptMap).length ? Object.entries(deptMap).map(([k,v]) => `${k}(${v})`).join(', ') : '(none)');

    // ──────────────────────────────────────────
    // 3. Insert/update vehicles & GPS data
    // ──────────────────────────────────────────
    for (const v of TEST_VEHICLES) {
      // Resolve department ID
      const deptId = deptMap[v.dept_name.toUpperCase()] || null;

      if (!deptId) {
        console.log(`[!] No department "${v.dept_name}" found — skipping vehicle ${v.plate_no}. Make sure departments exist in the DB.`);
        continue;
      }

      // Insert or update response_vehicle
      await conn.query(`
        INSERT INTO response_vehicle (vehicle_ID, plate_no, vehicle_type, dept_ID, status)
        VALUES (?, ?, ?, ?, 'Available')
        ON DUPLICATE KEY UPDATE
          plate_no     = VALUES(plate_no),
          vehicle_type = VALUES(vehicle_type),
          dept_ID      = VALUES(dept_ID)
      `, [v.vehicle_ID, v.plate_no, v.vehicle_type, deptId]);
      console.log(`[✓] Vehicle ${v.plate_no} (ID ${v.vehicle_ID}) → dept ${v.dept_name} (${deptId})`);

      // Insert GPS device credential
      await conn.query(`
        INSERT INTO gps_device (vehicle_ID, api_key, sms_secret)
        VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE
          api_key    = VALUES(api_key),
          sms_secret = VALUES(sms_secret),
          is_active  = 1
      `, [v.vehicle_ID, `${API_KEY}-v${v.vehicle_ID}`, `${SMS_KEY}-v${v.vehicle_ID}`]);
      console.log(`[✓] GPS device registered for vehicle ${v.vehicle_ID}`);

      // Insert test vehicle location (simulated GPS fix in Iriga City)
      await conn.query(`
        INSERT INTO vehicle_location
          (vehicle_ID, latitude, longitude, speed_kph, course_deg, altitude_m, satellites, fix_timestamp, received_at, source)
        VALUES (?, ?, ?, ?, ?, ?, ?, NOW(), NOW(), 'wifi')
        ON DUPLICATE KEY UPDATE
          latitude      = VALUES(latitude),
          longitude     = VALUES(longitude),
          speed_kph     = VALUES(speed_kph),
          course_deg    = VALUES(course_deg),
          altitude_m    = VALUES(altitude_m),
          satellites    = VALUES(satellites),
          fix_timestamp = NOW(),
          received_at   = NOW(),
          source        = 'wifi'
      `, [v.vehicle_ID, v.latitude, v.longitude, v.speed_kph, v.course_deg, v.altitude_m, v.satellites]);
      console.log(`[✓] Location set: ${v.latitude}, ${v.longitude} (${v.speed_kph} km/h)\n`);
    }

    // ──────────────────────────────────────────
    // 4. Verify — show what's in the DB now
    // ──────────────────────────────────────────
    const [result] = await conn.query(`
      SELECT v.vehicle_ID, v.plate_no, v.vehicle_type, d.deptName,
             l.latitude, l.longitude, l.speed_kph, l.fix_timestamp, l.source
      FROM response_vehicle v
      LEFT JOIN department d ON v.dept_ID = d.dept_ID
      LEFT JOIN vehicle_location l ON v.vehicle_ID = l.vehicle_ID
      ORDER BY v.vehicle_ID
    `);

    console.log('══════════════════════════════════════════════');
    console.log('  VEHICLES NOW IN DATABASE');
    console.log('══════════════════════════════════════════════');
    for (const r of result) {
      const loc = r.latitude ? `${r.latitude}, ${r.longitude}` : 'No GPS';
      console.log(`  ID ${r.vehicle_ID} | ${r.plate_no} | ${r.vehicle_type} | ${r.deptName || 'N/A'} | ${loc} | ${r.source || '-'}`);
    }
    console.log('══════════════════════════════════════════════\n');
    console.log('[✓] Done! Refresh your ResQ dashboard to see the vehicles on the map.');

  } catch (err) {
    console.error('[✗] Error:', err.message);
    if (err.code === 'ER_NO_SUCH_TABLE') {
      console.error('\n    → Make sure the core resq_db tables (department, response_vehicle) exist.');
      console.error('      Run your main database setup SQL first.\n');
    }
  } finally {
    if (conn) await conn.end();
  }
})();
