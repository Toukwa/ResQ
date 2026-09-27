const mysql = require('mysql2/promise');

async function updateNotificationsTable() {
  const db = mysql.createPool({
    host: 'localhost',
    user: 'root',
    password: '',
    database: 'resq_db',
    waitForConnections: true,
    connectionLimit: 10,
    queueLimit: 0,
    multipleStatements: true
  });

  try {
    console.log('Checking notifications table structure...');
    
    // Check if table exists
    const [tables] = await db.query("SHOW TABLES LIKE 'notifications'");
    
    if (tables.length === 0) {
      console.log('Creating notifications table...');
      await db.query(`
        CREATE TABLE notifications (
          notification_ID INT AUTO_INCREMENT PRIMARY KEY,
          recipient_ID INT NULL,
          title VARCHAR(255) NULL,
          message TEXT NOT NULL,
          notification_type VARCHAR(50) NULL,
          req_ID INT NULL,
          disp_ID INT NULL,
          is_read TINYINT(1) DEFAULT 0,
          read_at DATETIME NULL,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
          INDEX idx_recipient (recipient_ID),
          INDEX idx_read (is_read),
          INDEX idx_timestamp (created_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
      `);
      console.log('Notifications table created successfully!');
    } else {
      console.log('Notifications table exists, checking structure...');
      
      // Check columns
      const [columns] = await db.query("DESCRIBE notifications");
      const columnNames = columns.map(col => col.Field);
      
      console.log('Current columns:', columnNames);
      
      // Add missing columns if needed
      if (!columnNames.includes('recipient_ID')) {
        await db.query('ALTER TABLE notifications ADD COLUMN recipient_ID INT NULL');
        console.log('Added recipient_ID column');
      }
      
      if (!columnNames.includes('notification_type')) {
        await db.query('ALTER TABLE notifications ADD COLUMN notification_type VARCHAR(50) NULL');
        console.log('Added notification_type column');
      }
      
      if (!columnNames.includes('req_ID')) {
        await db.query('ALTER TABLE notifications ADD COLUMN req_ID INT NULL');
        console.log('Added req_ID column');
      }
      
      if (!columnNames.includes('disp_ID')) {
        await db.query('ALTER TABLE notifications ADD COLUMN disp_ID INT NULL');
        console.log('Added disp_ID column');
      }
      
      if (!columnNames.includes('is_read')) {
        await db.query('ALTER TABLE notifications ADD COLUMN is_read TINYINT(1) DEFAULT 0');
        console.log('Added is_read column');
      }
      
      if (!columnNames.includes('read_at')) {
        await db.query('ALTER TABLE notifications ADD COLUMN read_at DATETIME NULL');
        console.log('Added read_at column');
      }
      
      // Drop foreign key constraints if they exist
      try {
        await db.query('ALTER TABLE notifications DROP FOREIGN KEY notifications_ibfk_1');
        console.log('Dropped foreign key constraint');
      } catch (e) {
        // Ignore if constraint doesn't exist
        console.log('No foreign key constraint to drop or error dropping it');
      }
      
      // Ensure recipient_ID is nullable
      await db.query('ALTER TABLE notifications MODIFY recipient_ID INT NULL');
      console.log('Ensured recipient_ID is nullable');
      
      // Rename created_at to timestamp for consistency
      if (columnNames.includes('created_at') && !columnNames.includes('timestamp')) {
        await db.query('ALTER TABLE notifications CHANGE COLUMN created_at timestamp DATETIME DEFAULT CURRENT_TIMESTAMP');
        console.log('Renamed created_at to timestamp for consistency');
      }
    }
    
    console.log('Notifications table update completed successfully!');
  } catch (err) {
    console.error('Error updating notifications table:', err.message);
  } finally {
    await db.end();
  }
}

updateNotificationsTable();