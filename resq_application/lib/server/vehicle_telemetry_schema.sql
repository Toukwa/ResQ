-- Run once against the resq_db database before starting server.js.
-- A vehicle belongs to a department through response_vehicle.dept_ID.
-- Do not store or accept a department ID from a tracker.

CREATE TABLE IF NOT EXISTS gps_device (
  vehicle_ID INT NOT NULL,
  api_key VARCHAR(128) NOT NULL,
  sms_secret VARCHAR(128) NOT NULL,
  is_active TINYINT(1) NOT NULL DEFAULT 1,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (vehicle_ID),
  CONSTRAINT fk_gps_device_vehicle
    FOREIGN KEY (vehicle_ID) REFERENCES response_vehicle(vehicle_ID)
    ON DELETE CASCADE,
  UNIQUE KEY uq_gps_device_api_key (api_key)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS vehicle_location (
  vehicle_ID INT NOT NULL,
  latitude DECIMAL(10,7) NOT NULL,
  longitude DECIMAL(10,7) NOT NULL,
  speed_kph DECIMAL(6,2) NULL,
  course_deg DECIMAL(6,2) NULL,
  altitude_m DECIMAL(8,2) NULL,
  satellites TINYINT UNSIGNED NULL,
  fix_timestamp DATETIME NOT NULL,
  received_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  source ENUM('wifi', 'sms') NOT NULL,
  PRIMARY KEY (vehicle_ID),
  CONSTRAINT fk_vehicle_location_vehicle
    FOREIGN KEY (vehicle_ID) REFERENCES response_vehicle(vehicle_ID)
    ON DELETE CASCADE,
  KEY idx_vehicle_location_received (received_at)
) ENGINE=InnoDB;

-- Create one unique credential pair for each installed tracker.
-- Use a long random value for both placeholders and copy them into the sketch.
INSERT INTO gps_device (vehicle_ID, api_key, sms_secret)
VALUES (1, 'REPLACE_WITH_LONG_WIFI_DEVICE_KEY', 'REPLACE_WITH_LONG_SMS_SECRET')
ON DUPLICATE KEY UPDATE api_key = VALUES(api_key), sms_secret = VALUES(sms_secret), is_active = 1;
