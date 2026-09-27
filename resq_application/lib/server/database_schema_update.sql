-- Enhanced System Logs Table for Comprehensive Audit Logging
-- This script updates the system_logs table to track all system events while maintaining data privacy

-- Drop existing system_logs table if it exists
DROP TABLE IF EXISTS system_logs;

-- Create enhanced system_logs table
CREATE TABLE system_logs (
  log_id INT AUTO_INCREMENT PRIMARY KEY,
  user_ID INT NULL,
  user_role VARCHAR(50) NULL,
  action VARCHAR(50) NOT NULL,
  entity_type VARCHAR(50) NOT NULL,
  entity_id INT NULL,
  status VARCHAR(20) NULL,
  details TEXT NULL,
  ip_address VARCHAR(45) NULL,
  user_agent VARCHAR(255) NULL,
  timestamp DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_user_action (user_ID, action),
  INDEX idx_entity (entity_type, entity_id),
  INDEX idx_timestamp (timestamp),
  INDEX idx_action_type (action, entity_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Valid actions: LOGIN, LOGOUT, REGISTER, CREATE, UPDATE, DELETE, DISPATCH, ARRIVE, RESOLVE, STATUS_CHANGE, VIEW, EXPORT, etc.
-- Valid entity_types: USER, INCIDENT, VEHICLE, DEPARTMENT, DISPATCH, NOTIFICATION, SYSTEM, etc.

-- Add comments for documentation
ALTER TABLE system_logs 
  COMMENT = 'Comprehensive audit log for all system events - ID-based logging for privacy';

-- Create a view for admin-friendly audit log display
CREATE OR REPLACE VIEW admin_audit_logs AS
SELECT
  sl.log_id,
  sl.user_ID,
  sl.user_role,
  r.userName as user_name,
  r.role as user_role_display,
  sl.action,
  sl.entity_type,
  sl.entity_id,
  sl.status,
  sl.details,
  sl.ip_address,
  sl.user_agent,
  sl.timestamp,
  CASE
    WHEN sl.entity_type = 'INCIDENT' THEN (SELECT incType FROM emergency_request WHERE Req_ID = sl.entity_id)
    WHEN sl.entity_type = 'VEHICLE' THEN (SELECT plate_no FROM response_vehicle WHERE vehicle_ID = sl.entity_id)
    WHEN sl.entity_type = 'DEPARTMENT' THEN (SELECT deptName FROM department WHERE dept_ID = sl.entity_id)
    WHEN sl.entity_type = 'DISPATCH' THEN (SELECT CONCAT('Dispatch #', Disp_ID) FROM dispatch_event WHERE Disp_ID = sl.entity_id)
    ELSE NULL
  END as entity_reference
FROM system_logs sl
LEFT JOIN resident r ON sl.user_ID = r.Citizen_ID;

-- Grant appropriate permissions (adjust based on your database user setup)
-- GRANT SELECT, INSERT ON system_logs TO 'your_app_user'@'localhost';

-- Set default value of plate_no, vehicle_type, and dept_ID to NULL for response_vehicle (Unassigned state upon detection)
ALTER TABLE response_vehicle MODIFY COLUMN plate_no VARCHAR(50) NULL DEFAULT NULL;
ALTER TABLE response_vehicle MODIFY COLUMN vehicle_type VARCHAR(50) NULL DEFAULT NULL;
ALTER TABLE response_vehicle MODIFY COLUMN dept_ID INT NULL DEFAULT NULL;
ALTER TABLE response_vehicle ADD COLUMN IF NOT EXISTS HardwareID_mapping VARCHAR(100) NULL DEFAULT NULL;
ALTER TABLE gps_device ADD COLUMN IF NOT EXISTS hardware_id VARCHAR(100) NULL DEFAULT NULL;

-- Reset existing response_vehicle rows to default unassigned values
UPDATE response_vehicle SET plate_no = NULL, vehicle_type = NULL, dept_ID = NULL;
-- GRANT SELECT ON admin_audit_logs TO 'your_admin_user'@'localhost';