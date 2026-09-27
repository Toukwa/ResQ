-- Create notifications table for user notification system
CREATE TABLE IF NOT EXISTS notifications (
  notification_ID INT AUTO_INCREMENT PRIMARY KEY,
  recipient_ID INT NULL,
  title VARCHAR(255) NULL,
  message TEXT NOT NULL,
  notification_type VARCHAR(50) NULL,
  req_ID INT NULL,
  disp_ID INT NULL,
  is_read TINYINT(1) DEFAULT 0,
  read_at DATETIME NULL,
  timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_recipient (recipient_ID),
  INDEX idx_read (is_read),
  INDEX idx_timestamp (timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;