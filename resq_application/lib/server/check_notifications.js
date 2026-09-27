const mysql = require('mysql2/promise');

async function checkNotifications() {
  const db = mysql.createPool({
    host: 'localhost',
    user: 'root',
    password: '',
    database: 'resq_db',
    waitForConnections: true,
    connectionLimit: 10,
    queueLimit: 0
  });

  try {
    console.log('Checking notifications table structure...');
    const [columns] = await db.query('DESCRIBE notifications');
    console.log('Table columns:', columns.map(col => col.Field));
    
    console.log('\nChecking notification data...');
    const [notifications] = await db.query('SELECT * FROM notifications ORDER BY timestamp DESC LIMIT 10');
    
    if (notifications.length > 0) {
      console.log('Recent notifications:');
      notifications.forEach(notif => {
        console.log(`- ID: ${notif.notification_ID}, Recipient: ${notif.recipient_ID}, Title: ${notif.title}, Message: ${notif.message?.substring(0, 50)}...`);
      });
    } else {
      console.log('No notifications found in database');
    }
    
    console.log('\nChecking users for notification testing...');
    const [users] = await db.query('SELECT Citizen_ID, userName, role FROM resident LIMIT 5');
    console.log('Available users:', users.map(u => `ID: ${u.Citizen_ID}, Name: ${u.userName}, Role: ${u.role}`));
    
  } catch (err) {
    console.error('Error checking notifications:', err.message);
  } finally {
    await db.end();
  }
}

checkNotifications();